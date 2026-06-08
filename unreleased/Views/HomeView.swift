import SwiftUI

private enum CreateProjectZoom {
    static let sourceID = "createProject"
}

struct HomeView: View {
    @Binding var navigationPath: NavigationPath
    var projectZoomNamespace: Namespace.ID
    @Namespace private var createProjectZoomNamespace

    @Environment(ProjectStore.self) private var store
    @Environment(AudioPlayer.self) private var player
    @Environment(AppSearchState.self) private var searchState

    @State private var isShowingCreate = false
    @State private var isShowingDocumentPicker = false
    @State private var isImporting = false

    @State private var editingProject: Project?
    @State private var projectAddingTracks: Project?
    @State private var projectPendingDelete: Project?
    @State private var isImportingToExisting = false
    @State private var showStorageLimitAlert = false
    @State private var importError: String? = nil

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    private var showsBottomChrome: Bool {
        searchState.isActive || (player.currentTrack != nil && !player.isShowingNowPlaying)
    }

    /// Extra scroll inset when the floating mini player or search bar is visible (matches project detail).
    private var scrollBottomPadding: CGFloat {
        showsBottomChrome ? 100 : 24
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
        .sheet(item: $projectAddingTracks) { project in
            DocumentPicker(
                onPick: { urls in
                    projectAddingTracks = nil
                    importTracksToExisting(urls: urls, into: project)
                },
                onCancel: { projectAddingTracks = nil }
            )
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
        .alert("Storage Full", isPresented: $showStorageLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You've used all \(store.formattedStorageLimit) of your storage. Delete some tracks to free up space.")
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
                    showStorageLimitAlert = true
                }
            } label: {
                HStack {
                    if isImporting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Add Audio")
                            .font(.system(size: 17, weight: .bold))
                    }
                }
                .frame(width: 200, height: 52)
                .background(Color.black, in: Capsule())
                .foregroundStyle(.white)
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
                        Button {
                            if store.hasStorageCapacity {
                                projectAddingTracks = project
                            } else {
                                showStorageLimitAlert = true
                            }
                        } label: {
                            Label("Add tracks", systemImage: "plus")
                        }

                        Button {
                            editingProject = project
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            projectPendingDelete = project
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, scrollBottomPadding)
        }
        .animation(.smooth(duration: 0.35), value: scrollBottomPadding)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 8) {
                NavigationLink(value: NotificationsRoute()) {
                    Image(systemName: "bell")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                        .overlay(alignment: .topTrailing) {
                            if store.unreadNotificationCount > 0 {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                                    .offset(x: -4, y: 4)
                            }
                        }
                }
                .buttonStyle(.plain)

                Button {
                    player.isShowingNowPlaying = false
                    searchState.activateOrFocus(scope: .library, placeholder: "Search your library")
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }

                NavigationLink(value: ProfileRoute()) {
                    Image(systemName: "person")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }

        if !store.projects.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isShowingCreate = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .matchedTransitionSource(
                    id: CreateProjectZoom.sourceID,
                    in: createProjectZoomNamespace
                )
            }
        }
    }

    // MARK: - Import helpers

    private func importTracksToExisting(urls: [URL], into project: Project) {
        guard !urls.isEmpty else { return }
        isImportingToExisting = true
        Task {
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                if accessing { url.stopAccessingSecurityScopedResource() }

                if fileSize > 0, fileSize > store.freeStorageBytes {
                    let name = url.deletingPathExtension().lastPathComponent
                    importError = "\"\(name)\" is too large for your remaining storage (\(store.formattedFreeStorage) free). Free up space in Settings → Storage & Sync."
                    continue
                }

                if let track = try? await store.importAudioFile(from: url) {
                    store.addTrack(track, to: project.id)
                }
            }
            isImportingToExisting = false
        }
    }

    private func importAndCreateProject(urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        Task {
            var tracks: [Track] = []
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                if accessing { url.stopAccessingSecurityScopedResource() }

                if fileSize > 0, fileSize > store.freeStorageBytes {
                    let name = url.deletingPathExtension().lastPathComponent
                    importError = "\"\(name)\" is too large for your remaining storage (\(store.formattedFreeStorage) free). Free up space in Settings → Storage & Sync."
                    continue
                }

                if let track = try? await store.importAudioFile(from: url) {
                    tracks.append(track)
                }
            }

            guard !tracks.isEmpty else {
                isImporting = false
                return
            }

            let name = tracks.count == 1
                ? tracks[0].title
                : "untitled project"

            let project = Project(name: name, tracks: tracks)
            store.addProject(project)

            isImporting = false
            navigationPath.append(project.id)
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
                                .foregroundStyle(.white)
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
