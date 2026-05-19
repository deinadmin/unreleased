import SwiftUI

// MARK: - Project Cover

/// Animated cover square.
/// - When `isPlaying` is false: cover centered, vinyl hidden (offset behind cover).
/// - When `isPlaying` is true:  cover slides left, vinyl slides out from the right and rotates.
///
/// Size contract: the layout frame is always `size × size`.
/// Total visual extent when playing = `size × 1.375`, so callers should pass
/// `size = availableWidth / 1.375` to keep everything on screen.
struct ProjectCoverView: View {
    let gradient: GradientTheme
    var size: CGFloat = 260
    var cornerRadius: CGFloat = 20
    var showVinyl: Bool = true
    var isPlaying: Bool = false

    // How far the cover slides left (= how far the vinyl bleeds right, symmetric).
    private var shift: CGFloat { size * 0.1875 }
    // Vinyl x-offset when playing: places vinyl center at cover's right edge.
    private var vinylPlayX: CGFloat { size * 0.3125 }

    @State private var isSpinning = false

    var body: some View {
        ZStack {
            if showVinyl {
                VinylRecordView(gradient: gradient, diameter: size * 0.75)
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .animation(
                        isSpinning
                            ? .linear(duration: 3.5).repeatForever(autoreverses: false)
                            : .linear(duration: 0),   // instant reset — vinyl is hidden at this point
                        value: isSpinning
                    )
                    .offset(x: isPlaying ? vinylPlayX : 0)
                    .animation(.easeInOut(duration: 0.55), value: isPlaying)
            }

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(gradient.gradient)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
                .offset(x: isPlaying ? -shift : 0)
                .animation(.easeInOut(duration: 0.25), value: isPlaying)
        }
        .frame(width: size, height: size)
        .onChange(of: isPlaying, initial: true) { _, playing in
            // Give the snap-to-zero a single frame head-start before starting the spin,
            // so the repeatForever animation always begins from 0°.
            if playing {
                isSpinning = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(16))
                    isSpinning = true
                }
            } else {
                isSpinning = false
            }
        }
    }
}

// MARK: - Vinyl Record

struct VinylRecordView: View {
    let gradient: GradientTheme
    var diameter: CGFloat = 200

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(white: 0.1))
                .frame(width: diameter, height: diameter)

            ForEach([0.88, 0.76, 0.64, 0.52] as [Double], id: \.self) { f in
                Circle()
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
                    .frame(width: diameter * f, height: diameter * f)
            }

            Circle()
                .fill(gradient.gradient)
                .frame(width: diameter * 0.3, height: diameter * 0.3)

            Circle()
                .fill(Color(white: 0.15))
                .frame(width: diameter * 0.06, height: diameter * 0.06)
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Small cover thumbnail (used in lists / mini player)

struct ProjectCoverThumbnail: View {
    let gradient: GradientTheme
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(gradient.gradient)
            .frame(width: size, height: size)
    }
}

#Preview {
    @Previewable @State var playing = false
    VStack(spacing: 32) {
        ProjectCoverView(gradient: GradientTheme.presets[0], size: 240, isPlaying: playing)
        Button(playing ? "Pause" : "Play") { playing.toggle() }
            .buttonStyle(.bordered)
    }
    .padding()
}
