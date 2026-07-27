import FirebaseFirestore
import Foundation

/// Syncs projects with Firestore and uploads audio/covers to Storage. Local JSON remains the UI source of truth.
@MainActor
final class ProjectSyncService {
    struct ProjectPatch {
        var coverStoragePath: String?
        var accentColorHex: String?
        var coverGradientColors: [String]?
    }

    typealias ProjectSnapshotProvider = () -> [Project]
    typealias ProjectUpdater = (_ projects: [Project], _ persistLocally: Bool) -> Void
    typealias TrackUpdater = (_ projectID: UUID, _ track: Track, _ persistLocally: Bool) -> Void
    typealias ProjectPatcher = (_ projectID: UUID, _ patch: ProjectPatch, _ persistLocally: Bool) -> Void
    typealias ProjectRemover = (_ projectID: UUID, _ persistLocally: Bool) -> Void

    private let userID: String
    private let audioDirectory: URL
    private let coverDirectory: URL
    private let snapshotProvider: ProjectSnapshotProvider
    private let projectUpdater: ProjectUpdater
    private let trackUpdater: TrackUpdater
    private let projectPatcher: ProjectPatcher
    private let projectRemover: ProjectRemover
    /// Provides the current user's username for embedding in project pushes.
    var usernameProvider: (() -> String?)? = nil
    /// Returns false when the library is over the plan's storage limit, so audio
    /// uploads are held back rather than uploaded and immediately rejected by the
    /// server-side quota enforcement (which would also loop and re-prompt upsells).
    var canUploadAudioProvider: (() -> Bool)? = nil

    private var listener: ListenerRegistration?
    private var pushTask: Task<Void, Never>?
    private var audioRepairTask: Task<Void, Never>?
    private var lastSyncedUpdated: [UUID: Date] = [:]
    private var applyingRemote = false
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    private var coverUploadTasks: [UUID: Task<Void, Never>] = [:]
    private var coverDownloadTasks: [UUID: Task<Void, Never>] = [:]
    /// Storage paths that returned 404 — skip retrying until next session.
    private var failedCoverStoragePaths: Set<String> = []
    private var isPushing = false

    var onActivityChanged: (@MainActor () -> Void)?
    /// Called on the main actor after a cover image has been successfully downloaded to disk.
    var onCoverDownloaded: (@MainActor (UUID) -> Void)?

    /// True while metadata is pushing, uploads are running, or cloud work is still pending.
    var isActive: Bool {
        isPushing
            || pushTask != nil
            || audioRepairTask != nil
            || !uploadTasks.isEmpty
            || !coverUploadTasks.isEmpty
            || hasPendingCloudWork
    }

    /// Tracks with a local audio file that still need uploading to Storage.
    var pendingUploadTrackCount: Int {
        snapshotProvider()
            .filter { !$0.isShared }
            .flatMap(\.tracks)
            .reduce(0) { count, track in
                count + uploadCandidates(in: track).lazy.filter { version in
                    let localURL = self.audioDirectory.appendingPathComponent(version.fileName)
                    return version.storagePath == nil
                        && FileManager.default.fileExists(atPath: localURL.path)
                }.count
            }
    }

    /// Distinguishes an upload that is actively making progress from local
    /// audio that remains pending after cloud storage rejected it.
    var hasActiveAudioUploads: Bool {
        !uploadTasks.isEmpty
    }

    private var hasPendingCloudWork: Bool {
        let projects = snapshotProvider().filter { !$0.isShared }
        for project in projects {
            let lastSynced = lastSyncedUpdated[project.id]
            if lastSynced == nil || project.updatedDate > lastSynced! {
                return true
            }

            for track in project.tracks {
                let hasPendingVersion = uploadCandidates(in: track).contains { version in
                    let localURL = audioDirectory.appendingPathComponent(version.fileName)
                    return version.storagePath == nil
                        && FileManager.default.fileExists(atPath: localURL.path)
                }
                if hasPendingVersion {
                    return true
                }
            }

            if let fileName = project.coverImageFileName,
               project.coverStoragePath == nil {
                let localURL = coverDirectory.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: localURL.path) {
                    return true
                }
            }
        }
        return false
    }

    private func notifyActivityChanged() {
        onActivityChanged?()
    }

    init(
        userID: String,
        audioDirectory: URL,
        coverDirectory: URL,
        snapshotProvider: @escaping ProjectSnapshotProvider,
        projectUpdater: @escaping ProjectUpdater,
        trackUpdater: @escaping TrackUpdater,
        projectPatcher: @escaping ProjectPatcher,
        projectRemover: @escaping ProjectRemover
    ) {
        self.userID = userID
        self.audioDirectory = audioDirectory
        self.coverDirectory = coverDirectory
        self.snapshotProvider = snapshotProvider
        self.projectUpdater = projectUpdater
        self.trackUpdater = trackUpdater
        self.projectPatcher = projectPatcher
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
        scheduleMissingAudioRepair()
    }

    func stop() {
        listener?.remove()
        listener = nil
        pushTask?.cancel()
        pushTask = nil
        audioRepairTask?.cancel()
        audioRepairTask = nil
        isPushing = false
        uploadTasks.values.forEach { $0.cancel() }
        uploadTasks.removeAll()
        coverUploadTasks.values.forEach { $0.cancel() }
        coverUploadTasks.removeAll()
        coverDownloadTasks.values.forEach { $0.cancel() }
        coverDownloadTasks.removeAll()
        lastSyncedUpdated.removeAll()
        failedCoverStoragePaths.removeAll()
    }

    func schedulePush() {
        guard !applyingRemote else { return }
        pushTask?.cancel()
        notifyActivityChanged()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            await self.pushPendingProjects()
            self.pushTask = nil
            self.notifyActivityChanged()
        }
    }

    /// Repairs cloud objects that disappeared while their Firestore
    /// `storagePath` remained intact. Without this check iOS keeps playing its
    /// local cache, but web playback receives `storage/object-not-found`.
    func scheduleMissingAudioRepair() {
        guard audioRepairTask == nil else { return }
        audioRepairTask = Task { [weak self] in
            defer {
                self?.audioRepairTask = nil
                self?.notifyActivityChanged()
            }
            await self?.repairMissingAudioObjects()
        }
        notifyActivityChanged()
    }

    private func repairMissingAudioObjects() async {
        if let canUploadAudioProvider, !canUploadAudioProvider() { return }

        let projects = snapshotProvider().filter { !$0.isShared }
        for project in projects {
            for track in project.tracks {
                for version in uploadCandidates(in: track) {
                    guard !Task.isCancelled else { return }
                    guard let storagePath = version.storagePath else { continue }

                    let localURL = audioDirectory.appendingPathComponent(version.fileName)
                    guard FileManager.default.fileExists(atPath: localURL.path) else { continue }

                    do {
                        let exists = try await AudioFileCache.shared.objectExists(
                            storagePath: storagePath
                        )
                        guard !exists else { continue }

                        if !track.versions.isEmpty {
                            try await writeVersionAccess(
                                projectID: project.id,
                                version: version
                            )
                        }
                        _ = try await AudioFileCache.shared.upload(
                            localURL: localURL,
                            to: storagePath,
                            contentType: mimeType(for: version.fileExtension)
                        )
                    } catch {
                        print(
                            "ProjectSyncService: missing audio repair failed for "
                            + "\(version.id) — \(error)"
                        )
                    }
                }
            }
        }
    }

    func enqueueAudioUpload(projectID: UUID, track: Track) {
        guard uploadCandidates(in: track).contains(where: { $0.storagePath == nil }),
              uploadTasks[track.id] == nil
        else { return }
        let trackID = track.id
        uploadTasks[trackID] = Task { [weak self] in
            defer {
                self?.uploadTasks.removeValue(forKey: trackID)
                self?.notifyActivityChanged()
            }
            await self?.uploadAudio(projectID: projectID, track: track)
        }
        notifyActivityChanged()
    }

    func enqueueCoverUpload(projectID: UUID) {
        coverUploadTasks[projectID]?.cancel()
        notifyActivityChanged()
        coverUploadTasks[projectID] = Task { [weak self] in
            defer {
                self?.coverUploadTasks.removeValue(forKey: projectID)
                self?.notifyActivityChanged()
            }
            await self?.uploadCover(projectID: projectID)
        }
    }

    func enqueueCoverDownload(projectID: UUID) {
        guard coverDownloadTasks[projectID] == nil else { return }
        coverDownloadTasks[projectID] = Task { [weak self] in
            await self?.downloadCover(projectID: projectID)
            self?.coverDownloadTasks.removeValue(forKey: projectID)
        }
    }

    func deleteFromCloud(project: Project) async {
        let doc = CloudPaths.projectDocument(userID: userID, projectID: project.id)
        for track in project.tracks {
            await deleteTrackFromCloud(track)
        }
        if let coverPath = project.coverStoragePath {
            await AudioFileCache.shared.delete(storagePath: coverPath)
        }
        try? await doc.delete()
        lastSyncedUpdated[project.id] = nil
    }

    func deleteCoverFromCloud(storagePath: String) async {
        await AudioFileCache.shared.delete(storagePath: storagePath)
    }

    func deleteTrackFromCloud(_ track: Track) async {
        let uploadTask = uploadTasks[track.id]
        uploadTask?.cancel()
        await uploadTask?.value
        uploadTasks[track.id] = nil
        let paths = Set(track.displayedVersions.map { version in
            version.storagePath ?? expectedStoragePath(for: version, in: track)
        })
        for path in paths {
            await AudioFileCache.shared.delete(storagePath: path)
        }
        for version in track.versions {
            try? await CloudPaths.versionAccessDocument(
                userID: userID,
                versionID: version.id
            ).delete()
        }
    }

    func deleteVersionFromCloud(_ version: TrackVersion, trackID: UUID) async {
        let uploadTask = uploadTasks[trackID]
        uploadTask?.cancel()
        await uploadTask?.value
        uploadTasks[trackID] = nil
        let path = version.storagePath ?? CloudPaths.versionAudioStoragePath(
            userID: userID,
            versionID: version.id,
            fileExtension: version.fileExtension
        )
        await AudioFileCache.shared.delete(storagePath: path)
        try? await CloudPaths.versionAccessDocument(
            userID: userID,
            versionID: version.id
        ).delete()
    }

    func updateVersionAccess(
        projectID: UUID,
        version: TrackVersion
    ) async {
        do {
            try await writeVersionAccess(projectID: projectID, version: version)
        } catch {
            print("ProjectSyncService: version visibility update failed — \(error)")
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
        isPushing = true
        notifyActivityChanged()
        defer {
            isPushing = false
            notifyActivityChanged()
        }

        let projects = snapshotProvider().filter { !$0.isShared }

        for project in projects {
            let lastSynced = lastSyncedUpdated[project.id]
            if let lastSynced, project.updatedDate <= lastSynced {
                continue
            }

            do {
                let doc = CloudPaths.projectDocument(userID: userID, projectID: project.id)
                let username = usernameProvider?()
                try await doc.setData(FirestoreProjectCodec.encode(project, ownerUsername: username), merge: true)
                await ProjectInviteService.refreshPreviewIfExists(
                    project: project,
                    ownerUID: userID,
                    ownerUsername: username
                )
                for track in project.tracks {
                    for version in track.versions {
                        try await writeVersionAccess(projectID: project.id, version: version)
                    }
                }
                lastSyncedUpdated[project.id] = project.updatedDate

                for track in project.tracks
                where uploadCandidates(in: track).contains(where: { $0.storagePath == nil }) {
                    enqueueAudioUpload(projectID: project.id, track: track)
                }

                if project.coverImageFileName != nil && project.coverStoragePath == nil {
                    enqueueCoverUpload(projectID: project.id)
                }
            } catch {
                print("ProjectSyncService: push failed for \(project.id) — \(error)")
            }
        }
    }

    // MARK: - Audio upload

    private func uploadAudio(projectID: UUID, track: Track) async {
        // Hold uploads while over the storage limit; the server would reject them
        // anyway. They resume automatically once the user frees up space.
        if let canUploadAudioProvider, !canUploadAudioProvider() { return }

        var synced = track
        if synced.versions.isEmpty {
            guard synced.storagePath == nil else { return }
            let localURL = audioDirectory.appendingPathComponent(synced.fileName)
            guard FileManager.default.fileExists(atPath: localURL.path) else { return }
            let storagePath = CloudPaths.audioStoragePath(
                userID: userID,
                trackID: synced.id,
                fileExtension: synced.fileExtension
            )
            do {
                let uploadedSize = try await AudioFileCache.shared.upload(
                    localURL: localURL,
                    to: storagePath,
                    contentType: mimeType(for: synced.fileExtension)
                )
                synced.storagePath = storagePath
                if uploadedSize > 0 { synced.fileSize = uploadedSize }
                trackUpdater(projectID, synced, true)
                schedulePush()
            } catch {
                print("ProjectSyncService: audio upload failed for \(track.id) — \(error)")
            }
            return
        }

        for index in synced.versions.indices where synced.versions[index].storagePath == nil {
            guard !Task.isCancelled else { return }
            let version = synced.versions[index]
            let localURL = audioDirectory.appendingPathComponent(version.fileName)
            guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
            let storagePath = CloudPaths.versionAudioStoragePath(
                userID: userID,
                versionID: version.id,
                fileExtension: version.fileExtension
            )

            do {
                try await writeVersionAccess(projectID: projectID, version: version)
                let uploadedSize = try await AudioFileCache.shared.upload(
                    localURL: localURL,
                    to: storagePath,
                    contentType: mimeType(for: version.fileExtension)
                )
                synced.versions[index].storagePath = storagePath
                if uploadedSize > 0 {
                    synced.versions[index].fileSize = uploadedSize
                }
                synced.applyActiveVersionMetadata()
                trackUpdater(projectID, synced, true)
                schedulePush()
            } catch {
                print(
                    "ProjectSyncService: audio upload failed for version "
                    + "\(version.id) — \(error)"
                )
            }
        }
    }

    private func uploadCandidates(in track: Track) -> [TrackVersion] {
        track.displayedVersions
    }

    private func expectedStoragePath(for version: TrackVersion, in track: Track) -> String {
        if track.versions.isEmpty {
            return CloudPaths.audioStoragePath(
                userID: userID,
                trackID: track.id,
                fileExtension: version.fileExtension
            )
        }
        return CloudPaths.versionAudioStoragePath(
            userID: userID,
            versionID: version.id,
            fileExtension: version.fileExtension
        )
    }

    private func writeVersionAccess(
        projectID: UUID,
        version: TrackVersion
    ) async throws {
        try await CloudPaths.versionAccessDocument(
            userID: userID,
            versionID: version.id
        ).setData(
            [
                "projectID": projectID.uuidString,
                "isPublic": version.isPublic,
            ],
            merge: true
        )
    }

    // MARK: - Cover upload / download

    private func uploadCover(projectID: UUID) async {
        guard let project = snapshotProvider().first(where: { $0.id == projectID }),
              let fileName = project.coverImageFileName,
              project.coverStoragePath == nil
        else { return }

        let localURL = coverDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: localURL.path) else { return }

        let storagePath = CloudPaths.coverStoragePath(userID: userID, fileName: fileName)

        do {
            _ = try await AudioFileCache.shared.upload(
                localURL: localURL,
                to: storagePath,
                contentType: "image/jpeg"
            )
            projectPatcher(
                projectID,
                ProjectPatch(coverStoragePath: storagePath, accentColorHex: project.accentColorHex, coverGradientColors: project.coverGradientColors),
                true
            )
            schedulePush()
        } catch {
            print("ProjectSyncService: cover upload failed for \(projectID) — \(error)")
        }
    }

    private func downloadCover(projectID: UUID) async {
        guard let project = snapshotProvider().first(where: { $0.id == projectID }),
              let storagePath = project.coverStoragePath,
              !failedCoverStoragePaths.contains(storagePath)
        else { return }

        let fileName = project.coverImageFileName ?? "\(projectID.uuidString).jpg"
        let destination = coverDirectory.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destination.path) { return }

        do {
            try await AudioFileCache.shared.download(storagePath: storagePath, to: destination)
            onCoverDownloaded?(projectID)
        } catch {
            failedCoverStoragePaths.insert(storagePath)
            print("ProjectSyncService: cover download failed for \(projectID) — \(error)")
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
