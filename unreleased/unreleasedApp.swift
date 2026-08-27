import FirebaseAppCheck
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
        // Must be set before `configure()` so the first token request uses it.
        Self.configureAppCheck()
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        Self.clearKeychainOnFreshInstall()
        Self.configureFirestoreCache()
        AuthManager.configureGoogleSignIn()
        _authManager = State(initialValue: AuthManager())
    }

    /// Attests that requests come from a genuine build of this app rather than a
    /// script holding the same public config.
    ///
    /// Enforcement is a per-service switch in the Firebase console. Until it is
    /// turned on this only reports metrics, so shipping it is safe and lets the
    /// "verified requests" share be confirmed before anything starts failing.
    /// Debug builds use the debug provider, whose token has to be registered
    /// under App Check > Apps > Manage debug tokens.
    private static func configureAppCheck() {
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
        #endif
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
        // ProjectStore already owns the explicit offline library. Keeping raw
        // Firestore snapshots only in memory prevents one signed-in account's
        // private documents from remaining on a shared device for the next.
        settings.cacheSettings = MemoryCacheSettings()
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
        let audioExtensions = ["mp3", "m4a", "wav", "aiff", "aif", "aac", "flac"]
        let pathExtension = url.pathExtension.lowercased()
        return audioExtensions.contains(pathExtension)
    }
}
