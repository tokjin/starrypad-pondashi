import Foundation

/// 同じパッドを再生中にもう一度押したとき
enum RetriggerBehavior: String, Codable, CaseIterable, Identifiable {
    case layer
    case stop
    case fadeOut
    case restart

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .layer: return "重ねて再生"
        case .stop: return "停止"
        case .fadeOut: return "フェードアウトで停止"
        case .restart: return "停止してから再生"
        }
    }
}

/// 各フェーダー（F1/F2）に割り当てる機能
enum FaderRole: String, Codable, CaseIterable, Identifiable {
    case none
    case master
    case pan
    case dynamics
    case pitch
    case reverbSend
    case delaySend
    case delayFeedback
    case delayTime
    case playbackRate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "なし"
        case .master: return "マスター音量"
        case .pan: return "PAN（左右）"
        case .dynamics: return "コンプレッサー"
        case .pitch: return "ピッチ"
        case .reverbSend: return "リバーブセンド"
        case .delaySend: return "ディレイ量（センド）"
        case .delayFeedback: return "ディレイフィードバック"
        case .delayTime: return "ディレイタイム"
        case .playbackRate: return "再生速度"
        }
    }
}

/// 各ノブ（K1/K2）に割り当てる機能
enum KnobRole: String, Codable, CaseIterable, Identifiable {
    case none
    case master
    case gain
    case pan
    case dynamics
    case pitch
    case reverbSend
    case delaySend
    case delayFeedback
    case delayTime
    case playbackRate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "なし"
        case .master: return "マスター音量"
        case .gain: return "バス音量（追加）"
        case .pan: return "PAN（左右）"
        case .dynamics: return "コンプレッサー"
        case .pitch: return "ピッチ"
        case .reverbSend: return "リバーブセンド"
        case .delaySend: return "ディレイ量（センド）"
        case .delayFeedback: return "ディレイフィードバック"
        case .delayTime: return "ディレイタイム"
        case .playbackRate: return "再生速度"
        }
    }
}

/// パッドグリッド上のセル背景色（nil = 既定のコントロール色／再生時はアクセント）
struct PadSlotTint: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    /// プリセット選択のハイライト用（RGBA すべて近いとき真）
    func isApproxEqual(to other: PadSlotTint, epsilon: Double = 0.05) -> Bool {
        abs(r - other.r) <= epsilon
            && abs(g - other.g) <= epsilon
            && abs(b - other.b) <= epsilon
            && abs(a - other.a) <= epsilon
    }
}

/// インスペクターから選べるおすすめ色（暗め・白字とのコントラスト向け）
struct PadColorPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let tint: PadSlotTint

    func matches(_ current: PadSlotTint?) -> Bool {
        guard let current else { return false }
        return current.isApproxEqual(to: tint)
    }

    /// 基本は不透明の暗色。名前は短くしてグリッドに収める。
    static let builtin: [PadColorPreset] = [
        PadColorPreset(id: "slate", name: "スレート", tint: PadSlotTint(r: 0.20, g: 0.22, b: 0.27, a: 1)),
        PadColorPreset(id: "charcoal", name: "チャコール", tint: PadSlotTint(r: 0.14, g: 0.15, b: 0.18, a: 1)),
        PadColorPreset(id: "ink", name: "インク", tint: PadSlotTint(r: 0.10, g: 0.11, b: 0.14, a: 1)),
        PadColorPreset(id: "navy", name: "ネイビー", tint: PadSlotTint(r: 0.09, g: 0.13, b: 0.28, a: 1)),
        PadColorPreset(id: "indigo", name: "インディゴ", tint: PadSlotTint(r: 0.14, g: 0.14, b: 0.34, a: 1)),
        PadColorPreset(id: "plum", name: "プラム", tint: PadSlotTint(r: 0.20, g: 0.12, b: 0.24, a: 1)),
        PadColorPreset(id: "wine", name: "ワイン", tint: PadSlotTint(r: 0.26, g: 0.10, b: 0.14, a: 1)),
        PadColorPreset(id: "forest", name: "フォレスト", tint: PadSlotTint(r: 0.10, g: 0.20, b: 0.14, a: 1)),
        PadColorPreset(id: "teal", name: "ティール", tint: PadSlotTint(r: 0.07, g: 0.22, b: 0.24, a: 1)),
        PadColorPreset(id: "sepia", name: "セピア", tint: PadSlotTint(r: 0.24, g: 0.18, b: 0.12, a: 1))
    ]
}

/// 1 スロット（パッド 1 つ分）の設定
struct SlotConfig: Codable, Equatable, Identifiable {
    var id: Int { index }
    let index: Int
    /// ブックマークまたは絶対パス（保存時はブックマーク推奨）
    var fileBookmark: Data?
    var filePath: String?
    var volume: Float
    var loop: Bool
    var fadeInMs: Double
    var fadeOutMs: Double
    /// 再生開始位置（ファイル先頭からのミリ秒）。ループ時も各周の先頭からこの位置で再生します。
    var startOffsetMs: Double
    var chokeGroup: Int?
    var respectNoteOff: Bool
    /// `false` のときは常に最大音量相当で再生（MIDI ベロシティを無視）
    var velocitySensitive: Bool
    var retriggerBehavior: RetriggerBehavior
    /// パッドセルの背景に重ねる色。nil で従来どおりシステム色ベース。
    var padTint: PadSlotTint?
    /// パッド上の表示名。nil または空のときは `filePath` のファイル名を使う。
    var fileDisplayName: String?

    enum CodingKeys: String, CodingKey {
        case index, fileBookmark, filePath, volume, loop, fadeInMs, fadeOutMs, startOffsetMs, chokeGroup, respectNoteOff, velocitySensitive, retriggerBehavior, padTint, fileDisplayName
    }

    init(
        index: Int,
        fileBookmark: Data?,
        filePath: String?,
        volume: Float,
        loop: Bool,
        fadeInMs: Double,
        fadeOutMs: Double,
        startOffsetMs: Double,
        chokeGroup: Int?,
        respectNoteOff: Bool,
        velocitySensitive: Bool,
        retriggerBehavior: RetriggerBehavior,
        padTint: PadSlotTint? = nil,
        fileDisplayName: String? = nil
    ) {
        self.index = index
        self.fileBookmark = fileBookmark
        self.filePath = filePath
        self.volume = volume
        self.loop = loop
        self.fadeInMs = fadeInMs
        self.fadeOutMs = fadeOutMs
        self.startOffsetMs = startOffsetMs
        self.chokeGroup = chokeGroup
        self.respectNoteOff = respectNoteOff
        self.velocitySensitive = velocitySensitive
        self.retriggerBehavior = retriggerBehavior
        self.padTint = padTint
        self.fileDisplayName = fileDisplayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        fileBookmark = try c.decodeIfPresent(Data.self, forKey: .fileBookmark)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? false
        fadeInMs = try c.decodeIfPresent(Double.self, forKey: .fadeInMs) ?? 0
        fadeOutMs = try c.decodeIfPresent(Double.self, forKey: .fadeOutMs) ?? 0
        startOffsetMs = try c.decodeIfPresent(Double.self, forKey: .startOffsetMs) ?? 0
        chokeGroup = try c.decodeIfPresent(Int.self, forKey: .chokeGroup)
        respectNoteOff = try c.decodeIfPresent(Bool.self, forKey: .respectNoteOff) ?? false
        velocitySensitive = try c.decodeIfPresent(Bool.self, forKey: .velocitySensitive) ?? false
        retriggerBehavior = try c.decodeIfPresent(RetriggerBehavior.self, forKey: .retriggerBehavior) ?? .layer
        padTint = try c.decodeIfPresent(PadSlotTint.self, forKey: .padTint)
        fileDisplayName = try c.decodeIfPresent(String.self, forKey: .fileDisplayName)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encodeIfPresent(fileBookmark, forKey: .fileBookmark)
        try c.encodeIfPresent(filePath, forKey: .filePath)
        try c.encode(volume, forKey: .volume)
        try c.encode(loop, forKey: .loop)
        try c.encode(fadeInMs, forKey: .fadeInMs)
        try c.encode(fadeOutMs, forKey: .fadeOutMs)
        try c.encode(startOffsetMs, forKey: .startOffsetMs)
        try c.encodeIfPresent(chokeGroup, forKey: .chokeGroup)
        try c.encode(respectNoteOff, forKey: .respectNoteOff)
        try c.encode(velocitySensitive, forKey: .velocitySensitive)
        try c.encode(retriggerBehavior, forKey: .retriggerBehavior)
        try c.encodeIfPresent(padTint, forKey: .padTint)
        try c.encodeIfPresent(fileDisplayName, forKey: .fileDisplayName)
    }

    /// パッドグリッドに表示するラベル（音声なしは「空」）。
    func padDisplayLabel(emptyLabel: String = "空") -> String {
        guard let path = filePath else { return emptyLabel }
        let base = (path as NSString).lastPathComponent
        if let custom = fileDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        return base
    }

    static func empty(index: Int) -> SlotConfig {
        SlotConfig(
            index: index,
            fileBookmark: nil,
            filePath: nil,
            volume: 1,
            loop: false,
            fadeInMs: 0,
            fadeOutMs: 0,
            startOffsetMs: 0,
            chokeGroup: nil,
            respectNoteOff: false,
            velocitySensitive: false,
            retriggerBehavior: .layer,
            padTint: nil,
            fileDisplayName: nil
        )
    }

    /// グリッド上の入れ替え／移動用に、スロット番号だけ差し替えたコピーを返す。
    func replacingIndex(_ newIndex: Int) -> SlotConfig {
        SlotConfig(
            index: newIndex,
            fileBookmark: fileBookmark,
            filePath: filePath,
            volume: volume,
            loop: loop,
            fadeInMs: fadeInMs,
            fadeOutMs: fadeOutMs,
            startOffsetMs: startOffsetMs,
            chokeGroup: chokeGroup,
            respectNoteOff: respectNoteOff,
            velocitySensitive: velocitySensitive,
            retriggerBehavior: retriggerBehavior,
            padTint: padTint,
            fileDisplayName: fileDisplayName
        )
    }
}

/// 48 スロット分のキット + グローバル設定
struct PresetKit: Codable, Equatable {
    var name: String
    var slots: [SlotConfig]
    var masterVolume: Float
    var maxPolyphony: Int
    var stealOldestVoice: Bool
    /// インデックス 0=F1, 1=F2
    var faderRoles: [FaderRole]
    /// インデックス 0=K1, 1=K2
    var knobRoles: [KnobRole]

    enum CodingKeys: String, CodingKey {
        case name, slots, masterVolume, maxPolyphony, stealOldestVoice, faderRoles, knobRoles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        masterVolume = try c.decodeIfPresent(Float.self, forKey: .masterVolume) ?? 1
        maxPolyphony = try c.decodeIfPresent(Int.self, forKey: .maxPolyphony) ?? 32
        stealOldestVoice = try c.decodeIfPresent(Bool.self, forKey: .stealOldestVoice) ?? true
        if let roles = try c.decodeIfPresent([FaderRole].self, forKey: .faderRoles) {
            var r = Array(roles.prefix(2))
            while r.count < 2 { r.append(.none) }
            faderRoles = r
        } else {
            faderRoles = [.master, .pan]
        }
        if let kroles = try c.decodeIfPresent([KnobRole].self, forKey: .knobRoles) {
            var r = Array(kroles.prefix(2))
            while r.count < 2 { r.append(.none) }
            knobRoles = r
        } else {
            knobRoles = [.none, .none]
        }
        var decoded = try c.decode([SlotConfig].self, forKey: .slots)
        if decoded.count < Self.slotCount {
            for i in decoded.count ..< Self.slotCount {
                decoded.append(SlotConfig.empty(index: i))
            }
        } else if decoded.count > Self.slotCount {
            decoded = Array(decoded.prefix(Self.slotCount))
        }
        slots = decoded
    }

    static let slotCount = 48
    static let banks = 3
    static let padsPerBank = 16

    init(
        name: String,
        slots: [SlotConfig],
        masterVolume: Float,
        maxPolyphony: Int,
        stealOldestVoice: Bool,
        faderRoles: [FaderRole],
        knobRoles: [KnobRole]
    ) {
        self.name = name
        self.slots = slots
        self.masterVolume = masterVolume
        self.maxPolyphony = maxPolyphony
        self.stealOldestVoice = stealOldestVoice
        self.faderRoles = faderRoles.count >= 2 ? Array(faderRoles.prefix(2)) : [.master, .pan]
        self.knobRoles = knobRoles.count >= 2 ? Array(knobRoles.prefix(2)) : [.none, .none]
    }

    static func makeEmpty(name: String = "Untitled") -> PresetKit {
        PresetKit(
            name: name,
            slots: (0 ..< slotCount).map { SlotConfig.empty(index: $0) },
            masterVolume: 1,
            maxPolyphony: 32,
            stealOldestVoice: true,
            faderRoles: [.master, .pan],
            knobRoles: [.none, .none]
        )
    }

    func slotIndex(bank: Int, padIndex: Int) -> Int {
        bank * Self.padsPerBank + padIndex
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(slots, forKey: .slots)
        try c.encode(masterVolume, forKey: .masterVolume)
        try c.encode(maxPolyphony, forKey: .maxPolyphony)
        try c.encode(stealOldestVoice, forKey: .stealOldestVoice)
        try c.encode(faderRoles, forKey: .faderRoles)
        try c.encode(knobRoles, forKey: .knobRoles)
    }
}

enum PresetIOError: LocalizedError {
    case bookmarkFailed
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .bookmarkFailed: return "ファイルへのアクセス権を取得できませんでした。"
        case .fileNotFound: return "音声ファイルが見つかりません。"
        }
    }
}

enum PresetStore {
    private static func appSupportDir() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("StarrypadPondashi", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func presetsDirectory() throws -> URL {
        let dir = try appSupportDir().appendingPathComponent("Presets", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 音声ファイルを Presets 隣の Samples にコピーしてパスを返す（任意スレッド）
    static func importAudioFile(from sourceURL: URL) throws -> String {
        let samples = try appSupportDir().appendingPathComponent("Samples", isDirectory: true)
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        let dest = samples.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return dest.path
    }

    static func resolveURL(for slot: SlotConfig) -> URL? {
        if let path = slot.filePath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let data = slot.fileBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                _ = url.startAccessingSecurityScopedResource()
                return url
            }
        }
        return nil
    }

    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func save(_ kit: PresetKit, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(kit)
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> PresetKit {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PresetKit.self, from: data)
    }
}
