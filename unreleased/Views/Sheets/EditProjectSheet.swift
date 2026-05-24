import SwiftUI

struct EditProjectSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let project: Project

    @State private var name: String = ""
    @State private var gradient: GradientTheme = GradientTheme.presets[0]
    @State private var coverImage: UIImage?
    @State private var previewVinylGradient: GradientTheme? = nil
    @FocusState private var nameIsFocused: Bool

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
            name = project.name
            gradient = project.gradient
            coverImage = store.coverImage(for: project)
            if let img = store.coverImage(for: project) {
                let (start, end) = ProjectAccentColor.gradientHexPair(from: img)
                previewVinylGradient = GradientTheme(colors: [start, end], startX: 0, startY: 0, endX: 1, endY: 1)
            }
        }
        .onChange(of: coverImage) { _, newImage in
            if let newImage {
                let (start, end) = ProjectAccentColor.gradientHexPair(from: newImage)
                previewVinylGradient = GradientTheme(colors: [start, end], startX: 0, startY: 0, endX: 1, endY: 1)
            } else {
                previewVinylGradient = nil
            }
        }
    }

    @ViewBuilder
    private var coverPreview: some View {
        VStack(spacing: 12) {
            ProjectCoverView(gradient: gradient, coverImage: coverImage, vinylGradient: previewVinylGradient, size: 160, cornerRadius: 20, showVinyl: true)
                .animation(.smooth(duration: 0.35), value: gradient)
                .animation(.smooth(duration: 0.35), value: coverImage != nil)

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
                .focused($nameIsFocused)
                .padding(14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onSubmit { save() }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                nameIsFocused = true
            }
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
