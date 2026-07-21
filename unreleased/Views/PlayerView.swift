import SwiftUI
import UIKit

/// Unified mini ↔ full player: one card shape morphs in place.
struct PlayerView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(ProjectStore.self) private var store
    @Environment(\.navigateToTrackNotes) private var navigateToTrackNotes
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var offset: CGFloat = 0
    @State private var lastDragTranslation: CGFloat = 0
    @State private var isDragging = false
    @State private var miniScrubPillVisible = false
    @State private var miniScrubProgress: Double = 0
    @State private var isShowingTrackInfo = false
    @State private var isShowingQueue = false
    @State private var isShowingNotes = false
    @State private var bottomAccessoryHapticTrigger = 0
    /// Flips to true once the insertion-spring has settled so the matched-
    /// geometry hero cover can take over from the static placeholder cover.
    @State private var heroSettled = false
    /// Cancellation handle for the delayed settle task.
    @State private var heroSettleTask: Task<Void, Never>? = nil
    /// Tracks whether the mini-player cover button is being held down so the
    /// hero cover (and its placeholder) can show a press-scale effect.
    @State private var isCoverPressed = false
    /// Live scrubbing progress during waveform drag (used for cover rotation).
    @State private var liveScrubProgress: Double = 0
    /// Whether we're currently scrubbing (used for timestamp updates).
    @State private var isScrubbing: Bool = false
    /// Target progress position after a seek completes — displayed until player catches up.
    @State private var targetScrubProgress: Double? = nil

    @Namespace private var morph

    private let compactHeight: CGFloat = 50
    /// Height of the area between drag handle and bottom accessories when the
    /// expanded player is shown. Used to keep the queue view's middle area the
    /// same size as the player view so toggling between them feels stable.
    private static let expandedMiddleHeight: CGFloat = 478
    /// Space between the mini player bar and the floating scrub time pill.
    private let miniWaveformWidth: CGFloat = 130
    private let miniWaveformHeight: CGFloat = 36
    private var miniScrubPillLift: CGFloat { compactHeight + 8 }
    private let compactCoverInset: CGFloat = 4
    private let sideMargin: CGFloat = 12

    private var isExpanded: Bool { player.isShowingNowPlaying }

    /// On iPad the mini player caps its width and stays centered at the bottom.
    private var cardMaxWidth: CGFloat {
        horizontalSizeClass == .regular && !isExpanded ? 480 : .infinity
    }

    private var bottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.safeAreaInsets.bottom ?? 34
    }

    private var screenCornerRadius: CGFloat {
        (UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 44
    }

    private var bottomCardRadius: CGFloat {
        max(0, screenCornerRadius - sideMargin)
    }

    private var compactCornerRadius: CGFloat { compactHeight / 2 }

    private var cardTopLeading: CGFloat { isExpanded ? 36 : compactCornerRadius }
    private var cardTopTrailing: CGFloat { isExpanded ? 36 : compactCornerRadius }
    private var cardBottomLeading: CGFloat { isExpanded ? bottomCardRadius : compactCornerRadius }
    private var cardBottomTrailing: CGFloat { isExpanded ? bottomCardRadius : compactCornerRadius }

    private var compactCoverSize: CGFloat { compactHeight - compactCoverInset * 2 }

    /// Latest project metadata from the store (name, cover, gradient).
    private var liveProject: Project? {
        guard let id = player.currentProject?.id else { return nil }
        return store.projects.first(where: { $0.id == id }) ?? player.currentProject
    }

    /// Latest track metadata from the store (title, waveform, etc.).
    private var liveTrack: Track? {
        guard let trackID = player.currentTrack?.id,
              let project = liveProject
        else { return player.currentTrack }
        return project.tracks.first(where: { $0.id == trackID }) ?? player.currentTrack
    }

    // MARK: - Body

    var body: some View {
        if let track = liveTrack, let project = liveProject {
            ZStack(alignment: .bottom) {
                playerCard(track: track, project: project)
                    .padding(.horizontal, sideMargin)
                    // Expanded: same inset as sides so bottom corners stay concentric with the device.
                    // Mini: keep the existing float above the home indicator.
                    .padding(.bottom, isExpanded ? sideMargin : 8)
                    .ignoresSafeArea(edges: isExpanded ? .bottom : [])

                // Hero cover lives in this stable coordinate space (a sibling of the card,
                // not inside its overlay) so matched geometry resolves cleanly while the
                // card itself is animating between sizes/positions.
                // Hidden until heroSettled: the miniBar placeholder cover handles the
                // visual during the insertion spring. Once settled the hero snaps into
                // place with no secondary animation (matchedGeometryEffect is already
                // at the correct position when it becomes visible).
                heroCover(project: project)
                    // Isolates the hero's geometry group from the ZStack's
                    // coordinate-space changes as the card expands/collapses,
                    // preventing the matched-geometry resolution from jittering.
                    .geometryGroup()
                    // Press-scale for the mini-player play/pause tap target.
                    .scaleEffect((!isExpanded || isShowingQueue || isShowingNotes) && isCoverPressed ? 0.88 : 1.0)
                    .animation(
                        .spring(response: 0.22, dampingFraction: 0.65),
                        value: isCoverPressed
                    )
                    .opacity(heroSettled ? 1 : 0)
                    .animation(.none, value: heroSettled)
            }
            .frame(maxWidth: cardMaxWidth)
            // Always apply drag offset — gating on isExpanded caused instant snap on dismiss/snap-back.
            .offset(y: offset)
            .transaction { transaction in
                if isDragging { transaction.disablesAnimations = true }
            }
            .scaleEffect(isExpanded && offset > 0 ? max(0.93, 1 - offset / 1400) : 1, anchor: .bottom)
            .gesture(isExpanded ? dismissGesture : nil)
            .onAppear {
                offset = 0
                lastDragTranslation = 0
                // Wait for the insertion spring to fully settle before revealing the
                // matched-geometry hero cover. During this window the mini bar shows
                // a static placeholder cover so there is no visible gap. 0.55 s is
                // comfortably past the longest insertion spring (response 0.44 s).
                heroSettleTask?.cancel()
                heroSettleTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.55))
                    guard !Task.isCancelled else { return }
                    heroSettled = true
                }
            }
            .onDisappear {
                heroSettled = false
                heroSettleTask?.cancel()
                heroSettleTask = nil
            }
            .onChange(of: player.isShowingNowPlaying) { _, showing in
                offset = 0
                lastDragTranslation = 0
                if showing {
                    dismissKeyboard()
                    // Player is expanding — settle the hero immediately so the
                    // mini→full morph animation is visible from the first frame.
                    heroSettleTask?.cancel()
                    heroSettleTask = nil
                    heroSettled = true
                } else {
                    isShowingQueue = false
                    isShowingNotes = false
                }
            }
            .sheet(isPresented: $isShowingTrackInfo) {
                if let track = liveTrack, let project = liveProject {
                    TrackInfoSheet(
                        track: track,
                        project: project,
                        onOpenNotes: {
                            isShowingTrackInfo = false
                            openTrackNotes()
                        }
                    )
                }
            }
        }
    }

    // MARK: - Card shell

    @ViewBuilder
    private func playerCard(track: Track, project: Project) -> some View {
        VStack(spacing: 0) {
            if isExpanded {
                dragHandle
                    .padding(.top, 12)

                Group {
                    if isShowingQueue {
                        queueExpandedMiddle(track: track, project: project)
                    } else if isShowingNotes {
                        notesExpandedMiddle(track: track, project: project)
                    } else {
                        playerExpandedMiddle(track: track, project: project)
                    }
                }
                .frame(height: Self.expandedMiddleHeight)

                bottomAccessories
                    .padding(.top, 16)
                    .padding(.horizontal, 8)
                    .padding(.bottom, bottomInset)
            } else {
                miniBar(track: track, project: project)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: compactHeight)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: cardTopLeading,
                bottomLeadingRadius: cardBottomLeading,
                bottomTrailingRadius: cardBottomTrailing,
                topTrailingRadius: cardTopTrailing,
                style: .continuous
            )
            .fill(isExpanded ? Color(white: 0.10) : PlayerChrome.surfaceBackground)
            .shadow(
                color: .black.opacity(isExpanded ? 0.45 : 0.35),
                radius: isExpanded ? 40 : 18,
                x: 0,
                y: isExpanded ? -6 : 6
            )
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: cardTopLeading,
                bottomLeadingRadius: cardBottomLeading,
                bottomTrailingRadius: cardBottomTrailing,
                topTrailingRadius: cardTopTrailing,
                style: .continuous
            )
        )
        .contentShape(
            UnevenRoundedRectangle(
                topLeadingRadius: cardTopLeading,
                bottomLeadingRadius: cardBottomLeading,
                bottomTrailingRadius: cardBottomTrailing,
                topTrailingRadius: cardTopTrailing,
                style: .continuous
            )
        )
        .overlay(alignment: .bottom) {
            if !isExpanded {
                miniScrubTimePill
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: miniScrubPillVisible)
            }
        }
    }

    private var miniScrubTimePill: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: compactHeight)
            Spacer(minLength: 0)
            ZStack {
                if miniScrubPillVisible {
                    Text(miniScrubTimeLabel)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(PlayerChrome.surfaceBackground, in: Capsule())
                        .fixedSize()
                        .transition(
                            .scale(scale: 0.88, anchor: .bottom)
                            .combined(with: .opacity)
                        )
                }
            }
            .frame(width: miniWaveformWidth)
            Color.clear.frame(width: 10)
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .frame(height: 0, alignment: .bottom)
        .offset(y: -miniScrubPillLift)
        .allowsHitTesting(false)
    }

    private var miniScrubTimeLabel: String {
        let current = formatPlaybackTime(miniScrubProgress * player.duration)
        let total = formatPlaybackTime(player.duration)
        return "\(current) / \(total)"
    }

    // MARK: - Mini bar

    @ViewBuilder
    private func miniBar(track: Track, project: Project) -> some View {
        Button {
            player.isShowingNowPlaying = true
        } label: {
            HStack(spacing: 0) {
                // ZStack lets the matched-geometry anchor (coverSlot) and the static
                // placeholder cover occupy the same cell. The placeholder is shown while
                // the insertion spring is running so the hero cover can reveal itself
                // only after the spring has settled (avoiding the "giant circle shrinks
                // into place" glitch that matchedGeometryEffect produces on first appear).
                ZStack {
                    coverSlot(size: compactCoverSize, isTapToPlay: true)
                    if !heroSettled {
                        HeroCoverView(
                            gradient: project.gradient,
                            coverImage: store.coverImage(for: project),
                            isPlaying: player.isPlaying,
                            isLoadingAudio: player.isLoadingAudio,
                            loadingProgress: player.loadingProgress,
                            showsMiniOverlay: true,
                            showsShadow: false,
                            playbackProgress: player.playbackProgress,
                            isScrubbing: false,
                            duration: player.duration
                        )
                        .allowsHitTesting(false)
                        .scaleEffect(isCoverPressed ? 0.88 : 1.0)
                        .animation(
                            .spring(response: 0.22, dampingFraction: 0.65),
                            value: isCoverPressed
                        )
                        .transition(.identity)
                    }
                }
                .frame(width: compactCoverSize, height: compactCoverSize)
                .padding(.leading, compactCoverInset)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(project.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .padding(.leading, 4 + compactCoverInset)
                .frame(maxWidth: .infinity, alignment: .leading)

                waveformSection(track: track)
                    .frame(width: miniWaveformWidth, height: miniWaveformHeight)
                    .padding(.trailing, 10)
            }
            .frame(height: compactHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared morphing cover (same circle in every player state)

    /// Invisible anchor placed at each position the cover can occupy.
    /// Only one slot lives in the hierarchy at a time, so matched geometry
    /// interpolates the hero cover between consecutive slots.
    @ViewBuilder
    private func coverSlot(size: CGFloat, isTapToPlay: Bool) -> some View {
        Group {
            if isTapToPlay {
                Button {
                    player.togglePlayPause()
                } label: {
                    Color.clear.contentShape(Circle())
                }
                // Feeds isPressed state back so heroCover can show the
                // scale-down effect while the button is being held.
                .buttonStyle(CoverPressButtonStyle(isPressed: $isCoverPressed))
                .disabled(player.isLoadingAudio)
                .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .matchedGeometryEffect(id: "cover", in: morph, isSource: true)
    }

    /// The single visible cover. Lives in an overlay so it smoothly resizes
    /// and moves between the mini, expanded and queue slots.
    @ViewBuilder
    private func heroCover(project: Project) -> some View {
        HeroCoverView(
            gradient: project.gradient,
            coverImage: store.coverImage(for: project),
            isPlaying: player.isPlaying,
            isLoadingAudio: player.isLoadingAudio,
            loadingProgress: player.loadingProgress,
            showsMiniOverlay: !isExpanded || isShowingQueue || isShowingNotes,
            showsShadow: isExpanded && !isShowingQueue && !isShowingNotes,
            playbackProgress: targetScrubProgress ?? (isScrubbing ? liveScrubProgress : player.playbackProgress),
            isScrubbing: isScrubbing,
            duration: player.duration
        )
        .id(coverArtIdentity(for: project))
        .matchedGeometryEffect(id: "cover", in: morph, isSource: false)
        .allowsHitTesting(false)
        // Belt-and-suspenders: completely disable animations on the hero while
        // the insertion spring is still running. The placeholder cover in miniBar
        // handles the visual during this window.
        .transaction { tx in
            if !heroSettled { tx.disablesAnimations = true }
        }
        // Mini player: block implicit play/pause transitions on the matched-geometry
        // group (expanded scale animation is handled inside HeroCoverView).
        .animation(isExpanded ? nil : .none, value: player.isPlaying)
    }

    // MARK: - Waveform

    @ViewBuilder
    private func waveformSection(track: Track) -> some View {
        ScrollingMiniWaveformView(
            trackID: track.id,
            waveformData: track.waveformData,
            progress: player.playbackProgress,
            duration: player.duration,
            showsScrubTimeOverlay: !isExpanded,
            onScrubOverlayChange: !isExpanded ? { visible, progress in
                miniScrubPillVisible = visible
                miniScrubProgress = progress
                isScrubbing = visible
            } : nil,
            visibleBars: isExpanded ? 44 : 38,
            onScrubProgress: { progress in
                liveScrubProgress = progress
                isScrubbing = true
            },
            onSeek: { p in
                targetScrubProgress = p
                isScrubbing = false
                player.seek(to: p * player.duration)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    targetScrubProgress = nil
                }
            }
        )
        .frame(height: isExpanded ? 60 : 26)
        .frame(maxWidth: isExpanded ? .infinity : nil)
        .onChange(of: player.currentTime) { _, _ in
            if let target = targetScrubProgress {
                let tolerance = player.duration * 0.01
                if abs(player.currentTime - target * player.duration) < tolerance {
                    targetScrubProgress = nil
                }
            }
        }
    }

    // MARK: - Expanded sections

    private var dragHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 36, height: 4)
    }

    @ViewBuilder
    private func expandedTitle(track: Track, project: Project) -> some View {
        VStack(spacing: 4) {
            Text(track.title)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(project.name)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.52))
        }
        .frame(maxWidth: .infinity)
    }

    private var timeRow: some View {
        let displayTime: TimeInterval
        if let target = targetScrubProgress {
            displayTime = target * player.duration
        } else if isScrubbing {
            displayTime = liveScrubProgress * player.duration
        } else {
            displayTime = player.currentTime
        }
        let displayFormatted = formatPlaybackTime(displayTime)
        return HStack {
            Text(displayFormatted)
            Spacer()
            Text(player.formattedDuration)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.35))
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(player.isShuffleEnabled ? .white : .white.opacity(0.32))
                    .frame(width: 44, height: 44)
            }
            Spacer()

            Button { player.skipBackward() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            Spacer()

            Button { player.togglePlayPause() } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.white)
                        .frame(width: 62, height: 62)
                    if player.isLoadingAudio {
                        TwoToneCircleSpinner(diameter: 28, lineWidth: 2.5)
                            .environment(\.colorScheme, .light)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.black)
                            .animation(nil, value: player.isPlaying)
                    }
                }
            }
            .disabled(player.isLoadingAudio)
            .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)

            Spacer()

            Button { player.skipForward() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            Spacer()

            Button { player.toggleLooping() } label: {
                Image(systemName: player.isLooping ? "repeat.1" : "repeat")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(player.isLooping ? .white : .white.opacity(0.32))
                    .frame(width: 44, height: 44)
            }
        }
    }

    // MARK: - Expanded middle compositions

    @ViewBuilder
    private func playerExpandedMiddle(track: Track, project: Project) -> some View {
        VStack(spacing: 0) {
            expandedTitle(track: track, project: project)
                .padding(.top, 16)
                .padding(.horizontal, 24)

            coverSlot(size: 200, isTapToPlay: false)
                .padding(.top, 18)

            waveformSection(track: track)
                .padding(.horizontal, 24)
                .padding(.top, 20)

            timeRow
                .padding(.horizontal, 24)
                .padding(.top, 6)

            transportControls
                .padding(.horizontal, 20)
                .padding(.top, 20)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Queue view

    @ViewBuilder
    private func queueExpandedMiddle(track: Track, project: Project) -> some View {
        VStack(spacing: 0) {
            nowPlayingSection(track: track, project: project)
                .padding(.top, 14)
                .padding(.horizontal, 20)

            upNextSectionHeader
                .padding(.top, 10)
                .padding(.horizontal, 19)
                .padding(.bottom, 6)

            queueScrollList
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func nowPlayingSection(track: Track, project: Project) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOW PLAYING")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.6)

            HStack(spacing: 12) {
                coverSlot(size: 52, isTapToPlay: true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(project.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var upNextSectionHeader: some View {
        HStack {
            Text("UP NEXT")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.6)

            Spacer()

            if !player.queue.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        player.clearQueue()
                    }
                } label: {
                    Text("Clear")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var queueScrollList: some View {
        let entries = player.queueItems
        if entries.isEmpty {
            queueEmptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.item.id) { index, entry in
                        queueRow(item: entry.item, track: entry.track, project: entry.project)
                            .padding(.horizontal, 20)
                        if index < entries.count - 1 {
                            Divider()
                                .overlay(Color.white.opacity(0.06))
                                .padding(.leading, 20 + 44 + 12)
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.bottom, 8)
            }
            .mask(scrollFadeMask)
        }
    }

    /// Gradient mask applied to both the queue and notes scroll views.
    /// Only the bottom edge fades — the scroll view's own clipping handles the
    /// top, and a top fade would eat into the first visible item at rest.
    private var scrollFadeMask: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 30)
        }
    }

    private var queueEmptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note.list")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("Nothing queued")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text("Add tracks from any project to play them next.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func queueRow(item: QueuedItem, track: Track, project: Project) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                    isShowingQueue = false
                }
                player.playQueueItem(id: item.id)
            } label: {
                HStack(spacing: 12) {
                    ProjectCoverThumbnail(
                        gradient: project.gradient,
                        coverImage: store.coverImage(for: project),
                        size: 44,
                        cornerRadius: 9
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(project.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    player.removeQueueItem(id: item.id)
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove from queue")
        }
        .padding(.vertical, 8)
    }

    private var bottomAccessories: some View {
        HStack(spacing: 0) {
            bottomAccessoryButton(icon: "doc.text", label: "notes", isActive: isShowingNotes) {
                bottomAccessoryHapticTrigger += 1
                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                    isShowingNotes.toggle()
                    if isShowingNotes { isShowingQueue = false }
                }
            }
            bottomAccessoryButton(
                icon: "list.bullet",
                label: "queue",
                isActive: isShowingQueue
            ) {
                bottomAccessoryHapticTrigger += 1
                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                    isShowingQueue.toggle()
                    if isShowingQueue { isShowingNotes = false }
                }
            }
            bottomAccessoryButton(icon: "ellipsis", label: "options") {
                isShowingTrackInfo = true
            }
        }
        .sensoryFeedback(.selection, trigger: bottomAccessoryHapticTrigger)
    }

    private static let bottomAccessoryHeight: CGFloat = 48

    private func bottomAccessoryButton(
        icon: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .frame(height: 22)

                Text(label)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(height: 14)
            }
            .foregroundStyle(isActive ? .white : .white.opacity(0.48))
            .frame(height: Self.bottomAccessoryHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Notes view

    @ViewBuilder
    private func notesExpandedMiddle(track: Track, project: Project) -> some View {
        VStack(spacing: 0) {
            nowPlayingSection(track: track, project: project)
                .padding(.top, 14)
                .padding(.horizontal, 20)

            notesSectionHeader(track: track, project: project)
                .padding(.top, 10)
                .padding(.horizontal, 19)
                .padding(.bottom, 6)

            notesScrollContent(track: track, project: project)
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func notesSectionHeader(track: Track, project: Project) -> some View {
        HStack {
            Text("NOTES")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.6)

            Spacer()

            if !project.isShared {
                Button {
                    openTrackNotes()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Edit")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func notesScrollContent(track: Track, project: Project) -> some View {
        if track.notes.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
                Text("No notes yet")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                if !project.isShared {
                    Text("Tap Edit to start writing.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                Text(track.notes)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
            }
            .mask(scrollFadeMask)
        }
    }

    // MARK: - Dismiss gesture

    /// How far down (pt) before a release dismisses — high so flicks travel further first.
    private let dismissOffsetThreshold: CGFloat = 220
    /// Predicted end offset for a throw — must be a strong downward flick.
    private let dismissFlickThreshold: CGFloat = 520
    /// How quickly upward drag stiffens — lower = harder to pull further up.
    private let upwardDragStiffness: CGFloat = 85

    /// Snappier spring when collapsing the full player (open uses ContentView's slower spring).
    private static let dismissSpring = Animation.spring(response: 0.30, dampingFraction: 0.86)
    private static let snapBackSpring = Animation.spring(response: 0.34, dampingFraction: 0.78)

    /// Finger moving up (delta < 0). Downward offset cancels 1:1 first; above rest, speed falls off with stretch.
    private func offsetAfterUpwardDrag(delta: CGFloat, from current: CGFloat) -> CGFloat {
        guard delta < 0 else { return current }

        if current > 0 {
            let cancelDown = max(delta, -current)
            let remaining = delta - cancelDown
            if remaining == 0 { return current + cancelDown }
            return offsetAfterUpwardDrag(delta: remaining, from: current + cancelDown)
        }

        let stretch = max(0, -current)
        let resistance = 1 / pow(1 + stretch / upwardDragStiffness, 1.6)
        return current + delta * resistance
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                isDragging = true
                let delta = value.translation.height - lastDragTranslation
                lastDragTranslation = value.translation.height

                if delta < 0 {
                    offset = offsetAfterUpwardDrag(delta: delta, from: offset)
                } else {
                    offset += delta
                }
            }
            .onEnded { value in
                let predictedOffset = offset + value.predictedEndTranslation.height - value.translation.height
                lastDragTranslation = 0
                isDragging = false

                if offset > dismissOffsetThreshold
                    || (offset >= 0 && predictedOffset > dismissFlickThreshold) {
                    withAnimation(Self.dismissSpring) {
                        offset = 0
                        player.isShowingNowPlaying = false
                    }
                } else {
                    withAnimation(Self.snapBackSpring) {
                        offset = 0
                    }
                }
            }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func coverArtIdentity(for project: Project) -> String {
        let gradientKey = project.gradient.colors.joined(separator: "-")
        return "\(project.id.uuidString)-\(project.coverImageFileName ?? "none")-\(gradientKey)"
    }

    private func openTrackNotes() {
        guard let track = liveTrack, let project = liveProject else { return }
        let trackID = track.id
        let projectID = project.id
        player.isShowingNowPlaying = false
        DispatchQueue.main.async {
            navigateToTrackNotes(trackID, projectID)
        }
    }
}

// MARK: - Now playing pulse icon

private struct NowPlayingPulseIcon: View {
    let isPlaying: Bool

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: isPlaying)
    }
}

// MARK: - Hero cover (the single visible circle that morphs across player states)

private struct HeroCoverView: View {
    let gradient: GradientTheme
    let coverImage: UIImage?
    let isPlaying: Bool
    let isLoadingAudio: Bool
    let loadingProgress: Double
    let showsMiniOverlay: Bool
    let showsShadow: Bool
    /// Current playback progress (0…1), already scrub-adjusted by the parent.
    let playbackProgress: Double
    /// True while the user's finger is on the waveform scrubber.
    let isScrubbing: Bool
    /// Track duration in seconds — calibrates scrub rotation to match play-speed.
    let duration: TimeInterval

    // Accumulated rotation in degrees at the last pause/scrub-start.
    @State private var accumulatedDegrees: Double = 0
    // Non-nil only while playing (and not scrubbing) so the TimelineView can
    // advance the angle in real time without needing a SwiftUI animation.
    @State private var playStartDate: Date? = nil
    // Progress value at the moment the most recent scrub gesture started,
    // used to compute rotation delta as the finger moves.
    @State private var lastScrubProgress: Double = 0

    /// 18 °/s → one full revolution every 20 seconds, matching a slow vinyl spin.
    private let degreesPerSecond: Double = 18.0

    /// Subtle "paused = slightly shrunken" feel in the expanded player view.
    private var coverScale: CGFloat {
        showsShadow ? (isPlaying ? 1.0 : 0.93) : 1.0
    }

    /// Rotation angle at a given instant, accounting for elapsed play time.
    private func rotationAt(_ date: Date) -> Double {
        guard let start = playStartDate else { return accumulatedDegrees }
        return accumulatedDegrees + date.timeIntervalSince(start) * degreesPerSecond
    }

    @ViewBuilder
    private func coverArtwork(rotation: Double) -> some View {
        Group {
            if let coverImage {
                ZStack {
                    Circle().fill(Color(white: 0.12))
                    Image(uiImage: coverImage)
                        .resizable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaledToFill()
                        .clipped()
                        .contentTransition(.identity)
                }
            } else {
                Circle().fill(gradient.gradient)
            }
        }
        .clipShape(Circle())
        .animation(nil, value: isPlaying)
        .scaleEffect(coverScale)
        .animation(showsShadow ? .smooth(duration: 0.4) : nil, value: isPlaying)
        .rotationEffect(.degrees(rotation))
    }

    var body: some View {
        ZStack {
            // Keep only the rotating artwork in the per-frame subtree. Liquid
            // Glass and controls must not be invalidated at display refresh rate.
            TimelineView(.animation(minimumInterval: nil, paused: !isPlaying || isScrubbing)) { tl in
                let degrees = rotationAt(tl.date)
                coverArtwork(rotation: degrees)
                    .background {
                        Circle()
                            .fill(.black.opacity(0.001))
                            .shadow(
                                color: .black.opacity(showsShadow ? 0.4 : 0),
                                radius: showsShadow ? 26 : 0,
                                x: 0,
                                y: showsShadow ? 10 : 0
                            )
                    }
            }

            // Mini-bar dim layer (fades out when the player expands).
            Circle()
                .glassEffect(.clear)
                .opacity(showsMiniOverlay ? 1 : 0)

            // Mini-bar play/pause icon (or loading indicator).
            Group {
                if isLoadingAudio {
                    TwoToneCircleSpinner(diameter: 18, lineWidth: 2)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .animation(nil, value: isPlaying)
                }
            }
            .coverControlContrast(for: coverImage, fallbackGradient: gradient)
            .opacity(showsMiniOverlay ? 1 : 0)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            lastScrubProgress = playbackProgress
            if isPlaying && !isScrubbing {
                playStartDate = Date()
            }
        }
        // Play/pause: start or freeze the real-time angle accumulator.
        .onChange(of: isPlaying) { _, playing in
            if playing && !isScrubbing {
                playStartDate = Date()
            } else {
                accumulatedDegrees = rotationAt(Date())
                playStartDate = nil
            }
        }
        // Scrub start/end: freeze time-based rotation and hand control to
        // the playbackProgress onChange below; resume on scrub end.
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                accumulatedDegrees = rotationAt(Date())
                playStartDate = nil
                lastScrubProgress = playbackProgress
            } else if isPlaying {
                playStartDate = Date()
            }
        }
        // Drive rotation from scrub position. Delta is scaled so that
        // scrubbing across the entire track rotates the same total angle
        // as playing the track would — keeping the two motions in sync.
        .onChange(of: playbackProgress) { _, newProgress in
            guard isScrubbing else { return }
            let effectiveDuration = duration > 0 ? duration : 180.0
            let delta = newProgress - lastScrubProgress
            accumulatedDegrees += delta * effectiveDuration * degreesPerSecond
            lastScrubProgress = newProgress
        }
    }
}

// MARK: - Cover press button style

/// Transparent button style that forwards `isPressed` state to a binding so
/// the hero cover (which lives outside the button label) can animate in sync.
private struct CoverPressButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
    }
}
