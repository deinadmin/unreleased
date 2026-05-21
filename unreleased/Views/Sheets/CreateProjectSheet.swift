import SwiftUI

struct CreateProjectSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var gradient: GradientTheme = .random()
    @State private var coverImage: UIImage?
    @State private var isShowingDocumentPicker = false
    @State private var isImporting = false
    @FocusState private var nameIsFocused: Bool

    var onCreated: ((Project) -> Void)? = nil

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
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.borderless)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(8)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") { createProject() }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                        .disabled(trimmedName.isEmpty)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(8)
                }
            }
        }
        .sheet(isPresented: $isShowingDocumentPicker) {}
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    @ViewBuilder
    private var coverPreview: some View {
        VStack(spacing: 12) {
            ProjectCoverView(gradient: gradient, coverImage: coverImage, size: 160, cornerRadius: 20, showVinyl: true)
                .animation(.smooth(duration: 0.35), value: gradient)
                .animation(.smooth(duration: 0.35), value: coverImage != nil)

            Button {
                coverImage = nil
                gradient = .random()
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
                .onSubmit { createProject() }
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

    private func createProject() {
        let finalName = trimmedName.isEmpty ? "untitled project" : trimmedName
        var project = Project(name: finalName, gradient: gradient)
        project.accentColorHex = store.resolvedAccentHex(gradient: gradient, coverImage: coverImage)
        if let coverImage, let fileName = store.saveCoverImage(coverImage, projectID: project.id) {
            project.coverImageFileName = fileName
        }
        store.addProject(project)
        if project.coverImageFileName != nil {
            store.enqueueCoverUpload(projectID: project.id)
        }
        onCreated?(project)
        dismiss()
    }
}

#Preview {
    CreateProjectSheet()
        .environment(ProjectStore())
}
