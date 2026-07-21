import SwiftUI

private enum CreateProjectZoom {
    static let sourceID = "createProject"
}

private enum ChromeZoom {
    static let notifications = "notifications"
    static let profile = "profile"
}

struct HomeView: View {
    @Binding var navigationPath: NavigationPath
    var projectZoomNamespace: Namespace.ID
    @Namespace private var createProjectZoomNamespace

    @Environment(ProjectStore.self) private var store
    @Environment(AudioPlayer.self) private var player
    @Environment(PlayerToastCenter.self) private var toastCenter
    @Environment(AppSearchState.self) private var searchState
    @Environment(AuthManager.self) private var auth
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var chromeZoomNamespace

    @State private var isShowingCreate = false
    @State private var isShowingNotifications = false
    @State private var isShowingProfile = false
    @State private var isShowingDocumentPicker = false
    @State private var isImporting = false

    @State private var editingProject: Project?
    @State private var projectAddingTracks: Project?
    @State private var projectPendingShare: Project?
    @State private var projectPendingDelete: Project?
    @State private var projectPendingLeave: Project?
    @State private var isImportingToExisting = false
    @State private var importError: String? = nil

    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }

    /// Two flexible columns on iPhone; smaller adaptive cards on iPad.
    private var columns: [GridItem] {
        if isRegularWidth {
            [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]
        } else {
            [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16),
            ]
        }
    }

    private var filteredProjects: [Project] {
        let query = searchState.text.trimmingCharacters(in: .whitespaces)
        guard searchState.isActive, searchState.scope == .library, !query.isEmpty else {
            return store.projects
        }
        return store.projects.filter { project in
            project.name.localizedCaseInsensitiveContains(query)
                || project.tracks.contains {
                    $0.title.localizedCaseInsensitiveContains(query)
                }
        }
    }

    var body: some View {
        ZStack {
            if store.projects.isEmpty {
                emptyState
            } else if searchState.isActive, searchState.scope == .library,
                      !searchState.text.trimmingCharacters(in: .whitespaces).isEmpty,
                      filteredProjects.isEmpty {
                ContentUnavailableView.search(text: searchState.text)
            } else {
                projectGrid
            }
        }
        .navigationTitle("unreleased")
        .toolbar { toolbarContent }
        .sheet(isPresented: $isShowingCreate) {
            CreateProjectSheet { project in
                navigationPath.append(project.id)
            }
            .navigationTransition(
                .zoom(sourceID: CreateProjectZoom.sourceID, in: createProjectZoomNamespace)
            )
        }
        .sheet(isPresented: $isShowingDocumentPicker) {
            DocumentPicker(
                onPick: { urls in
                    isShowingDocumentPicker = false
                    importAndCreateProject(urls: urls)
                },
                onCancel: { isShowingDocumentPicker = false }
            )
        }
        .sheet(item: $editingProject) { project in
            EditProjectSheet(project: project, coverImage: store.coverImage(for: project))
                .navigationTransition(
                    .zoom(sourceID: project.id, in: projectZoomNamespace)
                )
        }
        // iPad: notifications & profile open as zoom-transition sheets.
        .sheet(isPresented: $isShowingNotifications) {
            NavigationStack {
                NotificationsView()
                    .navigationDestination(for: ProfileRoute.self) { _ in
                        ProfileView()
                    }
            }
            .navigationTransition(
                .zoom(sourceID: ChromeZoom.notifications, in: chromeZoomNamespace)
            )
            .environment(\.appBottomChromeIsVisible, false)
        }
        .sheet(isPresented: $isShowingProfile) {
            NavigationStack {
                ProfileView()
                    .navigationDestination(for: StorageSyncRoute.self) { _ in
                        StorageSyncView()
                    }
                    .navigationDestination(for: NotificationSettingsRoute.self) { _ in
                        NotificationSettingsView()
                    }
                    .navigationDestination(for: EqualizerRoute.self) { _ in
                        EqualizerView()
                    }
                    .navigationDestination(for: AboutRoute.self) { _ in
                        AboutView()
                    }
            }
            .navigationTransition(
                .zoom(sourceID: ChromeZoom.profile, in: chromeZoomNamespace)
            )
            .environment(\.appBottomChromeIsVisible, false)
        }
        .sheet(item: $projectAddingTracks) { project in
            DocumentPicker(
                onPick: { urls in
                    projectAddingTracks = nil
                    importTracksToExisting(urls: urls, into: project)
                },
                onCancel: { projectAddingTracks = nil }
            )
        }
        .sheet(item: $projectPendingShare) { project in
            ProjectShareSheet(project: project)
        }
        .alert(
            "Delete Project?",
            isPresented: Binding(
                get: { projectPendingDelete != nil },
                set: { if !$0 { projectPendingDelete = nil } }
            ),
            presenting: projectPendingDelete
        ) { project in
            Button("Delete", role: .destructive) {
                if player.currentProject?.id == project.id { player.stop() }
                store.deleteProject(project)
                projectPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { projectPendingDelete = nil }
        } message: { _ in
            Text("This will permanently delete the project and all of its tracks.")
        }
        .alert(
            "Leave Project?",
            isPresented: Binding(
                get: { projectPendingLeave != nil },
                set: { if !$0 { projectPendingLeave = nil } }
            ),
            presenting: projectPendingLeave
        ) { project in
            Button("Leave", role: .destructive) {
                if player.currentProject?.id == project.id { player.stop() }
                store.deleteProject(project)
                projectPendingLeave = nil
            }
            Button("Cancel", role: .cancel) { projectPendingLeave = nil }
        } message: { project in
            Text("You will lose access to \(project.name) and it will be removed from your library.")
        }
        .alert("Import Error", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()

            ProjectCoverView(gradient: GradientTheme.presets[0], size: 240, cornerRadius: 28, showVinyl: true)
                .padding(.bottom, 36)

            Text("Start your first project")
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Create a home for your work-in-progress music")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 40)

            Button {
                if store.hasStorageCapacity {
                    isShowingDocumentPicker = true
                } else {
                    store.presentStorageUpsell(.uploadFull)
                }
            } label: {
                HStack {
                    if isImporting {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Text("Add Audio")
                            .font(.system(size: 17, weight: .bold))
                    }
                }
                .frame(width: 200, height: 52)
                .background(Color("AccentColor"), in: Capsule())
                .foregroundStyle(.black)
            }
            .padding(.top, 28)
            .disabled(isImporting)

            Spacer()

            Text("Learn how to import into unreleased")
                .font(.system(size: 13))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.bottom, 32)
        }
    }

    // MARK: - Project Grid

    private var projectGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(filteredProjects) { project in
                    NavigationLink(value: project.id) {
                        ProjectCard(project: project, zoomNamespace: projectZoomNamespace)
                    }
                    .contextMenu {
                        Group {
                            if project.isShared {
                                Button(role: .destructive) {
                                    projectPendingLeave = project
                                } label: {
                                    Label("Leave Project", systemImage: "person.fill.xmark")
                                }
                            } else {
                                Button {
                                    if store.hasStorageCapacity {
                                        projectAddingTracks = project
                                    } else {
                                        store.presentStorageUpsell(.uploadFull)
                                    }
                                } label: {
                                    Label("Add tracks", systemImage: "plus")
                                }

                                Button {
                                    editingProject = project
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }

                                Button {
                                    projectPendingShare = project
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }

                                Button(role: .destructive) {
                                    projectPendingDelete = project
                                    } label: {
                                        Label {
                                            Text("Delete")
                                        } icon: {
                                            RedProjectTrashMenuIcon()
                                        }
                                    }
                                    .tint(.red)
                                }
                            }
                        }
                        .tint(.primary)
                    }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .bottomChromeAwarePadding(resting: 24)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !store.projects.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isShowingCreate = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .matchedTransitionSource(
                    id: CreateProjectZoom.sourceID,
                    in: createProjectZoomNamespace
                )
            }
        }

        // First glass group: notifications + search.
        ToolbarItemGroup(placement: .topBarTrailing) {
            notificationsButton
            searchButton
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        // Second glass group: profile picture button.
        ToolbarItem(placement: .topBarTrailing) {
            profileButton
        }
        .sharedBackgroundVisibility(.hidden)
    }

    @ViewBuilder
    private var notificationsButton: some View {
        if isRegularWidth {
            Button {
                isShowingNotifications = true
            } label: {
                notificationsIcon
            }
            .matchedTransitionSource(id: ChromeZoom.notifications, in: chromeZoomNamespace)
        } else {
            NavigationLink(value: NotificationsRoute()) {
                notificationsIcon
            }
        }
    }

    private var searchButton: some View {
        Button {
            player.isShowingNowPlaying = false
            searchState.activateOrFocus(scope: .library, placeholder: "Search your library")
        } label: {
            Image(systemName: "magnifyingglass")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var profileButton: some View {
        if isRegularWidth {
            Button {
                isShowingProfile = true
            } label: {
                profileAvatar
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: ChromeZoom.profile, in: chromeZoomNamespace)
        } else {
            NavigationLink(value: ProfileRoute()) {
                profileAvatar
            }
            .buttonStyle(.plain)
        }
    }

    private var notificationsIcon: some View {
        Image(systemName: "bell")
            .overlay(alignment: .topTrailing) {
                if store.unreadNotificationCount > 0 {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .offset(x: 5, y: -5)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    /// Circular profile picture that fills its glass button edge-to-edge (no inner padding).
    @ViewBuilder
    private var profileAvatar: some View {
        // On iPad this view is a matched transition source for the profile sheet.
        // Combining a live glass effect with that source makes SwiftUI repeatedly
        // update the glass during push/pop transitions (and can stall the UI).
        if isRegularWidth {
            ToolbarProfileAvatar(size: 42)
        } else {
            ToolbarProfileAvatar(size: 42)
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }

    // MARK: - Import helpers

    private func importTracksToExisting(urls: [URL], into project: Project) {
        guard !urls.isEmpty else { return }
        isImportingToExisting = true
        let toastID = toastCenter.showImporting(fileCount: urls.count)
        Task {
            var imported: [Track] = []
            for url in urls {
                let fileSize = await store.fileSize(at: url)

                if fileSize > 0, fileSize > store.freeStorageBytes {
                    let name = url.deletingPathExtension().lastPathComponent
                    store.presentStorageUpsell(.uploadTooLarge(fileName: name))
                    continue
                }

                if let track = try? await store.importAudioFile(from: url) {
                    imported.append(track)
                }
            }
            store.addTracks(imported, to: project.id)
            isImportingToExisting = false
            toastCenter.finishImporting(id: toastID)
        }
    }

    private func importAndCreateProject(urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        let toastID = toastCenter.showImporting(fileCount: urls.count)
        Task {
            var tracks: [Track] = []
            for url in urls {
                let fileSize = await store.fileSize(at: url)

                if fileSize > 0, fileSize > store.freeStorageBytes {
                    let name = url.deletingPathExtension().lastPathComponent
                    store.presentStorageUpsell(.uploadTooLarge(fileName: name))
                    continue
                }

                if let track = try? await store.importAudioFile(from: url) {
                    tracks.append(track)
                }
            }

            guard !tracks.isEmpty else {
                isImporting = false
                toastCenter.finishImporting(id: toastID)
                return
            }

            let name = tracks.count == 1
                ? tracks[0].title
                : "untitled project"

            let project = Project(name: name, tracks: tracks)
            store.addProject(project)

            isImporting = false
            toastCenter.finishImporting(id: toastID)
            navigationPath.append(project.id)
        }
    }
}

private struct RedProjectTrashMenuIcon: View {
    var body: some View {
        if let image = UIImage(systemName: "trash")?
            .withTintColor(.systemRed, renderingMode: .alwaysOriginal) {
            Image(uiImage: image)
        }
    }
}

// MARK: - Project Card

private struct ProjectCard: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(ProjectStore.self) private var store
    let project: Project
    let zoomNamespace: Namespace.ID

    @State private var playHapticTick = 0

    private var isActiveProject: Bool { player.currentProject?.id == project.id }
    private var showsPause: Bool { isActiveProject && player.isPlaying }
    private var coverImage: UIImage? { store.coverImage(for: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let coverImage {
                        Image(uiImage: coverImage)
                            .resizable()
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .scaledToFill()
                            .clipped()
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(project.gradient.gradient)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .matchedTransitionSource(id: project.id, in: zoomNamespace)

                if !project.tracks.isEmpty {
                    Button(action: playOrPause) {
                        ZStack {
                            Image(systemName: showsPause ? "pause.fill" : "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .coverControlContrast(
                                    for: coverImage,
                                    fallbackGradient: project.gradient
                                )
                                .animation(nil, value: showsPause)
                        }
                        .frame(width: 32, height: 32)
                        .contentShape(.circle)
                    }
                    .glassEffect(.clear.interactive(), in: Circle())
                    .padding(10)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(project.trackCountText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: playHapticTick)
    }

    private func playOrPause() {
        if isActiveProject {
            player.togglePlayPause()
        } else if let first = project.tracks.first {
            player.play(track: first, in: project)
        }
        playHapticTick &+= 1
    }
}

// MARK: - Toolbar Profile Avatar

/// Circular avatar for the toolbar profile button. Renders the user's Firebase
/// photo edge-to-edge with a circular avatar placeholder fallback (no inner padding).
struct ToolbarProfileAvatar: View {
    @Environment(ProfileAvatarStore.self) private var avatarStore
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let image = avatarStore.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .contentShape(Circle())
    }

    private var placeholder: some View {
        Image(systemName: "person.fill")
            .font(.system(size: size * 0.42, weight: .medium))
    }
}
