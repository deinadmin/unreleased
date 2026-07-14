import SwiftUI
import UIKit

struct ProjectDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store
    @Environment(AudioPlayer.self) private var player
    @Environment(PlayerToastCenter.self) private var toastCenter
    @Environment(AppSearchState.self) private var searchState
    @Environment(AuthManager.self) private var auth
    @Environment(\.navigateToTrackNotes) private var navigateToTrackNotes
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let projectID: UUID
    var projectZoomNamespace: Namespace.ID

    @State private var isShowingDocumentPicker = false
    @State private var isImporting = false
    @State private var isShowingEdit = false
    @State private var isShowingShare = false
    @State private var importError: String? = nil
    @State private var trackForInfo: Track? = nil
    @State private var showNavTitle = false
    @State private var showDeleteConfirm = false
    @State private var ownerLabel: String = ""

    private var project: Project? {
        store.projects.first { $0.id == projectID }
    }

    private func filteredTracks(for project: Project) -> [Track] {
        let query = searchState.text.trimmingCharacters(in: .whitespaces)
        guard searchState.isActive,
              searchState.scope == .project(projectID),
              !query.isEmpty
        else { return project.tracks }
        return project.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
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
            if let project {
                EditProjectSheet(project: project, coverImage: store.coverImage(for: project))
                    .navigationTransition(
                        .zoom(sourceID: project.id, in: projectZoomNamespace)
                    )
            }
        }
        .sheet(isPresented: $isShowingShare) {
            if let project {
                ProjectShareSheet(project: project)
            }
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
                    onOpenNotes: {
                        trackForInfo = nil
                        navigateToTrackNotes(track.id, project.id)
                    }
                )
            }
        }
        .alert(
            project?.isShared == true ? "Leave Project?" : "Delete Project?",
            isPresented: $showDeleteConfirm,
            presenting: project
        ) { project in
            Button(project.isShared ? "Leave" : "Delete", role: .destructive) {
                confirmDeleteProject()
            }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            if project.isShared {
                Text("This will remove the project from your library.")
            } else {
                Text("This will permanently delete the project and all of its tracks.")
            }
        }
        .alert("Import Error", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .task(id: projectID) {
            await resolveOwnerLabel()
            await resolveLinkEnabled()
        }
        .onChange(of: store.currentUsername) { _, _ in
            if project?.isShared == false {
                Task { await resolveOwnerLabel() }
            }
        }
    }

    /// Refreshes linkEnabled from the owner's preview doc and persists it on the Project.
    /// Called async after first render — the initial value already comes from the persisted model,
    /// so the toolbar renders at the correct size from frame one.
    private func resolveLinkEnabled() async {
        guard let project, project.isShared, let ownerID = project.ownerID else { return }
        let preview = await ProjectInviteService.fetchPreview(ownerUID: ownerID, projectID: project.id)
        if let enabled = preview?.linkEnabled {
            store.setLinkEnabled(enabled, forSharedProjectID: projectID)
        }
    }

    private func resolveOwnerLabel() async {
        if let ownerID = project?.ownerID {
            // Shared project — use cached username or fetch it.
            if let cached = project?.ownerUsername, !cached.isEmpty {
                ownerLabel = cached
            } else {
                ownerLabel = await UserProfileService.fetchUsername(forUID: ownerID) ?? "Unknown"
            }
        } else {
            // Own project — use current username; empty string shows "…" via the header.
            ownerLabel = store.currentUsername ?? ""
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(project: Project) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection(project: project)
                    .equatable()
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

    private func headerDownloadState(for project: Project) -> ProjectHeaderDownloadState {
        ProjectHeaderDownloadState(
            isDownloading: project.tracks.contains { store.isDownloading($0.id) },
            isFullyDownloaded: store.projectIsFullyDownloaded(project),
            hasPendingDownloads: store.projectHasPendingDownloads(project)
        )
    }

    private func headerSection(project: Project) -> ProjectDetailHeaderSection {
        ProjectDetailHeaderSection(
            project: project,
            coverImage: store.coverImage(for: project),
            vinylGradient: store.vinylGradient(for: project),
            isPlaying: isThisProjectPlaying(project),
            downloadState: headerDownloadState(for: project),
            zoomNamespace: projectZoomNamespace,
            ownerLabel: ownerLabel,
            isImporting: isImporting,
            onCoverLongPress: project.isShared ? nil : { isShowingEdit = true },
            onAddTracks: project.isShared ? nil : { requestAddTracks() }
        )
    }

    private func requestAddTracks() {
        if store.hasStorageCapacity {
            isShowingDocumentPicker = true
        } else {
            store.presentStorageUpsell(.uploadFull)
        }
    }

    @ViewBuilder
    private func trackListSection(project: Project) -> some View {
        VStack(spacing: 0) {
            // Regular width (iPad): the add-tracks button lives in the header's info column.
            if !project.isShared, horizontalSizeClass != .regular {
                AddTracksButton(isImporting: isImporting, action: requestAddTracks)
                    .padding(.horizontal, 20)
            }

            let tracks = filteredTracks(for: project)
            if searchState.isActive,
               searchState.scope == .project(projectID),
               !searchState.text.trimmingCharacters(in: .whitespaces).isEmpty,
               tracks.isEmpty {
                ContentUnavailableView.search(text: searchState.text)
                    .padding(.top, 32)
            } else if !tracks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(
                            track: track,
                            index: index + 1,
                            project: project,
                            accentColor: store.accentColor(for: project),
                            onShowInfo: { trackForInfo = track }
                        )
                        .padding(.horizontal, 20)

                        if index < tracks.count - 1 {
                            Divider()
                                .padding(.leading, 20 + 28 + 12)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(project: Project) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                ProjectCoverThumbnail(
                    gradient: project.gradient,
                    coverImage: store.coverImage(for: project),
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
                if !project.isShared || project.linkEnabled != false {
                    Button {
                        isShowingShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }

                Button {
                    player.isShowingNowPlaying = false
                    searchState.activateOrFocus(
                        scope: .project(projectID),
                        placeholder: "Search tracks"
                    )
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }

                Menu {
                    if !(project.isShared) {
                        Button {
                            if store.hasStorageCapacity {
                                isShowingDocumentPicker = true
                            } else {
                                store.presentStorageUpsell(.uploadFull)
                            }
                        } label: {
                            Label("Add tracks", systemImage: "plus")
                        }
                        .disabled(isImporting)
                        Button {
                            isShowingEdit = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(
                            project.isShared ? "Leave Project" : "Delete",
                            systemImage: project.isShared ? "person.fill.xmark" : "trash"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    // MARK: - Actions

    private func importTracks(urls: [URL], into project: Project) {
        guard !urls.isEmpty else { return }
        isImporting = true
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

                do {
                    let track = try await store.importAudioFile(from: url)
                    imported.append(track)
                } catch {
                    importError = error.localizedDescription
                }
            }
            store.addTracks(imported, to: project.id)
            isImporting = false
            toastCenter.finishImporting(id: toastID)
        }
    }

    private func confirmDeleteProject() {
        guard let project else { return }
        if player.currentProject?.id == project.id {
            player.stop()
        }
        if project.isShared {
            store.removeSharedProject(project.id)
        } else {
            store.deleteProject(project)
        }
        dismiss()
    }
}

// MARK: - Project header (isolated from search-driven list updates)

private struct ProjectHeaderDownloadState: Equatable {
    var isDownloading: Bool
    var isFullyDownloaded: Bool
    var hasPendingDownloads: Bool
}

private struct ProjectDetailHeaderSection: View, Equatable {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let project: Project
    let coverImage: UIImage?
    let vinylGradient: GradientTheme
    let isPlaying: Bool
    let downloadState: ProjectHeaderDownloadState
    let zoomNamespace: Namespace.ID
    let ownerLabel: String
    var isImporting: Bool = false
    var onCoverLongPress: (() -> Void)? = nil
    var onAddTracks: (() -> Void)? = nil

    @State private var longPressHapticTick = 0

    /// Fixed cover size for the regular-width (iPad) side-by-side layout.
    private static let regularCoverSize: CGFloat = 260

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.project.id == rhs.project.id
            && lhs.isPlaying == rhs.isPlaying
            && lhs.project.name == rhs.project.name
            && lhs.project.trackCountText == rhs.project.trackCountText
            && lhs.project.formattedDuration == rhs.project.formattedDuration
            && lhs.project.gradient == rhs.project.gradient
            && lhs.vinylGradient == rhs.vinylGradient
            && lhs.coverImage === rhs.coverImage
            && lhs.downloadState == rhs.downloadState
            && lhs.ownerLabel == rhs.ownerLabel
            && lhs.isImporting == rhs.isImporting
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularBody
            } else {
                compactBody
            }
        }
        .sensoryFeedback(.increase, trigger: longPressHapticTick)
    }

    // MARK: Compact (iPhone) — cover on top, info below

    private var compactBody: some View {
        VStack(spacing: 0) {
            // Total visual width when playing = size × 1.375, so:
            //   size = availableWidth / 1.375
            // This keeps the cover + vinyl within the padded container in both states.
            GeometryReader { geo in
                let coverSize = geo.size.width / 1.375
                cover(size: coverSize)
                    .frame(width: geo.size.width, height: coverSize, alignment: .center)
            }
            .aspectRatio(1.375, contentMode: .fit)

            HStack(alignment: .center) {
                titleAndStats

                Spacer()

                playbackButtons
            }
            .padding(.top, 16)
        }
    }

    // MARK: Regular (iPad) — cover on the left, info column on the right

    private var regularBody: some View {
        HStack(alignment: .center, spacing: 28) {
            // Reserve the cover's full visual extent (size × 1.375) so the
            // vinyl slide-out never overlaps the info column.
            cover(size: Self.regularCoverSize)
                .frame(
                    width: Self.regularCoverSize * 1.375,
                    height: Self.regularCoverSize,
                    alignment: .center
                )

            VStack(alignment: .leading, spacing: 20) {
                titleAndStats

                playbackButtons

                if let onAddTracks {
                    AddTracksButton(isImporting: isImporting, action: onAddTracks)
                        .frame(maxWidth: 280)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Shared pieces

    private func cover(size: CGFloat) -> some View {
        ProjectCoverView(
            gradient: project.gradient,
            coverImage: coverImage,
            vinylGradient: vinylGradient,
            size: size,
            cornerRadius: 20,
            showVinyl: true,
            isPlaying: isPlaying
        )
        .matchedTransitionSource(id: project.id, in: zoomNamespace)
        .onLongPressGesture(minimumDuration: 0.5) {
            longPressHapticTick &+= 1
            onCoverLongPress?()
        }
    }

    private var titleAndStats: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary)

            HStack(spacing: 4) {
                Text("\(ownerLabel.isEmpty ? "…" : "@\(ownerLabel)") • \(project.trackCountText) • \(project.formattedDuration)")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var playbackButtons: some View {
        HStack(spacing: 8) {
            ProjectDownloadButton(project: project, downloadState: downloadState)
            PlayButton(project: project)
        }
    }
}

// MARK: - Add tracks button

struct AddTracksButton: View {
    var isImporting: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
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
}

// MARK: - Project download button

private struct ProjectDownloadButton: View {
    @Environment(ProjectStore.self) private var store

    let project: Project
    let downloadState: ProjectHeaderDownloadState

    @State private var showRemoveDownloadConfirm = false

    private var isVisible: Bool {
        !project.tracks.isEmpty
            && (downloadState.isDownloading
                || downloadState.isFullyDownloaded
                || downloadState.hasPendingDownloads)
    }

    var body: some View {
        if isVisible {
            Button(action: tap) {
                DownloadCircleIndicator(
                    symbolPointSize: 22,
                    isDownloading: downloadState.isDownloading,
                    isFilled: downloadState.isFullyDownloaded
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(downloadState.isDownloading)
            .accessibilityLabel(downloadAccessibilityLabel)
            .alert("Remove Downloads?", isPresented: $showRemoveDownloadConfirm) {
                Button("Remove", role: .destructive) {
                    store.removeProjectDownloads(project.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All offline copies for this project will be deleted from your device.")
            }
        }
    }

    private var downloadAccessibilityLabel: String {
        if downloadState.isDownloading { return "Downloading project" }
        if downloadState.isFullyDownloaded { return "Remove project downloads" }
        return "Download project"
    }

    private func tap() {
        if downloadState.isFullyDownloaded {
            showRemoveDownloadConfirm = true
        } else {
            store.downloadProject(project.id)
        }
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
    let accentColor: Color
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
                            .foregroundStyle(isActive ? accentColor : .primary)
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
            PlayingBarsIndicator(accentColor: accentColor)
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
    let accentColor: Color
    @State private var animating = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach([0.6, 1.0, 0.75], id: \.self) { height in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accentColor)
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
