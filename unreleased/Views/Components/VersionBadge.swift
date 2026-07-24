import SwiftUI

struct VersionBadge: View {
    enum Style {
        case standard
        case player
    }

    let number: Int
    var style: Style = .standard

    var body: some View {
        Text("v\(number)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
            .accessibilityLabel("Version \(number)")
    }

    private var foreground: Color {
        switch style {
        case .standard: .secondary
        case .player: .white.opacity(0.88)
        }
    }

    private var background: Color {
        switch style {
        case .standard: Color(.tertiarySystemFill)
        case .player: .white.opacity(0.14)
        }
    }
}
