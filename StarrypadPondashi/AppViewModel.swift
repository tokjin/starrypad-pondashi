import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation
import os
import SwiftUI

private let vmAudioLog = Logger(subsystem: "com.starrypad.pondashi", category: "AppViewModel")

/// スタッターで同じ位置へ戻す間隔（秒）。長いほど1回の繰り返しで聞こえる幅が広い。
private let stutterRepeatIntervalSec: TimeInterval = 0.13

/// パッド 16 個分のノートキャプチャ
struct PadCaptureSession {
    var bankIndex: Int
    var step: Int
    var notes: [Int]

    init(bankIndex: Int) {
        self.bankIndex = bankIndex
        step = 0
        notes = Array(repeating: -1, count: 16)
    }

    mutating func consume(note: Int) -> Bool {
        guard step < 16 else { return true }
        notes[step] = note
        step += 1
        return step >= 16
    }
}

final class AppViewModel: ObservableObject {
    let midi = StarrypadMIDIClient()
    let engine = SampleEngine()

    /// UI 用（`SampleEngine` の再生中スロットを反映）
    @Published private(set) var playingSlots: Set<Int> = []
    /// トランスポート一時停止（`SampleEngine.isTransportPaused` と同期）
    @Published private(set) var isTransportPaused: Bool = false

    @Published var kit: PresetKit
    @Published var profile: StarrypadProfile
    @Published var uiBank: Int = 0
    @Published var midiLog: [String] = []
    @Published var faderDisplay: [Float] = [1, 0.5]
    @Published var knobDisplay: [Float] = [0.5, 0.5]
    @Published var capturePadSession: PadCaptureSession?
    @Published var captureControlMessage: String?
    @Published var captureFaderIndex: Int?
    @Published var captureKnobIndex: Int?
    /// ハードの論理ボタン（停止・バンク・再生/一時停止など）のノート学習
    @Published var captureButtonIndex: Int?
    /// 直近に叩かれたパッド（短時間ハイライト用）
    @Published private(set) var lastHitSlot: Int?
    /// A/B「予約」モードで次に切り替えるパッド（UI ハイライト用）
    @Published private(set) var pendingQueueSlot: Int?

    /// YouTube / yt-dlp 取り込み中（空パッドのインスペクタ用）
    @Published var youtubeImportInProgress = false
    @Published var youtubeImportError: String?

    /// 音声出力デバイス一覧（設定画面用）
    @Published private(set) var audioOutputDeviceList: [(id: AudioDeviceID, name: String)] = []
    /// `nil` = システム既定
    @Published var selectedAudioOutputDeviceID: AudioDeviceID?

    private static let audioOutputDeviceDefaultsKey = "selectedAudioOutputDeviceID"

    private var cancellables = Set<AnyCancellable>()
    private var padHitClearTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?
    private let logLimit = 80
    /// ハードボタンが CC のとき、連続値でトグルが多重発火しないよう直前値を保持（ボタン添字）
    private var lastHardwareButtonCCValue: [Int: Int] = [:]
    /// A/B（buttons 4/5）が「押されている」状態（予約モード用）
    private var sideButtonHeld: Set<Int> = []
    /// スタッター用：スロットごとの正規化シーク位置
    private var stutterAnchorNormalized: [Int: Float] = [:]
    private var stutterTimer: Timer?

    init() {
        kit = AppStatePersistence.loadKitIfPresent() ?? PresetKit.makeEmpty()
        profile = AppStatePersistence.loadProfileIfPresent() ?? ProfileStore.loadBundledDefault()
        applyFaderRolesToEngine()

        midi.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ev in
                self?.handleMIDI(ev)
            }
            .store(in: &cancellables)

        engine.$playingSlots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                self?.playingSlots = s
            }
            .store(in: &cancellables)

        engine.$isTransportPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] v in
                self?.isTransportPaused = v
            }
            .store(in: &cancellables)

        $kit.dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { k in try? AppStatePersistence.saveKit(k) }
            .store(in: &cancellables)

        $profile.dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { p in try? AppStatePersistence.saveProfile(p) }
            .store(in: &cancellables)

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            try? AppStatePersistence.saveKit(self.kit)
            try? AppStatePersistence.saveProfile(self.profile)
        }

        refreshAudioOutputDevices()
        if let v = UserDefaults.standard.object(forKey: Self.audioOutputDeviceDefaultsKey) as? UInt32, v != 0 {
            let aid = AudioDeviceID(v)
            if audioOutputDeviceList.contains(where: { $0.id == aid }) {
                selectedAudioOutputDeviceID = aid
            }
        }
        // 起動直後に setOutputDevice すると stop/start が走り無音になることがあるため、
        // 保存済みの出力先は SettingsView.onAppear の applySavedAudioOutputDevice で適用する。
    }

    func refreshAudioOutputDevices() {
        audioOutputDeviceList = AudioOutputDevices.listOutputDevices()
    }

    func selectAudioOutputDevice(_ id: AudioDeviceID?) {
        vmAudioLog.info("selectAudioOutputDevice id=\(id.map { String($0) } ?? "nil(system)")")
        selectedAudioOutputDeviceID = id
        engine.setOutputDevice(id)
        if let id {
            UserDefaults.standard.set(UInt32(id), forKey: Self.audioOutputDeviceDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.audioOutputDeviceDefaultsKey)
        }
    }

    /// 保存済みの選択をエンジンへ再適用する。起動直後の `init` では呼ばず、設定を開いたときなどに使う。
    func applySavedAudioOutputDevice() {
        let saved = selectedAudioOutputDeviceID
        vmAudioLog.info("applySavedAudioOutputDevice id=\(saved.map { String($0) } ?? "nil")")
        engine.setOutputDevice(saved)
    }

    /// バックグラウンドで `AVAudioEngine` が内部停止したあとにフォーカスが戻ったときの軽い復帰（毎回は走らない）。
    func recoverEngineIfStoppedAfterBackground() {
        guard !engine.isEngineRunning else { return }
        vmAudioLog.warning("recoverEngineIfStoppedAfterBackground — engine not running, re-applying output")
        let saved = selectedAudioOutputDeviceID
        engine.setOutputDevice(saved)
    }

    /// 保存した出力先を破棄し、システム既定に戻す。音が別デバイスに流れている疑いがあるときに使う。
    func clearSavedOutputDeviceAndUseSystemDefault() {
        vmAudioLog.info("clearSavedOutputDeviceAndUseSystemDefault")
        selectedAudioOutputDeviceID = nil
        UserDefaults.standard.removeObject(forKey: Self.audioOutputDeviceDefaultsKey)
        engine.setOutputDevice(nil)
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    /// フェーダー・ノブの役割に応じて PAN・コンプ・ピッチ・再生速度・エフェクト・マスター出力をエンジンへ反映
    func applyFaderRolesToEngine() {
        let fRoles = kit.faderRoles
        let kRoles = kit.knobRoles

        var panSamples: [Float] = []
        for i in 0 ..< min(2, fRoles.count, faderDisplay.count) where fRoles[i] == .pan {
            panSamples.append(faderDisplay[i] * 2 - 1)
        }
        for i in 0 ..< min(2, kRoles.count, knobDisplay.count) where kRoles[i] == .pan {
            panSamples.append(knobDisplay[i] * 2 - 1)
        }
        let pan: Float
        if panSamples.isEmpty {
            pan = 0
        } else {
            let s = panSamples.reduce(0, +) / Float(panSamples.count)
            pan = max(-1, min(1, s))
        }
        engine.setPan(pan)

        var dynSamples: [Float] = []
        for i in 0 ..< min(2, fRoles.count, faderDisplay.count) where fRoles[i] == .dynamics {
            dynSamples.append(faderDisplay[i])
        }
        for i in 0 ..< min(2, kRoles.count, knobDisplay.count) where kRoles[i] == .dynamics {
            dynSamples.append(knobDisplay[i])
        }
        let dyn: Float
        if dynSamples.isEmpty {
            dyn = 0
        } else {
            dyn = dynSamples.reduce(0, +) / Float(dynSamples.count)
        }
        engine.setDynamicsAmount(dyn)

        var pitchSamples: [Float] = []
        for i in 0 ..< min(2, fRoles.count, faderDisplay.count) where fRoles[i] == .pitch {
            pitchSamples.append(faderDisplay[i])
        }
        for i in 0 ..< min(2, kRoles.count, knobDisplay.count) where kRoles[i] == .pitch {
            pitchSamples.append(knobDisplay[i])
        }
        if pitchSamples.isEmpty {
            engine.setPitchCents(0)
        } else {
            let u = pitchSamples.reduce(0, +) / Float(pitchSamples.count)
            let cents = Float((Double(u) - 0.5) * 2400)
            engine.setPitchCents(cents)
        }

        var playbackSamples: [Float] = []
        for i in 0 ..< min(2, fRoles.count, faderDisplay.count) where fRoles[i] == .playbackRate {
            playbackSamples.append(faderDisplay[i])
        }
        for i in 0 ..< min(2, kRoles.count, knobDisplay.count) where kRoles[i] == .playbackRate {
            playbackSamples.append(knobDisplay[i])
        }
        if playbackSamples.isEmpty {
            engine.setPlaybackRateUnity()
        } else {
            let u = playbackSamples.reduce(0, +) / Float(playbackSamples.count)
            engine.setPlaybackRateNormalized(u)
        }

        var revSamples: [Float] = []
        for i in 0 ..< min(2, fRoles.count, faderDisplay.count) where fRoles[i] == .reverbSend {
            revSamples.append(faderDisplay[i])
        }
        for i in 0 ..< min(2, kRoles.count, knobDisplay.count) where kRoles[i] == .reverbSend {
            revSamples.append(knobDisplay[i])
        }
        engine.setReverbSend(revSamples.isEmpty ? 0 : revSamples.reduce(0, +) / Float(revSamples.count))

        var dlySendSamples: [Float] = []
        for i in 0 ..< min(2, fRoles.count, faderDisplay.count) where fRoles[i] == .delaySend {
            dlySendSamples.append(faderDisplay[i])
        }
        for i in 0 ..< min(2, kRoles.count, knobDisplay.count) where kRoles[i] == .delaySend {
            dlySendSamples.append(knobDisplay[i])
        }
        engine.setDelaySend(dlySendSamples.isEmpty ? 0 : dlySendSamples.reduce(0, +) / Float(dlySendSamples.count))

        var dlyFbSamples: [Float] = []
        for i in 0 ..< min(2, fRoles.count, faderDisplay.count) where fRoles[i] == .delayFeedback {
            dlyFbSamples.append(faderDisplay[i])
        }
        for i in 0 ..< min(2, kRoles.count, knobDisplay.count) where kRoles[i] == .delayFeedback {
            dlyFbSamples.append(knobDisplay[i])
        }
        engine.setDelayFeedback(dlyFbSamples.isEmpty ? 0 : dlyFbSamples.reduce(0, +) / Float(dlyFbSamples.count))

        var dlyTimeSamples: [Float] = []
        for i in 0 ..< min(2, fRoles.count, faderDisplay.count) where fRoles[i] == .delayTime {
            dlyTimeSamples.append(faderDisplay[i])
        }
        for i in 0 ..< min(2, kRoles.count, knobDisplay.count) where kRoles[i] == .delayTime {
            dlyTimeSamples.append(knobDisplay[i])
        }
        if dlyTimeSamples.isEmpty {
            engine.setDelayTime(0.2)
        } else {
            engine.setDelayTime(dlyTimeSamples.reduce(0, +) / Float(dlyTimeSamples.count))
        }

        var eqLowSamples: [Float] = []
        var eqMidSamples: [Float] = []
        var eqHighSamples: [Float] = []
        for i in 0 ..< min(2, kRoles.count, knobDisplay.count) {
            switch kRoles[i] {
            case .eqLow: eqLowSamples.append(knobDisplay[i])
            case .eqMid: eqMidSamples.append(knobDisplay[i])
            case .eqHigh: eqHighSamples.append(knobDisplay[i])
            default: break
            }
        }
        let lowDb = eqLowSamples.isEmpty ? 0 : EQToneKnobMapping.gainDb(fromNormalized: eqLowSamples.reduce(0, +) / Float(eqLowSamples.count))
        let midDb = eqMidSamples.isEmpty ? 0 : EQToneKnobMapping.gainDb(fromNormalized: eqMidSamples.reduce(0, +) / Float(eqMidSamples.count))
        let highDb = eqHighSamples.isEmpty ? 0 : EQToneKnobMapping.gainDb(fromNormalized: eqHighSamples.reduce(0, +) / Float(eqHighSamples.count))
        engine.setEQTone(lowDb: lowDb, midDb: midDb, highDb: highDb)

        syncMasterOutputToEngine()
    }

    func syncMasterOutputToEngine() {
        let m = max(0, min(1, kit.masterVolume))
        let hasHardwareMaster =
            kit.faderRoles.contains(.master) ||
            kit.knobRoles.contains(where: { $0 == .master || $0 == .gain })
        let g: Float
        if hasHardwareMaster {
            g = max(0, min(1, m * masterFaderFactor() * masterKnobFactor()))
        } else {
            g = m
        }
        engine.setMasterVolume(g)
    }

    /// マスターに割り当てたフェーダー値の積（割当なしは 1）
    func masterFaderFactor() -> Float {
        let roles = kit.faderRoles
        var product: Float = 1
        var any = false
        for i in 0 ..< min(2, roles.count, faderDisplay.count) where roles[i] == .master {
            product *= faderDisplay[i]
            any = true
        }
        return any ? product : 1
    }

    /// マスター音量／バス音量に割り当てたノブ値の積（割当なしは 1）
    func masterKnobFactor() -> Float {
        let roles = kit.knobRoles
        var product: Float = 1
        var any = false
        for i in 0 ..< min(2, roles.count, knobDisplay.count) {
            switch roles[i] {
            case .master, .gain:
                product *= knobDisplay[i]
                any = true
            case .none, .pan, .dynamics, .pitch, .reverbSend, .delaySend, .delayFeedback, .delayTime, .playbackRate, .eqLow, .eqMid, .eqHigh:
                break
            }
        }
        return any ? product : 1
    }

    func registerPadHit(_ slot: Int) {
        lastHitSlot = slot
        padHitClearTask?.cancel()
        padHitClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            await MainActor.run {
                self?.lastHitSlot = nil
            }
        }
    }

    func assignAudio(url: URL, toSlot slot: Int) throws {
        let path = try PresetStore.importAudioFile(from: url)
        let bookmark = try? PresetStore.bookmark(for: URL(fileURLWithPath: path))
        guard slot >= 0, slot < PresetKit.slotCount else { return }
        var k = kit
        k.slots[slot].filePath = path
        k.slots[slot].fileBookmark = bookmark
        k.slots[slot].fileDisplayName = nil
        kit = k
    }

    func clearYoutubeImportError() {
        youtubeImportError = nil
    }

    /// 空パッド向け: `yt-dlp -x --audio-format mp3` で取得して Samples に登録
    func importYouTubeToPad(rawInput: String, slot: Int) {
        Task { @MainActor in
            youtubeImportInProgress = true
            youtubeImportError = nil
            defer { youtubeImportInProgress = false }
            do {
                let watchURL = try YouTubeAudioImport.resolveWatchURL(from: rawInput)
                let (mp3, tempDir) = try await Task.detached(priority: .userInitiated) {
                    try YouTubeAudioImport.downloadAudioMP3(youtubeURL: watchURL)
                }.value
                defer { try? FileManager.default.removeItem(at: tempDir) }
                try assignAudio(url: mp3, toSlot: slot)
            } catch {
                youtubeImportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// DnD 等：コピーをバックグラウンドで行い、完了後にメインでキットを更新
    func assignAudioAsync(from url: URL, toSlot slot: Int) {
        guard slot >= 0, slot < PresetKit.slotCount else { return }
        Task.detached(priority: .userInitiated) {
            do {
                let path = try PresetStore.importAudioFile(from: url)
                let bookmark = try? PresetStore.bookmark(for: URL(fileURLWithPath: path))
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    var k = self.kit
                    k.slots[slot].filePath = path
                    k.slots[slot].fileBookmark = bookmark
                    k.slots[slot].fileDisplayName = nil
                    self.kit = k
                }
            } catch {}
        }
    }

    func clearSlot(_ slot: Int) {
        guard slot >= 0, slot < PresetKit.slotCount else { return }
        var k = kit
        k.slots[slot].filePath = nil
        k.slots[slot].fileBookmark = nil
        k.slots[slot].fileDisplayName = nil
        kit = k
    }

    /// ソースの内容で先を上書きし、ソースは空スロットにする（通常ドロップ＝置き換え）。
    func replacePadSlot(from source: Int, to dest: Int) {
        guard source != dest, source >= 0, dest >= 0, source < PresetKit.slotCount, dest < PresetKit.slotCount else { return }
        var k = kit
        k.slots[dest] = k.slots[source].replacingIndex(dest)
        k.slots[source] = SlotConfig.empty(index: source)
        kit = k
    }

    /// ソースの設定を先へコピーし、ソースはそのまま（⌥+ドロップ＝複製）。
    func duplicatePadSlot(from source: Int, to dest: Int) {
        guard source != dest, source >= 0, dest >= 0, source < PresetKit.slotCount, dest < PresetKit.slotCount else { return }
        var k = kit
        k.slots[dest] = k.slots[source].replacingIndex(dest)
        kit = k
    }

    func setFader(index: Int, value: Float) {
        guard index >= 0, index < faderDisplay.count else { return }
        faderDisplay[index] = max(0, min(1, value))
        applyFaderRolesToEngine()
    }

    func setFaderRole(index: Int, role: FaderRole) {
        guard index >= 0, index < 2 else { return }
        var k = kit
        while k.faderRoles.count < 2 { k.faderRoles.append(.none) }
        k.faderRoles[index] = role
        kit = k
        applyFaderRolesToEngine()
    }

    func setKnobRole(index: Int, role: KnobRole) {
        guard index >= 0, index < 2 else { return }
        var k = kit
        while k.knobRoles.count < 2 { k.knobRoles.append(.none) }
        k.knobRoles[index] = role
        kit = k
        applyFaderRolesToEngine()
    }

    func setKnob(index: Int, value: Float) {
        guard index >= 0, index < knobDisplay.count else { return }
        knobDisplay[index] = max(0, min(1, value))
        applyFaderRolesToEngine()
    }

    /// インスペクタでスロット音量を変更したとき、再生中のボイスへ即反映
    func applyLiveSlotVolume(slotIndex: Int) {
        guard kit.slots.indices.contains(slotIndex) else { return }
        engine.applySlotVolumeLive(slotIndex: slotIndex, slotVolume: kit.slots[slotIndex].volume)
    }

    func triggerSlot(_ slot: Int, velocity: Int = 127) {
        guard slot >= 0, slot < PresetKit.slotCount else { return }
        if isQueueModifierActive {
            pendingQueueSlot = slot
            return
        }
        playSlotInternal(slot, velocity: velocity)
    }

    /// キュー予約を挟まずに再生（内部・クロスフェード完了後）
    private func playSlotInternal(_ slot: Int, velocity: Int = 127) {
        stopStutterEffect()
        applyFaderRolesToEngine()
        registerPadHit(slot)

        let cfg = kit.slots[slot]
        guard let fileURL = PresetStore.resolveURL(for: cfg) else { return }
        guard let file = try? AVAudioFile(forReading: fileURL) else { return }

        let active = engine.hasActiveVoice(for: slot)
        if active {
            switch cfg.retriggerBehavior {
            case .layer:
                break
            case .stop:
                engine.stopSlotImmediate(slot)
                return
            case .fadeOut:
                engine.stopSlot(slot, fadeOutMs: cfg.fadeOutMs)
                return
            case .restart:
                engine.stopSlotImmediate(slot)
            }
        }

        let vel = cfg.velocitySensitive ? velocity : 127
        engine.play(
            file: file,
            slotIndex: slot,
            slotVolume: cfg.volume,
            velocity: vel,
            maxPolyphony: kit.maxPolyphony,
            stealOldest: kit.stealOldestVoice,
            loop: cfg.loop,
            fadeInMs: cfg.fadeInMs,
            fadeOutMs: cfg.fadeOutMs,
            startOffsetMs: cfg.startOffsetMs,
            chokeGroup: cfg.chokeGroup
        )
    }

    private var isQueueModifierActive: Bool {
        for idx in sideButtonHeld where idx == 4 || idx == 5 {
            if modeForSideButton(idx) == .queueNextPad { return true }
        }
        return false
    }

    private func modeForSideButton(_ buttonIndex: Int) -> SideButtonBehavior {
        switch buttonIndex {
        case 4: return kit.sideButtonAMode
        case 5: return kit.sideButtonBMode
        default: return .panic
        }
    }

    private func commitQueueTransition() {
        guard let slot = pendingQueueSlot else { return }
        pendingQueueSlot = nil
        if playingSlots.isEmpty {
            playSlotInternal(slot, velocity: 127)
            return
        }
        let fadeMs = 450.0
        engine.fadeOutAllThen(fadeOutMs: fadeMs) { [weak self] in
            self?.playSlotInternal(slot, velocity: 127)
        }
    }

    private func startStutterEffect() {
        stopStutterEffect()
        stutterAnchorNormalized.removeAll()
        for slot in playingSlots {
            if let t = engine.playbackTimeline(for: slot), t.durationSec > 0 {
                stutterAnchorNormalized[slot] = Float(t.positionSec / t.durationSec)
            }
        }
        guard !stutterAnchorNormalized.isEmpty else { return }
        stutterTimer = Timer.scheduledTimer(withTimeInterval: stutterRepeatIntervalSec, repeats: true) { [weak self] _ in
            guard let self else { return }
            for (slot, u) in self.stutterAnchorNormalized {
                self.engine.seek(slotIndex: slot, normalized: u)
            }
        }
    }

    private func stopStutterEffect() {
        stutterTimer?.invalidate()
        stutterTimer = nil
        stutterAnchorNormalized.removeAll()
    }

    private func ccKeyPressed(_ v: Int) -> Bool {
        v >= 64 || (v > 0 && v < 64)
    }

    /// 再生中の全ボイスを一時停止／再開（ハードの再生／一時停止ボタンと同じ）
    func toggleTransportPause() {
        engine.toggleTransportPause()
    }

    func stopAll() {
        stopStutterEffect()
        engine.stopAll()
    }

    func panic() {
        stopStutterEffect()
        engine.stopAll()
    }

    func startPadCapture(bank: Int) {
        capturePadSession = PadCaptureSession(bankIndex: bank)
        captureFaderIndex = nil
        captureKnobIndex = nil
        captureButtonIndex = nil
        captureControlMessage = "バンク \(bank + 1): 左下を PAD1 とし、右→上の順で 16 パッドを押してください"
    }

    func cancelCapture() {
        capturePadSession = nil
        captureFaderIndex = nil
        captureKnobIndex = nil
        captureButtonIndex = nil
        captureControlMessage = nil
    }

    func startFaderCapture(index: Int) {
        captureFaderIndex = index
        captureKnobIndex = nil
        captureButtonIndex = nil
        captureControlMessage = "フェーダー \(index + 1) を動かしてください（CC を記録）"
    }

    func startKnobCapture(index: Int) {
        captureKnobIndex = index
        captureFaderIndex = nil
        captureButtonIndex = nil
        captureControlMessage = "ノブ \(index + 1) を回してください（CC を記録）"
    }

    /// プロファイルの `buttons[index]` に記録（0〜3=従来、4=A、5=B）
    func startButtonCapture(index: Int) {
        guard index >= 0 else { return }
        capturePadSession = nil
        captureFaderIndex = nil
        captureKnobIndex = nil
        captureButtonIndex = index
        captureControlMessage = "「\(Self.hardwareButtonRoleName(index: index))」に割り当てるパッド（ノート）またはトランスポートボタン（CC）を操作してください"
    }

    private static func hardwareButtonRoleName(index: Int) -> String {
        switch index {
        case 0: return "全停止"
        case 1: return "バンクを次へ"
        case 2: return "バンクを前へ"
        case 3: return "再生／一時停止"
        case 4: return "A ボタン"
        case 5: return "B ボタン"
        default: return "ボタン \(index + 1)"
        }
    }

    func exportProfileJSON() -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(profile) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveProfileToApplicationSupport() throws {
        let dir = try ProfileStore.applicationProfilesURL()
        let url = dir.appendingPathComponent("\(profile.name).json")
        let data = try JSONEncoder().encode(profile)
        try data.write(to: url, options: .atomic)
    }

    func savePresetPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(kit.name).json"
        panel.begin { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            try? PresetStore.save(self.kit, to: url)
        }
    }

    func loadPresetPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] r in
            guard r == .OK, let url = panel.url?.resolvingSymlinksInPath(), let self else { return }
            if let k = try? PresetStore.load(from: url) {
                self.kit = k
                self.applyFaderRolesToEngine()
            }
        }
    }

    private func logLine(_ s: String) {
        midiLog.insert(s, at: 0)
        if midiLog.count > logLimit { midiLog.removeLast() }
    }

    private func handleMIDI(_ ev: MIDIRawEvent) {
        switch ev {
        case let .noteOn(ch, n, v):
            logLine("NoteOn ch=\(ch + 1) note=\(n) vel=\(v)")
        case let .noteOff(ch, n, v):
            logLine("NoteOff ch=\(ch + 1) note=\(n) vel=\(v)")
        case let .controlChange(ch, cc, val):
            logLine("CC ch=\(ch + 1) cc=\(cc) val=\(val)")
        case let .programChange(ch, p):
            logLine("PC ch=\(ch + 1) prog=\(p)")
        }

        if var cap = capturePadSession {
            if case let .noteOn(ch, note, vel) = ev, vel > 0 {
                if profile.midiChannel == nil || profile.midiChannel == ch {
                    let done = cap.consume(note: note)
                    capturePadSession = cap
                    if done { applyCapturedPadsFromSession() }
                }
            }
            return
        }

        if let fi = captureFaderIndex {
            if case let .controlChange(ch, cc, _) = ev {
                if profile.midiChannel == nil || profile.midiChannel == ch {
                    var p = profile
                    while p.faders.count <= fi { p.faders.append(.cc(channel: nil, number: 0)) }
                    p.faders[fi] = .cc(channel: profile.midiChannel ?? ch, number: cc)
                    profile = p
                    captureFaderIndex = nil
                    captureControlMessage = "フェーダー \(fi + 1) を CC \(cc) に割り当てました"
                }
            }
            return
        }

        if let ki = captureKnobIndex {
            if case let .controlChange(ch, cc, _) = ev {
                if profile.midiChannel == nil || profile.midiChannel == ch {
                    var p = profile
                    while p.knobs.count <= ki { p.knobs.append(.cc(channel: nil, number: 0)) }
                    p.knobs[ki] = .cc(channel: profile.midiChannel ?? ch, number: cc)
                    profile = p
                    captureKnobIndex = nil
                    captureControlMessage = "ノブ \(ki + 1) を CC \(cc) に割り当てました"
                }
            }
            return
        }

        if let bi = captureButtonIndex {
            if case let .noteOn(ch, note, vel) = ev, vel > 0 {
                if profile.midiChannel == nil || profile.midiChannel == ch {
                    var p = profile
                    while p.buttons.count <= bi {
                        p.buttons.append(.cc(channel: nil, number: 0))
                    }
                    p.buttons[bi] = .note(channel: profile.midiChannel ?? ch, note: note)
                    profile = p
                    captureButtonIndex = nil
                    let label = Self.hardwareButtonRoleName(index: bi)
                    captureControlMessage = "「\(label)」をノート \(note)（CH \(ch + 1)）に割り当てました"
                }
            } else if case let .controlChange(ch, cc, _) = ev {
                if profile.midiChannel == nil || profile.midiChannel == ch {
                    var p = profile
                    while p.buttons.count <= bi {
                        p.buttons.append(.cc(channel: nil, number: 0))
                    }
                    p.buttons[bi] = .cc(channel: profile.midiChannel ?? ch, number: cc)
                    profile = p
                    captureButtonIndex = nil
                    let label = Self.hardwareButtonRoleName(index: bi)
                    captureControlMessage = "「\(label)」を CC \(cc)（CH \(ch + 1)）に割り当てました"
                }
            }
            return
        }

        switch ev {
        case let .programChange(ch, program):
            if profile.midiChannel == nil || profile.midiChannel == ch, let b = profile.bankFromProgramChange(program) {
                uiBank = b
            }
        case let .controlChange(ch, cc, val):
            handleControlChange(channel: ch, cc: cc, value: val)
        case let .noteOn(ch, note, velocity):
            handleNoteOn(channel: ch, note: note, velocity: velocity)
        case let .noteOff(ch, note, _):
            handleNoteOff(channel: ch, note: note)
        }
    }

    private func applyCapturedPadsFromSession() {
        guard var s = capturePadSession, s.step >= 16 else { return }
        var p = profile
        while p.banks.count <= s.bankIndex { p.banks.append(Array(repeating: 0, count: 16)) }
        p.banks[s.bankIndex] = s.notes
        profile = p
        capturePadSession = nil
        captureControlMessage = "パッドマップを保存しました（バンク \(s.bankIndex + 1)）"
    }

    /// PAN／EQ 系は MIDI 64 を中央（フラット）に、それ以外は 0…127 を 0…1 に線形マップ。
    private func knobNormalizedFromMidi(_ value: Int, role: KnobRole) -> Float {
        switch role {
        case .pan, .eqLow, .eqMid, .eqHigh:
            let t = max(-1, min(1, (Float(value) - 64) / 63))
            return max(0, min(1, (t + 1) / 2))
        default:
            return max(0, min(1, Float(value) / 127))
        }
    }

    private func handleControlChange(channel: Int, cc: Int, value: Int) {
        if let action = profile.bankSwitchHardwareAction(channel: channel, number: cc, isNote: false) {
            if case .cycleToNextBank = action {
                guard value >= 64 else { return }
            }
            applyBankSwitchHardwareAction(action)
            return
        }
        if let role = profile.roleForControlChange(channel: channel, cc: cc) {
            switch role {
            case .fader(let i):
                if i < faderDisplay.count {
                    let v: Float
                    if kit.faderRoles.indices.contains(i), kit.faderRoles[i] == .pan {
                        let pan = max(-1, min(1, (Float(value) - 64) / 63))
                        v = max(0, min(1, (pan + 1) / 2))
                    } else {
                        v = max(0, min(1, Float(value) / 127))
                    }
                    faderDisplay[i] = v
                    applyFaderRolesToEngine()
                }
            case .knob(let i):
                if i < knobDisplay.count {
                    let role = kit.knobRoles.indices.contains(i) ? kit.knobRoles[i] : KnobRole.none
                    let v = knobNormalizedFromMidi(value, role: role)
                    knobDisplay[i] = v
                    applyFaderRolesToEngine()
                }
            case .button(let i):
                if i >= 4 {
                    handleSideButtonCC(buttonIndex: i, value: value)
                } else {
                    handleHardwareButtonCC(buttonIndex: i, value: value)
                }
            }
        }
    }

    /// A/B（CC）。押下／離脱を検出してモードごとに処理。
    private func handleSideButtonCC(buttonIndex: Int, value: Int) {
        let mode = modeForSideButton(buttonIndex)
        let prev = lastHardwareButtonCCValue[buttonIndex] ?? -1
        lastHardwareButtonCCValue[buttonIndex] = value
        let wasDown = prev >= 0 && ccKeyPressed(prev)
        let isDown = ccKeyPressed(value)

        switch mode {
        case .panic:
            let crossedHigh = prev < 64 && value >= 64
            let crossedLowBinary = prev <= 0 && value > 0 && value < 64
            guard crossedHigh || crossedLowBinary else { return }
            panic()
        case .queueNextPad:
            if !wasDown && isDown {
                sideButtonHeld.insert(buttonIndex)
            } else if wasDown && !isDown {
                sideButtonHeld.remove(buttonIndex)
                let anyQueueStill = [4, 5].contains { sideButtonHeld.contains($0) && modeForSideButton($0) == .queueNextPad }
                if !anyQueueStill {
                    commitQueueTransition()
                }
            }
        case .stutter:
            if !wasDown && isDown {
                startStutterEffect()
            } else if wasDown && !isDown {
                stopStutterEffect()
            }
        }
    }

    /// CC 系ハードボタン（0〜3）。127/64 系の「64 以上へ立ち上がり」または 0/1 系の「0→正」のどちらでも 1 回だけ処理。
    private func handleHardwareButtonCC(buttonIndex: Int, value: Int) {
        let prev = lastHardwareButtonCCValue[buttonIndex] ?? -1
        lastHardwareButtonCCValue[buttonIndex] = value
        let crossedHigh = prev < 64 && value >= 64
        let crossedLowBinary = prev <= 0 && value > 0 && value < 64
        guard crossedHigh || crossedLowBinary else { return }
        performHardwareButtonAction(index: buttonIndex)
    }

    private func performHardwareButtonAction(index: Int) {
        switch index {
        case 0: stopAll()
        case 1: uiBank = (uiBank + 1) % PresetKit.banks
        case 2: uiBank = (uiBank + PresetKit.banks - 1) % PresetKit.banks
        case 3: toggleTransportPause()
        default: break
        }
    }

    private func applyBankSwitchHardwareAction(_ action: BankSwitchHardwareAction) {
        switch action {
        case .selectBank(let b):
            uiBank = max(0, min(b, PresetKit.banks - 1))
        case .cycleToNextBank:
            uiBank = (uiBank + 1) % PresetKit.banks
        }
    }

    private func handleNoteOn(channel: Int, note: Int, velocity: Int) {
        if let action = profile.bankSwitchHardwareAction(channel: channel, number: note, isNote: true) {
            applyBankSwitchHardwareAction(action)
            return
        }
        if let idx = profile.padIndex(note: note, channel: channel) {
            triggerSlot(idx, velocity: velocity)
            return
        }
        if let role = profile.roleForNote(channel: channel, note: note) {
            switch role {
            case .button(let i) where i >= 4:
                guard velocity > 0 else { return }
                handleSideButtonNoteDown(buttonIndex: i)
            case .button(let i):
                guard velocity > 0 else { return }
                performHardwareButtonAction(index: i)
            case .fader, .knob:
                break
            }
        }
    }

    private func handleSideButtonNoteDown(buttonIndex: Int) {
        switch modeForSideButton(buttonIndex) {
        case .queueNextPad:
            sideButtonHeld.insert(buttonIndex)
        case .panic:
            panic()
        case .stutter:
            startStutterEffect()
        }
    }

    private func handleSideButtonNoteUp(buttonIndex: Int) {
        switch modeForSideButton(buttonIndex) {
        case .queueNextPad:
            sideButtonHeld.remove(buttonIndex)
            let anyQueueStill = [4, 5].contains { sideButtonHeld.contains($0) && modeForSideButton($0) == .queueNextPad }
            if !anyQueueStill {
                commitQueueTransition()
            }
        case .panic:
            break
        case .stutter:
            stopStutterEffect()
        }
    }

    private func handleNoteOff(channel: Int, note: Int) {
        if let role = profile.roleForNote(channel: channel, note: note) {
            switch role {
            case .button(let i) where i >= 4:
                handleSideButtonNoteUp(buttonIndex: i)
                return
            case .button, .fader, .knob:
                break
            }
        }
        guard let idx = profile.padIndex(note: note, channel: channel) else { return }
        let cfg = kit.slots[idx]
        if cfg.respectNoteOff {
            engine.stopSlot(idx, fadeOutMs: cfg.fadeOutMs)
        }
    }
}
