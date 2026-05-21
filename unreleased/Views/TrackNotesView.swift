import SwiftUI

struct TrackNotesView: View {
    @Environment(ProjectStore.self) private var store

    let trackID: UUID
    let projectID: UUID

    @State private var draftNotes = ""
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var isEditorFocused: Bool

    private var track: Track? {
        store.projects.first { $0.id == projectID }?
            .tracks.first { $0.id == trackID }
    }

    private var project: Project? {
        store.projects.first { $0.id == projectID }
    }

    var body: some View {
        Group {
            if let track, let project {
                notesEditor
                    .navigationTitle(track.title)
                    .navigationSubtitle(project.name)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draftNotes = track?.notes ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isEditorFocused = true
            }
        }
        .onChange(of: draftNotes) { _, newValue in
            scheduleSave(newValue)
        }
        .onDisappear {
            saveTask?.cancel()
            store.updateTrackNotes(draftNotes, trackID: trackID, projectID: projectID)
        }
        .tint(project.map { store.accentColor(for: $0) } ?? .accentColor)
    }

    private var notesEditor: some View {
        TextEditor(text: $draftNotes)
            .font(.system(size: 17))
            .foregroundStyle(.primary)
            .scrollContentBackground(.hidden)
            .focused($isEditorFocused)
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .contentMargins(.vertical, 12, for: .scrollContent)
            .scrollClipDisabled()
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scheduleSave(_ notes: String) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.updateTrackNotes(notes, trackID: trackID, projectID: projectID)
        }
    }
}

#Preview {
    NavigationStack {
        TrackNotesView(trackID: UUID(), projectID: UUID())
    }
    .environment(ProjectStore())
}
