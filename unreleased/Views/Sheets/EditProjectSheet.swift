import SwiftUI

struct EditProjectSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let project: Project

    @State private var name: String
    @State private var gradient: GradientTheme
    @State private var coverImage: UIImage?
    @State private var previewVinylGradient: GradientTheme? = nil

    init(project: Project, coverImage: UIImage? = nil) {
        self.project = project
        _name = State(initialValue: project.name)
        _gradient = State(initialValue: project.gradient)
        _coverImage = State(initialValue: coverImage)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    coverPreview
                    nameField
                    gradientSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .navigationTitle("Edit Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(8)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(8)
                }
            }
        }
        .onAppear {
            guard previewVinylGradient == nil, let coverImage else { return }
            Task.detached(priority: .userInitiated) {
                let (start, end) = ProjectAccentColor.gradientHexPair(from: coverImage)
                let g = GradientTheme(colors: [start, end], startX: 0, startY: 0, endX: 1, endY: 1)
                await MainActor.run {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        previewVinylGradient = g
                    }
                }
            }
        }
        .onChange(of: coverImage) { _, newImage in
            guard let newImage else {
                previewVinylGradient = nil
                return
            }
            Task.detached(priority: .userInitiated) {
                let (start, end) = ProjectAccentColor.gradientHexPair(from: newImage)
                let g = GradientTheme(colors: [start, end], startX: 0, startY: 0, endX: 1, endY: 1)
                await MainActor.run { previewVinylGradient = g }
            }
        }
    }

    @ViewBuilder
    private var coverPreview: some View {
        VStack(spacing: 12) {
            ProjectCoverView(gradient: gradient, coverImage: coverImage, vinylGradient: previewVinylGradient, size: 160, cornerRadius: 20, showVinyl: true)

            Button {
                withAnimation(.smooth) {
                    coverImage = nil
                    gradient = .random()
                }
            } label: {
                Label("Randomize", systemImage: "shuffle")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.scaleBordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project Name")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("untitled project", text: $name)
                .font(.system(size: 17))
                .padding(14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onSubmit { save() }
        }
    }

    @ViewBuilder
    private var gradientSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cover")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            GradientPickerView(selected: $gradient, coverImage: $coverImage)
        }
    }

    private func save() {
        var updated = project
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        updated.name = trimmed.isEmpty ? "untitled project" : trimmed
        updated.gradient = gradient
        updated.accentColorHex = store.resolvedAccentHex(gradient: gradient, coverImage: coverImage)
        updated.coverGradientColors = store.resolvedCoverGradientColors(coverImage: coverImage)

        if let coverImage {
            if updated.coverImageFileName != nil {
                store.deleteCoverImage(fileName: updated.coverImageFileName)
            }
            if let previousCloudPath = updated.coverStoragePath {
                store.deleteCoverFromCloud(storagePath: previousCloudPath)
                updated.coverStoragePath = nil
            }
            updated.coverImageFileName = store.saveCoverImage(coverImage, projectID: project.id)
        } else if updated.coverImageFileName != nil {
            store.deleteCoverImage(fileName: updated.coverImageFileName)
            updated.coverImageFileName = nil
            if let previousCloudPath = updated.coverStoragePath {
                store.deleteCoverFromCloud(storagePath: previousCloudPath)
                updated.coverStoragePath = nil
            }
        }

        store.updateProject(updated)
        if updated.coverImageFileName != nil {
            store.enqueueCoverUpload(projectID: project.id)
        }
        dismiss()
    }
}

#Preview {
    EditProjectSheet(project: Project(name: "Waves"))
        .environment(ProjectStore())
}
