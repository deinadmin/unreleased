import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(AudioFileImportManager.self) private var importManager
    @State private var store = ProjectStore()
    @State private var player: AudioPlayer
    @State private var navigationPath = NavigationPath()
    @Namespace private var projectZoomNamespace
    @State private var toastCenter = PlayerToastCenter()
    @State private var searchState = AppSearchState()
    @State private var showingSaveInSheet = false

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
        let player = AudioPlayer(store: store)
        store.audioPlayer = player
        _store = State(initialValue: store)
        _player = State(initialValue: player)
    }

    var body: some View {
        ZStack(alignment: .bottom) {

            // ── Main app content ─────────────────────────────────────────────────
            NavigationStack(path: $navigationPath) {
                HomeView(
                    navigationPath: $navigationPath,
                    projectZoomNamespace: projectZoomNamespace
                )
                    .navigationDestination(for: UUID.self) { projectID in
                        ProjectDetailView(
                            projectID: projectID,
                            projectZoomNamespace: projectZoomNamespace
                        )
                        .navigationTransition(
                            .zoom(sourceID: projectID, in: projectZoomNamespace)
                        )
                    }
                    .navigationDestination(for: TrackNotesRoute.self) { route in
                        TrackNotesView(trackID: route.trackID, projectID: route.projectID)
                    }
                    .navigationDestination(for: ProfileRoute.self) { _ in
                        ProfileView()
                    }
                    .navigationDestination(for: StorageSyncRoute.self) { _ in
                        StorageSyncView()
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
        .onChange(of: importManager.pendingImportToken) { _, token in
            guard token != nil else { return }
            handlePendingImport()
        }
        .onAppear {
            importManager.loadPendingImportIfNeeded()
            if importManager.pendingImportToken != nil {
                handlePendingImport()
            }
        }
        .sheet(isPresented: $showingSaveInSheet, onDismiss: { importManager.clearURL() }) {
            if let audioURL = importManager.audioURL {
                SaveInSheet(
                    audioURL: audioURL,
                    onBack: {
                        showingSaveInSheet = false
                        importManager.clearURL()
                    },
                    onSaved: {
                        showingSaveInSheet = false
                    }
                )
                .environment(store)
                .environment(toastCenter)
                .presentationDetents([.medium, .large])
            }
        }
        .ignoresSafeArea(edges: player.isShowingNowPlaying ? .bottom : [])
        // Snappier open, fast close — keyed off the destination state.
        .animation(
            .spring(
                response: player.isShowingNowPlaying ? 0.38 : 0.30,
                dampingFraction: player.isShowingNowPlaying ? 0.88 : 0.86
            ),
            value: player.isShowingNowPlaying
        )
        .animation(.smooth(duration: 0.35), value: player.currentTrack?.id)
        .task(id: auth.signedInUserID) {
            store.configureSync(userID: auth.signedInUserID)
        }
    }

    // MARK: - Import handling

    private func handlePendingImport() {
        guard !importManager.pendingItems.isEmpty else { return }
        if let projectID = importManager.destinationProjectID {
            silentlyImportAll(into: projectID)
        } else {
            showingSaveInSheet = true
        }
    }

    private func silentlyImportAll(into projectID: UUID) {
        let items = importManager.pendingItems
        Task {
            do {
                for item in items {
                    var track = try await store.importAudioFile(from: item.url)
                    if let title = item.title, !title.isEmpty {
                        track.title = title
                    }
                    store.addTrack(track, to: projectID)
                }
                let name = store.projects.first(where: { $0.id == projectID })?.name ?? "project"
                importManager.clearPending()
                toastCenter.showTrackAdded(to: name)
            } catch {
                importManager.clearDestination()
                showingSaveInSheet = true
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
