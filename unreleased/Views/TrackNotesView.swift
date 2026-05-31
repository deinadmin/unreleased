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

    private var isReadOnly: Bool { project?.isShared ?? false }

    var body: some View {
        Group {
            if let track, let project {
                Group {
                    if isReadOnly {
                        notesViewer(notes: track.notes)
                    } else {
                        notesEditor
                    }
                }
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
            guard !isReadOnly else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isEditorFocused = true
            }
        }
        .onChange(of: draftNotes) { _, newValue in
            guard !isReadOnly else { return }
            scheduleSave(newValue)
        }
        .onDisappear {
            guard !isReadOnly else { return }
            saveTask?.cancel()
            store.updateTrackNotes(draftNotes, trackID: trackID, projectID: projectID)
        }
        .tint(project.map { store.accentColor(for: $0) } ?? .accentColor)
    }

    // MARK: - Read-only viewer (shared tracks)

    @ViewBuilder
    private func notesViewer(notes: String) -> some View {
        if notes.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No notes")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(notes)
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .contentMargins(.horizontal, 20, for: .scrollContent)
                    .contentMargins(.vertical, 12, for: .scrollContent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            .scrollEdgeEffectStyle(.soft, for: .vertical)
        }
    }

    // MARK: - Editable (own tracks)

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
