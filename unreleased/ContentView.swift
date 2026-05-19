import SwiftUI

struct ContentView: View {
    @State private var store = ProjectStore()
    @State private var player = AudioPlayer()
    @Namespace private var playerNS

    var body: some View {
        ZStack(alignment: .bottom) {

            // ── Main app content ─────────────────────────────────────────────────
            NavigationStack {
                HomeView()
            }
            .environment(store)
            .environment(player)
            // Reserve room so the last list item doesn't hide under the mini player
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.currentTrack != nil {
                    Color.clear.frame(height: 66)
                }
            }
            // Blur the app when the full player is open (background blur, not dim)
            .blur(radius: player.isShowingNowPlaying ? 24 : 0)
            .overlay {
                Color.black
                    .opacity(player.isShowingNowPlaying ? 0.22 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // ── Mini player — hidden while full player is open ───────────────────
            if player.currentTrack != nil, !player.isShowingNowPlaying {
                MiniPlayerView(namespace: playerNS)
                    .environment(player)
                    .environment(store)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // ── Full now-playing overlay ─────────────────────────────────────────
            if player.isShowingNowPlaying {
                NowPlayingView(namespace: playerNS)
                    .environment(player)
                    .environment(store)
                    .ignoresSafeArea()
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal:   .move(edge: .bottom).combined(with: .opacity)
                        )
                    )
                    .zIndex(10)
            }
        }
        // One unified spring drives all state changes (blur, mini player, full player)
        .animation(.spring(response: 0.48, dampingFraction: 0.82), value: player.isShowingNowPlaying)
        .animation(.smooth(duration: 0.35), value: player.currentTrack?.id)
    }
}

#Preview {
    ContentView()
}
