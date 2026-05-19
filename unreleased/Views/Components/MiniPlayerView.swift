import SwiftUI

struct MiniPlayerView: View {
    /// Shared namespace for the hero cover-circle transition.
    var namespace: Namespace.ID

    @Environment(AudioPlayer.self) private var player
    @Environment(ProjectStore.self) private var store

    // Capsule height = circle diameter: the gradient circle's centre aligns
    // exactly with the capsule end-cap centre → perfect visual concentricity.
    private let capsuleHeight: CGFloat = 50

    var body: some View {
        if let track = player.currentTrack, let project = player.currentProject {
            bar(track: track, project: project)
        }
    }

    // MARK: - Main bar

    @ViewBuilder
    private func bar(track: Track, project: Project) -> some View {
        HStack(spacing: 0) {

            // ── Left: circular cover = play/pause tap target ──────────────────
            coverButton(project: project)

            // ── Center: track + project name (tap → full player) ─────────────
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
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            // ── Right: scrolling waveform scrubber ────────────────────────────
            ScrollingMiniWaveformView(
                trackID: track.id,
                waveformData: track.waveformData,
                progress: player.playbackProgress,
                onSeek: { p in player.seek(to: p * player.duration) }
            )
            .frame(width: 130, height: 26)
            .padding(.trailing, 10)
        }
        .frame(height: capsuleHeight)
        .background {
            Capsule()
                .fill(Color(white: 0.13))
                .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 6)
        }
    }

    // MARK: - Circular cover with play/pause overlay

    @ViewBuilder
    private func coverButton(project: Project) -> some View {
        ZStack {
            // Hero element: gradient circle. matchedGeometryEffect animates this
            // circle from its mini-player size/position into the full-player cover.
            Circle()
                .fill(project.gradient.gradient)
                .matchedGeometryEffect(id: "playerCover", in: namespace)
                .padding(3)

            // Subtle dark veil for icon legibility — not part of the hero geometry.
            Circle()
                .fill(.black.opacity(0.18))
                .padding(3)

            // Play / pause icon
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: capsuleHeight, height: capsuleHeight)
        .contentShape(Circle().inset(by: 3))
        .onTapGesture {
            player.togglePlayPause()
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
    }
}
