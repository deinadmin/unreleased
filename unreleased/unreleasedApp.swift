import FirebaseCore
import SwiftUI

@main
struct unreleasedApp: App {
    @State private var authManager: AuthManager

    init() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        AuthManager.configureGoogleSignIn()
        _authManager = State(initialValue: AuthManager())
    }

    var body: some Scene {
        WindowGroup {
            AuthRootView()
                .environment(authManager)
                .buttonStyle(.scale)
                .onOpenURL { url in
                    _ = authManager.handleGoogleURL(url)
                }
        }
    }
}
