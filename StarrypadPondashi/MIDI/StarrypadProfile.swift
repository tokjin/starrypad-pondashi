import Foundation

/// MIDI 上のコントロール定義（CC またはノート）
enum MIDISourceSpec: Codable, Equatable {
    case cc(channel: Int?, number: Int)
    case note(channel: Int?, note: Int)

    private enum CodingKeys: String, CodingKey {
        case type, channel, number, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let channel = try c.decodeIfPresent(Int.self, forKey: .channel)
        switch type {
        case "cc":
            let n = try c.decode(Int.self, forKey: .number)
            self = .cc(channel: channel, number: n)
        case "note":
            let n = try c.decode(Int.self, forKey: .note)
            self = .note(channel: channel, note: n)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .cc(ch, num):
            try c.encode("cc", forKey: .type)
            try c.encodeIfPresent(ch, forKey: .channel)
            try c.encode(num, forKey: .number)
        case let .note(ch, n):
            try c.encode("note", forKey: .type)
            try c.encodeIfPresent(ch, forKey: .channel)
            try c.encode(n, forKey: .note)
        }
    }
}

/// バンク切替: プログラムチェンジ、`notes`／`cycleNote` でノートまたは CC を指定可能
struct BankSwitchSpec: Codable, Equatable {
    var programChanges: [Int]?
    /// 添字 0=A, 1=B, 2=C に対応するノートまたは CC（`MIDISourceSpec`）
    var notes: [MIDISourceSpec]?
    /// 1 ボタンでバンクを順に進めるハード向け（`PAD BANK` など）
    var cycleNote: MIDISourceSpec?
}

/// ハードのバンクボタンから `uiBank` を決めるときの結果
enum BankSwitchHardwareAction: Equatable {
    case selectBank(Int)
    case cycleToNextBank
}

struct StarrypadProfile: Codable, Equatable, Identifiable {
    var id: String { name }
    var version: Int
    var name: String
    var deviceNameHints: [String]
    /// nil = 全チャンネル
    var midiChannel: Int?
    /// 3 バンク × 16 ノート番号（左下を PAD1 とし、右・上方向に 2〜16。キャプチャ手順に合わせる）
    var banks: [[Int]]
    var faders: [MIDISourceSpec]
    var knobs: [MIDISourceSpec]
    var buttons: [MIDISourceSpec]
    var bankSwitch: BankSwitchSpec?

    static let defaultProfileName = "StarrypadDefault"

    /// プレースホルダー（実機キャプチャで上書き推奨）
    static func placeholder(name: String = "Starrypad Placeholder") -> StarrypadProfile {
        let bank0 = (0 ..< 16).map { 36 + $0 }
        let bank1 = (0 ..< 16).map { 52 + $0 }
        let bank2 = (0 ..< 16).map { 68 + $0 }
        return StarrypadProfile(
            version: 1,
            name: name,
            deviceNameHints: ["Starrypad", "DONNER", "Donner"],
            midiChannel: nil,
            banks: [bank0, bank1, bank2],
            faders: [.cc(channel: nil, number: 1), .cc(channel: nil, number: 2)],
            knobs: [.cc(channel: nil, number: 3), .cc(channel: nil, number: 4)],
            buttons: [
                .note(channel: nil, note: 100),
                .note(channel: nil, note: 101),
                .note(channel: nil, note: 102),
                /// 再生／一時停止（多くの実機は CC で送るため既定は CC 60）
                .cc(channel: nil, number: 60),
                .note(channel: nil, note: 96),
                .note(channel: nil, note: 97)
            ],
            bankSwitch: BankSwitchSpec(programChanges: [0, 1, 2], notes: nil, cycleNote: nil)
        )
    }

    func padIndex(note: Int, channel: Int) -> Int? {
        if let ch = midiChannel, ch != channel { return nil }
        for (b, notes) in banks.enumerated() {
            if let i = notes.firstIndex(of: note) {
                return b * 16 + i
            }
        }
        return nil
    }

    func controlRole(source: MIDISourceSpec, channel: Int, number: Int, isNote: Bool) -> HardwareControlRole? {
        if let ch = midiChannel, ch != channel { return nil }
        for (i, spec) in faders.enumerated() where matches(spec, channel: channel, number: number, isNote: isNote) {
            return .fader(i)
        }
        for (i, spec) in knobs.enumerated() where matches(spec, channel: channel, number: number, isNote: isNote) {
            return .knob(i)
        }
        for (i, spec) in buttons.enumerated() where matches(spec, channel: channel, number: number, isNote: isNote) {
            return .button(i)
        }
        return nil
    }

    func roleForControlChange(channel: Int, cc: Int) -> HardwareControlRole? {
        controlRole(source: .cc(channel: nil, number: cc), channel: channel, number: cc, isNote: false)
    }

    func roleForNote(channel: Int, note: Int) -> HardwareControlRole? {
        controlRole(source: .note(channel: nil, note: note), channel: channel, number: note, isNote: true)
    }

    private func matches(_ spec: MIDISourceSpec, channel: Int, number: Int, isNote: Bool) -> Bool {
        switch spec {
        case let .cc(ch, num):
            if isNote { return false }
            if let c = ch, c != channel { return false }
            return num == number
        case let .note(ch, n):
            if !isNote { return false }
            if let c = ch, c != channel { return false }
            return n == number
        }
    }

    func bankFromProgramChange(_ program: Int) -> Int? {
        guard let pcs = bankSwitch?.programChanges else { return nil }
        return pcs.firstIndex(of: program)
    }

    /// プログラムチェンジ以外（ノート／CC）でバンクを合わせる。`midiChannel` と一致する場合のみ。
    func bankSwitchHardwareAction(channel: Int, number: Int, isNote: Bool) -> BankSwitchHardwareAction? {
        if let ch = midiChannel, ch != channel { return nil }
        guard let bs = bankSwitch else { return nil }

        if let spec = bs.cycleNote, matches(spec, channel: channel, number: number, isNote: isNote) {
            return .cycleToNextBank
        }
        if let specs = bs.notes {
            for (i, spec) in specs.enumerated() where i < PresetKit.banks {
                if matches(spec, channel: channel, number: number, isNote: isNote) {
                    return .selectBank(i)
                }
            }
        }
        return nil
    }
}

enum HardwareControlRole: Equatable {
    case fader(Int)
    case knob(Int)
    case button(Int)
}

enum ProfileStore {
    static func loadBundledDefault() -> StarrypadProfile {
        guard let url = Bundle.main.url(forResource: StarrypadProfile.defaultProfileName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(StarrypadProfile.self, from: data)
        else {
            return .placeholder()
        }
        return p
    }

    static func applicationProfilesURL() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("StarrypadPondashi/Profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
