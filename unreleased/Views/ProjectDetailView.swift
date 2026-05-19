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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
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

                trackListSection(project: project)
                    .padding(.top, 24)
            }
            .padding(.bottom, 100)
        }
        .onAppear {
            // Lazy waveform analysis for tracks imported before the analyzer existed.
            for track in project.tracks where track.waveformData == nil {
                store.analyzeWaveformIfNeeded(for: track, in: project.id)
            }
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
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 6)
                        Text("\(project.trackCountText) • \(project.formattedDuration)")
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
                            onDelete: { trackToDelete = track }
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
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
    @Environment(AudioPlayer.self) private var player
    @Environment(ProjectStore.self) private var store

    let project: Project

    private var isActiveProject: Bool {
        player.currentProject?.id == project.id
    }

    var body: some View {
        Button {
            playOrPause()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 56, height: 56)
                Image(systemName: isActiveProject && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
    }

    private func playOrPause() {
        if isActiveProject {
            player.togglePlayPause()
        } else if let first = project.tracks.first {
            let url = store.audioFileURL(for: first)
            player.play(track: first, in: project, fileURL: url)
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
    let onDelete: () -> Void

    private var isActive: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        Button {
            let url = store.audioFileURL(for: track)
            player.play(track: track, in: project, fileURL: url)
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
                        Text(track.formattedAddedDate)
                        Text("•")
                        Text(track.formattedFileSize)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Menu {
                    Button {
                        let url = store.audioFileURL(for: track)
                        player.play(track: track, in: project, fileURL: url)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
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
