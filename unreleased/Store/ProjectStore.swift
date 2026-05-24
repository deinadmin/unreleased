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
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]
    private var suppressSync = false
    /// Stable `UIImage` instances so SwiftUI doesn't crossfade covers on unrelated state updates.
    private var coverImageCache: [String: UIImage] = [:]
    /// Kept weak so store updates can refresh lock-screen / Control Center metadata.
    weak var audioPlayer: AudioPlayer?

    init() {
        load()
    }

    // MARK: - Cloud sync

    enum SyncStatus: Equatable {
        case offline
        case syncing
        case synced
        case error(String)
    }

    func configureSync(userID: String?) {
        syncService?.stop()
        syncService = nil
        syncStatus = userID == nil ? .offline : .syncing

        guard let userID else { return }

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

        syncService = service
        service.start()
        syncStatus = .synced
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
        let fileName = "\(projectID.uuidString).jpg"
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
        if let image = coverImage(for: project) {
            return ProjectAccentColor.color(hex: ProjectAccentColor.hex(from: image))
        }
        return ProjectAccentColor.color(hex: ProjectAccentColor.hex(from: project.gradient))
    }

    func resolvedAccentHex(gradient: GradientTheme, coverImage: UIImage?) -> String {
        if let coverImage {
            return ProjectAccentColor.hex(from: coverImage)
        }
        return ProjectAccentColor.hex(from: gradient)
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
                if let updated = trackInProject(track.id, projectID: projectID) {
                    analyzeWaveformIfNeeded(for: updated, in: projectID)
                }
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

    /// Analyzes waveform from a local audio file. Call after playback has cached the track. Never synced to Firestore.
    func analyzeWaveformIfNeeded(for track: Track, in projectID: UUID) {
        guard track.waveformData == nil,
              hasCachedAudio(for: track) || hasDownloadedFile(for: track)
        else { return }
        let url = localAudioURL(for: track)
        Task {
            let waveform = await WaveformAnalyzer.analyze(url: url, targetBars: 200)
            guard !waveform.isEmpty,
                  let pIdx = projects.firstIndex(where: { $0.id == projectID }),
                  let tIdx = projects[pIdx].tracks.firstIndex(where: { $0.id == track.id })
            else { return }
            projects[pIdx].tracks[tIdx].waveformData = waveform
            save()
        }
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
        // waveformData is a local-only cache never written to Firestore.
        // Re-apply it from the current store so a remote snapshot doesn't
        // silently wipe the analyzed waveforms and cause the UI to fall
        // back to seeded random bars mid-playback.
        var merged = projects
        for pIdx in merged.indices {
            guard let local = self.projects.first(where: { $0.id == merged[pIdx].id }) else { continue }
            for tIdx in merged[pIdx].tracks.indices where merged[pIdx].tracks[tIdx].waveformData == nil {
                if let localTrack = local.tracks.first(where: { $0.id == merged[pIdx].tracks[tIdx].id }) {
                    merged[pIdx].tracks[tIdx].waveformData = localTrack.waveformData
                }
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
        // Preserve local waveformData — Firestore never stores it.
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

    private func trackInProject(_ trackID: UUID, projectID: UUID) -> Track? {
        projects.first(where: { $0.id == projectID })?
            .tracks.first(where: { $0.id == trackID })
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
