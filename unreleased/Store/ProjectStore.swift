import Foundation
import Observation
import AVFoundation
import SwiftUI

@Observable
final class ProjectStore {
    var projects: [Project] = []
    var syncStatus: SyncStatus = .offline
    /// Per-track download progress 0…1 while a user-initiated download is active.
    var downloadProgress: [UUID: Double] = [:]

    private let dataURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("projects.json")
    }()

    var audioFilesURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("AudioFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    var downloadsURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    var coverImagesURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("CoverImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private var syncService: ProjectSyncService?
    private var planService: UserPlanService?
    private var storageService: StorageEnforcementService?
    private var profileService: UserProfileService?
    private var sharedSyncService: SharedProjectSyncService?
    private var notificationsService: NotificationsService?
    var currentUserID: String?
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]
    private var suppressSync = false
    /// Stable `UIImage` instances so SwiftUI doesn't crossfade covers on unrelated state updates.
    private var coverImageCache: [String: UIImage] = [:]
    /// Kept weak so store updates can refresh lock-screen / Control Center metadata.
    weak var audioPlayer: AudioPlayer?

    init() {
        load()
    }

    // MARK: - Plan

    var currentPlan: UserPlan = .default

    // MARK: - Storage upsell

    /// Non-nil while the storage upsell sheet should be presented. Observed at the
    /// app root, which shows `StorageUpsellSheet`. Set via `presentStorageUpsell`.
    var storageUpsell: StorageUpsellContext? = nil

    /// Presents the storage upsell for the given reason (deduped so a reason that's
    /// already on screen isn't re-presented).
    func presentStorageUpsell(_ reason: StorageUpsellContext.Reason) {
        guard storageUpsell?.reason != reason else { return }
        storageUpsell = StorageUpsellContext(reason: reason)
    }

    // MARK: - Profile / Username

    /// The signed-in user's username, or nil if not yet set.
    var currentUsername: String? = nil
    /// True after the profile service has delivered its first update (even if username is nil).
    var hasCheckedUsername: Bool = false

    /// Atomically claims a username. Throws if taken.
    func setUsername(_ username: String) async throws {
        guard let userID = currentUserID else { return }
        try await profileService?.setUsername(username, forUserID: userID)
        currentUsername = username
        // Trigger a sync push so the new username is included in project documents.
        syncService?.schedulePush()
    }

    // MARK: - Notifications

    /// In-app notifications addressed to the signed-in user, newest first.
    var notifications: [AppNotification] = []

    var unreadNotificationCount: Int {
        notifications.lazy.filter { !$0.read }.count
    }

    func markNotificationRead(_ notification: AppNotification) {
        guard let userID = currentUserID, !notification.read else { return }
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            notifications[index].read = true
        }
        Task { await NotificationsService.markRead(userID: userID, notificationID: notification.id) }
    }

    func markAllNotificationsRead() {
        guard let userID = currentUserID else { return }
        let unreadIDs = notifications.filter { !$0.read }.map(\.id)
        guard !unreadIDs.isEmpty else { return }
        for index in notifications.indices { notifications[index].read = true }
        Task { await NotificationsService.markAllRead(userID: userID, ids: unreadIDs) }
    }

    func deleteNotification(_ notification: AppNotification) {
        guard let userID = currentUserID else { return }
        notifications.removeAll { $0.id == notification.id }
        Task { await NotificationsService.delete(userID: userID, notificationID: notification.id) }
    }

    // MARK: - Inviting

    /// Searches for users to invite by username, excluding the signed-in user.
    func searchUsersToInvite(_ query: String) async -> [UserSearchResult] {
        await UserProfileService.searchUsers(prefix: query, excludingUID: currentUserID)
    }

    /// Owner invites a user (by UID) to a project they own. Records a pending invite
    /// and delivers an in-app notification (and push, via the Cloud Function trigger).
    /// Returns the notification document ID so the caller can cancel it later if needed.
    @discardableResult
    func inviteUser(_ user: UserSearchResult, to project: Project) async throws -> String {
        guard let ownerUID = currentUserID, let ownerUsername = currentUsername else { return "" }
        return try await ProjectInviteService.inviteUser(
            recipientUID: user.id,
            recipientUsername: user.username,
            project: project,
            ownerUID: ownerUID,
            ownerUsername: ownerUsername
        )
    }

    // MARK: - Storage limit

    /// Nil means no cap (unlimited plan).
    var storageLimitBytes: Int64? {
        currentPlan.storageLimitBytes
    }

    /// Only the user's own projects count against their storage limit. Shared
    /// projects they merely follow/stream live in the owner's storage, not theirs.
    var totalUsedStorageBytes: Int64 {
        projects
            .filter { !$0.isShared }
            .flatMap(\.tracks)
            .reduce(0) { $0 + $1.fileSize }
    }

    var freeStorageBytes: Int64 {
        guard let limit = storageLimitBytes else { return Int64.max }
        return max(0, limit - totalUsedStorageBytes)
    }

    var storageUsedFraction: Double {
        guard let limit = storageLimitBytes, limit > 0 else { return 0 }
        return min(1.0, Double(totalUsedStorageBytes) / Double(limit))
    }

    var hasStorageCapacity: Bool {
        guard let limit = storageLimitBytes else { return true }
        return totalUsedStorageBytes < limit
    }

    /// True when the library already exceeds the plan limit — typically after a
    /// downgrade. Existing tracks are kept, but cloud streaming is paused until
    /// the user frees up enough space to get back under the limit.
    var isOverStorageLimit: Bool {
        guard let limit = storageLimitBytes else { return false }
        return totalUsedStorageBytes > limit
    }

    /// Whether adding `additionalBytes` would still fit within the plan limit.
    /// Used to gate uploads so a well-behaved client never trips the server-side
    /// enforcement (which would otherwise delete the upload and prompt an upsell).
    func canStore(additionalBytes: Int64) -> Bool {
        guard let limit = storageLimitBytes else { return true }
        return totalUsedStorageBytes + max(0, additionalBytes) <= limit
    }

    var formattedTotalUsed: String {
        ByteCountFormatter.string(fromByteCount: totalUsedStorageBytes, countStyle: .file)
    }

    var formattedStorageLimit: String {
        guard let limit = storageLimitBytes else { return "Unlimited" }
        return ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
    }

    var formattedFreeStorage: String {
        guard storageLimitBytes != nil else { return "Unlimited" }
        return ByteCountFormatter.string(fromByteCount: freeStorageBytes, countStyle: .file)
    }

    // MARK: - Cloud sync

    enum SyncStatus: Equatable {
        case offline
        case syncing
        case synced
        case error(String)
    }

    func configureSync(userID: String?) {
        planService?.stop()
        planService = nil

        storageService?.stop()
        storageService = nil

        profileService?.stop()
        profileService = nil

        syncService?.stop()
        syncService = nil

        sharedSyncService?.stop()
        sharedSyncService = nil

        notificationsService?.stop()
        notificationsService = nil

        currentUserID = userID
        syncStatus = userID == nil ? .offline : .syncing

        if userID == nil {
            currentUsername = nil
            hasCheckedUsername = false
            notifications = []
        }

        guard let userID else {
            currentPlan = .default
            return
        }

        let plan = UserPlanService()
        planService = plan
        plan.start(userID: userID) { [weak self] updated in
            self?.currentPlan = updated
        }

        // Server-side quota enforcement backstop: surfaces an upsell when the
        // Cloud Function rejects an over-limit upload (e.g. from a tampered app).
        let storage = StorageEnforcementService()
        storageService = storage
        storage.start(
            userID: userID,
            onState: { _ in },
            onRejection: { [weak self] in
                self?.presentStorageUpsell(.serverBlocked)
            }
        )

        let profile = UserProfileService()
        profileService = profile
        profile.start(userID: userID) { [weak self] username in
            self?.currentUsername = username
            self?.hasCheckedUsername = true
        }

        let notifications = NotificationsService()
        notificationsService = notifications
        notifications.start(userID: userID) { [weak self] items in
            self?.notifications = items
        }

        let service = ProjectSyncService(
            userID: userID,
            audioDirectory: audioFilesURL,
            coverDirectory: coverImagesURL,
            snapshotProvider: { [weak self] in
                self?.projects ?? []
            },
            projectUpdater: { [weak self] projects, persistLocally in
                self?.applyRemoteProjects(projects, persistLocally: persistLocally)
            },
            trackUpdater: { [weak self] projectID, track, persistLocally in
                self?.applyTrackUpdate(track, projectID: projectID, persistLocally: persistLocally)
            },
            projectPatcher: { [weak self] projectID, patch, persistLocally in
                self?.applyProjectPatch(projectID: projectID, patch: patch, persistLocally: persistLocally)
            },
            projectRemover: { [weak self] projectID, persistLocally in
                self?.removeProjectLocally(id: projectID, persistLocally: persistLocally)
            }
        )
        service.onActivityChanged = { [weak self] in
            self?.updateSyncStatus()
        }
        service.usernameProvider = { [weak self] in self?.currentUsername }
        service.canUploadAudioProvider = { [weak self] in !(self?.isOverStorageLimit ?? false) }

        syncService = service
        service.start()

        let shared = SharedProjectSyncService(
            projectUpdater: { [weak self] project in
                self?.applySharedProjectUpdate(project)
            },
            projectRemover: { [weak self] projectID in
                self?.removeSharedProject(projectID)
            }
        )
        sharedSyncService = shared

        // Reconnect listeners for shared projects already saved locally.
        for project in projects where project.isShared {
            if let ownerID = project.ownerID {
                shared.subscribe(ownerID: ownerID, projectID: project.id)
            }
        }

        updateSyncStatus()
    }

    var pendingCloudUploadCount: Int {
        syncService?.pendingUploadTrackCount ?? 0
    }

    private func updateSyncStatus() {
        guard syncService != nil else {
            syncStatus = .offline
            return
        }
        syncStatus = syncService!.isActive ? .syncing : .synced
    }

    // MARK: - Project CRUD

    func addProject(_ project: Project) {
        projects.insert(project, at: 0)
        save()
    }

    func updateProject(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = project
        updated.updatedDate = Date()
        projects[index] = updated
        save()
        audioPlayer?.syncCurrentItemFromStore()
    }

    func deleteProject(_ project: Project) {
        if project.isShared {
            removeSharedProject(project.id)
            return
        }
        project.tracks.forEach {
            cancelDownload(trackID: $0.id)
            deleteAudioFile(fileName: $0.fileName)
            deleteDownloadedFile(fileName: $0.fileName)
        }
        deleteCoverImage(fileName: project.coverImageFileName)
        deleteCoverFromCloud(storagePath: project.coverStoragePath)
        projects.removeAll { $0.id == project.id }
        save()

        let tracks = project.tracks
        let service = syncService
        Task {
            await service?.deleteFromCloud(project: project)
            for track in tracks {
                await service?.deleteTrackFromCloud(track)
            }
        }
    }

    // MARK: - Shared projects

    /// Fetches a project from another user's Firestore collection and adds it to the local library.
    func addSharedProjectByLink(ownerID: String, projectID: UUID) async {
        guard !projects.contains(where: { $0.id == projectID }) else { return }
        guard var project = await sharedSyncService?.fetchProject(ownerID: ownerID, projectID: projectID) else { return }

        // Fetch linkEnabled in parallel with other setup work so the toolbar renders
        // at the right size the very first time the user opens this project.
        let preview = await ProjectInviteService.fetchPreview(ownerUID: ownerID, projectID: project.id)
        project.linkEnabled = preview?.linkEnabled

        projects.insert(project, at: 0)
        persistLocalOnly()

        sharedSyncService?.subscribe(ownerID: ownerID, projectID: projectID)

        // Clear any pending username-invite now that it's been accepted.
        if let myUID = currentUserID {
            await ProjectInviteService.clearPendingInvite(
                ownerUID: ownerID, projectID: projectID, inviteeUID: myUID
            )
        }

        if project.coverStoragePath != nil {
            Task { await downloadSharedCoverIfNeeded(for: project) }
        }
    }

    /// Removes a shared project from the local library and stops its Firestore listener.
    /// Also removes the user from the owner's invitee list so they no longer appear as a
    /// listener and lose read access to the project.
    func removeSharedProject(_ projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }), project.isShared else { return }
        sharedSyncService?.unsubscribe(projectID: projectID)

        // Revoke our own access on the owner's side (delete invitee + any pending invite).
        if let ownerID = project.ownerID, let myUID = currentUserID {
            Task {
                try? await ProjectInviteService.removeInvitee(
                    ownerUID: ownerID, projectID: projectID, inviteeUID: myUID
                )
                await ProjectInviteService.clearPendingInvite(
                    ownerUID: ownerID, projectID: projectID, inviteeUID: myUID
                )
            }
        }

        project.tracks.forEach {
            cancelDownload(trackID: $0.id)
            deleteDownloadedFile(fileName: $0.fileName)
        }
        deleteCoverImage(fileName: project.coverImageFileName)
        projects.removeAll { $0.id == projectID }
        persistLocalOnly()
    }

    private func applySharedProjectUpdate(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = project
        let local = projects[index]
        // Preserve locally analyzed waveforms.
        for tIdx in updated.tracks.indices {
            if let localTrack = local.tracks.first(where: { $0.id == updated.tracks[tIdx].id }),
               updated.tracks[tIdx].waveformData == nil {
                updated.tracks[tIdx].waveformData = localTrack.waveformData
            }
        }
        // linkEnabled lives in the preview doc, not the project doc — keep the cached value.
        updated.linkEnabled = local.linkEnabled
        projects[index] = updated
        persistLocalOnly()

        if updated.coverStoragePath != nil {
            Task { await downloadSharedCoverIfNeeded(for: updated) }
        }
    }

    /// Persists a refreshed `linkEnabled` value for a shared project. No-op for own projects.
    func setLinkEnabled(_ enabled: Bool, forSharedProjectID projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID && $0.isShared }) else { return }
        guard projects[index].linkEnabled != enabled else { return }
        projects[index].linkEnabled = enabled
        persistLocalOnly()
    }

    private func downloadSharedCoverIfNeeded(for project: Project) async {
        guard let storagePath = project.coverStoragePath else { return }
        let fileName = project.coverImageFileName ?? "\(project.id.uuidString).jpg"
        let destination = coverImagesURL.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try? await AudioFileCache.shared.download(storagePath: storagePath, to: destination)
    }

    // MARK: - Track CRUD

    func addTrack(_ track: Track, to projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].tracks.append(track)
        projects[index].updatedDate = Date()
        save()
        syncService?.enqueueAudioUpload(projectID: projectID, track: track)
    }

    func deleteTrack(_ track: Track, from projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].tracks.removeAll { $0.id == track.id }
        projects[index].updatedDate = Date()
        cancelDownload(trackID: track.id)
        deleteAudioFile(fileName: track.fileName)
        deleteDownloadedFile(fileName: track.fileName)
        save()

        let service = syncService
        Task { await service?.deleteTrackFromCloud(track) }
    }

    func moveTrack(in projectID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].tracks.move(fromOffsets: source, toOffset: destination)
        projects[index].updatedDate = Date()
        save()
    }

    /// Moves a track to another project. The audio file on disk is unchanged.
    func moveTrack(_ track: Track, from sourceProjectID: UUID, to destinationProjectID: UUID) {
        guard sourceProjectID != destinationProjectID,
              let sourceIdx = projects.firstIndex(where: { $0.id == sourceProjectID }),
              let destIdx = projects.firstIndex(where: { $0.id == destinationProjectID }),
              let trackIdx = projects[sourceIdx].tracks.firstIndex(where: { $0.id == track.id })
        else { return }

        let track = projects[sourceIdx].tracks.remove(at: trackIdx)
        projects[sourceIdx].updatedDate = Date()
        projects[destIdx].tracks.append(track)
        projects[destIdx].updatedDate = Date()
        save()
    }

    // MARK: - Cover images

    func coverImage(for project: Project) -> UIImage? {
        loadCoverImage(fileName: project.coverImageFileName)
    }

    func loadCoverImage(fileName: String?) -> UIImage? {
        guard let fileName else { return nil }
        if let cached = coverImageCache[fileName] { return cached }
        let url = coverImagesURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data)
        else { return nil }
        coverImageCache[fileName] = image
        return image
    }

    @discardableResult
    func saveCoverImage(_ image: UIImage, projectID: UUID) -> String? {
        let version = Int(Date().timeIntervalSince1970)
        let fileName = "\(projectID.uuidString)-\(version).jpg"
        let url = coverImagesURL.appendingPathComponent(fileName)
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            coverImageCache[fileName] = image
            return fileName
        } catch {
            print("ProjectStore: cover save failed — \(error)")
            return nil
        }
    }

    func deleteCoverImage(fileName: String?) {
        guard let fileName else { return }
        coverImageCache.removeValue(forKey: fileName)
        let url = coverImagesURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    func accentColor(for project: Project) -> Color {
        if let hex = project.accentColorHex {
            return ProjectAccentColor.color(hex: hex)
        }
        return ProjectAccentColor.color(hex: ProjectAccentColor.hex(from: project.gradient))
    }

    func resolvedAccentHex(gradient: GradientTheme, coverImage: UIImage?) -> String {
        if let coverImage {
            return ProjectAccentColor.hex(from: coverImage)
        }
        return ProjectAccentColor.hex(from: gradient)
    }

    /// Returns the two hex gradient stop colors extracted from `coverImage`, or nil when no image is provided.
    func resolvedCoverGradientColors(coverImage: UIImage?) -> [String]? {
        guard let coverImage else { return nil }
        let (start, end) = ProjectAccentColor.gradientHexPair(from: coverImage)
        return [start, end]
    }

    /// Returns a `GradientTheme` suitable for the vinyl ring:
    /// uses cover-extracted colors when available, otherwise falls back to the project's preset gradient.
    func vinylGradient(for project: Project) -> GradientTheme {
        if let colors = project.coverGradientColors, colors.count >= 2 {
            return GradientTheme(colors: [colors[0], colors[1]], startX: 0, startY: 0, endX: 1, endY: 1)
        }
        return project.gradient
    }

    func enqueueCoverUpload(projectID: UUID) {
        syncService?.enqueueCoverUpload(projectID: projectID)
    }

    func deleteCoverFromCloud(storagePath: String?) {
        guard let storagePath else { return }
        let service = syncService
        Task { await service?.deleteCoverFromCloud(storagePath: storagePath) }
    }

    func hasLocalCoverFile(for project: Project) -> Bool {
        guard let fileName = project.coverImageFileName else { return false }
        return FileManager.default.fileExists(
            atPath: coverImagesURL.appendingPathComponent(fileName).path
        )
    }

    // MARK: - Audio Import

    func importAudioFile(from sourceURL: URL) async throws -> Track {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.lowercased()
        let fileName = "\(UUID().uuidString).\(ext)"
        let destURL = audioFilesURL.appendingPathComponent(fileName)

        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: destURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0

        let asset = AVURLAsset(url: destURL)
        let duration: TimeInterval
        do {
            let cmDuration = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cmDuration)
        } catch {
            duration = 0
        }

        let rawTitle = sourceURL.deletingPathExtension().lastPathComponent
        let title = rawTitle.isEmpty ? "Untitled" : rawTitle

        let waveform = await WaveformAnalyzer.analyze(url: destURL, targetBars: 200)

        var track = Track(
            title: title,
            fileName: fileName,
            fileSize: fileSize,
            duration: duration,
            waveformData: waveform.isEmpty ? nil : waveform,
            isDownloaded: true
        )
        try? pinTrackToDownloads(&track)
        return track
    }

    // MARK: - Downloads

    func downloadedFileURL(for track: Track) -> URL {
        downloadsURL.appendingPathComponent(track.fileName)
    }

    func hasDownloadedFile(for track: Track) -> Bool {
        let url = downloadedFileURL(for: track)
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              size > 0
        else { return false }
        if track.fileSize > 0 { return size == track.fileSize }
        return true
    }

    func isDownloading(_ trackID: UUID) -> Bool {
        downloadTasks[trackID] != nil
    }

    func isTrackDownloaded(_ track: Track) -> Bool {
        track.isDownloaded && hasDownloadedFile(for: track)
    }

    func projectHasPendingDownloads(_ project: Project) -> Bool {
        project.tracks.contains { !isTrackDownloaded($0) && ($0.storagePath != nil || hasCachedAudio(for: $0)) }
    }

    func projectIsFullyDownloaded(_ project: Project) -> Bool {
        !project.tracks.isEmpty && project.tracks.allSatisfy(isTrackDownloaded)
    }

    func downloadTrack(_ track: Track, in projectID: UUID) {
        guard !isDownloading(track.id), !isTrackDownloaded(track) else { return }

        // Over the storage limit (e.g. after a downgrade): block pulling more
        // data down from the cloud until the user frees up space. Already-cached
        // tracks can still be pinned offline.
        if isOverStorageLimit, !hasCachedAudio(for: track) {
            presentStorageUpsell(.overLimitPlayback)
            return
        }

        downloadTasks[track.id]?.cancel()
        downloadTasks[track.id] = Task { @MainActor in
            downloadProgress[track.id] = 0
            defer {
                downloadProgress.removeValue(forKey: track.id)
                downloadTasks.removeValue(forKey: track.id)
            }

            do {
                try await performDownload(track)
                setTrackDownloaded(track.id, projectID: projectID, downloaded: true)
            } catch {
                if !Task.isCancelled {
                    print("ProjectStore: download failed — \(error)")
                }
            }
        }
    }

    func removeDownload(_ track: Track, in projectID: UUID) {
        cancelDownload(trackID: track.id)
        deleteDownloadedFile(fileName: track.fileName)
        setTrackDownloaded(track.id, projectID: projectID, downloaded: false)
    }

    func downloadProject(_ projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        for track in project.tracks where !isTrackDownloaded(track) {
            downloadTrack(track, in: projectID)
        }
    }

    func removeProjectDownloads(_ projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        for track in project.tracks where isTrackDownloaded(track) {
            removeDownload(track, in: projectID)
        }
    }

    func updateTrackNotes(_ notes: String, trackID: UUID, projectID: UUID) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let tIdx = projects[pIdx].tracks.firstIndex(where: { $0.id == trackID })
        else { return }

        guard projects[pIdx].tracks[tIdx].notes != notes else { return }
        projects[pIdx].tracks[tIdx].notes = notes
        projects[pIdx].updatedDate = Date()
        save()
    }

    func updateTrackTitle(_ title: String, trackID: UUID, projectID: UUID) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let tIdx = projects[pIdx].tracks.firstIndex(where: { $0.id == trackID })
        else { return }

        guard projects[pIdx].tracks[tIdx].title != title else { return }
        projects[pIdx].tracks[tIdx].title = title
        projects[pIdx].updatedDate = Date()
        save()
        audioPlayer?.syncCurrentItemFromStore()
    }

    func audioFileURL(for track: Track) -> URL {
        audioFilesURL.appendingPathComponent(track.fileName)
    }

    func localAudioURL(for track: Track) -> URL {
        if hasDownloadedFile(for: track) {
            return downloadedFileURL(for: track)
        }
        return audioFileURL(for: track)
    }

    func hasCachedAudio(for track: Track) -> Bool {
        let url = audioFileURL(for: track)
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              size > 0
        else { return false }
        if track.fileSize > 0 { return size == track.fileSize }
        return true
    }

    /// Prefers user download, then cache; otherwise streams once into the cache directory.
    func playbackURL(
        for track: Track,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> URL? {
        if hasDownloadedFile(for: track) {
            onProgress?(1)
            return downloadedFileURL(for: track)
        }

        if hasCachedAudio(for: track) {
            onProgress?(1)
            return audioFileURL(for: track)
        }

        guard let storagePath = track.storagePath else {
            return nil
        }

        do {
            return try await AudioFileCache.shared.ensureLocalFile(
                for: track,
                storagePath: storagePath,
                in: audioFilesURL,
                onProgress: onProgress
            )
        } catch {
            print("ProjectStore: audio cache failed — \(error)")
            return nil
        }
    }

    // MARK: - Remote merge

    private func applyRemoteProjects(_ projects: [Project], persistLocally: Bool) {
        suppressSync = true
        // Waveforms are stored inline on the Firestore document, so a remote
        // snapshot normally already carries them. This re-applies the local
        // waveform only as a fallback (e.g. a not-yet-pushed local import or a
        // legacy track) so the UI never flips to placeholder bars.
        var merged = projects
        for pIdx in merged.indices {
            guard let local = self.projects.first(where: { $0.id == merged[pIdx].id }) else { continue }
            for tIdx in merged[pIdx].tracks.indices where merged[pIdx].tracks[tIdx].waveformData == nil {
                if let localTrack = local.tracks.first(where: { $0.id == merged[pIdx].tracks[tIdx].id }) {
                    merged[pIdx].tracks[tIdx].waveformData = localTrack.waveformData
                }
            }
            // Delete the stale local cover when the remote project has a different cover file.
            if let oldFileName = local.coverImageFileName,
               oldFileName != merged[pIdx].coverImageFileName {
                deleteCoverImage(fileName: oldFileName)
            }
        }
        self.projects = merged
        if persistLocally {
            persistLocalOnly()
        }
        suppressSync = false
        syncService?.schedulePush()

        for project in self.projects where project.coverStoragePath != nil {
            syncService?.enqueueCoverDownload(projectID: project.id)
        }
    }

    private func applyProjectPatch(
        projectID: UUID,
        patch: ProjectSyncService.ProjectPatch,
        persistLocally: Bool
    ) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        if let coverStoragePath = patch.coverStoragePath {
            projects[index].coverStoragePath = coverStoragePath
        }
        if let accentColorHex = patch.accentColorHex {
            projects[index].accentColorHex = accentColorHex
        }
        if let coverGradientColors = patch.coverGradientColors {
            projects[index].coverGradientColors = coverGradientColors
        }
        projects[index].updatedDate = Date()
        if persistLocally {
            persistLocalOnly()
        }
    }

    private func applyTrackUpdate(_ track: Track, projectID: UUID, persistLocally: Bool) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let tIdx = projects[pIdx].tracks.firstIndex(where: { $0.id == track.id })
        else { return }

        suppressSync = true
        // Fall back to the local waveform if a remote update arrives without one.
        var updatedTrack = track
        if updatedTrack.waveformData == nil {
            updatedTrack.waveformData = projects[pIdx].tracks[tIdx].waveformData
        }
        projects[pIdx].tracks[tIdx] = updatedTrack
        projects[pIdx].updatedDate = Date()
        if persistLocally {
            persistLocalOnly()
        }
        suppressSync = false
        syncService?.schedulePush()
    }

    private func removeProjectLocally(id: UUID, persistLocally: Bool) {
        suppressSync = true
        projects.removeAll { $0.id == id }
        if persistLocally {
            persistLocalOnly()
        }
        suppressSync = false
    }

    // MARK: - Persistence

    private func deleteAudioFile(fileName: String) {
        let url = audioFilesURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    private func deleteDownloadedFile(fileName: String) {
        let url = downloadsURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    private func cancelDownload(trackID: UUID) {
        downloadTasks[trackID]?.cancel()
        downloadTasks.removeValue(forKey: trackID)
        downloadProgress.removeValue(forKey: trackID)
    }

    private func setTrackDownloaded(_ trackID: UUID, projectID: UUID, downloaded: Bool) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let tIdx = projects[pIdx].tracks.firstIndex(where: { $0.id == trackID })
        else { return }
        projects[pIdx].tracks[tIdx].isDownloaded = downloaded
        projects[pIdx].updatedDate = Date()
        save()
    }

    private func performDownload(_ track: Track) async throws {
        let destination = downloadedFileURL(for: track)
        try FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        if let storagePath = track.storagePath {
            let trackID = track.id
            _ = try await AudioFileCache.shared.ensureLocalFile(
                for: track,
                storagePath: storagePath,
                in: downloadsURL,
                onProgress: { @Sendable progress in
                    Task { @MainActor in
                        self.downloadProgress[trackID] = progress
                    }
                }
            )
            return
        }

        if hasCachedAudio(for: track) {
            try FileManager.default.copyItem(at: audioFileURL(for: track), to: destination)
            await MainActor.run { downloadProgress[track.id] = 1 }
            return
        }

        throw URLError(.fileDoesNotExist)
    }

    private func pinTrackToDownloads(_ track: inout Track) throws {
        let destination = downloadedFileURL(for: track)
        let source = audioFileURL(for: track)
        try FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        track.isDownloaded = true
    }

    private func reconcileDownloadsOnLoad() {
        var changed = false
        for pIdx in projects.indices {
            for tIdx in projects[pIdx].tracks.indices {
                var track = projects[pIdx].tracks[tIdx]
                if hasDownloadedFile(for: track) {
                    if !track.isDownloaded {
                        track.isDownloaded = true
                        projects[pIdx].tracks[tIdx] = track
                        changed = true
                    }
                } else if track.isDownloaded {
                    track.isDownloaded = false
                    projects[pIdx].tracks[tIdx] = track
                    changed = true
                } else if track.storagePath == nil, hasCachedAudio(for: track) {
                    if (try? pinTrackToDownloads(&track)) != nil {
                        projects[pIdx].tracks[tIdx] = track
                        changed = true
                    }
                }
            }
        }
        if changed { persistLocalOnly() }
    }

    func save() {
        persistLocalOnly()
        guard !suppressSync else { return }
        syncService?.schedulePush()
    }

    private func persistLocalOnly() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: dataURL, options: .atomicWrite)
        } catch {
            print("ProjectStore: save failed — \(error)")
        }
        mirrorProjectsToAppGroup()
    }

    private func mirrorProjectsToAppGroup() {
        let mirrors = projects.map { project in
            AudioImportBridge.ProjectMirror(
                id: project.id,
                name: project.name,
                gradientColors: project.gradient.colors,
                gradientStartX: project.gradient.startX,
                gradientStartY: project.gradient.startY,
                gradientEndX: project.gradient.endX,
                gradientEndY: project.gradient.endY
            )
        }
        AudioImportBridge.mirrorProjects(mirrors)
    }

    /// Wipes all locally persisted library data. Call on sign-out so the next
    /// account starts from a clean slate rather than seeing the previous user's projects.
    func clearLocalLibrary() {
        projects = []
        try? FileManager.default.removeItem(at: dataURL)
        AudioImportBridge.mirrorProjects([])
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: dataURL.path) else { return }
        do {
            let data = try Data(contentsOf: dataURL)
            projects = try JSONDecoder().decode([Project].self, from: data)
            reconcileDownloadsOnLoad()
        } catch {
            print("ProjectStore: load failed — \(error)")
        }
    }
}
