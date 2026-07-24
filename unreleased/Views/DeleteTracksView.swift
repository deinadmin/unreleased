import SwiftUI

struct DeleteTracksView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(MiniPlayerVisibility.self) private var miniPlayerVisibility

    @State private var selection = Set<OwnedTrackDeletionID>()
    @State private var sortField: TrackSortField = .size
    @State private var sortDirection: SortDirection = .descending
    @State private var showDeleteConfirmation = false

    private var ownedTracks: [OwnedTrackItem] {
        store.projects
            .filter { !$0.isShared }
            .flatMap { project in
                project.tracks.map { OwnedTrackItem(projectID: project.id, track: $0) }
            }
    }

    private var sortedTracks: [OwnedTrackItem] {
        ownedTracks.sorted(by: areInIncreasingOrder)
    }

    private var allTracksSelected: Bool {
        !ownedTracks.isEmpty && selection.count == ownedTracks.count
    }

    private var deleteButtonTitle: String {
        selection.isEmpty ? "Delete" : "Delete (\(selection.count))"
    }

    var body: some View {
        List(sortedTracks) { item in
            let isSelected = selection.contains(item.id)

            Button {
                toggleSelection(item.id)
            } label: {
                HStack(spacing: 12) {
                    TrackSelectionIndicator(isSelected: isSelected)
                    DeleteTrackRow(track: item.track)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(item.track.title), \(item.track.formattedFileSize), "
                    + item.track.addedDate.formatted(date: .abbreviated, time: .omitted)
            )
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .overlay {
            if ownedTracks.isEmpty {
                ContentUnavailableView(
                    "No Tracks to Delete",
                    systemImage: "waveform",
                    description: Text("Tracks from projects you own will appear here.")
                )
            }
        }
        .navigationTitle("Delete tracks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }

            if !ownedTracks.isEmpty {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(allTracksSelected ? "Deselect All" : "Select All") {
                        toggleSelectAll()
                    }

                    Spacer()

                    Button(deleteButtonTitle, role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
        .neutralAlert(deleteConfirmationTitle, isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: deleteSelectedTracks)
            Button("Cancel", role: .cancel) {}
                .tint(.primary)
        } message: {
            Text("The selected tracks will be permanently deleted from this device and the cloud. This can’t be undone.")
        }
        .onChange(of: ownedTracks.map(\.id)) { _, availableTrackIDs in
            selection.formIntersection(Set(availableTrackIDs))
        }
        .onAppear {
            miniPlayerVisibility.hide(for: .deleteTracks)
        }
        .onDisappear {
            miniPlayerVisibility.show(for: .deleteTracks)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortField) {
                ForEach(TrackSortField.allCases) { field in
                    Label(field.title, systemImage: field.systemImage)
                        .tag(field)
                }
            }

            Picker("Order", selection: $sortDirection) {
                Label("Ascending", systemImage: "arrow.up")
                    .tag(SortDirection.ascending)
                Label("Descending", systemImage: "arrow.down")
                    .tag(SortDirection.descending)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort tracks")
        .accessibilityValue("\(sortField.title), \(sortDirection.title)")
    }

    private var deleteConfirmationTitle: String {
        let count = selection.count
        return count == 1 ? "Delete Track?" : "Delete \(count) Tracks?"
    }

    private func toggleSelectAll() {
        if allTracksSelected {
            selection.removeAll()
        } else {
            selection = Set(ownedTracks.map(\.id))
        }
    }

    private func toggleSelection(_ id: OwnedTrackDeletionID) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
        }
    }

    private func deleteSelectedTracks() {
        store.deleteOwnedTracks(at: selection)
        selection.removeAll()
    }

    private func areInIncreasingOrder(_ lhs: OwnedTrackItem, _ rhs: OwnedTrackItem) -> Bool {
        switch sortField {
        case .size:
            if lhs.track.fileSize != rhs.track.fileSize {
                return sortDirection.isAscending
                    ? lhs.track.fileSize < rhs.track.fileSize
                    : lhs.track.fileSize > rhs.track.fileSize
            }
        case .title:
            let comparison = lhs.track.title.localizedStandardCompare(rhs.track.title)
            if comparison != .orderedSame {
                return sortDirection.isAscending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }
        case .date:
            if lhs.track.addedDate != rhs.track.addedDate {
                return sortDirection.isAscending
                    ? lhs.track.addedDate < rhs.track.addedDate
                    : lhs.track.addedDate > rhs.track.addedDate
            }
        }

        let titleComparison = lhs.track.title.localizedStandardCompare(rhs.track.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }
        if lhs.id.projectID != rhs.id.projectID {
            return lhs.id.projectID.uuidString < rhs.id.projectID.uuidString
        }
        return lhs.id.trackID.uuidString < rhs.id.trackID.uuidString
    }
}

private struct OwnedTrackItem: Identifiable {
    let projectID: UUID
    let track: Track

    var id: OwnedTrackDeletionID {
        OwnedTrackDeletionID(projectID: projectID, trackID: track.id)
    }
}

private struct DeleteTrackRow: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text("\(track.formattedFileSize) • \(track.addedDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct TrackSelectionIndicator: View {
    @Environment(\.colorScheme) private var colorScheme

    let isSelected: Bool

    private var selectedFill: Color {
        colorScheme == .dark ? .white : .accentColor
    }

    private var checkmarkColor: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? selectedFill : .clear)

            Circle()
                .strokeBorder(
                    isSelected ? selectedFill : Color.secondary.opacity(0.65),
                    lineWidth: 1.5
                )

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(checkmarkColor)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

private enum TrackSortField: String, CaseIterable, Identifiable {
    case size
    case title
    case date

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .size: "internaldrive"
        case .title: "textformat"
        case .date: "calendar"
        }
    }
}

private enum SortDirection: String {
    case ascending
    case descending

    var isAscending: Bool { self == .ascending }
    var title: String { rawValue.capitalized }
}

#Preview {
    NavigationStack {
        DeleteTracksView()
    }
    .environment(ProjectStore())
    .environment(MiniPlayerVisibility())
}
