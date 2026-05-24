import SwiftUI

// MARK: - Shared auth styling

enum AuthChrome {
    static let socialButtonHeight: CGFloat = 56
    static let primaryButtonHeight: CGFloat = 56
    static let horizontalPadding: CGFloat = 28
    static let pageBackground = Color(.systemBackground)
    static let elevatedFill = Color(.secondarySystemBackground)
    static let borderColor = Color.primary.opacity(0.06)

    static let headlineFont = Font.system(size: 26, weight: .bold)
    static let bodyFont = Font.system(size: 15)
    static let legalFont = Font.system(size: 12)
}

struct AuthAppMark: View {
    @Environment(\.colorScheme) private var colorScheme

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
                .fill(AuthChrome.elevatedFill)
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08),
                    radius: 24,
                    x: 0,
                    y: 10
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(AuthChrome.borderColor, lineWidth: 1)
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
            .background(AuthChrome.elevatedFill, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(AuthChrome.borderColor, lineWidth: 1)
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
                .foregroundStyle(.primary)
        case .google:
            Image("Google")
                .resizable()
                .scaledToFit()
        }
    }
}

struct AuthPrimaryButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    var isEnabled: Bool = true
    var isLoading: Bool = false
    var action: () -> Void

    private var buttonFill: Color {
        guard isEnabled else {
            return colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.35)
        }
        return colorScheme == .dark ? .white : .black
    }

    private var labelColor: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .tint(labelColor)
                } else {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: AuthChrome.primaryButtonHeight)
            .background(buttonFill, in: Capsule())
            .foregroundStyle(labelColor)
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
