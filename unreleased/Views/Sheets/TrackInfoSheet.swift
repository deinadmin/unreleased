import SwiftUI
import UIKit

struct TrackInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store
    @Environment(AudioPlayer.self) private var player
    @Environment(PlayerToastCenter.self) private var toastCenter

    let track: Track
    let project: Project
    var onOpenNotes: () -> Void

    @State private var selectedDetent: PresentationDetent = .medium
    @State private var detentBeforeMove: PresentationDetent = .medium
    @State private var isShowingMove = false
    @State private var showDeleteConfirm = false
    @State private var showRemoveDownloadConfirm = false
    @State private var showRenameAlert = false
    @State private var renameText = ""

    private var isMediumDetent: Bool { selectedDetent == .medium }

    private var liveTrack: Track {
        store.projects.first { $0.id == project.id }?
            .tracks.first { $0.id == track.id } ?? track
    }

    private static let sheetFade = Animation.easeInOut(duration: 0.28)

    var body: some View {
        ZStack {
            trackInfoContent
                .opacity(isShowingMove ? 0 : 1)
                .allowsHitTesting(!isShowingMove)

            if isShowingMove {
                MoveTrackView(
                    track: track,
                    sourceProjectID: project.id,
                    onBack: { withAnimation(Self.sheetFade) { isShowingMove = false } },
                    onMoved: { dismiss() }
                )
                .transition(.opacity)
            }
        }
        .animation(Self.sheetFade, value: isShowingMove)
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationContentInteraction(isMediumDetent && !isShowingMove ? .resizes : .scrolls)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemGroupedBackground))
        .onChange(of: isShowingMove) { _, showing in
            if showing {
                detentBeforeMove = selectedDetent
                selectedDetent = .medium
            } else {
                selectedDetent = detentBeforeMove
            }
        }
        .alert("Rename", isPresented: $showRenameAlert) {
            TextField("Track name", text: $renameText)
            Button("Save") {
                confirmRename()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete Track?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                confirmDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the track from the project.")
        }
        .alert("Remove Download?", isPresented: $showRemoveDownloadConfirm) {
            Button("Remove", role: .destructive) {
                store.removeDownload(liveTrack, in: project.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The offline copy of this track will be deleted from your device.")
        }
    }

    @ViewBuilder
    private var trackInfoContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                infoCard
                primaryActionsGroup
                secondaryActionsGroup
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .scrollDisabled(isMediumDetent)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Info card

    @ViewBuilder
    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(liveTrack.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text(liveTrack.infoMetadataLine)
                if store.isDownloading(liveTrack.id) || store.isTrackDownloaded(liveTrack) {
                    TrackDownloadStatusView(track: liveTrack)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)

            WaveformView(
                trackID: liveTrack.id,
                waveformData: liveTrack.waveformData,
                progress: 1,
                barCount: 72,
                accentColor: Color(.label),
                baseColor: Color(.label)
            )
            .frame(height: 56)
            .allowsHitTesting(false)

            Text(liveTrack.fileName)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.6), lineWidth: 1)
        }
    }

    // MARK: - Action groups

    private var primaryActions: [TrackInfoAction] {
        var actions: [TrackInfoAction] = []

        if !project.isShared {
            actions.append(TrackInfoAction(title: "Rename", systemImage: "pencil") {
                renameText = liveTrack.title
                showRenameAlert = true
            })
            actions.append(TrackInfoAction(title: "Replace audio", systemImage: "waveform.badge.plus"))
        }

        actions.append(TrackInfoAction(
            title: project.isShared ? "View notes" : "Edit notes",
            systemImage: "doc.text"
        ) {
            dismiss()
            DispatchQueue.main.async { onOpenNotes() }
        })

        actions.append(TrackInfoAction(title: "Share snippet", systemImage: "play.square"))

        if store.isTrackDownloaded(liveTrack) {
            actions.append(TrackInfoAction(title: "Remove download", systemImage: "arrow.down.circle.fill") {
                showRemoveDownloadConfirm = true
            })
        } else if store.isDownloading(liveTrack.id) {
            actions.append(TrackInfoAction(title: "Downloading…", systemImage: "arrow.down.circle") {})
        } else {
            actions.append(TrackInfoAction(title: "Download", systemImage: "arrow.down.circle") {
                store.downloadTrack(liveTrack, in: project.id)
            })
        }

        actions.append(TrackInfoAction(title: "Add to queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
            player.addToQueue(liveTrack, in: project)
            dismiss()
            DispatchQueue.main.async { toastCenter.showTrackQueued() }
        })

        return actions
    }

    private var secondaryActions: [TrackInfoAction] {
        var actions: [TrackInfoAction] = [
            TrackInfoAction(title: "Export audio", systemImage: "square.and.arrow.down") {
                exportAudio()
            },
        ]

        if !project.isShared {
            actions.append(TrackInfoAction(title: "Move", systemImage: "arrow.right.square") {
                withAnimation(Self.sheetFade) { isShowingMove = true }
            })
            actions.append(TrackInfoAction(title: "Delete", systemImage: "trash", isDestructive: true) {
                showDeleteConfirm = true
            })
        }

        return actions
    }

    @ViewBuilder
    private var primaryActionsGroup: some View {
        TrackInfoActionGroup(actions: primaryActions)
    }

    @ViewBuilder
    private var secondaryActionsGroup: some View {
        TrackInfoActionGroup(actions: secondaryActions)
    }

    // MARK: - Rename

    private func confirmRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        let newTitle = trimmed.isEmpty ? "Untitled" : trimmed
        store.updateTrackTitle(newTitle, trackID: liveTrack.id, projectID: project.id)
    }

    // MARK: - Delete

    private func confirmDelete() {
        store.deleteTrack(liveTrack, from: project.id)
        if player.currentTrack?.id == liveTrack.id {
            player.stop()
        }
        dismiss()
        DispatchQueue.main.async {
            toastCenter.showTrackDeleted()
        }
    }

    // MARK: - Export

    private func exportAudio() {
        if store.hasDownloadedFile(for: liveTrack) {
            presentShareSheet(url: store.downloadedFileURL(for: liveTrack))
            return
        }

        if store.hasCachedAudio(for: liveTrack) {
            presentShareSheet(url: store.audioFileURL(for: liveTrack))
            return
        }

        guard liveTrack.storagePath != nil else { return }

        Task {
            guard let url = await store.playbackURL(for: liveTrack) else { return }
            await MainActor.run {
                presentShareSheet(url: url)
            }
        }
    }

    private func presentShareSheet(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = av.popoverPresentationController,
           let presenter = topViewController() {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        topViewController()?.present(av, animated: true)
    }

    private func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return nil }
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }
}

// MARK: - Action list

private struct TrackInfoAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    var isDestructive = false
    var handler: () -> Void = {}

    init(
        title: String,
        systemImage: String,
        isDestructive: Bool = false,
        handler: @escaping () -> Void = {}
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = isDestructive
        self.handler = handler
    }
}

private struct TrackInfoActionGroup: View {
    let actions: [TrackInfoAction]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                TrackInfoActionRow(action: action)
                if index < actions.count - 1 {
                    Divider()
                        .padding(.leading, 54)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct TrackInfoActionRow: View {
    let action: TrackInfoAction

    var body: some View {
        Button(action: action.handler) {
            HStack(spacing: 14) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(action.isDestructive ? Color.red : .primary)
                    .frame(width: 24)

                Text(action.title)
                    .font(.system(size: 16))
                    .foregroundStyle(action.isDestructive ? Color.red : .primary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Track metadata

private extension Track {
    var infoMetadataLine: String {
        var parts: [String] = []
        if duration > 0 { parts.append(compactDurationText) }
        parts.append(formattedFileSize)
        return parts.joined(separator: " • ")
    }

    var compactDurationText: String {
        guard duration > 0 else { return "--" }
        let total = Int(duration)
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

#Preview {
    let track = Track(
        title: "bad für mich",
        fileName: "bad für mich (mastered) [edited #1].wav",
        fileSize: 28_400_000,
        duration: 169,
        waveformData: (0..<120).map { i in
            let t = Float(i) / 120
            return 0.15 + 0.85 * abs(sin(t * .pi * 10))
        }
    )
    let project = Project(name: "demo", tracks: [track])
    TrackInfoSheet(track: track, project: project, onOpenNotes: {})
}
