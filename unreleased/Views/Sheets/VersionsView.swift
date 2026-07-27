import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct VersionsView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AudioPlayer.self) private var player

    let track: Track
    let project: Project
    var onBack: () -> Void

    @State private var previewPlayer = VersionPreviewPlayer()
    @State private var isShowingPicker = false
    @State private var isImporting = false
    @State private var loadingVersionID: UUID?
    @State private var importError: String?
    @State private var isRenamingVersion = false
    @State private var renamingVersionID: UUID?
    @State private var versionName = ""
    @State private var initialActiveVersionID: UUID?
    @State private var mainWasPlayingAtEntry = false
    @State private var draggingVersionID: UUID?
    @State private var lastDragTargetID: UUID?
    @State private var reorderFeedbackTrigger = 0

    private var liveProject: Project {
        store.projects.first(where: { $0.id == project.id }) ?? project
    }

    private var liveTrack: Track {
        liveProject.tracks.first(where: { $0.id == track.id }) ?? track
    }

    private var visibleVersions: [TrackVersion] {
        liveTrack.visibleVersions(isShared: liveProject.isShared)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

            versionsContent
        }
        .padding(.top, 12)
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $isShowingPicker) {
            DocumentPicker(
                onPick: { urls in
                    isShowingPicker = false
                    if let url = urls.first {
                        importVersion(from: url)
                    }
                },
                onCancel: { isShowingPicker = false },
                allowsMultipleSelection: false
            )
        }
        .neutralAlert(
            "Couldn’t Add Version",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
                .tint(.primary)
        } message: {
            Text(importError ?? "")
        }
        .neutralAlert("Rename Version", isPresented: $isRenamingVersion) {
            TextField("Version name", text: $versionName)
            Button("Save") {
                confirmVersionRename()
            }
            .tint(.primary)
            Button("Cancel", role: .cancel) {
                renamingVersionID = nil
            }
            .tint(.primary)
        }
        .onAppear {
            initialActiveVersionID = liveTrack.resolvedActiveVersionID
            if player.currentTrack?.id == track.id {
                mainWasPlayingAtEntry = player.isPlaying
            }
        }
        .onDisappear {
            finishPreviewSession()
        }
        .sensoryFeedback(.increase, trigger: reorderFeedbackTrigger)
    }

    private var header: some View {
        HStack {
            Text("Versions")
                .font(.system(size: 22, weight: .bold))

            Spacer(minLength: 12)

            Button(action: onBack) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
        }
    }

    private var versionsContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !liveProject.isShared {
                    addVersionButton
                }

                versionsSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
    }

    private var addVersionButton: some View {
        Button {
            requestAddVersion()
        } label: {
            HStack(spacing: 8) {
                if isImporting {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(isImporting ? "Adding version…" : "Add new version")
                    .font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.scale)
        .disabled(isImporting)
    }

    private var versionsSection: some View {
        VStack(spacing: 12) {
            LazyVStack(spacing: 12) {
                ForEach(visibleVersions) { version in
                    versionRow(for: version)
                }
            }
            .animation(
                .spring(response: 0.25, dampingFraction: 0.86),
                value: visibleVersions.map(\.id)
            )

            if !liveProject.isShared, visibleVersions.count > 1 {
                Text("Drag any version card to reorder. The top item always has the highest version number.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func versionRow(for version: TrackVersion) -> some View {
        let isOwner = !liveProject.isShared
        let isLastPublicVersion = version.isPublic
            && visibleVersions.lazy.filter(\.isPublic).count == 1

        let row = VersionRow(
            version: version,
            name: displayName(for: version),
            number: liveTrack.versionNumber(for: version.id) ?? 1,
            isSelected: liveTrack.resolvedActiveVersionID == version.id,
            isPlayingPreview: previewPlayer.currentVersionID == version.id
                && previewPlayer.isPlaying,
            isLoading: loadingVersionID == version.id,
            previewProgress: previewProgress(for: version),
            previewDuration: previewDuration(for: version),
            showsVisibilityControl: isOwner,
            canChangeVisibility: isOwner && !isLastPublicVersion,
            canDelete: isOwner && visibleVersions.count > 1,
            onSelect: { select(version) },
            onPreview: { preview(version) },
            onSeek: { seekPreview(version, to: $0) },
            onRename: { beginRenaming(version) },
            onToggleVisibility: {
                store.setVersionPublic(
                    !version.isPublic,
                    versionID: version.id,
                    trackID: track.id,
                    projectID: project.id
                )
            },
            onDelete: {
                if previewPlayer.currentVersionID == version.id {
                    previewPlayer.stop()
                }
                store.deleteVersion(version.id, from: track.id, in: project.id)
            }
        )

        if isOwner, visibleVersions.count > 1 {
            row
                .onDrag {
                    draggingVersionID = version.id
                    lastDragTargetID = nil
                    return NSItemProvider(object: version.id.uuidString as NSString)
                } preview: {
                    Color.primary
                        .opacity(0.001)
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: VersionReorderDropDelegate(
                        targetID: version.id,
                        draggingID: $draggingVersionID,
                        lastTargetID: $lastDragTargetID,
                        move: moveVersion
                    )
                )
        } else {
            row
        }
    }

    private func moveVersion(_ sourceID: UUID, onto targetID: UUID) {
        guard !liveProject.isShared,
              sourceID != targetID,
              let sourceIndex = visibleVersions.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = visibleVersions.firstIndex(where: { $0.id == targetID })
        else { return }

        let destination = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        store.moveVersion(
            for: track.id,
            in: project.id,
            from: IndexSet(integer: sourceIndex),
            to: destination
        )
        reorderFeedbackTrigger += 1
    }

    private func previewProgress(for version: TrackVersion) -> Double {
        guard previewPlayer.currentVersionID == version.id,
              previewPlayer.duration > 0
        else { return 0 }
        return min(max(previewPlayer.currentTime / previewPlayer.duration, 0), 1)
    }

    private func previewDuration(for version: TrackVersion) -> TimeInterval {
        previewPlayer.currentVersionID == version.id
            ? max(previewPlayer.duration, version.duration)
            : version.duration
    }

    private func requestAddVersion() {
        guard store.hasStorageCapacity else {
            store.presentStorageUpsell(.uploadFull)
            return
        }
        isShowingPicker = true
    }

    private func importVersion(from url: URL) {
        guard !isImporting else { return }
        isImporting = true
        Task {
            let fileSize = await store.fileSize(at: url)
            guard fileSize <= 0 || store.canStore(additionalBytes: fileSize) else {
                isImporting = false
                store.presentStorageUpsell(.uploadTooLarge(fileName: url.lastPathComponent))
                return
            }

            do {
                let imported = try await store.importAudioFile(from: url)
                store.addVersion(imported, to: track.id, in: project.id)
            } catch {
                importError = error.localizedDescription
            }
            isImporting = false
        }
    }

    private func displayName(for version: TrackVersion) -> String {
        liveTrack.versionDisplayName(for: version)
    }

    private func beginRenaming(_ version: TrackVersion) {
        renamingVersionID = version.id
        versionName = displayName(for: version)
        isRenamingVersion = true
    }

    private func confirmVersionRename() {
        guard let renamingVersionID else { return }
        let trimmedName = versionName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.renameVersion(
            renamingVersionID,
            to: trimmedName.isEmpty ? "Untitled Version" : trimmedName,
            for: track.id,
            in: project.id
        )
        self.renamingVersionID = nil
    }

    private func select(_ version: TrackVersion) {
        guard liveTrack.resolvedActiveVersionID != version.id else { return }

        let isCurrentTrack = player.currentTrack?.id == track.id
        let resumeTime = player.currentTime
        let shouldResumePlayback = player.isPlaying
            || (previewPlayer.currentVersionID != nil && mainWasPlayingAtEntry)

        previewPlayer.stop()
        loadingVersionID = nil
        store.selectVersion(version.id, for: track.id, in: project.id)

        guard isCurrentTrack,
              let updatedProject = store.projects.first(where: { $0.id == project.id }),
              let updatedTrack = updatedProject.tracks.first(where: { $0.id == track.id })
        else {
            initialActiveVersionID = version.id
            return
        }

        player.switchToVersion(
            track: updatedTrack,
            in: updatedProject,
            startingAt: min(resumeTime, updatedTrack.duration),
            shouldPlay: shouldResumePlayback
        )
        initialActiveVersionID = version.id
    }

    private func preview(_ version: TrackVersion) {
        if previewPlayer.currentVersionID == version.id {
            do {
                let url = store.audioFilesURL.appendingPathComponent(version.fileName)
                if FileManager.default.fileExists(atPath: url.path) {
                    try previewPlayer.toggle(versionID: version.id, url: url)
                    return
                }
            } catch {
                importError = error.localizedDescription
                return
            }
        }

        loadPreview(version)
    }

    private func seekPreview(_ version: TrackVersion, to progress: Double) {
        let clampedProgress = min(max(progress, 0), 1)
        if previewPlayer.currentVersionID == version.id {
            previewPlayer.seek(to: clampedProgress * previewDuration(for: version))
        } else {
            loadPreview(version, startingAt: clampedProgress)
        }
    }

    private func loadPreview(_ version: TrackVersion, startingAt progress: Double? = nil) {
        loadingVersionID = version.id
        if player.currentTrack?.id == track.id, player.isPlaying {
            player.togglePlayPause()
        }

        Task {
            let url = await store.playbackURL(for: version)
            guard loadingVersionID == version.id else { return }
            loadingVersionID = nil
            guard let url else {
                importError = "This version’s audio is not available on this device yet."
                return
            }
            do {
                try previewPlayer.toggle(versionID: version.id, url: url)
                if let progress {
                    previewPlayer.seek(to: progress * previewPlayer.duration)
                }
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func finishPreviewSession() {
        previewPlayer.stop()
        loadingVersionID = nil

        guard player.currentTrack?.id == track.id else { return }
        let resumeTime = player.currentTime
        let selectedChanged = initialActiveVersionID != liveTrack.resolvedActiveVersionID
        if selectedChanged {
            player.switchToVersion(
                track: liveTrack,
                in: liveProject,
                startingAt: min(resumeTime, liveTrack.duration),
                shouldPlay: mainWasPlayingAtEntry
            )
        } else if mainWasPlayingAtEntry, !player.isPlaying {
            player.togglePlayPause()
        }
    }
}

private struct VersionRow: View {
    let version: TrackVersion
    let name: String
    let number: Int
    let isSelected: Bool
    let isPlayingPreview: Bool
    let isLoading: Bool
    let previewProgress: Double
    let previewDuration: TimeInterval
    let showsVisibilityControl: Bool
    let canChangeVisibility: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onSeek: (Double) -> Void
    let onRename: () -> Void
    let onToggleVisibility: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    VersionBadge(number: number)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(version.formattedDuration)
                            Text("•")
                            Text(version.formattedFileSize)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityValue(isSelected ? "Selected" : "")

            previewScrubber
                .frame(minWidth: 62, idealWidth: 76, maxWidth: 88)

            Button(action: onPreview) {
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isPlayingPreview ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                    }
                }
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlayingPreview ? "Pause version \(number)" : "Preview version \(number)")

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color.accentColor.opacity(0.55)
                        : Color(.separator).opacity(0.16),
                    lineWidth: 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            if showsVisibilityControl {
                Button(action: onRename) {
                    Label("Rename Version", systemImage: "pencil")
                }
            }

            if showsVisibilityControl {
                Button(action: onToggleVisibility) {
                    Label(
                        version.isPublic ? "Hide Version" : "Show Version",
                        systemImage: version.isPublic ? "eye.slash" : "eye"
                    )
                }
                .disabled(!canChangeVisibility)
            }

            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    DestructiveMenuLabel(title: "Delete Version", systemImage: "trash")
                }
                .tint(.red)
            }
        }
        .tint(.primary)
    }

    private var previewScrubber: some View {
        ScrollingMiniWaveformView(
            trackID: version.id,
            waveformData: version.waveformData,
            progress: previewProgress,
            duration: previewDuration,
            visibleBars: 22,
            barColor: .primary,
            playheadColor: .accentColor,
            onSeek: onSeek
        )
        .frame(height: 28)
        .accessibilityLabel("Scrub version \(number)")
    }
}

private struct VersionReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggingID: UUID?
    @Binding var lastTargetID: UUID?
    let move: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingID,
              draggingID != targetID,
              lastTargetID != targetID
        else { return }

        lastTargetID = targetID
        withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
            move(draggingID, targetID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if lastTargetID == targetID {
            lastTargetID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        lastTargetID = nil
        return true
    }
}
