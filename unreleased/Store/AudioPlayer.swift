import AVFoundation
import MediaPlayer
import Observation
import Foundation
import UIKit

nonisolated private final class RemoteCommandTargetStorage {
    var registrations: [(command: MPRemoteCommand, target: Any)] = []
}

@Observable
@MainActor
final class AudioPlayer {
    var currentTrack: Track?
    var currentProject: Project?
    private(set) var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isShowingNowPlaying: Bool = false
    var isShuffleEnabled: Bool = false
    var isLooping: Bool = false
    /// True while a remote audio file is downloading before playback can start.
    var isLoadingAudio: Bool = false
    /// Download progress 0…1 while `isLoadingAudio`; indeterminate UI when 0.
    var loadingProgress: Double = 0
    /// Drives an alert when a track is tapped on a device where it hasn't
    /// finished uploading to the cloud yet (no local copy + no storagePath).
    var showUploadPendingAlert: Bool = false
    /// Title of the track that triggered `showUploadPendingAlert`.
    var uploadPendingTrackTitle: String = ""
    /// User-queued tracks (played next, in order) before the rest of the current project.
    /// Universal — items may come from any project and persist across project changes.
    private(set) var queue: [QueuedItem] = []

    var playbackQuality: PlaybackQuality {
        didSet {
            UserDefaults.standard.set(playbackQuality.rawValue, forKey: Self.playbackQualityKey)
        }
    }

    var isEqualizerEnabled: Bool {
        didSet {
            applyEqualizerSettings()
            UserDefaults.standard.set(isEqualizerEnabled, forKey: Self.equalizerEnabledKey)
        }
    }
    private(set) var equalizerGains: [Float] {
        didSet {
            applyEqualizerSettings()
            UserDefaults.standard.set(equalizerGains, forKey: Self.equalizerGainsKey)
        }
    }
    private(set) var customEqualizerPresets: [CustomEqualizerPreset] {
        didSet {
            guard let data = try? JSONEncoder().encode(customEqualizerPresets) else { return }
            UserDefaults.standard.set(data, forKey: Self.customEqualizerPresetsKey)
        }
    }

    private let store: ProjectStore
    /// Origin context (project + track position) for what plays after the queue empties.
    /// Updated on direct plays only; preserved while queued tracks (from other projects)
    /// are playing so that the original project's remaining tracks resume after the queue.
    private var contextProjectID: UUID?
    private var contextTrackID: UUID?
    private var shuffleOrder: [UUID] = []
    private var shuffleIndex: Int = 0
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: EqualizerBand.all.count)
    private let equalizerSyncService = EqualizerSyncService()
    private var audioFile: AVAudioFile?
    private var playbackTimer: Timer?
    private var scheduledStartFrame: AVAudioFramePosition = 0
    private var scheduleGeneration = 0
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var loadTask: Task<Void, Never>?
    private var audioSessionActivationTask: Task<Void, Never>?
    /// AVAudioSession activation is synchronous and can wait on mediaserverd.
    /// Keep every category/activation call serialized and away from MainActor so
    /// rapid track changes cannot stack competing Core Audio operations or freeze UI.
    private nonisolated static let audioSessionQueue = DispatchQueue(
        label: "AudioPlayer.audioSession",
        qos: .userInitiated
    )
    private var wasPlayingBeforeInterruption = false
    // The reference is immutable, so deinit can read it without crossing
    // MainActor isolation. Registrations are otherwise mutated on MainActor.
    nonisolated private let remoteCommandTargetStorage = RemoteCommandTargetStorage()

    private let trackRestartThreshold: TimeInterval = 1.5
    private static let playbackQualityKey = "audio.playback.quality"
    private static let equalizerEnabledKey = "audio.equalizer.enabled"
    private static let equalizerGainsKey = "audio.equalizer.gains"
    private static let customEqualizerPresetsKey = "audio.equalizer.customPresets"
    private static let equalizerPresetsOwnerIDKey = "audio.equalizer.presetsOwnerID"

    private struct PlaybackTarget {
        let track: Track
        let project: Project
        let queueItemID: QueuedItem.ID?
    }

    init(store: ProjectStore) {
        self.store = store
        self.playbackQuality = UserDefaults.standard.string(forKey: Self.playbackQualityKey)
            .flatMap(PlaybackQuality.init(rawValue:)) ?? .standard
        let savedGains = (UserDefaults.standard.array(forKey: Self.equalizerGainsKey) as? [NSNumber])?
            .map(\.floatValue)
        if let savedGains,
           savedGains.count == EqualizerBand.all.count,
           savedGains.allSatisfy(\.isFinite) {
            self.equalizerGains = savedGains.map { min(max($0, -12), 12) }
        } else {
            self.equalizerGains = EqualizerPreset.flat.gains
        }
        self.isEqualizerEnabled = UserDefaults.standard.object(forKey: Self.equalizerEnabledKey) as? Bool ?? false
        let savedCustomPresets = UserDefaults.standard.data(forKey: Self.customEqualizerPresetsKey)
            .flatMap { try? JSONDecoder().decode([CustomEqualizerPreset].self, from: $0) }
        self.customEqualizerPresets = (savedCustomPresets ?? []).compactMap { preset in
            let title = preset.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  preset.gains.count == EqualizerBand.all.count,
                  preset.gains.allSatisfy(\.isFinite)
            else { return nil }

            var validatedPreset = preset
            validatedPreset.title = title
            validatedPreset.gains = preset.gains.map { min(max($0, -12), 12) }
            return validatedPreset
        }

        audioEngine.attach(playerNode)
        audioEngine.attach(equalizer)
        configureEqualizerBands()
        applyEqualizerSettings()
        setupRemoteCommands()
        setupInterruptionHandling()
    }

    deinit {
        for registration in remoteCommandTargetStorage.registrations {
            registration.command.removeTarget(registration.target)
        }
    }

    // MARK: - Equalizer

    var activeEqualizerPreset: EqualizerPreset? {
        EqualizerPreset.allCases.first { preset in
            zip(preset.gains, equalizerGains).allSatisfy { abs($0 - $1) < 0.05 }
        }
    }

    var activeCustomEqualizerPreset: CustomEqualizerPreset? {
        guard activeEqualizerPreset == nil else { return nil }
        return customEqualizerPresets.first { preset in
            preset.gains.count == equalizerGains.count
                && zip(preset.gains, equalizerGains).allSatisfy { abs($0 - $1) < 0.05 }
        }
    }

    func setEqualizerEnabled(_ enabled: Bool) {
        guard isEqualizerEnabled != enabled else { return }
        isEqualizerEnabled = enabled
    }

    func setEqualizerGain(_ gain: Float, at index: Int) {
        guard equalizerGains.indices.contains(index) else { return }
        let clampedGain = min(max(gain, -12), 12)
        guard abs(equalizerGains[index] - clampedGain) >= 0.05 else { return }
        equalizerGains[index] = clampedGain
    }

    func applyEqualizerPreset(_ preset: EqualizerPreset) {
        equalizerGains = preset.gains
        isEqualizerEnabled = true
    }

    func applyCustomEqualizerPreset(_ preset: CustomEqualizerPreset) {
        guard preset.gains.count == EqualizerBand.all.count else { return }
        equalizerGains = preset.gains
        isEqualizerEnabled = true
    }

    func saveCustomEqualizerPreset(named title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        customEqualizerPresets.append(
            CustomEqualizerPreset(title: trimmedTitle, gains: equalizerGains)
        )
        syncCustomEqualizerPresets()
    }

    func renameCustomEqualizerPreset(id: CustomEqualizerPreset.ID, to title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              let index = customEqualizerPresets.firstIndex(where: { $0.id == id })
        else { return }
        customEqualizerPresets[index].title = trimmedTitle
        syncCustomEqualizerPresets()
    }

    func deleteCustomEqualizerPreset(id: CustomEqualizerPreset.ID) {
        guard customEqualizerPresets.contains(where: { $0.id == id }) else { return }
        customEqualizerPresets.removeAll { $0.id == id }
        syncCustomEqualizerPresets()
    }

    func resetEqualizer() {
        equalizerGains = EqualizerPreset.flat.gains
    }

    func configureEqualizerSync(userID: String?) {
        guard let userID else {
            equalizerSyncService.stop()
            return
        }

        let defaults = UserDefaults.standard
        if let previousOwnerID = defaults.string(forKey: Self.equalizerPresetsOwnerIDKey),
           previousOwnerID != userID {
            customEqualizerPresets = []
        }
        defaults.set(userID, forKey: Self.equalizerPresetsOwnerIDKey)

        equalizerSyncService.start(
            userID: userID,
            localState: equalizerSyncState
        ) { [weak self] state in
            self?.applySyncedEqualizerState(state)
        }
    }

    private var equalizerSyncState: EqualizerSyncService.State {
        EqualizerSyncService.State(
            customPresets: customEqualizerPresets
        )
    }

    private func syncCustomEqualizerPresets() {
        equalizerSyncService.stateDidChange(equalizerSyncState)
    }

    private func applySyncedEqualizerState(_ state: EqualizerSyncService.State) {
        customEqualizerPresets = state.customPresets
    }

    // MARK: - Playback Control

    func play(
        track: Track,
        in project: Project,
        fileURL: URL,
        queueItemID: QueuedItem.ID? = nil
    ) {
        if currentTrack?.id == track.id, queueItemID == nil, !isLoadingAudio {
            togglePlayPause()
            return
        }
        if queueItemID == nil {
            contextProjectID = project.id
            contextTrackID = track.id
        }
        cancelLoad()
        isLoadingAudio = false
        loadingProgress = 0
        startPlayback(
            track: track,
            in: project,
            fileURL: fileURL,
            queueItemID: queueItemID
        )
    }

    /// Shows the mini player immediately; downloads uncached audio in the background.
    func play(
        track: Track,
        in project: Project,
        queueItemID: QueuedItem.ID? = nil
    ) {
        if currentTrack?.id == track.id, queueItemID == nil, !isLoadingAudio {
            togglePlayPause()
            return
        }

        // No local copy and no cloud object yet → the track is still uploading
        // from the device it was added on. There's nothing to stream, so surface
        // an alert instead of flashing a mini player that immediately vanishes.
        // The origin device always has the local file, so it never hits this.
        let hasLocal = store.hasCachedAudio(for: track) || store.hasDownloadedFile(for: track)
        let storagePath = store.projects.first(where: { $0.id == project.id })?
            .tracks.first(where: { $0.id == track.id })?.storagePath ?? track.storagePath
        if !hasLocal, storagePath == nil {
            uploadPendingTrackTitle = track.title
            showUploadPendingAlert = true
            return
        }

        // Over the storage limit (e.g. after a downgrade): streaming uncached cloud
        // tracks is paused until the user frees up space. Cached/downloaded tracks
        // remain playable, so only gate when there's no local copy.
        if !hasLocal, store.isOverStorageLimit {
            store.presentStorageUpsell(.overLimitPlayback)
            return
        }

        if queueItemID == nil {
            contextProjectID = project.id
            contextTrackID = track.id
        }

        cancelLoad()
        tearDownPlayer()

        currentTrack = track
        currentProject = project
        duration = track.duration
        currentTime = 0
        isPlaying = false
        refreshNowPlayingArtwork(for: project)
        updateNowPlayingInfo()

        if playbackQuality == .original, store.hasCachedAudio(for: track) {
            isLoadingAudio = false
            loadingProgress = 0
            startPlayback(
                track: track,
                in: project,
                fileURL: store.audioFileURL(for: track),
                queueItemID: queueItemID
            )
            return
        }

        isLoadingAudio = true
        loadingProgress = 0

        loadTask = Task {
            let url = await store.playbackURL(
                for: track,
                quality: playbackQuality
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.isLoadingAudio, self.currentTrack?.id == track.id else { return }
                    self.loadingProgress = progress
                }
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.currentTrack?.id == track.id else { return }
                self.isLoadingAudio = false
                self.loadingProgress = 0

                guard let url else {
                    self.currentTrack = nil
                    self.currentProject = nil
                    self.duration = 0
                    self.updateNowPlayingInfo()
                    return
                }

                self.startPlayback(
                    track: track,
                    in: project,
                    fileURL: url,
                    queueItemID: queueItemID
                )
            }
        }
    }

    /// Replaces the currently loaded audio for the same logical track without
    /// treating it as a play/pause tap. Used after selecting a different version.
    func switchToVersion(
        track: Track,
        in project: Project,
        startingAt time: TimeInterval,
        shouldPlay: Bool
    ) {
        let hasLocal = store.hasCachedAudio(for: track) || store.hasDownloadedFile(for: track)
        if !hasLocal, track.storagePath == nil {
            uploadPendingTrackTitle = track.title
            showUploadPendingAlert = true
            return
        }
        if !hasLocal, store.isOverStorageLimit {
            store.presentStorageUpsell(.overLimitPlayback)
            return
        }

        cancelLoad()
        tearDownPlayer()
        contextProjectID = project.id
        contextTrackID = track.id
        currentTrack = track
        currentProject = project
        duration = track.duration
        currentTime = min(max(time, 0), track.duration)
        isPlaying = false
        refreshNowPlayingArtwork(for: project)
        updateNowPlayingInfo()

        if playbackQuality == .original,
           (store.hasCachedAudio(for: track) || store.hasDownloadedFile(for: track)) {
            startPlayback(
                track: track,
                in: project,
                fileURL: store.localAudioURL(for: track),
                startingAt: time,
                shouldPlay: shouldPlay
            )
            return
        }

        isLoadingAudio = true
        loadingProgress = 0
        loadTask = Task {
            let url = await store.playbackURL(
                for: track,
                quality: playbackQuality
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.isLoadingAudio, self.currentTrack?.id == track.id else { return }
                    self.loadingProgress = progress
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.currentTrack?.id == track.id else { return }
                self.isLoadingAudio = false
                self.loadingProgress = 0
                guard let url else { return }
                self.startPlayback(
                    track: track,
                    in: project,
                    fileURL: url,
                    startingAt: time,
                    shouldPlay: shouldPlay
                )
            }
        }
    }

    private func startPlayback(
        track: Track,
        in project: Project,
        fileURL: URL,
        queueItemID: QueuedItem.ID? = nil,
        startingAt: TimeInterval = 0,
        shouldPlay: Bool = true
    ) {
        tearDownPlayer()

        if let queueItemID {
            dequeueQueueItem(id: queueItemID)
        }

        currentTrack = track
        currentProject = project
        currentTime = min(max(startingAt, 0), track.duration)
        duration = track.duration
        isPlaying = false
        refreshNowPlayingArtwork(for: project)
        updateNowPlayingInfo()

        let trackID = track.id
        audioSessionActivationTask = Task { [weak self] in
            let activationError = await Self.activateAudioSessionOffMain()
            guard let self, !Task.isCancelled, self.currentTrack?.id == trackID else { return }
            self.audioSessionActivationTask = nil

            guard activationError == nil else {
                self.isPlaying = false
                print("AudioPlayer: session activation failed — \(activationError!)")
                self.updateNowPlayingInfo()
                return
            }

            self.finishStartingPlayback(
                track: track,
                in: project,
                fileURL: fileURL,
                fromQueue: queueItemID != nil,
                startingAt: startingAt,
                shouldPlay: shouldPlay
            )
        }
    }

    private func finishStartingPlayback(
        track: Track,
        in project: Project,
        fileURL: URL,
        fromQueue: Bool,
        startingAt: TimeInterval,
        shouldPlay: Bool
    ) {
        var playbackStarted = false
        do {
            let file = try AVAudioFile(forReading: fileURL)
            audioFile = file
            duration = Double(file.length) / file.processingFormat.sampleRate
            try configureAudioGraph(for: file.processingFormat)
            let clampedStart = min(max(startingAt, 0), duration)
            let startFrame = AVAudioFramePosition(clampedStart * file.processingFormat.sampleRate)
            currentTime = clampedStart
            playbackStarted = scheduleAudio(from: startFrame, shouldPlay: shouldPlay)
            if !shouldPlay, audioEngine.isRunning {
                audioEngine.pause()
            }
        } catch {
            audioFile = nil
            duration = track.duration
            isPlaying = false
            print("AudioPlayer: playback setup failed — \(error)")
            updateNowPlayingInfo()
            return
        }

        // Only resync shuffle when this play is part of the active context — queued tracks
        // from foreign projects should not clobber the shuffleOrder of the context project.
        if isShuffleEnabled, !fromQueue {
            syncShuffleIndex(for: track.id)
        }
        isPlaying = shouldPlay && playbackStarted
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isLoadingAudio { return }
        guard audioFile != nil else { return }
        if isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func seek(to time: TimeInterval) {
        guard let file = audioFile else { return }
        let clamped = max(0, min(time, duration))
        let frame = AVAudioFramePosition(clamped * file.processingFormat.sampleRate)
        let shouldPlay = isPlaying
        let playbackStarted = scheduleAudio(from: frame, shouldPlay: shouldPlay)
        if shouldPlay {
            isPlaying = playbackStarted
        }
        currentTime = clamped
        updateNowPlayingInfo()
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
        if isShuffleEnabled {
            regenerateShuffleOrder()
        }
    }

    func toggleLooping() {
        isLooping.toggle()
    }

    /// Appends a track to the end of the universal queue. Tracks from any project are allowed.
    /// Queueing never changes playback; items become active after playback starts explicitly.
    func addToQueue(_ track: Track, in project: Project) {
        queue.append(QueuedItem(trackID: track.id, projectID: project.id))
    }

    func removeQueueItem(id: UUID) {
        queue.removeAll { $0.id == id }
    }

    func clearQueue() {
        queue = []
    }

    /// Plays a specific queued item, removing it and everything queued before it.
    /// Preserves the origin context so the original project resumes after the queue empties.
    func playQueueItem(id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue[index]
        guard let project = store.projects.first(where: { $0.id == item.projectID }),
              let track = project.tracks.first(where: { $0.id == item.trackID }) else {
            queue.remove(at: index)
            return
        }
        if index > 0 {
            queue.removeSubrange(0..<index)
        }
        play(track: track, in: project, queueItemID: item.id)
    }

    func isQueued(_ trackID: UUID) -> Bool {
        queue.contains { $0.trackID == trackID }
    }

    /// Resolved queued items with their current track and project metadata. Skips dead entries.
    var queueItems: [(item: QueuedItem, track: Track, project: Project)] {
        queue.compactMap { item in
            guard let project = store.projects.first(where: { $0.id == item.projectID }),
                  let track = project.tracks.first(where: { $0.id == item.trackID })
            else { return nil }
            return (item, track, project)
        }
    }

    /// Next track in the project (wraps to the first after the last).
    func skipForward() {
        guard let next = adjacentTrack(offset: 1) else { return }
        play(track: next.track, in: next.project, queueItemID: next.queueItemID)
    }

    /// Restart if past 1.5s; otherwise previous track (wraps to the last from the first).
    func skipBackward() {
        if isLoadingAudio { return }
        if currentTime > trackRestartThreshold {
            seek(to: 0)
            return
        }
        guard let previous = adjacentTrack(offset: -1) else { return }
        play(
            track: previous.track,
            in: previous.project,
            queueItemID: previous.queueItemID
        )
    }

    func stop() {
        cancelLoad()
        isLoadingAudio = false
        loadingProgress = 0
        tearDownPlayer()
        currentTrack = nil
        currentProject = nil
        contextProjectID = nil
        contextTrackID = nil
        queue = []
        isPlaying = false
        currentTime = 0
        duration = 0
        nowPlayingArtwork = nil
        updateNowPlayingInfo()
    }

    var playbackProgress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    var formattedCurrentTime: String { formatTime(currentTime) }
    var formattedDuration: String { formatTime(duration) }

    // MARK: - Private

    private func handlePlaybackEnded() {
        playbackTimer?.invalidate()
        playbackTimer = nil

        if isLooping {
            currentTime = 0
            isPlaying = scheduleAudio(from: 0, shouldPlay: true)
            updateNowPlayingInfo()
            return
        }

        guard let next = adjacentTrack(offset: 1) else {
            if audioEngine.isRunning {
                audioEngine.pause()
            }
            isPlaying = false
            currentTime = duration
            updateNowPlayingInfo()
            return
        }

        if next.track.id == currentTrack?.id, next.queueItemID == nil {
            currentTime = 0
            isPlaying = scheduleAudio(from: 0, shouldPlay: true)
            updateNowPlayingInfo()
            return
        }
        play(track: next.track, in: next.project, queueItemID: next.queueItemID)
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func projectTracks() -> [Track] {
        guard let projectID = currentProject?.id,
              let project = store.projects.first(where: { $0.id == projectID }) else { return [] }
        return project.tracks
    }

    private func currentTrackIndex(in tracks: [Track]) -> Int? {
        guard let currentTrack else { return nil }
        return tracks.firstIndex { $0.id == currentTrack.id }
    }

    private func adjacentTrack(offset: Int) -> PlaybackTarget? {
        if offset > 0 {
            // Queue always takes precedence for forward navigation.
            if let first = queueItems.first {
                return PlaybackTarget(
                    track: first.track,
                    project: first.project,
                    queueItemID: first.item.id
                )
            }
            // No queue: resume from the origin context project remainder.
            if let next = contextRemainder().first {
                return PlaybackTarget(
                    track: next.track,
                    project: next.project,
                    queueItemID: nil
                )
            }
            // Wrap around inside the context project (or current project as fallback).
            if let project = contextProject() ?? liveCurrentProject(),
               let first = project.tracks.first {
                return PlaybackTarget(track: first, project: project, queueItemID: nil)
            }
            return nil
        }

        // Backward navigation operates on the currently visible project.
        guard let project = liveCurrentProject() else { return nil }
        let tracks = project.tracks
        guard !tracks.isEmpty else { return nil }

        if isShuffleEnabled, offset < 0 {
            guard let result = shuffledAdjacentTrack(offset: offset, in: project, tracks: tracks)
            else { return nil }
            return PlaybackTarget(
                track: result.track,
                project: result.project,
                queueItemID: nil
            )
        }

        let index: Int
        if let current = currentTrackIndex(in: tracks) {
            index = (current + offset + tracks.count) % tracks.count
        } else {
            index = offset > 0 ? 0 : tracks.count - 1
        }

        return PlaybackTarget(track: tracks[index], project: project, queueItemID: nil)
    }

    /// Queued items (universal, in order) followed by the remaining tracks of the
    /// origin context project. Shuffle only reorders the project remainder, never the queue.
    private func upcomingItems() -> [(track: Track, project: Project)] {
        var result: [(Track, Project)] = queueItems.map { ($0.track, $0.project) }
        for entry in contextRemainder() {
            result.append((entry.track, entry.project))
        }
        return result
    }

    /// Tracks remaining in the origin context project after the context track.
    /// Falls back to the currently playing project/track when no context is set yet.
    private func contextRemainder() -> [(track: Track, project: Project)] {
        let projectID = contextProjectID ?? currentProject?.id
        let trackID = contextTrackID ?? currentTrack?.id
        guard let projectID, let trackID,
              let project = store.projects.first(where: { $0.id == projectID }),
              let idx = project.tracks.firstIndex(where: { $0.id == trackID })
        else { return [] }

        let remainder: [Track]
        if isShuffleEnabled, shuffleOrder.contains(trackID) {
            remainder = shuffledRemainderAfterCurrent(in: project, currentIdx: idx)
        } else {
            remainder = Array(project.tracks[(idx + 1)...])
        }
        return remainder.map { ($0, project) }
    }

    private func contextProject() -> Project? {
        guard let id = contextProjectID else { return nil }
        return store.projects.first(where: { $0.id == id })
    }

    private func liveCurrentProject() -> Project? {
        guard let id = currentProject?.id else { return nil }
        return store.projects.first(where: { $0.id == id })
    }

    private func liveCurrentTrack(in project: Project) -> Track? {
        guard let id = currentTrack?.id else { return nil }
        return project.tracks.first(where: { $0.id == id })
    }

    /// Refreshes cached track/project metadata after renames or project edits.
    func syncCurrentItemFromStore() {
        guard let project = liveCurrentProject(),
              let track = liveCurrentTrack(in: project)
        else { return }

        let metadataChanged = currentTrack?.title != track.title
            || currentProject?.name != project.name
            || currentProject?.coverImageFileName != project.coverImageFileName
            || currentProject?.gradient != project.gradient
            || currentProject?.accentColorHex != project.accentColorHex

        currentTrack = track
        currentProject = project

        guard metadataChanged else { return }
        refreshNowPlayingArtwork(for: project)
        updateNowPlayingInfo()
    }

    private func shuffledRemainderAfterCurrent(in project: Project, currentIdx: Int) -> [Track] {
        let tracks = project.tracks
        guard !tracks.isEmpty else { return [] }

        if shuffleOrder.isEmpty {
            regenerateShuffleOrder()
        }

        // Use the requested project track at currentIdx as the pivot — this lets the
        // context project's remainder be computed correctly even while a queued track
        // from a foreign project is the actually playing track.
        let pivotID = tracks[currentIdx].id
        guard let orderIdx = shuffleOrder.firstIndex(of: pivotID) else {
            return tracks.filter { $0.id != pivotID }
        }

        var result: [Track] = []
        for i in (orderIdx + 1)..<shuffleOrder.count {
            if let track = tracks.first(where: { $0.id == shuffleOrder[i] }) {
                result.append(track)
            }
        }
        return result
    }

    private func dequeueQueueItem(id: QueuedItem.ID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index)
    }

    private func regenerateShuffleOrder() {
        let tracks = projectTracks()
        guard !tracks.isEmpty else {
            shuffleOrder = []
            shuffleIndex = 0
            return
        }

        var ids = tracks.map(\.id).shuffled()
        if let currentID = currentTrack?.id, let currentPos = ids.firstIndex(of: currentID) {
            ids.remove(at: currentPos)
            ids.insert(currentID, at: 0)
            shuffleIndex = 0
        } else {
            shuffleIndex = 0
        }
        shuffleOrder = ids
    }

    private func syncShuffleIndex(for trackID: UUID) {
        if shuffleOrder.isEmpty {
            regenerateShuffleOrder()
        }
        if let index = shuffleOrder.firstIndex(of: trackID) {
            shuffleIndex = index
        } else {
            regenerateShuffleOrder()
        }
    }

    private func shuffledAdjacentTrack(
        offset: Int,
        in project: Project,
        tracks: [Track]
    ) -> (track: Track, project: Project)? {
        guard !shuffleOrder.isEmpty else {
            regenerateShuffleOrder()
            guard !shuffleOrder.isEmpty else { return nil }
            return shuffledAdjacentTrack(offset: offset, in: project, tracks: tracks)
        }

        let count = shuffleOrder.count
        let nextIndex = shuffleIndex + offset

        if nextIndex >= count {
            regenerateShuffleOrder()
            shuffleIndex = 0
        } else if nextIndex < 0 {
            shuffleIndex = count - 1
        } else {
            shuffleIndex = nextIndex
        }

        let trackID = shuffleOrder[shuffleIndex]
        guard let track = tracks.first(where: { $0.id == trackID }) else { return nil }
        return (track, project)
    }

    private func configureAudioGraph(for format: AVAudioFormat) throws {
        audioEngine.stop()
        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.disconnectNodeOutput(equalizer)
        audioEngine.connect(playerNode, to: equalizer, format: format)
        audioEngine.connect(equalizer, to: audioEngine.mainMixerNode, format: format)
        audioEngine.prepare()
        try audioEngine.start()
    }

    @discardableResult
    private func scheduleAudio(
        from requestedFrame: AVAudioFramePosition,
        shouldPlay: Bool
    ) -> Bool {
        guard let file = audioFile else { return false }

        scheduleGeneration += 1
        let generation = scheduleGeneration
        playerNode.stop()

        let startFrame = min(max(requestedFrame, 0), file.length)
        scheduledStartFrame = startFrame
        let remainingFrames = file.length - startFrame
        guard remainingFrames > 0 else {
            currentTime = duration
            return false
        }

        let frameCount = AVAudioFrameCount(min(remainingFrames, AVAudioFramePosition(UInt32.max)))
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.scheduleGeneration == generation else { return }
                self.handlePlaybackEnded()
            }
        }

        startPlaybackTimer()
        if shouldPlay {
            guard startEngineIfNeeded() else { return false }
            playerNode.play()
            return playerNode.isPlaying
        }
        return false
    }

    private func tearDownPlayer() {
        audioSessionActivationTask?.cancel()
        audioSessionActivationTask = nil
        scheduleGeneration += 1
        playbackTimer?.invalidate()
        playbackTimer = nil
        playerNode.stop()
        audioEngine.stop()
        audioFile = nil
        scheduledStartFrame = 0
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCurrentTimeFromEngine()
            }
        }
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateCurrentTimeFromEngine() {
        guard let file = audioFile,
              let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime)
        else { return }

        let renderedFrames = max(playerTime.sampleTime, 0)
        let elapsedFrames = scheduledStartFrame + renderedFrames
        currentTime = min(duration, Double(elapsedFrames) / file.processingFormat.sampleRate)
    }

    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        do {
            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
            }
            return true
        } catch {
            isPlaying = false
            print("AudioPlayer: engine start failed — \(error)")
            return false
        }
    }

    @discardableResult
    private func resumePlayback() -> Bool {
        guard audioFile != nil else {
            isPlaying = false
            updateNowPlayingInfo()
            return false
        }

        let expectedGeneration = scheduleGeneration
        audioSessionActivationTask?.cancel()
        audioSessionActivationTask = Task { [weak self] in
            let activationError = await Self.activateAudioSessionOffMain()
            guard let self,
                  !Task.isCancelled,
                  self.scheduleGeneration == expectedGeneration,
                  self.audioFile != nil
            else { return }
            self.audioSessionActivationTask = nil

            guard activationError == nil, self.startEngineIfNeeded() else {
                self.isPlaying = false
                if let activationError {
                    print("AudioPlayer: session activation failed — \(activationError)")
                }
                self.updateNowPlayingInfo()
                return
            }

            self.playerNode.play()
            self.isPlaying = self.playerNode.isPlaying
            self.updateNowPlayingInfo()
        }
        return true
    }

    private func pausePlayback() {
        audioSessionActivationTask?.cancel()
        audioSessionActivationTask = nil
        updateCurrentTimeFromEngine()
        playerNode.pause()

        // AVAudioPlayerNode.pause() alone leaves AVAudioEngine rendering silence.
        // iOS derives Now Playing activity from that audio session, so halt the
        // engine as well and restart it in resumePlayback().
        if audioEngine.isRunning {
            audioEngine.pause()
        }

        isPlaying = false
        updateNowPlayingInfo()
    }

    private func configureEqualizerBands() {
        for (index, definition) in EqualizerBand.all.enumerated() {
            let band = equalizer.bands[index]
            band.filterType = .parametric
            band.frequency = definition.frequency
            band.bandwidth = 1
        }
    }

    private func applyEqualizerSettings() {
        for (index, band) in equalizer.bands.enumerated() {
            band.gain = equalizerGains.indices.contains(index) ? equalizerGains[index] : 0
            band.bypass = !isEqualizerEnabled
        }

        let highestBoost = equalizerGains.max() ?? 0
        equalizer.globalGain = isEqualizerEnabled ? -min(max(highestBoost * 0.55, 0), 6) : 0
    }

    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleInterruption(notification)
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            updateCurrentTimeFromEngine()
            playerNode.pause()
            if audioEngine.isRunning {
                audioEngine.pause()
            }
            isPlaying = false
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = wasPlayingBeforeInterruption && options.contains(.shouldResume)
            wasPlayingBeforeInterruption = false
            if shouldResume {
                resumePlayback()
                return
            }
        @unknown default:
            break
        }
        updateNowPlayingInfo()
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        // Pause when headphones are unplugged (standard Apple behavior).
        if reason == .oldDeviceUnavailable {
            pausePlayback()
        }
    }

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()

        let playTarget = cc.playCommand.addTarget { [weak self] _ in
            self?.resumeFromRemoteCommand() ?? .noActionableNowPlayingItem
        }
        remoteCommandTargetStorage.registrations.append((cc.playCommand, playTarget))

        let pauseTarget = cc.pauseCommand.addTarget { [weak self] _ in
            self?.pauseFromRemoteCommand() ?? .noActionableNowPlayingItem
        }
        remoteCommandTargetStorage.registrations.append((cc.pauseCommand, pauseTarget))

        let toggleTarget = cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPauseFromRemoteCommand() ?? .noActionableNowPlayingItem
        }
        remoteCommandTargetStorage.registrations.append((cc.togglePlayPauseCommand, toggleTarget))

        let nextTarget = cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.skipForward()
            return .success
        }
        remoteCommandTargetStorage.registrations.append((cc.nextTrackCommand, nextTarget))

        let previousTarget = cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.skipBackward()
            return .success
        }
        remoteCommandTargetStorage.registrations.append((cc.previousTrackCommand, previousTarget))

        let positionTarget = cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: e.positionTime)
            }
            return .success
        }
        remoteCommandTargetStorage.registrations.append((cc.changePlaybackPositionCommand, positionTarget))

        updateRemoteCommandAvailability()
    }

    private func resumeFromRemoteCommand() -> MPRemoteCommandHandlerStatus {
        guard audioFile != nil else { return .noActionableNowPlayingItem }
        if isPlaying {
            updateNowPlayingInfo()
            return .success
        }
        return resumePlayback() ? .success : .commandFailed
    }

    private func pauseFromRemoteCommand() -> MPRemoteCommandHandlerStatus {
        guard audioFile != nil else { return .noActionableNowPlayingItem }
        if isPlaying {
            pausePlayback()
        } else {
            updateNowPlayingInfo()
        }
        return .success
    }

    private func togglePlayPauseFromRemoteCommand() -> MPRemoteCommandHandlerStatus {
        guard audioFile != nil else { return .noActionableNowPlayingItem }
        if isPlaying {
            pausePlayback()
            return .success
        }
        return resumePlayback() ? .success : .commandFailed
    }

    private func updateRemoteCommandAvailability() {
        let cc = MPRemoteCommandCenter.shared()
        let hasPlayableTrack = currentTrack != nil && audioFile != nil

        cc.playCommand.isEnabled = hasPlayableTrack && !isPlaying
        cc.pauseCommand.isEnabled = hasPlayableTrack && isPlaying
        cc.togglePlayPauseCommand.isEnabled = hasPlayableTrack
        cc.changePlaybackPositionCommand.isEnabled = hasPlayableTrack
        cc.nextTrackCommand.isEnabled = currentTrack != nil
        cc.previousTrackCommand.isEnabled = currentTrack != nil
    }

    private func clearNowPlayingInfo() {
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = nil
        updateRemoteCommandAvailability()
    }

    private func publishNowPlayingInfo(for track: Track, project: Project) {
        let playbackRate = isPlaying ? 1.0 : 0.0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: project.name,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }

        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = info
        updateRemoteCommandAvailability()
    }

    private nonisolated static func activateAudioSessionOffMain() async -> String? {
        await withCheckedContinuation { continuation in
            audioSessionQueue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    if session.category != .playback || session.mode != .default {
                        try session.setCategory(.playback, mode: .default, options: [])
                    }
                    try session.setActive(true)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack, let project = currentProject else {
            clearNowPlayingInfo()
            return
        }
        publishNowPlayingInfo(for: track, project: project)
    }

    private func refreshNowPlayingArtwork(for project: Project) {
        let image = store.coverImage(for: project)?.squareArtworkImage()
            ?? project.gradient.artworkImage()
        guard let image else {
            nowPlayingArtwork = nil
            return
        }
        let size = image.size
        nowPlayingArtwork = MPMediaItemArtwork(boundsSize: size) { _ in image }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Universal queue entry. Each occurrence has its own identity so duplicate tracks
/// can advance and be removed independently.
struct QueuedItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let trackID: UUID
    let projectID: UUID

    init(id: UUID = UUID(), trackID: UUID, projectID: UUID) {
        self.id = id
        self.trackID = trackID
        self.projectID = projectID
    }
}
