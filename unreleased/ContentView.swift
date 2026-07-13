import Combine
import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(AudioFileImportManager.self) private var importManager
    @Environment(ProjectLinkRouter.self) private var linkRouter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var store = ProjectStore()
    @State private var player: AudioPlayer
    @State private var navigationPath = NavigationPath()
    @Namespace private var projectZoomNamespace
    @State private var toastCenter = PlayerToastCenter()
    @State private var searchState = AppSearchState()
    @State private var showingSaveInSheet = false
    @State private var pendingInvite: PendingInvite? = nil
    /// Tracks the live layout height of the PlayerView so the toast can be
    /// positioned above the expanded card with the same spacing used for the mini player.
    @State private var playerViewHeight: CGFloat = 0

    private var needsUsername: Bool {
        auth.isSignedIn && store.hasCheckedUsername && store.currentUsername == nil
    }

    /// Matches `safeAreaBar` clearance above the mini player.
    private let miniPlayerReservedHeight: CGFloat = 66
    private let toastSpacingAbovePlayer: CGFloat = 10
    private let toastBottomInsetWithoutPlayer: CGFloat = 12

    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }

    private var showsMiniPlayer: Bool {
        player.currentTrack != nil && !player.isShowingNowPlaying
    }

    /// On iPad the search bar floats Spotlight-style near the top, so only the
    /// compact-width bottom search bar counts as bottom chrome.
    private var showsBottomSearchBar: Bool {
        searchState.isActive && !isRegularWidth
    }

    private var showsBottomChrome: Bool {
        showsBottomSearchBar || showsMiniPlayer
    }

    private var toastBottomInset: CGFloat {
        // When the full-screen player is open, position the toast above its top
        // edge using the measured card height (same spacing as above the mini player).
        if player.isShowingNowPlaying {
            return playerViewHeight + toastSpacingAbovePlayer
        }
        return showsBottomChrome
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
                    .navigationDestination(for: NotificationsRoute.self) { _ in
                        NotificationsView()
                    }
                    .navigationDestination(for: StorageSyncRoute.self) { _ in
                        StorageSyncView()
                    }
                    .navigationDestination(for: NotificationSettingsRoute.self) { _ in
                        NotificationSettingsView()
                    }
                    .navigationDestination(for: AboutRoute.self) { _ in
                        AboutView()
                    }
            }
            // Reserve room + native progressive blur under scroll content (iOS 26+)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if showsBottomChrome {
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

            if let toast = toastCenter.toast, !searchState.isActive {
                PlayerToastBanner(toast: toast)
                    .padding(.bottom, toastBottomInset)
                    .frame(maxWidth: .infinity)
                    .zIndex(11)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)),
                            removal: .opacity.combined(with: .offset(y: 6))
                        )
                    )
            }

            // ── Mini player or search bar ────────────────────────────────────────
            bottomChrome

            // ── Spotlight-style search (iPad) ────────────────────────────────────
            if isRegularWidth, searchState.isActive {
                spotlightSearchOverlay
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: searchState.isActive)
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
        .alert(
            "Still uploading",
            isPresented: Binding(
                get: { player.showUploadPendingAlert },
                set: { player.showUploadPendingAlert = $0 }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("“\(player.uploadPendingTrackTitle)” hasn’t finished uploading yet. It’ll be playable on this device once the upload completes.")
        }
        .sheet(
            item: Binding(
                get: { store.storageUpsell },
                set: { store.storageUpsell = $0 }
            )
        ) { context in
            StorageUpsellSheet(context: context) {
                navigationPath.append(StorageSyncRoute())
            }
            .environment(store)
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
            if auth.signedInUserID != nil {
                PushNotificationManager.shared.registerForPushNotifications()
                // Drain an invite tapped before we were ready (cold launch / pre-sign-in).
                if let pending = PushNotificationManager.shared.consumePendingProjectLink() {
                    routeProjectLink(ownerID: pending.ownerID, projectID: pending.projectID)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectInviteTapped)) { note in
            guard let ownerID = note.userInfo?[PushUserInfoKey.ownerID] as? String,
                  let projectID = note.userInfo?[PushUserInfoKey.projectID] as? String
            else { return }
            // Live tap handled now; clear the stored copy so it isn't re-routed later.
            _ = PushNotificationManager.shared.consumePendingProjectLink()
            routeProjectLink(ownerID: ownerID, projectID: projectID)
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
                preview: invite.preview,
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

    /// Forwards a notification-tapped invite into the existing deep-link flow.
    private func routeProjectLink(ownerID: String, projectID: String) {
        guard let uuid = UUID(uuidString: projectID) else { return }
        linkRouter.receive(ownerID: ownerID, projectID: uuid)
    }

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

        // New invite — preload the preview so the sheet renders fully before opening.
        let preview = await ProjectInviteService.fetchPreview(ownerUID: ownerID, projectID: projectID)
        pendingInvite = PendingInvite(ownerUID: ownerID, projectID: projectID, preview: preview)
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
        guard navigationPath.count > 0 else {
            // Already at root (e.g. after accepting an invite sheet): push directly so
            // the ProjectCard's matchedTransitionSource drives the zoom.
            navigationPath.append(projectID)
            return
        }
        // Pop back to HomeView first so the card is visible and its matchedTransitionSource
        // can anchor the zoom, then push after the pop animation has settled.
        navigationPath = NavigationPath()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            navigationPath.append(projectID)
        }
    }

    /// Spotlight-style floating search bar: centered horizontally, sitting in
    /// the middle of the upper third of the screen (iPad / regular width).
    private var spotlightSearchOverlay: some View {
        GeometryReader { geo in
            PlayerSearchBar()
                .frame(maxWidth: 560)
                .position(x: geo.size.width / 2, y: geo.size.height / 6)
        }
        .ignoresSafeArea(.keyboard)
        .zIndex(4)
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.96)),
                removal: .opacity.combined(with: .scale(scale: 0.98))
            )
        )
    }

    @ViewBuilder
    private var bottomChrome: some View {
        Group {
            if showsBottomSearchBar {
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
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { playerViewHeight = $0 }
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
    var preview: ProjectPreview? = nil
}

#Preview {
    ContentView()
}
