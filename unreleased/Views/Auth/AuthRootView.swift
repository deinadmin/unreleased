import SwiftUI

struct AuthRootView: View {
    @Environment(AuthManager.self) private var auth

    var body: some View {
        Group {
            if auth.isSignedIn {
                ContentView()
            } else {
                WelcomeView()
            }
        }
        .animation(.smooth(duration: 0.35), value: auth.signedInUserID)
    }
}

#Preview {
    AuthRootView()
        .environment(AuthManager())
}
