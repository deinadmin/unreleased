import FirebaseCore
import FirebaseFirestore
import SwiftUI

@main
struct unreleasedApp: App {
    @State private var authManager: AuthManager

    init() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        Self.configureFirestoreCache()
        AuthManager.configureGoogleSignIn()
        _authManager = State(initialValue: AuthManager())
    }

    private static func configureFirestoreCache() {
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings()
        Firestore.firestore().settings = settings
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
