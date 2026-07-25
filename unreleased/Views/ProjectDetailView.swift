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

    private var projectTint: Color {
        guard let project else { return Color("AccentColor") }
        return store.accentColor(for: project)
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
        .neutralAlert(
            project?.isShared == true ? "Leave Project?" : "Delete Project?",
            isPresented: $showDeleteConfirm,
            presenting: project
        ) { project in
            Button(project.isShared ? "Leave" : "Delete", role: .destructive) {
                confirmDeleteProject()
            }
            Button("Cancel", role: .cancel) {}
                .tint(.primary)
        } message: { project in
            if project.isShared {
                Text("This will remove the project from your library on every device.")
            } else {
                Text("This will permanently delete the project and all of its tracks.")
            }
        }
        .neutralAlert("Import Error", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
                .tint(.primary)
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
        .tint(projectTint)
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
            .bottomChromeAwarePadding(resting: 36)
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
                        .overlay(alignment: .bottomLeading) {
                            if index < tracks.count - 1 {
                                Divider()
                                    .padding(.leading, 20 + 28 + 12)
                            }
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
                    Group {
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
                            if project.isShared {
                                Label {
                                    Text("Leave Project")
                                } icon: {
                                    RedProjectDetailLeaveMenuIcon()
                                }
                            } else {
                                Label {
                                    Text("Delete")
                                } icon: {
                                    RedProjectDetailTrashMenuIcon()
                                }
                            }
                        }
                        .tint(project.isShared ? .primary : .red)
                    }
                    .tint(.primary)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .tint(.primary)
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

private struct RedProjectDetailTrashMenuIcon: View {
    var body: some View {
        if let image = UIImage(systemName: "trash")?
            .withTintColor(.systemRed, renderingMode: .alwaysOriginal) {
            Image(uiImage: image)
        }
    }
}

private struct RedProjectDetailLeaveMenuIcon: View {
    var body: some View {
        if let image = UIImage(systemName: "person.fill.xmark")?
            .withTintColor(.systemRed, renderingMode: .alwaysOriginal) {
            Image(uiImage: image)
        }
    }
}

private struct ProjectDetailHeaderSection: View, Equatable {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
    @ScaledMetric(relativeTo: .body) private var actionSpacing = 12.0

    /// Fixed cover size for the centered regular-width (iPad) layout.
    private static let regularCoverSize: CGFloat = 260

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.project.id == rhs.project.id
            && lhs.isPlaying == rhs.isPlaying
            && lhs.project.name == rhs.project.name
            && lhs.project.isShared == rhs.project.isShared
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
        centeredBody
        .sensoryFeedback(.increase, trigger: longPressHapticTick)
    }

    // MARK: Centered project summary

    private var centeredBody: some View {
        VStack(spacing: 0) {
            if horizontalSizeClass == .regular {
                cover(size: Self.regularCoverSize)
                    .frame(
                        width: Self.regularCoverSize * 1.375,
                        height: Self.regularCoverSize,
                        alignment: .center
                    )
            } else {
                // Total visual width when playing = size × 1.375. Keeping that
                // extent inside the container prevents the vinyl from clipping.
                GeometryReader { geometry in
                    let coverSize = geometry.size.width / 1.375
                    cover(size: coverSize)
                        .frame(
                            width: geometry.size.width,
                            height: coverSize,
                            alignment: .center
                        )
                }
                .aspectRatio(1.375, contentMode: .fit)
            }

            titleAndStats
                .padding(.top, 24)

            projectActions
                .padding(.top, 20)
        }
        .frame(maxWidth: .infinity)
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
        VStack(spacing: 4) {
            Text(project.name)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text("\(project.trackCountText) • \(project.formattedDuration) • by \(ownerLabel.isEmpty ? "…" : "@\(ownerLabel)")")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var projectActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: actionSpacing))
            : AnyLayout(HStackLayout(spacing: actionSpacing))
        let isEmptyOwnedProject = !project.isShared && project.tracks.isEmpty

        return layout {
            if !isEmptyOwnedProject {
                PlayButton(project: project)
                    .transition(.scale(scale: 0.72, anchor: .trailing).combined(with: .opacity))
                ProjectDownloadButton(project: project, downloadState: downloadState)
                    .transition(.scale(scale: 0.72, anchor: .trailing).combined(with: .opacity))
            }

            if !project.isShared {
                if let onAddTracks {
                    AddTracksCircleButton(
                        isImporting: isImporting,
                        showsFirstTrackLabel: isEmptyOwnedProject,
                        action: onAddTracks
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project actions")
        .animation(
            .spring(response: 0.42, dampingFraction: 0.82),
            value: isEmptyOwnedProject
        )
    }
}

// MARK: - Add tracks button

private struct AddTracksCircleButton: View {
    var isImporting: Bool
    var showsFirstTrackLabel: Bool
    var action: () -> Void

    @ScaledMetric(relativeTo: .body) private var controlDiameter = 48.0
    @ScaledMetric(relativeTo: .body) private var horizontalPadding = 20.0
    @ScaledMetric(relativeTo: .body) private var labelSpacing = 8.0
    @ScaledMetric(relativeTo: .body) private var spinnerDiameter = 18.0

    var body: some View {
        Button(action: action) {
            HStack(spacing: labelSpacing) {
                if isImporting {
                    TwoToneCircleSpinner(
                        diameter: spinnerDiameter,
                        lineWidth: max(1.5, spinnerDiameter * 0.11)
                    )
                } else {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                }

                if showsFirstTrackLabel {
                    Text(isImporting ? "Importing…" : "Add your first track")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(.horizontal, showsFirstTrackLabel ? horizontalPadding : 0)
            .frame(
                minWidth: max(44, controlDiameter),
                minHeight: max(44, controlDiameter)
            )
            .frame(height: max(44, controlDiameter))
            .background {
                SecondaryActionButtonBackground()
            }
            .foregroundStyle(.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(ProjectActionButtonStyle())
        .disabled(isImporting)
        .accessibilityLabel(
            isImporting
                ? "Importing tracks"
                : (showsFirstTrackLabel ? "Add your first track" : "Add tracks")
        )
        .animation(
            .spring(response: 0.42, dampingFraction: 0.82),
            value: showsFirstTrackLabel
        )
    }
}

// MARK: - Project download button

private struct ProjectDownloadButton: View {
    @Environment(ProjectStore.self) private var store

    let project: Project
    let downloadState: ProjectHeaderDownloadState

    @State private var showRemoveDownloadConfirm = false
    @State private var showCancelDownloadConfirm = false
    @ScaledMetric(relativeTo: .body) private var controlDiameter = 48.0
    @ScaledMetric(relativeTo: .body) private var symbolPointSize = 19.0

    private var canDownload: Bool {
        !project.tracks.isEmpty
            && (downloadState.isDownloading
                || downloadState.isFullyDownloaded
                || downloadState.hasPendingDownloads)
    }

    var body: some View {
        Button(action: tap) {
            ZStack {
                SecondaryActionButtonBackground()

                DownloadCircleIndicator(
                    symbolPointSize: symbolPointSize,
                    isDownloading: downloadState.isDownloading,
                    isFilled: downloadState.isFullyDownloaded
                )
            }
            .frame(
                width: max(44, controlDiameter),
                height: max(44, controlDiameter)
            )
            .contentShape(Circle())
        }
        .buttonStyle(ProjectActionButtonStyle())
        .disabled(!canDownload)
        .opacity(canDownload ? 1 : 0.45)
        .accessibilityLabel(downloadAccessibilityLabel)
        .accessibilityHint(downloadState.isDownloading ? "Shows a confirmation to cancel the download" : "")
        .neutralAlert("Cancel Download?", isPresented: $showCancelDownloadConfirm) {
            Button("Cancel Download", role: .destructive) {
                store.cancelProjectDownload(project.id)
            }
            Button("Keep Downloading", role: .cancel) {}
                .tint(.primary)
        } message: {
            Text("The download will stop and all downloaded tracks from this project will be removed from your device.")
        }
        .neutralAlert("Remove Downloads?", isPresented: $showRemoveDownloadConfirm) {
            Button("Remove", role: .destructive) {
                store.removeProjectDownloads(project.id)
            }
            Button("Cancel", role: .cancel) {}
                .tint(.primary)
        } message: {
            Text("All offline copies for this project will be deleted from your device.")
        }
    }

    private var downloadAccessibilityLabel: String {
        if downloadState.isDownloading { return "Downloading project" }
        if downloadState.isFullyDownloaded { return "Remove project downloads" }
        return "Download project"
    }

    private func tap() {
        if downloadState.isDownloading {
            showCancelDownloadConfirm = true
        } else if downloadState.isFullyDownloaded {
            showRemoveDownloadConfirm = true
        } else {
            store.downloadProject(project.id)
        }
    }
}

private struct SecondaryActionButtonBackground: View {
    var body: some View {
        Capsule()
            .fill(Color(.secondarySystemBackground))
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            }
    }
}

private struct ProjectActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(
                .spring(response: 0.2, dampingFraction: 0.78),
                value: configuration.isPressed
            )
    }
}

// MARK: - Play Button

private struct PlayButton: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(ProjectStore.self) private var store

    let project: Project

    @ScaledMetric(relativeTo: .body) private var controlHeight = 48.0
    @ScaledMetric(relativeTo: .body) private var horizontalPadding = 24.0
    @ScaledMetric(relativeTo: .body) private var labelSpacing = 8.0

    private var isActiveProject: Bool {
        player.currentProject?.id == project.id
    }

    private var buttonFill: Color { store.accentColor(for: project) }
    private var buttonFillHex: String { store.accentHex(for: project) }

    var body: some View {
        Button {
            playOrPause()
        } label: {
            HStack(spacing: labelSpacing) {
                Image(systemName: isActiveProject && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.bold))
                    .coverControlContrast(
                        for: nil,
                        backgroundHex: buttonFillHex
                    )
                    .animation(nil, value: player.isPlaying)

                Text(isActiveProject && player.isPlaying ? "Pause" : "Play")
                    .font(.subheadline.weight(.bold))
                    .coverControlContrast(
                        for: nil,
                        backgroundHex: buttonFillHex
                    )
            }
            .padding(.horizontal, horizontalPadding)
            .frame(height: max(44, controlHeight))
            .background(buttonFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(ProjectActionButtonStyle())
        .disabled(project.tracks.isEmpty)
        .opacity(project.tracks.isEmpty ? 0.45 : 1)
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
    @Environment(PlayerToastCenter.self) private var toastCenter

    let track: Track
    let index: Int
    let project: Project
    let accentColor: Color
    let onShowInfo: () -> Void

    @State private var playHapticTick = 0
    @State private var queueThresholdHapticTick = 0
    @State private var queueCompletionHapticTick = 0
    @State private var horizontalOffset: CGFloat = 0
    @State private var isQueueArmed = false
    @State private var isSuppressingTap = false
    @State private var tapSuppressionGeneration = 0

    private static let queueActivationDistance: CGFloat = 84
    private static let minimumProjectedCommitDistance: CGFloat = 44
    private static let maximumDirectReveal: CGFloat = 108
    private static let actionBackgroundWidth: CGFloat = 200

    private var isActive: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        ZStack(alignment: .leading) {
            queueActionBackground
            rowContent
                .background(Color(uiColor: .systemBackground))
                .offset(x: horizontalOffset)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .clipped()
        .gesture(queuePanGesture)
        .sensoryFeedback(.impact(weight: .medium), trigger: playHapticTick)
        .sensoryFeedback(.selection, trigger: queueThresholdHapticTick)
        .sensoryFeedback(.success, trigger: queueCompletionHapticTick)
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            Button {
                playTrack()
            } label: {
                HStack(spacing: 12) {
                    trackNumber
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(track.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(isActive ? accentColor : .primary)
                                .lineLimit(1)

                            if track.hasMultipleVersions,
                               let versionNumber = track.activeVersionNumber {
                                VersionBadge(number: versionNumber)
                            }
                        }

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
            .accessibilityAction(named: "Add to queue") {
                queueTrack()
            }

            Button(action: showInfo) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Track info")
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var queueActionBackground: some View {
        Color(uiColor: .systemBackground)
            .overlay(alignment: .leading) {
                accentColor
                    .frame(width: Self.actionBackgroundWidth)
                    .overlay(alignment: .leading) {
                        ZStack {
                            Circle()
                                .fill(.white.opacity(isQueueArmed ? 1 : 0.18))

                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(isQueueArmed ? accentColor : .white)
                        }
                        .frame(width: 42, height: 42)
                        .scaleEffect(queueActionScale)
                        .opacity(queueRevealProgress)
                        .offset(x: 10 - (1 - queueRevealProgress) * 8)
                        .animation(
                            .spring(response: 0.22, dampingFraction: 0.72),
                            value: isQueueArmed
                        )
                    }
            }
            .accessibilityHidden(true)
    }

    private var queueRevealProgress: CGFloat {
        min(max(horizontalOffset / Self.queueActivationDistance, 0), 1)
    }

    private var queueActionScale: CGFloat {
        let revealScale = 0.72 + (0.28 * queueRevealProgress)
        return isQueueArmed ? revealScale * 1.1 : revealScale
    }

    private var queuePanGesture: HorizontalPanGesture {
        HorizontalPanGesture(
            onChanged: handleDragChanged,
            onEnded: handleDragEnded,
            onCancelled: handleDragCancelled
        )
    }

    private func playTrack() {
        guard !isSuppressingTap else { return }
        playHapticTick &+= 1
        player.play(track: track, in: project)
    }

    private func showInfo() {
        guard !isSuppressingTap else { return }
        onShowInfo()
    }

    private func queueTrack() {
        player.addToQueue(track, in: project)
        toastCenter.showTrackQueued()
        queueCompletionHapticTick &+= 1
    }

    private func handleDragChanged(_ translation: CGPoint) {
        tapSuppressionGeneration &+= 1
        isSuppressingTap = true

        horizontalOffset = resistedOffset(for: translation.x)
        let shouldArm = horizontalOffset >= Self.queueActivationDistance
        if shouldArm, !isQueueArmed {
            queueThresholdHapticTick &+= 1
        }
        isQueueArmed = shouldArm
    }

    private func handleDragEnded(_ translation: CGPoint, _ predictedEndTranslation: CGPoint) {
        defer {
            releaseTapSuppressionAfterGesture()
        }

        let projectedOffset = resistedOffset(for: predictedEndTranslation.x)
        let shouldQueue = isQueueArmed
            || (horizontalOffset >= Self.minimumProjectedCommitDistance
                && projectedOffset >= Self.queueActivationDistance)

        if shouldQueue {
            queueTrack()
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            horizontalOffset = 0
            isQueueArmed = false
        }
    }

    private func handleDragCancelled() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            horizontalOffset = 0
            isQueueArmed = false
        }
        releaseTapSuppressionAfterGesture()
    }

    private func releaseTapSuppressionAfterGesture() {
        let generation = tapSuppressionGeneration
        Task { @MainActor in
            // A Button's action can be delivered shortly after the pan ends. Keep
            // suppressing it through that post-gesture window so a swipe-to-queue
            // can never also become a play tap.
            try? await Task.sleep(for: .milliseconds(300))
            guard generation == tapSuppressionGeneration else { return }
            isSuppressingTap = false
        }
    }

    private func resistedOffset(for translation: CGFloat) -> CGFloat {
        if translation < 0 {
            return -rubberBandDistance(-translation, dimension: 36)
        }

        guard translation > Self.maximumDirectReveal else { return translation }
        return Self.maximumDirectReveal
            + rubberBandDistance(
                translation - Self.maximumDirectReveal,
                dimension: 64
            )
    }

    /// Mirrors UIKit-style rubber banding: movement remains responsive near zero,
    /// then approaches a finite limit as the drag continues.
    private func rubberBandDistance(_ distance: CGFloat, dimension: CGFloat) -> CGFloat {
        let normalizedDistance = distance * 0.55 / dimension
        return dimension * (1 - (1 / (normalizedDistance + 1)))
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

/// A pan recognizer that only begins for horizontal movement. Rejecting vertical
/// movement before recognition lets an enclosing vertical ScrollView own the drag.
private struct HorizontalPanGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint, CGPoint) -> Void
    let onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        let translation = recognizer.translation(in: recognizer.view)

        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view)
            let predictedEndTranslation = CGPoint(
                x: translation.x + velocity.x / 4,
                y: translation.y + velocity.y / 4
            )
            onEnded(translation, predictedEndTranslation)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return false
            }

            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.15
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
