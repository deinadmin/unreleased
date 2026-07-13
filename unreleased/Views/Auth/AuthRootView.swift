import SwiftUI

struct AuthRootView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(ProfileAvatarStore.self) private var avatarStore

    var body: some View {
        Group {
            if auth.isSignedIn {
                ContentView()
            } else {
                WelcomeView()
            }
        }
        .animation(.smooth(duration: 0.35), value: auth.signedInUserID)
        .task(id: auth.signedInUserID) {
            avatarStore.observe(
                userID: auth.signedInUserID,
                fallbackPhotoURL: auth.photoURL
            )
        }
    }
}

#Preview {
    AuthRootView()
        .environment(AuthManager())
        .environment(ProfileAvatarStore())
}
