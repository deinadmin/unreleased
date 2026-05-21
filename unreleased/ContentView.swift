import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ProjectStore()
    @State private var player: AudioPlayer
    @State private var navigationPath = NavigationPath()
    @State private var toastCenter = PlayerToastCenter()
    @State private var searchState = AppSearchState()
    @State private var wasInBackground = false

    /// Matches `safeAreaBar` clearance above the mini player.
    private let miniPlayerReservedHeight: CGFloat = 66
    private let toastSpacingAbovePlayer: CGFloat = 10
    private let toastBottomInsetWithoutPlayer: CGFloat = 12

    private var showsMiniPlayer: Bool {
        player.currentTrack != nil && !player.isShowingNowPlaying
    }

    private var showsBottomChrome: Bool {
        searchState.isActive || showsMiniPlayer
    }

    private var toastBottomInset: CGFloat {
        showsBottomChrome
            ? miniPlayerReservedHeight + toastSpacingAbovePlayer
            : toastBottomInsetWithoutPlayer
    }

    init() {
        let store = ProjectStore()
        _store = State(initialValue: store)
        _player = State(initialValue: AudioPlayer(store: store))
    }

    var body: some View {
        ZStack(alignment: .bottom) {

            // ── Main app content ─────────────────────────────────────────────────
            NavigationStack(path: $navigationPath) {
                HomeView()
                    .navigationDestination(for: UUID.self) { projectID in
                        ProjectDetailView(projectID: projectID)
                    }
                    .navigationDestination(for: TrackNotesRoute.self) { route in
                        TrackNotesView(trackID: route.trackID, projectID: route.projectID)
                    }
                    .navigationDestination(for: ProfileRoute.self) { _ in
                        ProfileView()
                    }
            }
            // Reserve room + native progressive blur under scroll content (iOS 26+)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if searchState.isActive || (player.currentTrack != nil && !player.isShowingNowPlaying) {
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

            if let toast = toastCenter.toast, !player.isShowingNowPlaying, !searchState.isActive {
                PlayerToastBanner(toast: toast)
                    .padding(.bottom, toastBottomInset)
                    .frame(maxWidth: .infinity)
                    .zIndex(2)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)),
                            removal: .opacity.combined(with: .offset(y: 6))
                        )
                    )
            }

            // ── Mini player or search bar ────────────────────────────────────────
            bottomChrome
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: toastCenter.toast)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: toastBottomInset)
        .environment(store)
        .environment(player)
        .environment(toastCenter)
        .environment(searchState)
        .environment(\.navigateToTrackNotes) { trackID, projectID in
            if searchState.isActive {
                searchState.deactivate()
            }
            navigationPath.append(TrackNotesRoute(trackID: trackID, projectID: projectID))
        }
        .onChange(of: navigationPath.count) { _, _ in
            if searchState.isActive {
                searchState.deactivate()
            }
        }
        .ignoresSafeArea(edges: player.isShowingNowPlaying ? .bottom : [])
        // Slower open, snappier close — keyed off the destination state.
        .animation(
            .spring(
                response: player.isShowingNowPlaying ? 0.48 : 0.30,
                dampingFraction: player.isShowingNowPlaying ? 0.82 : 0.86
            ),
            value: player.isShowingNowPlaying
        )
        .animation(.smooth(duration: 0.35), value: player.currentTrack?.id)
        .task(id: auth.signedInUserID) {
            store.configureSync(userID: auth.signedInUserID)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                wasInBackground = true
            case .active:
                if wasInBackground, player.currentTrack != nil {
                    if searchState.isActive {
                        searchState.deactivate()
                    }
                    player.isShowingNowPlaying = true
                }
                wasInBackground = false
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var bottomChrome: some View {
        Group {
            if searchState.isActive {
                PlayerSearchBar()
                    .frame(maxWidth: .infinity, alignment: .bottom)
                    .zIndex(3)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)),
                            removal: .opacity.combined(with: .offset(y: 8))
                        )
                    )
            } else if player.currentTrack != nil {
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
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: searchState.isActive)
        .animation(.spring(response: 0.44, dampingFraction: 0.84), value: player.currentTrack != nil)
    }
}

#Preview {
    ContentView()
}
