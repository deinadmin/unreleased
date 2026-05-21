import SwiftUI

/// Minimal rotating ring — one half emphasized, one half muted (black/white on light, white/gray on dark).
/// `diameter` is the outer visual diameter of the ring (stroke centered on the path).
struct TwoToneCircleSpinner: View {
    var diameter: CGFloat = 14
    var lineWidth: CGFloat = 1.5

    @Environment(\.colorScheme) private var colorScheme
    @State private var rotation: Double = 0

    private var pathDiameter: CGFloat { max(0, diameter - lineWidth) }

    private var emphasized: Color { colorScheme == .dark ? .white : .black }
    private var muted: Color { colorScheme == .dark ? Color.white.opacity(0.28) : Color.black.opacity(0.2) }

    var body: some View {
        ZStack {
            arc(from: 0, to: 0.5, color: emphasized)
            arc(from: 0.5, to: 1, color: muted)
        }
        .frame(width: pathDiameter, height: pathDiameter)
        .frame(width: diameter, height: diameter)
        .rotationEffect(.degrees(rotation))
        .onAppear {
            rotation = 0
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }

    private func arc(from start: CGFloat, to end: CGFloat, color: Color) -> some View {
        Circle()
            .trim(from: start, to: end)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}
