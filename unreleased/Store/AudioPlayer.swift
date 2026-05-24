import AVFoundation
import MediaPlayer
import Observation
import Foundation
import UIKit

@Observable
@MainActor
final class AudioPlayer {
    var currentTrack: Track?
    var currentProject: Project?
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isShowingNowPlaying: Bool = false
    var isShuffleEnabled: Bool = false
    var isLooping: Bool = false
    /// True while a remote audio file is downloading before playback can start.
    var isLoadingAudio: Bool = false
    /// Download progress 0…1 while `isLoadingAudio`; indeterminate UI when 0.
    var loadingProgress: Double = 0
    /// User-queued tracks (played next, in order) before the rest of the current project.
    /// Universal — items may come from any project and persist across project changes.
    private(set) var queue: [QueuedItem] = []

    private let store: ProjectStore
    /// Origin context (project + track position) for what plays after the queue empties.
    /// Updated on direct plays only; preserved while queued tracks (from other projects)
    /// are playing so that the original project's remaining tracks resume after the queue.
    private var contextProjectID: UUID?
    private var contextTrackID: UUID?
    private var shuffleOrder: [UUID] = []
    private var shuffleIndex: Int = 0
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var loadTask: Task<Void, Never>?

    private let trackRestartThreshold: TimeInterval = 1.5

    init(store: ProjectStore) {
        self.store = store
        setupAudioSession()
        setupRemoteCommands()
        setupInterruptionHandling()
    }

    // MARK: - Playback Control

    func play(track: Track, in project: Project, fileURL: URL, fromQueue: Bool = false) {
        if currentTrack?.id == track.id, !isLoadingAudio {
            togglePlayPause()
            return
        }
        if !fromQueue {
            contextProjectID = project.id
            contextTrackID = track.id
        }
        cancelLoad()
        isLoadingAudio = false
        loadingProgress = 0
        startPlayback(track: track, in: project, fileURL: fileURL, fromQueue: fromQueue)
    }

    /// Shows the mini player immediately; downloads uncached audio in the background.
    func play(track: Track, in project: Project, fromQueue: Bool = false) {
        if currentTrack?.id == track.id, !isLoadingAudio {
            togglePlayPause()
            return
        }
        if !fromQueue {
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

        if store.hasCachedAudio(for: track) {
            isLoadingAudio = false
            loadingProgress = 0
            startPlayback(track: track, in: project, fileURL: store.audioFileURL(for: track), fromQueue: fromQueue)
            return
        }

        isLoadingAudio = true
        loadingProgress = 0

        loadTask = Task {
            let url = await store.playbackURL(for: track) { [weak self] progress in
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

                self.startPlayback(track: track, in: project, fileURL: url, fromQueue: fromQueue)
            }
        }
    }

    private func startPlayback(track: Track, in project: Project, fileURL: URL, fromQueue: Bool = false) {
        tearDownPlayer()

        dequeueIfQueued(track.id)

        currentTrack = track
        currentProject = project
        duration = track.duration
        currentTime = 0

        let item = AVPlayerItem(url: fileURL)
        player = AVPlayer(playerItem: item)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackEnded()
        }

        addTimeObserver()
        refreshNowPlayingArtwork(for: project)
        // Only resync shuffle when this play is part of the active context — queued tracks
        // from foreign projects should not clobber the shuffleOrder of the context project.
        if isShuffleEnabled, !fromQueue {
            syncShuffleIndex(for: track.id)
        }
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
        store.analyzeWaveformIfNeeded(for: track, in: project.id)
    }

    func togglePlayPause() {
        if isLoadingAudio { return }
        guard player != nil else { return }
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
        updateNowPlayingInfo()
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        player?.seek(to: cmTime) { [weak self] _ in
            self?.currentTime = clamped
            self?.updateNowPlayingInfo()
        }
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
    /// If nothing is currently playing, the added track starts playing immediately.
    func addToQueue(_ track: Track, in project: Project) {
        guard currentTrack != nil else {
            play(track: track, in: project)
            return
        }
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
        play(track: track, in: project, fromQueue: true)
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
        play(track: next.track, in: next.project, fromQueue: next.fromQueue)
    }

    /// Restart if past 1.5s; otherwise previous track (wraps to the last from the first).
    func skipBackward() {
        if isLoadingAudio { return }
        if currentTime > trackRestartThreshold {
            seek(to: 0)
            return
        }
        guard let previous = adjacentTrack(offset: -1) else { return }
        play(track: previous.track, in: previous.project, fromQueue: previous.fromQueue)
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    var playbackProgress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    var formattedCurrentTime: String { formatTime(currentTime) }
    var formattedDuration: String { formatTime(duration) }

    // MARK: - Private

    private func handlePlaybackEnded() {
        if isLooping, let track = currentTrack, let project = currentProject {
            play(track: track, in: project, fromQueue: true)
            return
        }

        guard let next = adjacentTrack(offset: 1) else {
            isPlaying = false
            currentTime = duration
            updateNowPlayingInfo()
            return
        }
        play(track: next.track, in: next.project, fromQueue: next.fromQueue)
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

    private func adjacentTrack(offset: Int) -> (track: Track, project: Project, fromQueue: Bool)? {
        if offset > 0 {
            // Queue always takes precedence for forward navigation.
            if let first = queueItems.first {
                return (first.track, first.project, true)
            }
            // No queue: resume from the origin context project remainder.
            if let next = contextRemainder().first {
                return (next.track, next.project, false)
            }
            // Wrap around inside the context project (or current project as fallback).
            if let project = contextProject() ?? liveCurrentProject(),
               let first = project.tracks.first {
                return (first, project, false)
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
            return (result.track, result.project, false)
        }

        let index: Int
        if let current = currentTrackIndex(in: tracks) {
            index = (current + offset + tracks.count) % tracks.count
        } else {
            index = offset > 0 ? 0 : tracks.count - 1
        }

        return (tracks[index], project, false)
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

    private func dequeueIfQueued(_ trackID: UUID) {
        guard let index = queue.firstIndex(where: { $0.trackID == trackID }) else { return }
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

    private func tearDownPlayer() {
        if let obs = timeObserver {
            player?.removeTimeObserver(obs)
            timeObserver = nil
        }
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        player?.pause()
        player = nil
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
        }
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: []
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioPlayer: session setup failed — \(error)")
        }
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
            isPlaying = false
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                player?.play()
                isPlaying = true
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
            player?.pause()
            isPlaying = false
            updateNowPlayingInfo()
        }
    }

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            self?.isPlaying = true
            self?.updateNowPlayingInfo()
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            self?.isPlaying = false
            self?.updateNowPlayingInfo()
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.skipForward()
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.skipBackward()
            return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: e.positionTime)
            }
            return .success
        }
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

    private func updateNowPlayingInfo() {
        guard let track = currentTrack, let project = currentProject else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: project.name,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Universal queue entry. Each entry has its own identity so duplicate tracks
/// (and removal of a specific instance) can be modelled cleanly later if needed.
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
