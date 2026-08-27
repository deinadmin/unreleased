import Foundation

enum AudioImportBridge {
    static let appGroupID = "group.de.carlsteen.unreleased"
    private static let pendingImportKey = "pendingImport"
    private static let projectMirrorsKey = "projectMirrors"
    private static let incomingFolderName = "IncomingImports"
    private static let supportedExtensions = Set([
        "mp3", "m4a", "wav", "aiff", "aif", "flac", "aac"
    ])

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    private static var incomingDirectory: URL? {
        guard let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        let folder = base.appendingPathComponent(incomingFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Project mirrors

    struct ProjectMirror: Codable, Identifiable, Sendable {
        let id: UUID
        let name: String
        let gradientColors: [String]
        let gradientStartX: Double
        let gradientStartY: Double
        let gradientEndX: Double
        let gradientEndY: Double
    }

    static func mirrorProjects(_ mirrors: [ProjectMirror]) {
        guard let data = try? JSONEncoder().encode(mirrors) else { return }
        defaults?.set(data, forKey: projectMirrorsKey)
    }

    static func readProjectMirrors() -> [ProjectMirror] {
        guard let data = defaults?.data(forKey: projectMirrorsKey),
              let mirrors = try? JSONDecoder().decode([ProjectMirror].self, from: data)
        else { return [] }
        return mirrors
    }

    // MARK: - Pending import (multi-file)

    struct PendingImport: Codable {
        struct Item: Codable {
            let filename: String
            let originalTitle: String?
        }
        let items: [Item]
        let destinationProjectID: UUID?
    }

    private static var storedPendingImport: PendingImport? {
        get {
            guard let data = defaults?.data(forKey: pendingImportKey) else { return nil }
            return try? JSONDecoder().decode(PendingImport.self, from: data)
        }
        set {
            if let value = newValue, let data = try? JSONEncoder().encode(value) {
                defaults?.set(data, forKey: pendingImportKey)
            } else {
                defaults?.removeObject(forKey: pendingImportKey)
            }
        }
    }

    /// Stage multiple audio files for the main app to pick up.
    static func stageImportedFiles(
        _ sourceItems: [(url: URL, title: String?)],
        destinationProjectID: UUID? = nil
    ) throws {
        guard let incomingDirectory else { throw BridgeError.appGroupUnavailable }

        clearPendingImport()

        var stagedItems: [PendingImport.Item] = []
        for source in sourceItems {
            let ext = try validatedExtension(for: source.url)
            let filename = "\(UUID().uuidString).\(ext)"
            let destination = incomingDirectory.appendingPathComponent(filename)
            try FileManager.default.copyItem(at: source.url, to: destination)
            stagedItems.append(PendingImport.Item(filename: filename, originalTitle: source.title))
        }

        storedPendingImport = PendingImport(items: stagedItems, destinationProjectID: destinationProjectID)
    }

    /// Convenience for staging a single file (direct open / Files app).
    @discardableResult
    static func stageImportedFile(
        from sourceURL: URL,
        destinationProjectID: UUID? = nil,
        originalTitle: String? = nil
    ) throws -> URL {
        guard let incomingDirectory else { throw BridgeError.appGroupUnavailable }

        clearPendingImport()

        let ext = try validatedExtension(for: sourceURL)
        let filename = "\(UUID().uuidString).\(ext)"
        let destination = incomingDirectory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        storedPendingImport = PendingImport(
            items: [PendingImport.Item(filename: filename, originalTitle: originalTitle)],
            destinationProjectID: destinationProjectID
        )
        return destination
    }

    static func consumePendingImport() -> (items: [(url: URL, title: String?)], destinationProjectID: UUID?)? {
        guard let incomingDirectory,
              let pending = storedPendingImport,
              !pending.items.isEmpty
        else { return nil }

        var result: [(url: URL, title: String?)] = []
        for item in pending.items {
            let url = incomingDirectory.appendingPathComponent(item.filename)
            if FileManager.default.fileExists(atPath: url.path) {
                result.append((url, item.originalTitle))
            }
        }

        storedPendingImport = nil
        guard !result.isEmpty else { return nil }
        return (result, pending.destinationProjectID)
    }

    static func clearPendingImport() {
        if let incomingDirectory, let pending = storedPendingImport {
            for item in pending.items {
                let url = incomingDirectory.appendingPathComponent(item.filename)
                try? FileManager.default.removeItem(at: url)
            }
        }
        storedPendingImport = nil
    }

    static func hasPendingImport() -> Bool {
        guard let incomingDirectory, let pending = storedPendingImport else { return false }
        return pending.items.contains {
            FileManager.default.fileExists(
                atPath: incomingDirectory.appendingPathComponent($0.filename).path
            )
        }
    }

    private static func validatedExtension(for url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw BridgeError.unsupportedAudioFormat
        }
        return ext
    }

    enum BridgeError: LocalizedError {
        case appGroupUnavailable
        case unsupportedAudioFormat

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                "The shared import folder is unavailable."
            case .unsupportedAudioFormat:
                "Choose an MP3, M4A, WAV, AIFF, FLAC, or AAC audio file."
            }
        }
    }
}
