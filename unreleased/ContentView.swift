import SwiftUI

struct ContentView: View {
    @State private var store = ProjectStore()
    @State private var player: AudioPlayer

    init() {
        let store = ProjectStore()
        _store = State(initialValue: store)
        _player = State(initialValue: AudioPlayer(store: store))
    }

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
                if player.currentTrack != nil, !player.isShowingNowPlaying {
                    Color.clear.frame(height: 66)
                }
            }
            .blur(radius: player.isShowingNowPlaying ? 24 : 0)
            .overlay {
                if player.isShowingNowPlaying {
                    Color.black
                        .opacity(0.22)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.isShowingNowPlaying = false
                        }
                }
            }

            // ── Unified morphing player (mini ↔ full) ────────────────────────────
            if player.currentTrack != nil {
                PlayerView()
                    .environment(player)
                    .environment(store)
                    .frame(maxWidth: .infinity, alignment: .bottom)
                    .zIndex(player.isShowingNowPlaying ? 10 : 1)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 18)),
                            removal: .opacity.combined(with: .offset(y: 10))
                        )
                    )
            }
        }
        .ignoresSafeArea(edges: player.isShowingNowPlaying ? .bottom : [])
        .animation(
            .spring(response: 0.44, dampingFraction: 0.84),
            value: player.currentTrack != nil
        )
        // Slower open, snappier close — keyed off the destination state.
        .animation(
            .spring(
                response: player.isShowingNowPlaying ? 0.48 : 0.30,
                dampingFraction: player.isShowingNowPlaying ? 0.82 : 0.86
            ),
            value: player.isShowingNowPlaying
        )
        .animation(.smooth(duration: 0.35), value: player.currentTrack?.id)
    }
}

#Preview {
    ContentView()
}
