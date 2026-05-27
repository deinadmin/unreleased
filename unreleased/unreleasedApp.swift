import FirebaseCore
import FirebaseFirestore
import SwiftUI

@main
struct unreleasedApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var authManager: AuthManager
    @State private var importManager = AudioFileImportManager()

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
                .environment(importManager)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onAppear {
                    importManager.loadPendingImportIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    importManager.loadPendingImportIfNeeded()
                }
        }
    }

    private func handleIncomingURL(_ url: URL) {
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
