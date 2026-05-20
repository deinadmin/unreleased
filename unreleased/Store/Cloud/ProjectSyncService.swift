import FirebaseFirestore
import Foundation

/// Syncs projects with Firestore and uploads audio to Storage. Local JSON remains the UI source of truth.
@MainActor
final class ProjectSyncService {
    typealias ProjectSnapshotProvider = () -> [Project]
    typealias ProjectUpdater = (_ projects: [Project], _ persistLocally: Bool) -> Void
    typealias TrackUpdater = (_ projectID: UUID, _ track: Track, _ persistLocally: Bool) -> Void
    typealias ProjectRemover = (_ projectID: UUID, _ persistLocally: Bool) -> Void

    private let userID: String
    private let audioDirectory: URL
    private let snapshotProvider: ProjectSnapshotProvider
    private let projectUpdater: ProjectUpdater
    private let trackUpdater: TrackUpdater
    private let projectRemover: ProjectRemover

    private var listener: ListenerRegistration?
    private var pushTask: Task<Void, Never>?
    private var lastSyncedUpdated: [UUID: Date] = [:]
    private var applyingRemote = false
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]

    init(
        userID: String,
        audioDirectory: URL,
        snapshotProvider: @escaping ProjectSnapshotProvider,
        projectUpdater: @escaping ProjectUpdater,
        trackUpdater: @escaping TrackUpdater,
        projectRemover: @escaping ProjectRemover
    ) {
        self.userID = userID
        self.audioDirectory = audioDirectory
        self.snapshotProvider = snapshotProvider
        self.projectUpdater = projectUpdater
        self.trackUpdater = trackUpdater
        self.projectRemover = projectRemover
    }

    func start() {
        guard listener == nil else { return }

        let collection = CloudPaths.projectsCollection(userID: userID)
        listener = collection.addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                print("ProjectSyncService: listener error — \(error)")
                return
            }
            guard let snapshot else { return }
            Task { @MainActor in
                self.handleSnapshot(snapshot)
            }
        }

        schedulePush()
    }

    func stop() {
        listener?.remove()
        listener = nil
        pushTask?.cancel()
        pushTask = nil
        uploadTasks.values.forEach { $0.cancel() }
        uploadTasks.removeAll()
        lastSyncedUpdated.removeAll()
    }

    func schedulePush() {
        guard !applyingRemote else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            await self.pushPendingProjects()
        }
    }

    func enqueueAudioUpload(projectID: UUID, track: Track) {
        guard track.storagePath == nil else { return }
        uploadTasks[track.id]?.cancel()
        uploadTasks[track.id] = Task { [weak self] in
            await self?.uploadAudio(projectID: projectID, track: track)
        }
    }

    func deleteFromCloud(project: Project) async {
        let doc = CloudPaths.projectDocument(userID: userID, projectID: project.id)
        for track in project.tracks {
            if let path = track.storagePath {
                await AudioFileCache.shared.delete(storagePath: path)
            }
        }
        try? await doc.delete()
        lastSyncedUpdated[project.id] = nil
    }

    func deleteTrackFromCloud(_ track: Track) async {
        if let path = track.storagePath {
            await AudioFileCache.shared.delete(storagePath: path)
        }
    }

    // MARK: - Snapshot handling

    private func handleSnapshot(_ snapshot: QuerySnapshot) {
        applyingRemote = true
        defer { applyingRemote = false }

        var merged = snapshotProvider()

        for change in snapshot.documentChanges {
            switch change.type {
            case .removed:
                guard let removedID = UUID(uuidString: change.document.documentID) else { continue }
                merged.removeAll { $0.id == removedID }
                lastSyncedUpdated[removedID] = nil
            case .added, .modified:
                guard let remote = FirestoreProjectCodec.decode(change.document) else { continue }
                if let index = merged.firstIndex(where: { $0.id == remote.id }) {
                    if remote.updatedDate > merged[index].updatedDate {
                        merged[index] = remote
                        lastSyncedUpdated[remote.id] = remote.updatedDate
                    }
                } else {
                    merged.insert(remote, at: 0)
                    lastSyncedUpdated[remote.id] = remote.updatedDate
                }
            }
        }

        projectUpdater(merged, true)
    }

    // MARK: - Push

    private func pushPendingProjects() async {
        let projects = snapshotProvider()

        for project in projects {
            let lastSynced = lastSyncedUpdated[project.id]
            if let lastSynced, project.updatedDate <= lastSynced {
                continue
            }

            do {
                let doc = CloudPaths.projectDocument(userID: userID, projectID: project.id)
                try await doc.setData(FirestoreProjectCodec.encode(project), merge: true)
                lastSyncedUpdated[project.id] = project.updatedDate

                for track in project.tracks where track.storagePath == nil {
                    enqueueAudioUpload(projectID: project.id, track: track)
                }
            } catch {
                print("ProjectSyncService: push failed for \(project.id) — \(error)")
            }
        }
    }

    // MARK: - Audio upload

    private func uploadAudio(projectID: UUID, track: Track) async {
        let localURL = audioDirectory.appendingPathComponent(track.fileName)
        guard FileManager.default.fileExists(atPath: localURL.path) else { return }

        let storagePath = CloudPaths.audioStoragePath(
            userID: userID,
            trackID: track.id,
            fileExtension: track.fileExtension
        )

        do {
            let contentType = mimeType(for: track.fileExtension)
            let uploadedSize = try await AudioFileCache.shared.upload(
                localURL: localURL,
                to: storagePath,
                contentType: contentType
            )

            var synced = track
            synced.storagePath = storagePath
            if uploadedSize > 0 {
                synced.fileSize = uploadedSize
            }

            trackUpdater(projectID, synced, true)
            schedulePush()
        } catch {
            print("ProjectSyncService: audio upload failed for \(track.id) — \(error)")
        }
    }

    private func mimeType(for ext: String) -> String {
        switch ext {
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "aiff", "aif": "audio/aiff"
        case "m4a", "aac": "audio/mp4"
        case "flac": "audio/flac"
        default: "application/octet-stream"
        }
    }
}

private extension DocumentReference {
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

    func setData(_ documentData: [String: Any], merge: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setData(documentData, merge: merge) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
