import Foundation

/// `yt-dlp` で YouTube から音声を取得し、一時 MP3 を返す。
enum YouTubeAudioImport {
    enum ImportError: LocalizedError {
        case emptyInput
        case invalidYouTubeReference
        case ytDlpNotFound
        case downloadFailed(exitCode: Int32, stderr: String)
        case outputFileMissing

        var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "入力が空です。"
            case .invalidYouTubeReference:
                return "YouTube の動画 URL または動画 ID を入力してください。"
            case .ytDlpNotFound:
                return "yt-dlp が見つかりません。PATH に入れるか、/opt/homebrew/bin または /usr/local/bin にインストールしてください。"
            case let .downloadFailed(code, stderr):
                let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if tail.isEmpty {
                    return "yt-dlp が失敗しました（終了コード \(code)）。"
                }
                return "yt-dlp が失敗しました（終了コード \(code)）: \(tail)"
            case .outputFileMissing:
                return "ダウンロードした MP3 が見つかりません。"
            }
        }
    }

    /// 動画 ID・`youtu.be`・`watch?v=` などを `https://www.youtube.com/watch?v=...` に正規化
    static func resolveWatchURL(from raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.emptyInput }

        if isBareVideoId(trimmed) {
            guard let u = URL(string: "https://www.youtube.com/watch?v=\(trimmed)") else {
                throw ImportError.invalidYouTubeReference
            }
            return u
        }

        var s = trimmed
        if !s.contains("://") {
            if s.hasPrefix("youtu.be/") {
                s = "https://" + s
            } else {
                s = "https://" + s
            }
        }

        guard let url = URL(string: s), let host = url.host?.lowercased() else {
            throw ImportError.invalidYouTubeReference
        }

        if host == "youtu.be" {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").first.map(String.init) ?? ""
            guard isBareVideoId(id) else { throw ImportError.invalidYouTubeReference }
            guard let u = URL(string: "https://www.youtube.com/watch?v=\(id)") else { throw ImportError.invalidYouTubeReference }
            return u
        }

        guard host.hasSuffix("youtube.com") else { throw ImportError.invalidYouTubeReference }

        if let q = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = q.queryItems,
           let v = items.first(where: { $0.name == "v" })?.value,
           !v.isEmpty
        {
            guard let u = URL(string: "https://www.youtube.com/watch?v=\(v)") else { throw ImportError.invalidYouTubeReference }
            return u
        }

        let path = url.path
        if path.hasPrefix("/shorts/") {
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 2, isBareVideoId(parts[1]),
               let u = URL(string: "https://www.youtube.com/watch?v=\(parts[1])")
            {
                return u
            }
        }
        if path.hasPrefix("/embed/") {
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 2, isBareVideoId(parts[1]),
               let u = URL(string: "https://www.youtube.com/watch?v=\(parts[1])")
            {
                return u
            }
        }

        throw ImportError.invalidYouTubeReference
    }

    /// 典型的な 11 文字の動画 ID（英数と `-` `_`）
    private static func isBareVideoId(_ s: String) -> Bool {
        guard s.count == 11 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func findYtDlpExecutable() throws -> URL {
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin"
        let candidates: [String] = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/yt-dlp").path
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let found = pathOfYtDlp(extraPaths: extraPaths) {
            return found
        }
        throw ImportError.ytDlpNotFound
    }

    private static func pathOfYtDlp(extraPaths: String) -> URL? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v yt-dlp"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "")
        p.environment = env
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        } catch {
            return nil
        }
        return nil
    }

    /// `-x --audio-format mp3` で取得。戻り値の MP3 は `tempDir` 内。使用後 `tempDir` ごと削除してよい。
    static func downloadAudioMP3(youtubeURL: URL) throws -> (mp3: URL, tempDir: URL) {
        let exe = try findYtDlpExecutable()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("starrypad-ytdlp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // `pad.%(ext)s` だと常に同じファイル名になり、Samples へコピー時に上書きされて全パッドが同一音源になる。
        // YouTube の動画 ID をファイル名に使い、曲ごとに一意にする。
        let outPattern = tempDir.appendingPathComponent("%(id)s.%(ext)s").path

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = [
            "-x", "--audio-format", "mp3",
            "--no-playlist",
            "-o", outPattern,
            youtubeURL.absoluteString
        ]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        proc.environment = env

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice

        try proc.run()
        proc.waitUntilExit()

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""

        guard proc.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempDir)
            throw ImportError.downloadFailed(exitCode: proc.terminationStatus, stderr: errText)
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
        guard let mp3 = files.first(where: { $0.pathExtension.lowercased() == "mp3" }) else {
            try? FileManager.default.removeItem(at: tempDir)
            throw ImportError.outputFileMissing
        }
        return (mp3, tempDir)
    }
}
