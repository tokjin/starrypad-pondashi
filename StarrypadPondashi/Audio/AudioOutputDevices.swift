import CoreAudio
import Foundation

/// macOS の音声出力デバイス列挙と既定出力の取得
enum AudioOutputDevices {
    /// システムの既定出力デバイス
    static func defaultOutputDeviceID() -> AudioDeviceID {
        var id = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        if err != noErr { return 0 }
        return id
    }

    /// 出力ストリームを持つデバイス（スピーカー・ヘッドホン等）
    static func listOutputDevices() -> [(id: AudioDeviceID, name: String)] {
        let allIDs = deviceObjectIDs()
        var result: [(AudioDeviceID, String)] = []
        for dev in allIDs where outputChannelCount(dev) > 0 {
            result.append((dev, deviceDisplayName(dev)))
        }
        result.sort { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        return result
    }

    private static func deviceObjectIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        var mutableSize = size
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &mutableSize, &ids) == noErr else { return [] }
        return ids
    }

    private static func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<UInt8>.alignment)
        defer { raw.deallocate() }
        var mutableSize = size
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &mutableSize, raw) == noErr else { return 0 }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        var ch = 0
        for i in 0 ..< buffers.count {
            ch += Int(buffers[i].mNumberChannels)
        }
        return ch
    }

    private static func deviceDisplayName(_ deviceID: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else {
            return "デバイス \(deviceID)"
        }
        let ptr = UnsafeMutablePointer<CFString>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        var mutableSize = size
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &mutableSize, ptr) == noErr else {
            return "デバイス \(deviceID)"
        }
        return ptr.pointee as String
    }
}
