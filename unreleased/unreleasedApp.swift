import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import SwiftUI

@main
struct unreleasedApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @State private var authManager: AuthManager
    @State private var profileAvatarStore = ProfileAvatarStore()
    @State private var importManager = AudioFileImportManager()
    @State private var linkRouter = ProjectLinkRouter()

    init() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        Self.clearKeychainOnFreshInstall()
        Self.configureFirestoreCache()
        AuthManager.configureGoogleSignIn()
        _authManager = State(initialValue: AuthManager())
    }

    /// UserDefaults is wiped when the app is deleted; Keychain is not.
    /// If this is a fresh install (no UserDefaults sentinel), sign out of Firebase
    /// so a stale Keychain token never auto-signs in a deleted account on first launch.
    private static func clearKeychainOnFreshInstall() {
        let key = "app.hasLaunchedBefore"
        if UserDefaults.standard.object(forKey: key) == nil {
            try? Auth.auth().signOut()
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    private static func configureFirestoreCache() {
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings()
        Firestore.firestore().settings = settings
    }

    var body: some Scene {
        WindowGroup {
            AuthRootView()
                .tint(Color("AccentColor"))
                .environment(authManager)
                .environment(profileAvatarStore)
                .buttonStyle(.scale)
                .environment(importManager)
                .environment(linkRouter)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onAppear {
                    importManager.loadPendingImportIfNeeded()
                    PushNotificationManager.shared.clearApplicationBadge()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    importManager.loadPendingImportIfNeeded()
                    PushNotificationManager.shared.clearApplicationBadge()
                }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        if linkRouter.receive(url: url) { return }

        if url.scheme == "unreleased", url.host == "import" {
            importManager.loadPendingImportIfNeeded()
            return
        }

        if isAudioFile(url) {
            importManager.setDirectImport(url: url)
        } else {
            _ = authManager.handleGoogleURL(url)
        }
    }

    private func isAudioFile(_ url: URL) -> Bool {
        let audioExtensions = ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg"]
        let pathExtension = url.pathExtension.lowercased()
        return audioExtensions.contains(pathExtension)
    }
}
