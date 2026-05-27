import SwiftUI

struct SaveInSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AudioFileImportManager.self) private var importManager
    @Environment(PlayerToastCenter.self) private var toastCenter
    @Environment(AuthManager.self) private var auth

    let audioURL: URL
    var onBack: () -> Void
    var onSaved: () -> Void

    @State private var searchText = ""
    @State private var isShowingCreate = false
    @State private var isSaving = false

    private var ownerLabel: String {
        if let email = auth.accountLabel,
           let name = email.split(separator: "@").first,
           !name.isEmpty {
            return String(name)
        }
        return "carlowav"
    }

    private var projectList: [Project] {
        let candidates = store.projects
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
                    ForEach(projectList) { project in
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
                saveToProject(project)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center) {
            Text("Save in")
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
            saveToProject(project)
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
        .disabled(isSaving)
    }

    // MARK: - Actions

    private func saveToProject(_ project: Project) {
        isSaving = true
        Task {
            do {
                let track = try await store.importAudioFile(from: audioURL)
                store.addTrack(track, to: project.id)
                importManager.clearURL()
                onSaved()
                DispatchQueue.main.async {
                    toastCenter.showTrackAdded(to: project.name)
                    isSaving = false
                }
            } catch {
                print("SaveInSheet: Failed to import audio file — \(error)")
                DispatchQueue.main.async {
                    isSaving = false
                }
            }
        }
    }
}

#Preview {
    SaveInSheet(
        audioURL: URL(fileURLWithPath: "/tmp/test.mp3"),
        onBack: {},
        onSaved: {}
    )
    .environment(ProjectStore())
    .environment(PlayerToastCenter())
    .environment(AuthManager())
    .environment(AudioFileImportManager())
}
