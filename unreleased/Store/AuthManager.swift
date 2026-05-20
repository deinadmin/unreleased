import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import Foundation
import GoogleSignIn
import UIKit

@Observable
@MainActor
final class AuthManager {
    var user: User?
    var isLoading = false
    var errorMessage: String?

    var isSignedIn: Bool { user != nil }

    /// Stable identity for SwiftUI animations when auth state changes.
    var signedInUserID: String? { user?.uid }

    var accountLabel: String? {
        if let email = user?.email, !email.isEmpty { return email }
        if let phone = user?.phoneNumber, !phone.isEmpty { return phone }
        return nil
    }

    /// Listener handle is removed from `deinit` (nonisolated); storage must not be MainActor-only.
    nonisolated(unsafe) private var authListener: AuthStateDidChangeListenerHandle?
    private var currentNonce: String?

    init() {
        user = Auth.auth().currentUser
        authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
            }
        }
    }

    deinit {
        if let authListener {
            Auth.auth().removeStateDidChangeListener(authListener)
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func signOut() {
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
            user = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Sign in with Apple

    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }

    func handleAppleSignIn(result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Apple sign-in failed."
                return
            }
            await signInWithApple(credential: credential)
        case .failure(let error):
            let nsError = error as NSError
            if nsError.code == ASAuthorizationError.canceled.rawValue { return }
            errorMessage = error.localizedDescription
        }
    }

    private func signInWithApple(credential: ASAuthorizationAppleIDCredential) async {
        guard let nonce = currentNonce else {
            errorMessage = "Invalid sign-in state. Try again."
            return
        }
        guard let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            errorMessage = "Unable to read Apple identity token."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: idToken,
                rawNonce: nonce,
                fullName: credential.fullName
            )
            let result = try await Auth.auth().signIn(with: firebaseCredential)
            user = result.user
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Email & password

    func signIn(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            user = result.user
        } catch {
            errorMessage = friendlyAuthMessage(for: error)
        }
    }

    func createAccount(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            user = result.user
        } catch {
            errorMessage = friendlyAuthMessage(for: error)
        }
    }

    @discardableResult
    func sendPasswordReset(to email: String) async -> Bool {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await Auth.auth().sendPasswordReset(withEmail: email)
            return true
        } catch {
            errorMessage = friendlyAuthMessage(for: error)
            return false
        }
    }

    // MARK: - Google

    static func configureGoogleSignIn() {
        guard let clientID = googleClientID else { return }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    }

    private static var googleClientID: String? {
        FirebaseApp.app()?.options.clientID ?? GoogleServiceInfo.clientID
    }

    var isGoogleSignInConfigured: Bool {
        Self.googleClientID != nil && GoogleServiceInfo.reversedClientID != nil
    }

    func signInWithGoogle() async {
        guard let clientID = Self.googleClientID else {
            errorMessage = """
            Google Sign-In isn’t configured in the app yet. In Firebase Console open Project settings → Your apps → iOS, download a fresh GoogleService-Info.plist (it must include CLIENT_ID and REVERSED_CLIENT_ID), replace the file in Xcode, then add the URL scheme from REVERSED_CLIENT_ID to Info.plist.
            """
            return
        }

        if GoogleServiceInfo.reversedClientID == nil {
            errorMessage = """
            GoogleService-Info.plist is missing REVERSED_CLIENT_ID. Download the latest plist from Firebase and add a URL scheme to Info.plist using that value.
            """
            return
        }

        guard let presenter = Self.topViewController() else {
            errorMessage = "Could not present Google sign-in."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            Self.configureGoogleSignIn()
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                errorMessage = "Missing Google ID token."
                return
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            let authResult = try await Auth.auth().signIn(with: credential)
            user = authResult.user
        } catch {
            let nsError = error as NSError
            if nsError.code == GIDSignInError.canceled.rawValue { return }
            errorMessage = error.localizedDescription
        }
    }

    func handleGoogleURL(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    // MARK: - Helpers

    private func friendlyAuthMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain,
           let code = AuthErrorCode(rawValue: nsError.code) {
            switch code {
            case .wrongPassword, .invalidCredential:
                return "Incorrect email or password."
            case .userNotFound:
                return "No account found for this email."
            case .emailAlreadyInUse:
                return "An account already exists for this email."
            case .weakPassword:
                return "Choose a password with at least 6 characters."
            case .invalidEmail:
                return "Enter a valid email address."
            case .networkError:
                return "Network error. Check your connection and try again."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return nil }

        var controller = root
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length

        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if status != errSecSuccess {
                fatalError("Unable to generate nonce.")
            }
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

