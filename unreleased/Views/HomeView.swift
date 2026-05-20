import SwiftUI

struct HomeView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AudioPlayer.self) private var player

    @State private var isShowingCreate = false
    @State private var isShowingDocumentPicker = false
    @State private var isImporting = false
    @State private var navigateToProjectID: UUID? = nil

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ZStack {
            if store.projects.isEmpty {
                emptyState
            } else {
                projectGrid
            }
        }
        .navigationTitle("unreleased")
        .toolbar { toolbarContent }
        .sheet(isPresented: $isShowingCreate) {
            CreateProjectSheet { project in
                navigateToProjectID = project.id
            }
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
        .navigationDestination(for: UUID.self) { id in
            ProjectDetailView(projectID: id)
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
                isShowingDocumentPicker = true
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
                ForEach(store.projects) { project in
                    NavigationLink(value: project.id) {
                        ProjectCard(project: project)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 8) {
                Button {
                    // Notifications
                } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }

                Button {
                    // Search
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }

                Button {
                    // Profile
                } label: {
                    Image(systemName: "person")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }
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
            }
        }
    }

    // MARK: - Import helpers

    private func importAndCreateProject(urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        Task {
            var tracks: [Track] = []
            for url in urls {
                if let track = try? await store.importAudioFile(from: url) {
                    tracks.append(track)
                }
            }

            let name = tracks.count == 1
                ? tracks[0].title
                : "untitled project"

            let project = Project(name: name, tracks: tracks)
            store.addProject(project)

            isImporting = false
            navigateToProjectID = project.id
        }
    }
}

// MARK: - Project Card

private struct ProjectCard: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(ProjectStore.self) private var store
    let project: Project

    @State private var playHapticTick = 0

    private var isActiveProject: Bool { player.currentProject?.id == project.id }
    private var showsPause: Bool { isActiveProject && player.isPlaying }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(project.gradient.gradient)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)

                if !project.tracks.isEmpty {
                    Button(action: playOrPause) {
                        ZStack {
                            Circle()
                                .fill(.black.opacity(0.6))
                                .frame(width: 32, height: 32)
                            Image(systemName: showsPause ? "pause.fill" : "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .animation(nil, value: showsPause)
                        }
                    }
                    .buttonStyle(.scale)
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
            let url = store.audioFileURL(for: first)
            player.play(track: first, in: project, fileURL: url)
        }
        playHapticTick &+= 1
    }
}
