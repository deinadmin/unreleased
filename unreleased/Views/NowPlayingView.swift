import SwiftUI
import UIKit

struct NowPlayingView: View {
    var namespace: Namespace.ID

    @Environment(AudioPlayer.self) private var player

    // Offset driven directly from onChanged — simple, correct, and the reduced
    // 100 ms time-observer means state-update lag is imperceptible.
    @State private var offset: CGFloat = 0

    // Standard iOS rubber-band: resistance grows with displacement so upward
    // pulls feel springy and bounded.
    private func rubberband(_ x: CGFloat) -> CGFloat {
        let coeff: CGFloat = 0.55
        let dim:   CGFloat = 700
        let mag = abs(x)
        let reduced = (1 - 1 / (mag * coeff / dim + 1)) * dim
        return x < 0 ? -reduced : reduced
    }

    // Read safe-area insets and screen corner radius from UIKit — no GeometryReader
    // needed, which removes one layout-pass per render cycle.
    private var bottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.safeAreaInsets.bottom ?? 34
    }

    // Device screen corner radius (private but universally safe to read).
    // The card's bottom corners are inset-adjusted to look concentric with the screen.
    private var screenCornerRadius: CGFloat {
        (UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 44
    }
    private let sideMargin: CGFloat = 12

    // MARK: - Body

    var body: some View {
        // Bottom-anchored: card sits flush with the screen's bottom edge so its
        // lower corners align concentrically with the device's squircle corners.
        ZStack(alignment: .bottom) {
            Color.clear

            cardContent
                .padding(.horizontal, sideMargin)
                .padding(.bottom, sideMargin)
        }
        .ignoresSafeArea()
        .offset(y: offset)
        .scaleEffect(offset > 0 ? max(0.93, 1 - offset / 1400) : 1, anchor: .bottom)
        .gesture(dismissGesture)
    }

    // MARK: - Card

    private var cardContent: some View {
        VStack(spacing: 0) {

            dragHandle
                .padding(.top, 12)

            titleSection
                .padding(.top, 16)
                .padding(.horizontal, 24)

            artworkSection
                .padding(.top, 18)

            waveformSection
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
                // Bottom padding = home-indicator height so content clears it,
                // but the card background extends all the way to the screen edge.
                .padding(.bottom, max(bottomInset, 16))
        }
        .frame(maxWidth: .infinity)
        .background(cardShape)
    }

    private var cardShape: some View {
        // Bottom corners are concentric with the device squircle:
        // innerRadius = screenCornerRadius - sideMargin (standard concentric rule).
        // Top corners are larger to look like a lifted bottom sheet.
        let bottomR = max(0, screenCornerRadius - sideMargin)
        return UnevenRoundedRectangle(
            topLeadingRadius:    36,
            bottomLeadingRadius: bottomR,
            bottomTrailingRadius: bottomR,
            topTrailingRadius:   36,
            style: .continuous
        )
        .fill(Color(white: 0.10))
        .shadow(color: .black.opacity(0.45), radius: 40, x: 0, y: -6)
    }

    // MARK: - Sections

    private var dragHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 36, height: 4)
    }

    private var titleSection: some View {
        VStack(spacing: 4) {
            if let track = player.currentTrack {
                Text(track.title)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            if let project = player.currentProject {
                Text(project.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.52))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var artworkSection: some View {
        Group {
            if let project = player.currentProject {
                ZStack {
                    Circle()
                        .fill(project.gradient.gradient.opacity(0.18))
                        .frame(width: 226, height: 226)
                        .blur(radius: 16)

                    Circle()
                        .fill(project.gradient.gradient)
                        .matchedGeometryEffect(id: "playerCover", in: namespace)
                        .frame(width: 200, height: 200)
                        .shadow(color: .black.opacity(0.4), radius: 26, x: 0, y: 10)
                        .scaleEffect(player.isPlaying ? 1.0 : 0.93)
                        .animation(.smooth(duration: 0.4), value: player.isPlaying)
                }
            }
        }
    }

    private var waveformSection: some View {
        Group {
            if let track = player.currentTrack {
                ScrollingMiniWaveformView(
                    trackID: track.id,
                    waveformData: track.waveformData,
                    progress: player.playbackProgress,
                    visibleBars: 44,
                    onSeek: { player.seek(to: $0 * player.duration) }
                )
                .frame(height: 60)
            }
        }
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
            Button { shareCurrentTrack() } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { player.skipBackward() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer()

            // Central play/pause button
            Button { player.togglePlayPause() } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.white)
                        .frame(width: 62, height: 62)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.black)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)

            Spacer()

            Button { player.skipForward() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {} label: {
                Image(systemName: "repeat")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.32))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private var bottomAccessories: some View {
        HStack(spacing: 0) {
            Button {} label: {
                VStack(spacing: 5) {
                    Image(systemName: "doc.text").font(.system(size: 19))
                    Text("notes").font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.48))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {} label: {
                VStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 19))
                    Text("edit").font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.48))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Gesture

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let t = value.translation.height
                // Apply rubber-banding for upward pulls; free movement downward.
                offset = t < 0 ? rubberband(t) : t
            }
            .onEnded { value in
                let t = value.predictedEndTranslation.height
                if value.translation.height > 120 || t > 300 {
                    player.isShowingNowPlaying = false
                } else {
                    // offset is already at the correct visual position here —
                    // withAnimation smoothly springs it back to 0. No jump possible
                    // because we never reset it before starting the animation.
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) {
                        offset = 0
                    }
                }
            }
    }

    // MARK: - Actions

    private func shareCurrentTrack() {
        guard let track = player.currentTrack else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url  = docs.appendingPathComponent("AudioFiles/\(track.fileName)")
        let av   = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first {
            window.rootViewController?.present(av, animated: true)
        }
    }
}
