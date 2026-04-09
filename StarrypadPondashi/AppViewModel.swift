import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation
import os
import SwiftUI

private let vmAudioLog = Logger(subsystem: "com.starrypad.pondashi", category: "AppViewModel")

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
    /// 直近に叩かれたパッド（短時間ハイライト用）
    @Published private(set) var lastHitSlot: Int?

    /// 音声出力デバイス一覧（設定画面用）
    @Published private(set) var audioOutputDeviceList: [(id: AudioDeviceID, name: String)] = []
    /// `nil` = システム既定
    @Published var selectedAudioOutputDeviceID: AudioDeviceID?

    private static let audioOutputDeviceDefaultsKey = "selectedAudioOutputDeviceID"

    private var cancellables = Set<AnyCancellable>()
    private var padHitClearTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?
    private let logLimit = 80

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
            case .none, .pan, .dynamics, .pitch, .reverbSend, .delaySend, .delayFeedback, .delayTime, .playbackRate:
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
        kit = k
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

    func triggerSlot(_ slot: Int, velocity: Int = 127) {
        guard slot >= 0, slot < PresetKit.slotCount else { return }
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

    func stopAll() {
        engine.stopAll()
    }

    func panic() {
        engine.stopAll()
    }

    func startPadCapture(bank: Int) {
        capturePadSession = PadCaptureSession(bankIndex: bank)
        captureControlMessage = "バンク \(bank + 1): 左下を PAD1 とし、右→上の順で 16 パッドを押してください"
    }

    func cancelCapture() {
        capturePadSession = nil
        captureFaderIndex = nil
        captureKnobIndex = nil
        captureControlMessage = nil
    }

    func startFaderCapture(index: Int) {
        captureFaderIndex = index
        captureKnobIndex = nil
        captureControlMessage = "フェーダー \(index + 1) を動かしてください（CC を記録）"
    }

    func startKnobCapture(index: Int) {
        captureKnobIndex = index
        captureFaderIndex = nil
        captureControlMessage = "ノブ \(index + 1) を回してください（CC を記録）"
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
                    let v: Float
                    if kit.knobRoles.indices.contains(i), kit.knobRoles[i] == .pan {
                        let pan = max(-1, min(1, (Float(value) - 64) / 63))
                        v = max(0, min(1, (pan + 1) / 2))
                    } else {
                        v = max(0, min(1, Float(value) / 127))
                    }
                    knobDisplay[i] = v
                    applyFaderRolesToEngine()
                }
            case .button:
                break
            }
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
            case .button(0):
                stopAll()
            case .button(1):
                uiBank = (uiBank + 1) % PresetKit.banks
            case .button(2):
                uiBank = (uiBank + PresetKit.banks - 1) % PresetKit.banks
            default:
                break
            }
        }
    }

    private func handleNoteOff(channel: Int, note: Int) {
        guard let idx = profile.padIndex(note: note, channel: channel) else { return }
        let cfg = kit.slots[idx]
        if cfg.respectNoteOff {
            engine.stopSlot(idx, fadeOutMs: cfg.fadeOutMs)
        }
    }
}
