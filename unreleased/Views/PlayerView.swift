import SwiftUI
import UIKit

/// Unified mini ↔ full player: one card shape morphs in place (no insert/remove swap).
struct PlayerView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(ProjectStore.self) private var store
    @Environment(\.navigateToTrackNotes) private var navigateToTrackNotes

    @State private var offset: CGFloat = 0
    @State private var lastDragTranslation: CGFloat = 0
    @State private var isDragging = false
    @State private var miniScrubPillVisible = false
    @State private var miniScrubProgress: Double = 0
    @State private var isShowingTrackInfo = false

    private let compactHeight: CGFloat = 50
    /// Space between the mini player bar and the floating scrub time pill.
    private let miniWaveformWidth: CGFloat = 130
    private var miniScrubPillLift: CGFloat { compactHeight + 8 }
    private let compactCoverInset: CGFloat = 4
    private let sideMargin: CGFloat = 12

    private var isExpanded: Bool { player.isShowingNowPlaying }

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
    private var coverSize: CGFloat { isExpanded ? 200 : compactCoverSize }

    // MARK: - Body

    var body: some View {
        if let track = player.currentTrack, let project = player.currentProject {
            ZStack(alignment: .bottom) {
                playerCard(track: track, project: project)
                    .padding(.horizontal, sideMargin)
                    // Expanded: same inset as sides so bottom corners stay concentric with the device.
                    // Mini: keep the existing float above the home indicator.
                    .padding(.bottom, isExpanded ? sideMargin : 8)
                    .ignoresSafeArea(edges: isExpanded ? .bottom : [])
            }
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
            }
            .onChange(of: player.isShowingNowPlaying) { _, showing in
                offset = 0
                lastDragTranslation = 0
                if showing { dismissKeyboard() }
            }
            .sheet(isPresented: $isShowingTrackInfo) {
                if let track = player.currentTrack, let project = player.currentProject {
                    TrackInfoSheet(
                        track: track,
                        project: project,
                        onOpenNotes: {
                            isShowingTrackInfo = false
                            navigateToTrackNotes(track.id, project.id)
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

                expandedTitle(track: track, project: project)
                    .padding(.top, 16)
                    .padding(.horizontal, 24)
            }

            coverSection(track: track, project: project)
                .padding(.top, isExpanded ? 18 : 0)

            if isExpanded {
                waveformSection(track: track)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)

                timeRow
                    .padding(.horizontal, 24)
                    .padding(.top, 6)

                transportControls
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                bottomAccessories
                    .padding(.top, 16)
                    .padding(.horizontal, 8)
                    .padding(.bottom, bottomInset)
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
            .fill(Color(white: isExpanded ? 0.10 : 0.13))
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
                        .background(Color.black, in: Capsule())
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

    // MARK: - Cover (single hero element)

    @ViewBuilder
    private func coverSection(track: Track, project: Project) -> some View {
        ZStack(alignment: isExpanded ? .center : .leading) {
            if isExpanded {
                PlayerCoverGlow(gradient: project.gradient.gradient, coverSize: coverSize, isPlaying: player.isPlaying)
                    .allowsHitTesting(false)
            }

            if !isExpanded {
                compactRow(track: track, project: project)
            }

            coverArt(project: project)
                .padding(.leading, isExpanded ? 0 : compactCoverInset)
                .padding(.vertical, isExpanded ? 0 : compactCoverInset)
                .frame(maxWidth: .infinity, alignment: isExpanded ? .center : .leading)
        }
        .frame(height: isExpanded ? nil : compactHeight)
    }

    @ViewBuilder
    private func coverArt(project: Project) -> some View {
        Button {
            if !isExpanded { player.togglePlayPause() }
        } label: {
            ZStack {
                PlayerCoverGradient(
                    gradient: project.gradient.gradient,
                    isExpanded: isExpanded,
                    isPlaying: player.isPlaying
                )
                .shadow(color: .black.opacity(isExpanded ? 0.4 : 0), radius: 26, x: 0, y: 10)

                Circle()
                    .fill(.black.opacity(isExpanded ? 0 : 0.18))

                if !isExpanded {
                    miniCoverOverlay
                }
            }
            .frame(width: coverSize, height: coverSize)
            .contentShape(Circle())
        }
        .buttonStyle(.scale)
        .disabled(isExpanded || player.isLoadingAudio)
        .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
    }

    @ViewBuilder
    private var miniCoverOverlay: some View {
        if player.isLoadingAudio {
            Group {
                if player.loadingProgress > 0 {
                    ProgressView(value: player.loadingProgress)
                        .progressViewStyle(.circular)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
            }
            .tint(.white)
            .scaleEffect(0.9)
        } else {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .animation(nil, value: player.isPlaying)
        }
    }

    @ViewBuilder
    private func compactRow(track: Track, project: Project) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: compactHeight)

            Button {
                player.isShowingNowPlaying = true
            } label: {
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
                .padding(.leading, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            waveformSection(track: track)
                .frame(width: miniWaveformWidth, height: 26)
                .padding(.trailing, 10)
        }
        .frame(height: compactHeight)
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
            } : nil,
            visibleBars: isExpanded ? 44 : 38,
            onSeek: { p in player.seek(to: p * player.duration) }
        )
        .frame(height: isExpanded ? 60 : 26)
        .frame(maxWidth: isExpanded ? .infinity : nil)
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
        HStack {
            Text(player.formattedCurrentTime)
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
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.black)
                        .animation(nil, value: player.isPlaying)
                }
            }
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

    private var bottomAccessories: some View {
        HStack(spacing: 0) {
            bottomAccessoryButton(icon: "doc.text", label: "notes") {
                openTrackNotes()
            }
            bottomAccessoryButton(icon: "square.and.arrow.up", label: "share") {
                shareCurrentTrack()
            }
            bottomAccessoryButton(icon: "ellipsis", label: "options") {
                isShowingTrackInfo = true
            }
        }
    }

    private static let bottomAccessoryHeight: CGFloat = 48

    private func bottomAccessoryButton(
        icon: String,
        label: String,
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
            .foregroundStyle(.white.opacity(0.48))
            .frame(height: Self.bottomAccessoryHeight)
            .frame(maxWidth: .infinity)
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

    private func openTrackNotes() {
        guard let track = player.currentTrack, let project = player.currentProject else { return }
        let trackID = track.id
        let projectID = project.id
        player.isShowingNowPlaying = false
        DispatchQueue.main.async {
            navigateToTrackNotes(trackID, projectID)
        }
    }

    private func shareCurrentTrack() {
        guard let track = player.currentTrack else { return }
        let url = store.hasDownloadedFile(for: track)
            ? store.downloadedFileURL(for: track)
            : store.audioFileURL(for: track)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first {
            window.rootViewController?.present(av, animated: true)
        }
    }
}

// MARK: - Cover artwork (animations isolated from play/pause icons)

private struct PlayerCoverGradient: View {
    let gradient: LinearGradient
    let isExpanded: Bool
    let isPlaying: Bool

    private var scale: CGFloat {
        isExpanded ? (isPlaying ? 1.0 : 0.93) : 1
    }

    var body: some View {
        Circle()
            .fill(gradient)
            .scaleEffect(scale)
            .animation(isExpanded ? .smooth(duration: 0.4) : nil, value: isPlaying)
    }
}

private struct PlayerCoverGlow: View {
    let gradient: LinearGradient
    let coverSize: CGFloat
    let isPlaying: Bool

    private var scale: CGFloat { isPlaying ? 1.0 : 0.93 }

    var body: some View {
        Circle()
            .fill(gradient.opacity(0.18))
            .frame(width: coverSize + 26, height: coverSize + 26)
            .scaleEffect(scale)
            .blur(radius: 16)
            .animation(.smooth(duration: 0.4), value: isPlaying)
    }
}
