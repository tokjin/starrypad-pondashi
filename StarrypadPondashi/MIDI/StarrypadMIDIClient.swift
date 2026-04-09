import Foundation
import CoreMIDI
import Combine

struct MIDIEndpointInfo: Identifiable, Equatable {
    let id: MIDIUniqueID
    let name: String
    let displayName: String
}

enum MIDIRawEvent: Equatable {
    case noteOn(channel: Int, note: Int, velocity: Int)
    case noteOff(channel: Int, note: Int, velocity: Int)
    case controlChange(channel: Int, cc: Int, value: Int)
    case programChange(channel: Int, program: Int)
}

final class StarrypadMIDIClient: ObservableObject {
    @Published private(set) var sources: [MIDIEndpointInfo] = []
    @Published var selectedSourceID: MIDIUniqueID? {
        didSet { applySelectedSource() }
    }

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private let eventSubject = PassthroughSubject<MIDIRawEvent, Never>()
    var eventPublisher: AnyPublisher<MIDIRawEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    init() {
        setupClient()
        let initial = Self.enumerateSources()
        sources = initial
        if selectedSourceID == nil {
            selectedSourceID = Self.pickPreferred(from: initial)?.id
        }
        applySelectedSource()
    }

    deinit {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func refreshSources() {
        let list = Self.enumerateSources()
        DispatchQueue.main.async {
            self.sources = list
        }
    }

    func pickPreferredSource() -> MIDIEndpointInfo? {
        Self.pickPreferred(from: sources)
    }

    private static func enumerateSources() -> [MIDIEndpointInfo] {
        var list: [MIDIEndpointInfo] = []
        let count = MIDIGetNumberOfSources()
        for i in 0 ..< count {
            let endpoint = MIDIGetSource(i)
            let id = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID)
            let name = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName) ?? "Source \(i)"
            list.append(MIDIEndpointInfo(id: id, name: name, displayName: name))
        }
        return list
    }

    private static func pickPreferred(from sources: [MIDIEndpointInfo]) -> MIDIEndpointInfo? {
        let hints = ["Starrypad", "DONNER", "Donner", "DPD"]
        for hint in hints {
            if let s = sources.first(where: { $0.name.localizedCaseInsensitiveContains(hint) }) {
                return s
            }
        }
        return sources.first
    }

    private func setupClient() {
        MIDIClientCreateWithBlock("StarrypadPondashi" as CFString, &client) { _ in
            DispatchQueue.main.async {
                self.refreshSources()
            }
        }
        MIDIInputPortCreateWithBlock(client, "Input" as CFString, &inputPort) { [weak self] packetList, _ in
            self?.parsePacketList(packetList)
        }
    }

    /// 選択ソースのみ接続し直す
    func applySelectedSource() {
        guard inputPort != 0 else { return }
        let count = MIDIGetNumberOfSources()
        for i in 0 ..< count {
            let endpoint = MIDIGetSource(i)
            MIDIPortDisconnectSource(inputPort, endpoint)
        }
        guard let sid = selectedSourceID else { return }
        for i in 0 ..< count {
            let endpoint = MIDIGetSource(i)
            let id = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID)
            if id == sid {
                MIDIPortConnectSource(inputPort, endpoint, nil)
                break
            }
        }
    }

    private func parsePacketList(_ packetList: UnsafePointer<MIDIPacketList>) {
        var packet = packetList.pointee.packet
        for _ in 0 ..< packetList.pointee.numPackets {
            let len = Int(packet.length)
            let data = withUnsafeBytes(of: &packet.data) { raw -> [UInt8] in
                let start = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return (0 ..< len).map { start[$0] }
            }
            parseBytes(data)
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private func parseBytes(_ data: [UInt8]) {
        var i = 0
        while i < data.count {
            let status = data[i]
            if status >= 0xF8 { i += 1; continue }
            if status & 0x80 == 0 { i += 1; continue }

            let type = status & 0xF0
            let channel = Int(status & 0x0F)

            switch type {
            case 0x80:
                guard i + 2 < data.count else { i += 1; continue }
                let note = Int(data[i + 1])
                let vel = Int(data[i + 2])
                eventSubject.send(.noteOff(channel: channel, note: note, velocity: vel))
                i += 3
            case 0x90:
                guard i + 2 < data.count else { i += 1; continue }
                let note = Int(data[i + 1])
                let vel = Int(data[i + 2])
                if vel == 0 {
                    eventSubject.send(.noteOff(channel: channel, note: note, velocity: 0))
                } else {
                    eventSubject.send(.noteOn(channel: channel, note: note, velocity: vel))
                }
                i += 3
            case 0xB0:
                guard i + 2 < data.count else { i += 1; continue }
                let cc = Int(data[i + 1])
                let val = Int(data[i + 2])
                eventSubject.send(.controlChange(channel: channel, cc: cc, value: val))
                i += 3
            case 0xC0:
                guard i + 1 < data.count else { i += 1; continue }
                let prog = Int(data[i + 1])
                eventSubject.send(.programChange(channel: channel, program: prog))
                i += 2
            default:
                let size = messageLength(statusByte: status)
                i += max(1, size)
            }
        }
    }

    private func messageLength(statusByte: UInt8) -> Int {
        let t = statusByte & 0xF0
        switch t {
        case 0xC0, 0xD0: return 2
        case 0x80, 0x90, 0xA0, 0xB0, 0xE0: return 3
        default: return 1
        }
    }
}

private func MIDIObjectGetIntegerProperty(_ object: MIDIObjectRef, _ property: CFString) -> MIDIUniqueID {
    var id: MIDIUniqueID = 0
    MIDIObjectGetIntegerProperty(object, property, &id)
    return id
}

private func MIDIObjectGetStringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String? {
    var cf: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, property, &cf) == noErr, let s = cf?.takeRetainedValue() else {
        return nil
    }
    return s as String
}
