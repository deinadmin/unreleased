import SwiftUI

// MARK: - Shared auth styling

enum AuthChrome {
    static let controlHeight: CGFloat = 52
    static let controlCornerRadius: CGFloat = 14
    static let horizontalPadding: CGFloat = 20
    static let pageBackground = Color(.systemBackground)
    static let elevatedFill = Color(.secondarySystemBackground)
    static let borderColor = Color.primary.opacity(0.06)

    static let headlineFont = Font.system(size: 22, weight: .bold)
    static let bodyFont = Font.system(size: 15)
    static let legalFont = Font.system(size: 12)
}

struct AuthAppMark: View {
    var size: CGFloat = 112
    var cornerRadius: CGFloat = 28

    var body: some View {
        Image("AppIconDisplay")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
            .accessibilityLabel("unreleased app icon")
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
            .frame(height: AuthChrome.controlHeight)
            .background(
                AuthChrome.elevatedFill,
                in: RoundedRectangle(cornerRadius: AuthChrome.controlCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AuthChrome.controlCornerRadius, style: .continuous)
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
    let title: String
    var isEnabled: Bool = true
    var isLoading: Bool = false
    var action: () -> Void

    private var buttonFill: Color {
        isEnabled ? Color("AccentColor") : Color("AccentColor").opacity(0.35)
    }

    private let labelColor = Color.black

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
            .frame(height: AuthChrome.controlHeight)
            .background(
                buttonFill,
                in: RoundedRectangle(cornerRadius: AuthChrome.controlCornerRadius, style: .continuous)
            )
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
