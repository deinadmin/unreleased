import SwiftUI

struct EditProjectSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let project: Project

    @State private var name: String = ""
    @State private var gradient: GradientTheme = GradientTheme.presets[0]
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            name = project.name
            gradient = project.gradient
        }
    }

    @ViewBuilder
    private var coverPreview: some View {
        VStack(spacing: 12) {
            ProjectCoverView(gradient: gradient, size: 160, cornerRadius: 20, showVinyl: true)
                .animation(.smooth(duration: 0.35), value: gradient)

            Button {
                withAnimation(.smooth) { gradient = .random() }
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
            Text("Cover Color")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            GradientPickerView(selected: $gradient)
        }
    }

    private func save() {
        var updated = project
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        updated.name = trimmed.isEmpty ? "untitled project" : trimmed
        updated.gradient = gradient
        store.updateProject(updated)
        dismiss()
    }
}

#Preview {
    EditProjectSheet(project: Project(name: "Waves"))
        .environment(ProjectStore())
}
