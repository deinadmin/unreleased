import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(AudioFileImportManager.self) private var importManager
    @Environment(ProjectLinkRouter.self) private var linkRouter
    @State private var store = ProjectStore()
    @State private var player: AudioPlayer
    @State private var navigationPath = NavigationPath()
    @Namespace private var projectZoomNamespace
    @State private var toastCenter = PlayerToastCenter()
    @State private var searchState = AppSearchState()
    @State private var showingSaveInSheet = false
    @State private var pendingInvite: PendingInvite? = nil

    private var needsUsername: Bool {
        auth.isSignedIn && store.currentUsername == nil
    }

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
        .task(id: linkRouter.pendingProjectID) {
            guard let projectID = linkRouter.pendingProjectID,
                  let ownerID = linkRouter.pendingOwnerID
            else { return }
            await handleIncomingProjectLink(ownerID: ownerID, projectID: projectID)
        }
        // Username picker — blocks the app until the user picks a username.
        .sheet(isPresented: Binding(get: { needsUsername }, set: { _ in })) {
            UsernamePickerSheet()
                .environment(store)
                .interactiveDismissDisabled(true)
        }
        // Invite sheet — shown when a project deep link arrives from another user.
        .sheet(item: $pendingInvite) { invite in
            ProjectInviteSheet(
                ownerUID: invite.ownerUID,
                projectID: invite.projectID,
                onAccepted: {
                    await handleInviteAccepted(ownerUID: invite.ownerUID, projectID: invite.projectID)
                },
                onDeclined: {
                    pendingInvite = nil
                    linkRouter.clear()
                }
            )
            .environment(store)
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

    // MARK: - Deep link navigation

    private func handleIncomingProjectLink(ownerID: String, projectID: UUID) async {
        if ownerID == auth.signedInUserID {
            // Own project — navigate directly.
            guard store.projects.contains(where: { $0.id == projectID }) else {
                linkRouter.clear()
                return
            }
            navigateToProject(projectID)
            linkRouter.clear()
            return
        }

        // Already accepted previously — just navigate.
        if store.projects.contains(where: { $0.id == projectID }) {
            navigateToProject(projectID)
            linkRouter.clear()
            return
        }

        // New invite — show the invite sheet (requires a username first).
        pendingInvite = PendingInvite(ownerUID: ownerID, projectID: projectID)
    }

    private func handleInviteAccepted(ownerUID: String, projectID: UUID) async {
        await store.addSharedProjectByLink(ownerID: ownerUID, projectID: projectID)
        pendingInvite = nil
        linkRouter.clear()
        if store.projects.contains(where: { $0.id == projectID }) {
            navigateToProject(projectID)
        }
    }

    private func navigateToProject(_ projectID: UUID) {
        if searchState.isActive { searchState.deactivate() }
        navigationPath = NavigationPath()
        navigationPath.append(projectID)
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

// MARK: - Supporting types

private struct PendingInvite: Identifiable {
    let id = UUID()
    let ownerUID: String
    let projectID: UUID
}

#Preview {
    ContentView()
}
