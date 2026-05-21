import SwiftUI

struct MoveTrackView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AudioPlayer.self) private var player
    @Environment(PlayerToastCenter.self) private var toastCenter
    @Environment(AuthManager.self) private var auth
    let track: Track
    let sourceProjectID: UUID
    var onBack: () -> Void
    var onMoved: () -> Void

    @State private var searchText = ""
    @State private var isShowingCreate = false

    private var ownerLabel: String {
        if let email = auth.accountLabel,
           let name = email.split(separator: "@").first,
           !name.isEmpty {
            return String(name)
        }
        return "carlowav"
    }

    private var destinationProjects: [Project] {
        let candidates = store.projects.filter { $0.id != sourceProjectID }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return candidates }
        return candidates.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)

            searchBar
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 0) {
                    createProjectRow
                    ForEach(destinationProjects) { project in
                        projectRow(project)
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .padding(.top, 12)
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $isShowingCreate) {
            CreateProjectSheet { project in
                moveTrack(to: project.id)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center) {
            Text("Move")
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

    // MARK: - Search

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            TextField("Search your library", text: $searchText)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Rows

    @ViewBuilder
    private var createProjectRow: some View {
        Button {
            isShowingCreate = true
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                Text("Create new project")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        Button {
            moveTrack(to: project.id)
        } label: {
            HStack(spacing: 14) {
                ProjectCoverThumbnail(
                    gradient: project.gradient,
                    coverImage: store.coverImage(for: project),
                    size: 48,
                    cornerRadius: 10
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(ownerLabel)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func moveTrack(to destinationProjectID: UUID) {
        let destinationName = store.projects
            .first(where: { $0.id == destinationProjectID })?
            .name ?? "project"

        store.moveTrack(track, from: sourceProjectID, to: destinationProjectID)

        if player.currentTrack?.id == track.id,
           let destination = store.projects.first(where: { $0.id == destinationProjectID }) {
            player.currentProject = destination
        }

        onMoved()
        DispatchQueue.main.async {
            toastCenter.showTrackMoved(to: destinationName)
        }
    }
}

#Preview {
    MoveTrackView(
        track: Track(title: "untitled", fileName: "a.mp3"),
        sourceProjectID: UUID(),
        onBack: {},
        onMoved: {}
    )
    .environment(ProjectStore())
    .environment(AudioPlayer(store: ProjectStore()))
    .environment(PlayerToastCenter())
    .environment(AuthManager())
}
