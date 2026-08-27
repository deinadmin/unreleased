import FirebaseStorage
import Foundation

/// Disk cache + Firebase Storage transfers for track audio.
actor AudioFileCache {
    static let shared = AudioFileCache()

    private var activeDownloads: [String: Task<URL, Error>] = [:]

    private func downloadKey(storagePath: String, directory: URL) -> String {
        "\(storagePath)-\(directory.path)"
    }

    func localURL(for track: Track, in directory: URL) -> URL {
        directory.appendingPathComponent(track.fileName)
    }

    func isCached(_ track: Track, in directory: URL) -> Bool {
        let url = localURL(for: track, in: directory)
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              size > 0
        else { return false }

        if track.fileSize > 0 {
            return size == track.fileSize
        }
        return true
    }

    /// Returns a cached file URL or downloads once from Storage into the audio cache directory.
    func ensureLocalFile(
        for track: Track,
        storagePath: String,
        in directory: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if isCached(track, in: directory) {
            onProgress?(1)
            return localURL(for: track, in: directory)
        }

        let key = downloadKey(storagePath: storagePath, directory: directory)
        if let existing = activeDownloads[key] {
            return try await existing.value
        }

        let task = Task<URL, Error> {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent(track.fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            do {
                try await CloudPaths.audioReference(storagePath: storagePath)
                    .writeToFileAsync(destination, onProgress: onProgress)
                return destination
            } catch {
                // A failed rendition probe must never leave a partial file that
                // a later playback could mistake for a valid cached asset.
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }

        activeDownloads[key] = task
        defer { activeDownloads[key] = nil }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func upload(
        localURL: URL,
        to storagePath: String,
        contentType: String?
    ) async throws -> Int64 {
        let ref = CloudPaths.audioReference(storagePath: storagePath)
        let metadata = StorageMetadata()
        metadata.contentType = contentType

        _ = try await ref.putFileAsync(from: localURL, metadata: metadata)
        let objectMeta = try await ref.getMetadata()
        return objectMeta.size
    }

    /// Checks whether a recorded Storage path still points at an object.
    ///
    /// A track can remain playable on this device from its disk cache after the
    /// server object has been removed (for example by quota enforcement). Cloud
    /// sync uses this to repair that otherwise invisible broken state.
    func objectExists(storagePath: String) async throws -> Bool {
        do {
            _ = try await CloudPaths.storageReference(storagePath: storagePath).getMetadata()
            return true
        } catch {
            let nsError = error as NSError
            if nsError.domain == StorageErrorDomain,
               nsError.code == StorageErrorCode.objectNotFound.rawValue {
                return false
            }
            throw error
        }
    }

    func delete(storagePath: String) async {
        try? await CloudPaths.storageReference(storagePath: storagePath).delete()
    }

    /** Cancels transfers and removes every account-owned local media directory. */
    func purgeLocalFiles(in directories: [URL]) {
        for task in activeDownloads.values { task.cancel() }
        activeDownloads.removeAll()
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func download(storagePath: String, to destination: URL) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try await CloudPaths.storageReference(storagePath: storagePath)
            .writeToFileAsync(destination, onProgress: nil)
    }
}

private extension StorageReference {
    func writeToFileAsync(_ url: URL, onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        let task = write(toFile: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var finished = false

                func complete(_ result: Result<Void, Error>) {
                    guard !finished else { return }
                    finished = true

                    switch result {
                    case .success:
                        onProgress?(1)
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                if let onProgress {
                    task.observe(.progress) { [weak task] snapshot in
                        guard task != nil else { return }
                        let total = snapshot.progress?.totalUnitCount ?? 0
                        let completed = snapshot.progress?.completedUnitCount ?? 0
                        guard total > 0 else { return }
                        onProgress(Double(completed) / Double(total))
                    }
                }

                task.observe(.success) { [weak task] _ in
                    guard task != nil else { return }
                    complete(.success(()))
                }

                task.observe(.failure) { [weak task] snapshot in
                    guard task != nil else { return }
                    complete(.failure(snapshot.error ?? URLError(.badServerResponse)))
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func putFileAsync(from url: URL, metadata: StorageMetadata?) async throws -> StorageMetadata {
        try await withCheckedThrowingContinuation { continuation in
            putFile(from: url, metadata: metadata) { meta, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let meta {
                    continuation.resume(returning: meta)
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
        }
    }

    func getMetadata() async throws -> StorageMetadata {
        try await withCheckedThrowingContinuation { continuation in
            getMetadata { meta, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let meta {
                    continuation.resume(returning: meta)
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
        }
    }

    func delete() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delete { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
