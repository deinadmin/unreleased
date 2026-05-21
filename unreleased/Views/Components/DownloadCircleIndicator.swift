import SwiftUI

/// `arrow.down.circle` / `.fill` aligned with a same-size two-tone spinner; playful spring transitions between states.
struct DownloadCircleIndicator: View {
    var symbolPointSize: CGFloat = 22
    var isDownloading: Bool = false
    var isFilled: Bool = false
    var iconColor: Color = .primary

    /// Outer diameter of the ring inside the SF Symbol (matches cap height × ratio).
    private var ringDiameter: CGFloat { symbolPointSize * 0.88 }
    private var ringLineWidth: CGFloat { max(1, symbolPointSize * 0.086) }

    private var systemImage: String {
        isFilled ? "arrow.down.circle.fill" : "arrow.down.circle"
    }

    private var downloadSpring: Animation {
        .spring(response: 0.48, dampingFraction: 0.58)
    }

    private var fillSpring: Animation {
        .spring(response: 0.36, dampingFraction: 0.5)
    }

    /// Pivot on the left so twist / spin matches the spinner’s clockwise sweep from the left.
    private var pivot: UnitPoint { .leading }

    var body: some View {
        ZStack {
            Image(systemName: systemImage)
                .font(.system(size: symbolPointSize, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(iconColor)
                .contentTransition(.symbolEffect(.replace.byLayer))
                .symbolEffect(.bounce.down.byLayer, options: .nonRepeating, value: isFilled)
                .scaleEffect(isDownloading ? 0.45 : 1, anchor: pivot)
                .rotationEffect(.degrees(isDownloading ? 110 : 0), anchor: pivot)
                .blur(radius: isDownloading ? 6 : 0)
                .opacity(isDownloading ? 0 : 1)

            TwoToneCircleSpinner(
                diameter: ringDiameter,
                lineWidth: ringLineWidth
            )
            .scaleEffect(isDownloading ? 1 : 0.3, anchor: pivot)
            .rotationEffect(.degrees(isDownloading ? 0 : -210), anchor: pivot)
            .blur(radius: isDownloading ? 0 : 5)
            .opacity(isDownloading ? 1 : 0)
        }
        .frame(width: symbolPointSize, height: symbolPointSize)
        .animation(downloadSpring, value: isDownloading)
        .animation(fillSpring, value: isFilled)
    }
}
