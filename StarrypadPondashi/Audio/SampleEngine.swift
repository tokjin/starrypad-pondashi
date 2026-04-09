import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

private extension Notification.Name {
    static let avAudioEngineConfiguration = Notification.Name(rawValue: "AVAudioEngineConfigurationChangeNotification")
}

/// フェーダー／ノブの 0…1 を `AVAudioUnitTimePitch.rate` にマップ（左=低速、中央=1 倍、右=高速）。
enum PlaybackRateMapping {
    static func rate(fromNormalized u: Float) -> Float {
        let c = max(0, min(1, u))
        let r = 0.5 * Float(pow(2.0, Double(c) * 2.0))
        return max(0.03125, min(32, r))
    }
}

private final class ActiveVoice {
    let player: AVAudioPlayerNode
    let mixer: AVAudioMixerNode
    let slotIndex: Int
    let chokeGroup: Int?
    let startTime: Date
    let file: AVAudioFile
    /// 現在スケジュール中のバッファがファイル内のどこから始まるか（ループの各周で更新）
    var segmentStartFrame: AVAudioFramePosition
    let loop: Bool
    let fadeOutMs: Double

    init(
        player: AVAudioPlayerNode,
        mixer: AVAudioMixerNode,
        slotIndex: Int,
        chokeGroup: Int?,
        file: AVAudioFile,
        segmentStartFrame: AVAudioFramePosition,
        loop: Bool,
        fadeOutMs: Double
    ) {
        self.player = player
        self.mixer = mixer
        self.slotIndex = slotIndex
        self.chokeGroup = chokeGroup
        self.startTime = Date()
        self.file = file
        self.segmentStartFrame = segmentStartFrame
        self.loop = loop
        self.fadeOutMs = fadeOutMs
    }
}

/// `… → dynamics → reverb → delay → 出力`。センドは各ユニットの wetDryMix（並列合算は AVAudioMixerNode の多入力で無音になり得るため直列に変更）。
final class SampleEngine: ObservableObject {
    private let engine = AVAudioEngine()
    private let mainMixer: AVAudioMixerNode
    private let timePitch: AVAudioUnitTimePitch
    private let dynamicsUnit: AVAudioUnitEffect
    private let reverbNode: AVAudioUnitReverb
    private let delayNode: AVAudioUnitDelay
    private var voicePool: [(player: AVAudioPlayerNode, mixer: AVAudioMixerNode, inUse: Bool)] = []
    private var activeVoices: [ActiveVoice] = []
    private let voiceQueue = DispatchQueue(label: "StarrypadPondashi.SampleEngine")
    private var configurationObserver: NSObjectProtocol?

    /// 各ボイス mixer に適用する定位（モノラル素材では `mainMixer.pan` だけでは効きにくいため）
    private var currentVoicePan: Float = 0

    @Published private(set) var playingSlots: Set<Int> = []

    var isEngineRunning: Bool { engine.isRunning }

    private let poolSize = 48

    init() {
        mainMixer = engine.mainMixerNode

        let tp = AVAudioUnitTimePitch()
        timePitch = tp
        engine.attach(tp)
        timePitch.rate = 1
        timePitch.pitch = 0

        let dynDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let dyn = AVAudioUnitEffect(audioComponentDescription: dynDesc)
        dynamicsUnit = dyn
        engine.attach(dyn)

        let rev = AVAudioUnitReverb()
        reverbNode = rev
        engine.attach(rev)
        rev.loadFactoryPreset(.mediumHall)
        rev.wetDryMix = 0

        let del = AVAudioUnitDelay()
        delayNode = del
        engine.attach(del)
        del.wetDryMix = 0
        del.delayTime = 0.35
        del.feedback = 28
        del.lowPassCutoff = 18_000

        for _ in 0 ..< poolSize {
            let player = AVAudioPlayerNode()
            let mix = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(mix)
            mix.outputVolume = 1
            mix.pan = 0
            voicePool.append((player, mix, false))
        }

        mainMixer.outputVolume = 1
        mainMixer.pan = 0

        engine.disconnectNodeInput(engine.outputNode)
        engine.connect(mainMixer, to: timePitch, format: nil)
        engine.connect(timePitch, to: dyn, format: nil)
        engine.connect(dyn, to: rev, format: nil)
        engine.connect(rev, to: del, format: nil)
        engine.connect(del, to: engine.outputNode, format: nil)

        configureDynamicsDefaults(dyn)
        setDynamicsAmount(0.35)

        engine.prepare()

        let hwFormat = mainMixer.outputFormat(forBus: 0)
        let voiceFormat: AVAudioFormat
        if hwFormat.sampleRate > 0, hwFormat.channelCount > 0 {
            voiceFormat = hwFormat
        } else if let fb = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) {
            voiceFormat = fb
        } else {
            voiceFormat = mainMixer.outputFormat(forBus: 0)
        }

        for i in 0 ..< poolSize {
            let player = voicePool[i].player
            let mix = voicePool[i].mixer
            engine.connect(player, to: mix, format: voiceFormat)
            engine.connect(mix, to: mainMixer, format: voiceFormat)
        }

        engine.isAutoShutdownEnabled = false
        engine.prepare()
        try? engine.start()

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .avAudioEngineConfiguration,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.recoverFromEngineConfigurationChange()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    private func recoverFromEngineConfigurationChange() {
        stopAll()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            try? engine.start()
        }
    }

    private func configureDynamicsDefaults(_ unit: AVAudioUnitEffect) {
        let au = unit.audioUnit
        AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.05, 0)
    }

    /// 0…1 をコンプのかかり具合にマップ（しきい値とメイクアップ）。UI の「なし」相当は `applyFaderRolesToEngine` 側で 0 → バイパス。
    func setDynamicsAmount(_ normalized: Float) {
        let v = max(0, min(1, normalized))
        let au = dynamicsUnit.audioUnit
        if v < 0.02 {
            dynamicsUnit.auAudioUnit.shouldBypassEffect = true
            return
        }
        dynamicsUnit.auAudioUnit.shouldBypassEffect = false
        let thresholdDb: AudioUnitParameterValue = -8 - (1 - v) * 35
        let makeupDb: AudioUnitParameterValue = v * 6
        AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, thresholdDb, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, makeupDb, 0)
    }

    func setPan(_ pan: Float) {
        let p = max(-1, min(1, pan))
        currentVoicePan = p
        mainMixer.pan = 0
        voiceQueue.sync {
            for i in voicePool.indices {
                voicePool[i].mixer.pan = p
            }
        }
    }

    func setPitchCents(_ cents: Float) {
        timePitch.pitch = max(-2400, min(2400, cents))
    }

    /// フェーダー／ノブ 0…1 を倍速に変換して `timePitch.rate` に設定（ピッチとは独立）。
    func setPlaybackRateNormalized(_ normalized: Float) {
        timePitch.rate = PlaybackRateMapping.rate(fromNormalized: normalized)
    }

    /// 再生速度ロール未割当時は 1 倍に戻す。
    func setPlaybackRateUnity() {
        timePitch.rate = 1
    }

    func setReverbSend(_ normalized: Float) {
        let v = max(0, min(1, normalized))
        reverbNode.wetDryMix = v * 100
    }

    func setDelaySend(_ normalized: Float) {
        let v = max(0, min(1, normalized))
        delayNode.wetDryMix = v * 100
    }

    func setDelayFeedback(_ normalized: Float) {
        let v = max(0, min(1, normalized))
        delayNode.feedback = v * 100
    }

    func setDelayTime(_ normalized: Float) {
        let v = max(0, min(1, normalized))
        delayNode.delayTime = TimeInterval(0.05 + Double(v) * 1.45)
    }

    func setMasterVolume(_ v: Float) {
        mainMixer.outputVolume = max(0, min(1, v))
    }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            try? engine.start()
        }
    }

    func setOutputDevice(_ deviceID: AudioDeviceID?) {
        guard let unit = halOutputAudioUnit() else {
            ensureEngineRunning()
            return
        }

        stopAll()
        if engine.isRunning {
            engine.stop()
        }
        defer {
            engine.prepare()
            ensureEngineRunning()
        }

        let resolved = deviceID ?? AudioOutputDevices.defaultOutputDeviceID()
        guard resolved != 0 else { return }

        var dev = resolved
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private func halOutputAudioUnit() -> AudioUnit? {
        let obj = engine.outputNode.auAudioUnit as NSObject
        let raw = obj.value(forKey: "audioUnit")
        return raw as? AudioUnit
    }

    func hasActiveVoice(for slotIndex: Int) -> Bool {
        voiceQueue.sync {
            activeVoices.contains { $0.slotIndex == slotIndex }
        }
    }

    func stopAll() {
        voiceQueue.sync {
            for v in activeVoices {
                v.player.stop()
                v.mixer.outputVolume = 0
                freePoolSlot(for: v)
            }
            activeVoices.removeAll()
            for i in voicePool.indices { voicePool[i].inUse = false }
            publishPlaying()
        }
    }

    func stopSlot(_ slotIndex: Int, fadeOutMs: Double = 0) {
        voiceQueue.async {
            let targets = self.activeVoices.filter { $0.slotIndex == slotIndex }
            for v in targets {
                self.stopVoice(v, fadeOutMs: fadeOutMs)
            }
        }
    }

    func stopSlotImmediate(_ slotIndex: Int) {
        voiceQueue.sync {
            let targets = self.activeVoices.filter { $0.slotIndex == slotIndex }
            for v in targets {
                self.stopVoiceImmediate(v)
            }
            self.publishPlaying()
        }
    }

    private func stopVoiceImmediate(_ voice: ActiveVoice) {
        voice.player.stop()
        voice.mixer.outputVolume = 0
        activeVoices.removeAll { $0 === voice }
        freePoolSlot(for: voice)
    }

    private func stopVoice(_ voice: ActiveVoice, fadeOutMs: Double) {
        if fadeOutMs <= 1 {
            stopVoiceImmediate(voice)
            publishPlaying()
            return
        }
        let start = voice.mixer.outputVolume
        let steps = max(2, Int(fadeOutMs / 20))
        let interval = fadeOutMs / Double(steps) / 1000
        for step in 1 ... steps {
            DispatchQueue.global().asyncAfter(deadline: .now() + interval * Double(step)) { [weak self] in
                self?.voiceQueue.async {
                    guard self?.activeVoices.contains(where: { $0 === voice }) == true else { return }
                    let t = Float(step) / Float(steps)
                    voice.mixer.outputVolume = start * (1 - t)
                    if step == steps {
                        voice.player.stop()
                        voice.mixer.outputVolume = 0
                        self?.activeVoices.removeAll { $0 === voice }
                        self?.freePoolSlot(for: voice)
                        self?.publishPlaying()
                    }
                }
            }
        }
    }

    private func freePoolSlot(for voice: ActiveVoice) {
        if let idx = voicePool.firstIndex(where: { $0.player === voice.player }) {
            voicePool[idx].inUse = false
        }
    }

    private func publishPlaying() {
        let set = Set(activeVoices.map(\.slotIndex))
        DispatchQueue.main.async {
            self.playingSlots = set
        }
    }

    /// ミリ秒オフセットをフレームに換算し、再生可能な区間を返す（ファイル末尾を超える場合は `nil`）。
    private static func playableSegment(file: AVAudioFile, startOffsetMs: Double) -> (start: AVAudioFramePosition, frames: AVAudioFrameCount)? {
        let len = file.length
        guard len > 0 else { return nil }
        let sr = file.fileFormat.sampleRate
        let offsetMs = max(0, startOffsetMs)
        let rawStart: AVAudioFramePosition = (sr > 0 && offsetMs > 0) ? AVAudioFramePosition((offsetMs / 1000.0) * sr) : 0
        let start = max(0, min(rawStart, len - 1))
        let remaining = len - start
        guard remaining > 0 else { return nil }
        return (start, AVAudioFrameCount(remaining))
    }

    func play(
        file: AVAudioFile,
        slotIndex: Int,
        slotVolume: Float,
        velocity: Int,
        maxPolyphony: Int,
        stealOldest: Bool,
        loop: Bool,
        fadeInMs: Double,
        fadeOutMs: Double,
        startOffsetMs: Double,
        chokeGroup: Int?
    ) {
        voiceQueue.async {
            self.ensureEngineRunning()
            guard self.engine.isRunning else { return }

            if let g = chokeGroup {
                let victims = self.activeVoices.filter { $0.chokeGroup == g && $0.slotIndex != slotIndex }
                for v in victims {
                    self.stopVoiceImmediate(v)
                }
            }

            while self.activeVoices.count >= maxPolyphony, stealOldest {
                guard let oldest = self.activeVoices.min(by: { $0.startTime < $1.startTime }) else { break }
                self.stopVoiceImmediate(oldest)
            }

            guard let segment = Self.playableSegment(file: file, startOffsetMs: startOffsetMs) else { return }

            guard let idx = self.voicePool.firstIndex(where: { !$0.inUse }) else { return }
            self.voicePool[idx].inUse = true
            let player = self.voicePool[idx].player
            let mix = self.voicePool[idx].mixer

            player.stop()
            mix.outputVolume = 0
            mix.pan = self.currentVoicePan

            let vel = max(0, min(127, velocity))
            let velScale = Float(vel) / 127
            let targetVol = max(0, min(1, slotVolume * velScale))

            let voice = ActiveVoice(
                player: player,
                mixer: mix,
                slotIndex: slotIndex,
                chokeGroup: chokeGroup,
                file: file,
                segmentStartFrame: segment.start,
                loop: loop,
                fadeOutMs: fadeOutMs
            )
            self.activeVoices.append(voice)

            if fadeInMs > 1 {
                let steps = max(2, Int(fadeInMs / 20))
                let interval = fadeInMs / Double(steps) / 1000
                for step in 1 ... steps {
                    DispatchQueue.global().asyncAfter(deadline: .now() + interval * Double(step)) { [weak self] in
                        self?.voiceQueue.async {
                            guard self?.activeVoices.contains(where: { $0 === voice }) == true else { return }
                            let t = Float(step) / Float(steps)
                            mix.outputVolume = targetVol * t
                        }
                    }
                }
            } else {
                mix.outputVolume = targetVol
            }

            if loop {
                self.scheduleLoop(player: player, file: file, voice: voice, fadeOutMs: fadeOutMs, nextStartFrame: segment.start)
            } else {
                player.scheduleSegment(file, startingFrame: segment.start, frameCount: segment.frames, at: nil) { [weak self] in
                    self?.voiceQueue.async {
                        guard let self else { return }
                        guard self.activeVoices.contains(where: { $0 === voice }) else { return }
                        if fadeOutMs > 1 {
                            self.stopVoice(voice, fadeOutMs: fadeOutMs)
                        } else {
                            voice.player.stop()
                            voice.mixer.outputVolume = 0
                            self.activeVoices.removeAll { $0 === voice }
                            self.freePoolSlot(for: voice)
                            self.publishPlaying()
                        }
                    }
                }
            }
            player.play()
            self.publishPlaying()
        }
    }

    /// `nextStartFrame` は初回のみインスペクタの開始位置、以降は先頭からループ。
    private func scheduleLoop(player: AVAudioPlayerNode, file: AVAudioFile, voice: ActiveVoice, fadeOutMs: Double, nextStartFrame: AVAudioFramePosition) {
        let len = file.length
        guard len > 0 else { return }
        let start = max(0, min(nextStartFrame, len - 1))
        let remaining = len - start
        guard remaining > 0 else { return }
        voice.segmentStartFrame = start
        player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(remaining), at: nil) { [weak self] in
            self?.voiceQueue.async {
                guard let self else { return }
                guard self.activeVoices.contains(where: { $0 === voice }) else { return }
                self.scheduleLoop(player: player, file: file, voice: voice, fadeOutMs: fadeOutMs, nextStartFrame: 0)
            }
        }
    }

    /// 指定スロットの先頭アクティブボイスについて、再生位置（秒）とファイル長（秒）を返す。
    func playbackTimeline(for slotIndex: Int) -> (positionSec: Double, durationSec: Double)? {
        voiceQueue.sync {
            guard let v = activeVoices.first(where: { $0.slotIndex == slotIndex }) else { return nil }
            return Self.playbackTimeline(for: v)
        }
    }

    private static func playbackTimeline(for v: ActiveVoice) -> (positionSec: Double, durationSec: Double)? {
        let len = v.file.length
        let sr = v.file.fileFormat.sampleRate
        guard len > 0, sr > 0 else { return nil }
        let durationSec = Double(len) / sr
        guard let nodeTime = v.player.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let pt = v.player.playerTime(forNodeTime: nodeTime),
              pt.isSampleTimeValid else {
            let pos = Double(v.segmentStartFrame) / sr
            return (min(pos, durationSec), durationSec)
        }
        // `sampleTime` は「セグメント先頭からの相対」か「ファイル上の絶対」のどちらか。両方足すとシーク直後に二重計上になる。
        let st = pt.sampleTime
        let combined = v.segmentStartFrame + st
        let absFrame: AVAudioFramePosition
        if combined > len - 1 {
            absFrame = max(0, min(st, len - 1))
        } else {
            absFrame = max(0, min(combined, len - 1))
        }
        return (Double(absFrame) / sr, durationSec)
    }

    /// 0…1 をファイル上の位置にマップして再スケジュール（レイヤー再生時は該当スロットの全ボイス）。
    /// UI からのシーク直後に `playbackTimeline` が古い状態を読まないよう、同期で完了させる。
    func seek(slotIndex: Int, normalized: Float) {
        let u = max(0, min(1, normalized))
        voiceQueue.sync {
            let targets = self.activeVoices.filter { $0.slotIndex == slotIndex }
            for v in targets {
                self.rescheduleVoiceFromPosition(v, normalized: u)
            }
        }
    }

    private func rescheduleVoiceFromPosition(_ voice: ActiveVoice, normalized: Float) {
        let file = voice.file
        let len = file.length
        guard len > 0 else { return }
        let target = AVAudioFramePosition(Double(len) * Double(normalized))
        let start = max(0, min(target, len - 1))
        let remaining = len - start
        guard remaining > 0 else { return }

        voice.player.stop()
        voice.segmentStartFrame = start
        let vol = voice.mixer.outputVolume

        if voice.loop {
            scheduleLoop(player: voice.player, file: file, voice: voice, fadeOutMs: voice.fadeOutMs, nextStartFrame: start)
        } else {
            voice.player.scheduleSegment(
                file,
                startingFrame: start,
                frameCount: AVAudioFrameCount(remaining),
                at: nil
            ) { [weak self] in
                self?.voiceQueue.async {
                    guard let self else { return }
                    guard self.activeVoices.contains(where: { $0 === voice }) else { return }
                    if voice.fadeOutMs > 1 {
                        self.stopVoice(voice, fadeOutMs: voice.fadeOutMs)
                    } else {
                        voice.player.stop()
                        voice.mixer.outputVolume = 0
                        self.activeVoices.removeAll { $0 === voice }
                        self.freePoolSlot(for: voice)
                        self.publishPlaying()
                    }
                }
            }
        }
        voice.mixer.outputVolume = vol
        voice.player.play()
    }
}
