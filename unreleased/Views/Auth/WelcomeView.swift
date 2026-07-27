import AuthenticationServices
import SwiftUI

struct WelcomeView: View {
    @Environment(AuthManager.self) private var auth

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            welcomeContent
        }
    }

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            AuthAppMark(size: 120, cornerRadius: 30)
                .resistedDragTilt(inverted: true)
                .padding(.bottom, 36)

            Text("Give your work-in-progress music a proper home")
                .font(AuthChrome.headlineFont)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, AuthChrome.horizontalPadding)
                .padding(.bottom, 40)

            VStack(spacing: 10) {
                AuthSocialButton(title: "Continue with Apple", icon: .apple) {
                    performAppleSignIn()
                }
                .disabled(auth.isLoading)

                AuthSocialButton(title: "Continue with Google", icon: .google) {
                    Task { await auth.signInWithGoogle() }
                }
                .disabled(auth.isLoading)

                NavigationLink(value: AuthRoute.email) {
                    Text("Continue with email")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(auth.isLoading)
            }
            .padding(.horizontal, AuthChrome.horizontalPadding)

            Spacer()

            AuthLegalFooter()
                .padding(.horizontal, 40)
                .padding(.bottom, 16)
        }
        .background(AuthChrome.pageBackground.ignoresSafeArea())
        .toolbarVisibility(.hidden, for: .navigationBar)
        .navigationDestination(for: AuthRoute.self) { route in
            switch route {
            case .email:
                EmailPasswordAuthView()
            }
        }
        .neutralAlert("Sign In", isPresented: errorBinding) {
            Button("OK") { auth.clearError() }
                .tint(.primary)
        } message: {
            Text(auth.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { auth.errorMessage != nil },
            set: { if !$0 { auth.clearError() } }
        )
    }

    private func performAppleSignIn() {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        auth.prepareAppleSignInRequest(request)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = AppleSignInDelegate.shared
        controller.presentationContextProvider = AppleSignInDelegate.shared
        AppleSignInDelegate.shared.onCompletion = { result in
            Task { await auth.handleAppleSignIn(result: result) }
        }
        controller.performRequests()
    }
}

// MARK: - Apple Sign In presentation

@MainActor
private final class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let shared = AppleSignInDelegate()
    var onCompletion: ((Result<ASAuthorization, Error>) -> Void)?

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else { return ASPresentationAnchor() }
        return window
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        onCompletion?(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        onCompletion?(.failure(error))
    }
}

enum AuthRoute: Hashable {
    case email
}

#Preview {
    NavigationStack {
        WelcomeView()
    }
    .environment(AuthManager())
}
