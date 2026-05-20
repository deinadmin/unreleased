import SwiftUI

// MARK: - Shared auth styling

enum AuthChrome {
    static let socialButtonHeight: CGFloat = 56
    static let primaryButtonHeight: CGFloat = 56
    static let horizontalPadding: CGFloat = 28
    static let socialFill = Color(white: 0.96)

    static let headlineFont = Font.system(size: 26, weight: .bold)
    static let bodyFont = Font.system(size: 15)
    static let legalFont = Font.system(size: 12)
}

struct AuthAppMark: View {
    var size: CGFloat = 112
    var cornerRadius: CGFloat = 28

    private let markGradient = GradientTheme(
        colors: ["#FF6FD8", "#FFB347", "#FF6FD8"],
        startX: 0.15,
        startY: 0,
        endX: 0.85,
        endY: 1
    )

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.08), radius: 24, x: 0, y: 10)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                }

            ProjectCoverView(
                gradient: markGradient,
                size: size * 0.72,
                cornerRadius: size * 0.18,
                showVinyl: true
            )
        }
        .frame(width: size, height: size)
    }
}

struct AuthSocialButton: View {
    let title: String
    let icon: AuthSocialIcon
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.view
                    .frame(width: 20, height: 20)
                    .fixedSize()
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: AuthChrome.socialButtonHeight)
            .background(AuthChrome.socialFill, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.scale)
    }
}

enum AuthSocialIcon {
    case apple
    case google

    @ViewBuilder
    var view: some View {
        switch self {
        case .apple:
            Image(systemName: "apple.logo")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.black)
        case .google:
            GoogleGLogo()
                .fixedSize()
        }
    }
}

/// Google "G" mark — square layout so it isn't stretched by the social button height.
private struct GoogleGLogo: View {
    private let blue = Color(red: 66 / 255, green: 133 / 255, blue: 244 / 255)
    private let red = Color(red: 234 / 255, green: 67 / 255, blue: 53 / 255)
    private let yellow = Color(red: 251 / 255, green: 188 / 255, blue: 5 / 255)
    private let green = Color(red: 52 / 255, green: 168 / 255, blue: 83 / 255)

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let outer = side * 0.48
            let inner = side * 0.30
            let stroke = side * 0.18

            ZStack {
                ringSegment(center: center, outer: outer, inner: inner, start: -45, end: 45, color: blue)
                ringSegment(center: center, outer: outer, inner: inner, start: 45, end: 135, color: yellow)
                ringSegment(center: center, outer: outer, inner: inner, start: 135, end: 225, color: green)
                ringSegment(center: center, outer: outer, inner: inner, start: 225, end: 315, color: red)

                // Horizontal bar of the G
                Path { path in
                    path.addRect(
                        CGRect(
                            x: center.x - stroke * 0.05,
                            y: center.y - stroke / 2,
                            width: outer * 0.95,
                            height: stroke
                        )
                    )
                }
                .fill(blue)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(width: 20, height: 20)
    }

    private func ringSegment(
        center: CGPoint,
        outer: CGFloat,
        inner: CGFloat,
        start: Double,
        end: Double,
        color: Color
    ) -> some View {
        Path { path in
            path.addArc(
                center: center,
                radius: outer,
                startAngle: .degrees(start),
                endAngle: .degrees(end),
                clockwise: false
            )
            path.addArc(
                center: center,
                radius: inner,
                startAngle: .degrees(end),
                endAngle: .degrees(start),
                clockwise: true
            )
            path.closeSubpath()
        }
        .fill(color)
    }
}

struct AuthPrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    var isLoading: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: AuthChrome.primaryButtonHeight)
            .background(isEnabled ? Color.black : Color.black.opacity(0.35), in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.scale)
        .disabled(!isEnabled || isLoading)
    }
}

struct AuthLegalFooter: View {
    var body: some View {
        Text(legalAttributed)
            .font(AuthChrome.legalFont)
            .foregroundStyle(Color(.tertiaryLabel))
            .multilineTextAlignment(.center)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "terms" || url.scheme == "privacy" {
                    // Placeholder — wire real URLs when available.
                    return .handled
                }
                return .systemAction
            })
    }

    private var legalAttributed: AttributedString {
        var text = AttributedString("By continuing you confirm that you’ve read and accepted our ")
        var terms = AttributedString("Terms")
        terms.link = URL(string: "terms://local")
        terms.underlineStyle = .single
        var and = AttributedString(" and ")
        var privacy = AttributedString("Privacy Policy")
        privacy.link = URL(string: "privacy://local")
        privacy.underlineStyle = .single
        text.append(terms)
        text.append(and)
        text.append(privacy)
        text.append(AttributedString("."))
        return text
    }
}
