import SwiftUI
import UIKit

struct ProjectDetailView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AudioPlayer.self) private var player

    let projectID: UUID

    @State private var isShowingDocumentPicker = false
    @State private var isImporting = false
    @State private var isShowingEdit = false
    @State private var importError: String? = nil
    @State private var showDeleteConfirm = false
    @State private var trackToDelete: Track? = nil
    @State private var trackForInfo: Track? = nil
    @State private var showNavTitle = false

    private var project: Project? {
        store.projects.first { $0.id == projectID }
    }

    var body: some View {
        Group {
            if let project {
                content(project: project)
            } else {
                ContentUnavailableView("Project not found", systemImage: "music.note")
            }
        }
        .navigationTitle(project?.name ?? "")
        .navigationSubtitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let project {
                toolbarContent(project: project)
            }
        }
        .sheet(isPresented: $isShowingEdit) {
            if let project { EditProjectSheet(project: project) }
        }
        .sheet(isPresented: $isShowingDocumentPicker) {
            if let project {
                DocumentPicker(
                    onPick: { urls in
                        isShowingDocumentPicker = false
                        importTracks(urls: urls, into: project)
                    },
                    onCancel: { isShowingDocumentPicker = false }
                )
            }
        }
        .sheet(item: $trackForInfo) { track in
            if let project {
                TrackInfoSheet(
                    track: track,
                    project: project,
                    onDelete: {
                        trackToDelete = track
                        trackForInfo = nil
                    }
                )
            }
        }
        .alert("Delete Track?", isPresented: .init(
            get: { trackToDelete != nil },
            set: { if !$0 { trackToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let t = trackToDelete { store.deleteTrack(t, from: projectID) }
                trackToDelete = nil
            }
            Button("Cancel", role: .cancel) { trackToDelete = nil }
        } message: {
            Text("This will remove the track from the project.")
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(project: Project) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection(project: project)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .onScrollVisibilityChange(threshold: 0.1) { visible in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showNavTitle = !visible
                        }
                    }

                trackListSection(project: project)
                    .padding(.top, 24)
            }
            .padding(.bottom, 100)
        }
    }

    // True only when this project's audio is actively playing.
    private func isThisProjectPlaying(_ project: Project) -> Bool {
        player.currentProject?.id == project.id && player.isPlaying
    }

    @ViewBuilder
    private func headerSection(project: Project) -> some View {
        VStack(spacing: 0) {
            // Total visual width when playing = size × 1.375, so:
            //   size = availableWidth / 1.375
            // This keeps the cover + vinyl within the padded container in both states.
            GeometryReader { geo in
                let coverSize = geo.size.width / 1.375
                ProjectCoverView(
                    gradient: project.gradient,
                    size: coverSize,
                    cornerRadius: 20,
                    showVinyl: true,
                    isPlaying: isThisProjectPlaying(project)
                )
                // Center the square frame inside the GeometryReader.
                .frame(width: geo.size.width, height: coverSize, alignment: .center)
            }
            // height = width / 1.375 matches the cover square height.
            .aspectRatio(1.375, contentMode: .fit)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Text("carlowav • \(project.trackCountText) • \(project.formattedDuration)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                PlayButton(project: project)
            }
            .padding(.top, 16)
        }
    }

    @ViewBuilder
    private func trackListSection(project: Project) -> some View {
        VStack(spacing: 0) {
            addTracksButton(project: project)
                .padding(.horizontal, 20)

            if !project.tracks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(project.tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(
                            track: track,
                            index: index + 1,
                            project: project,
                            onShowInfo: { trackForInfo = track }
                        )
                        .padding(.horizontal, 20)

                        if index < project.tracks.count - 1 {
                            Divider()
                                .padding(.leading, 20 + 28 + 12)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    @ViewBuilder
    private func addTracksButton(project: Project) -> some View {
        Button {
            isShowingDocumentPicker = true
        } label: {
            HStack(spacing: 8) {
                if isImporting {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(isImporting ? "Importing…" : "Add tracks")
                    .font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(.primary)
        }
        .disabled(isImporting)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(project: Project) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                ProjectCoverThumbnail(
                    gradient: project.gradient,
                    size: 28,
                    cornerRadius: 7
                )

                VStack(alignment: .leading, spacing: 0) {
                    Text(project.name)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .lineLimit(1)

                    Text("\(project.trackCountText) • \(project.formattedDuration)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(showNavTitle ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: showNavTitle)
        }

        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 8) {
                Button {
                    shareProject()
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }

                Button {
                    // search
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }

                Menu {
                    Button("Edit Project") { isShowingEdit = true }
                    if store.projectHasPendingDownloads(project) {
                        Button("Download Project") {
                            store.downloadProject(project.id)
                        }
                    }
                    if store.projectIsFullyDownloaded(project) {
                        Button("Remove Downloads") {
                            store.removeProjectDownloads(project.id)
                        }
                    }
                    Button("Delete Project", role: .destructive) { deleteProject() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }
            }
        }
    }

    // MARK: - Actions

    private func importTracks(urls: [URL], into project: Project) {
        isImporting = true
        Task {
            for url in urls {
                do {
                    let track = try await store.importAudioFile(from: url)
                    store.addTrack(track, to: project.id)
                } catch {
                    importError = error.localizedDescription
                }
            }
            isImporting = false
        }
    }

    private func shareProject() {
        guard let project else { return }
        let text = "\(project.name) — \(project.trackCountText)"
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first {
            window.rootViewController?.present(av, animated: true)
        }
    }

    private func deleteProject() {
        guard let project else { return }
        if player.currentProject?.id == project.id { player.stop() }
        store.deleteProject(project)
    }
}

// MARK: - Play Button

private struct PlayButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AudioPlayer.self) private var player
    @Environment(ProjectStore.self) private var store

    let project: Project

    private var isActiveProject: Bool {
        player.currentProject?.id == project.id
    }

    private var buttonFill: Color { colorScheme == .dark ? .white : .black }
    private var iconColor: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        Button {
            playOrPause()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(buttonFill)
                    .frame(width: 56, height: 56)
                Image(systemName: isActiveProject && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(iconColor)
                    .animation(nil, value: player.isPlaying)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
    }

    private func playOrPause() {
        if isActiveProject {
            player.togglePlayPause()
        } else if let first = project.tracks.first {
            player.play(track: first, in: project)
        }
    }
}

// MARK: - Track Row

private struct TrackRow: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(ProjectStore.self) private var store

    let track: Track
    let index: Int
    let project: Project
    let onShowInfo: () -> Void

    @State private var playHapticTick = 0

    private var isActive: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                playTrack()
            } label: {
                HStack(spacing: 12) {
                    trackNumber
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isActive ? Color.accentColor : .primary)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            TrackDownloadStatusView(track: track)
                            Text(track.formattedAddedDate)
                            Text("•")
                            Text(track.formattedFileSize)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onShowInfo) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Track info")
        }
        .padding(.vertical, 12)
        .sensoryFeedback(.impact(weight: .medium), trigger: playHapticTick)
    }

    private func playTrack() {
        playHapticTick &+= 1
        player.play(track: track, in: project)
    }

    @ViewBuilder
    private var trackNumber: some View {
        if isActive && player.isPlaying {
            PlayingBarsIndicator()
                .frame(width: 16, height: 16)
        } else {
            Text("\(index)")
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Playing bars indicator

private struct PlayingBarsIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach([0.6, 1.0, 0.75], id: \.self) { height in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: animating ? 16 * height : 4)
                    .animation(
                        .easeInOut(duration: 0.4 + height * 0.2)
                        .repeatForever(autoreverses: true)
                        .delay(height * 0.15),
                        value: animating
                    )
            }
        }
        .frame(height: 16)
        .onAppear { animating = true }
    }
}
