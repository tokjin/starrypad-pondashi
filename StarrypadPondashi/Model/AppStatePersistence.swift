import Foundation

/// Application Support へのキット・MIDI プロファイルの自動保存
enum AppStatePersistence {
    private static let kitFileName = "AutosavedKit.json"
    private static let profileFileName = "AutosavedProfile.json"

    private static func appSupportRoot() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("StarrypadPondashi", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func autosavedKitURL() throws -> URL {
        try appSupportRoot().appendingPathComponent(kitFileName)
    }

    static func autosavedProfileURL() throws -> URL {
        try appSupportRoot().appendingPathComponent(profileFileName)
    }

    static func loadKitIfPresent() -> PresetKit? {
        guard let url = try? autosavedKitURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let kit = try? JSONDecoder().decode(PresetKit.self, from: data)
        else { return nil }
        return kit
    }

    static func saveKit(_ kit: PresetKit) throws {
        let url = try autosavedKitURL()
        try PresetStore.save(kit, to: url)
    }

    static func loadProfileIfPresent() -> StarrypadProfile? {
        guard let url = try? autosavedProfileURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder().decode(StarrypadProfile.self, from: data)
        else { return nil }
        return profile
    }

    static func saveProfile(_ profile: StarrypadProfile) throws {
        let url = try autosavedProfileURL()
        let data = try JSONEncoder().encode(profile)
        try data.write(to: url, options: .atomic)
    }
}
