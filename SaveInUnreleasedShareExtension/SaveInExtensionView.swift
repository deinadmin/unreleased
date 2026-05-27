import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root view

struct SaveInExtensionView: View {
    let providers: [NSItemProvider]
    var onComplete: () -> Void

    @State private var projects: [AudioImportBridge.ProjectMirror] = []
    @State private var searchText = ""
    @State private var loadedFiles: [(url: URL, title: String)] = []
    @State private var isLoadingFiles = true
    @State private var isSaving = false

    private var filteredProjects: [AudioImportBridge.ProjectMirror] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var fileCountLabel: String {
        switch loadedFiles.count {
        case 0: return ""
        case 1: return loadedFiles[0].title
        default: return "\(loadedFiles.count) audio files"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, fileCountLabel.isEmpty ? 16 : 4)

            if !fileCountLabel.isEmpty {
                Text(fileCountLabel)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }

            searchBar
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            if isLoadingFiles {
                Spacer()
                ProgressView()
                    .tint(.secondary)
                Spacer()
            } else if projects.isEmpty {
                Spacer()
                Text("No projects yet")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filteredProjects) { project in
                            projectRow(project)
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .padding(.top, 12)
        .background(Color(.systemGroupedBackground))
        .task { await loadAllAudioFiles() }
        .onAppear { projects = AudioImportBridge.readProjectMirrors() }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center) {
            Text("Save in")
                .font(.system(size: 22, weight: .bold))

            Spacer(minLength: 12)

            Button(action: onComplete) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
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
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    // MARK: - Project row

    @ViewBuilder
    private func projectRow(_ project: AudioImportBridge.ProjectMirror) -> some View {
        Button {
            saveToProject(project)
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(project.linearGradient)
                    .frame(width: 48, height: 48)

                Text(project.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isSaving {
                    ProgressView()
                        .tint(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving || isLoadingFiles || loadedFiles.isEmpty)
    }

    // MARK: - File loading

    private static let audioTypeIdentifiers: [String] = [
        UTType.audio.identifier,
        UTType.mp3.identifier,
        UTType.mpeg4Audio.identifier,
        UTType.aiff.identifier,
        UTType.wav.identifier,
        "com.apple.coreaudio-format",
        "org.xiph.flac",
        "public.aac-audio",
    ]

    private func loadAllAudioFiles() async {
        isLoadingFiles = true
        var collected: [(url: URL, title: String)] = []

        for provider in providers {
            for typeID in Self.audioTypeIdentifiers
                where provider.hasItemConformingToTypeIdentifier(typeID)
            {
                if let result = await copyToTemp(provider: provider, typeIdentifier: typeID) {
                    collected.append(result)
                    break // one file per provider
                }
            }
        }

        loadedFiles = collected
        isLoadingFiles = false
    }

    private func copyToTemp(
        provider: NSItemProvider,
        typeIdentifier: String
    ) async -> (url: URL, title: String)? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let title = url.deletingPathExtension().lastPathComponent
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).\(url.pathExtension)")
                do {
                    if FileManager.default.fileExists(atPath: tmp.path) {
                        try FileManager.default.removeItem(at: tmp)
                    }
                    try FileManager.default.copyItem(at: url, to: tmp)
                    continuation.resume(returning: (tmp, title))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Save

    private func saveToProject(_ project: AudioImportBridge.ProjectMirror) {
        guard !loadedFiles.isEmpty, !isSaving else { return }
        isSaving = true
        let files = loadedFiles
        Task {
            do {
                try AudioImportBridge.stageImportedFiles(
                    files.map { (url: $0.url, title: $0.title) },
                    destinationProjectID: project.id
                )
                onComplete()
            } catch {
                isSaving = false
            }
        }
    }
}

// MARK: - Gradient helper

private extension AudioImportBridge.ProjectMirror {
    var linearGradient: LinearGradient {
        LinearGradient(
            colors: gradientColors.map { Color(hexString: $0) },
            startPoint: UnitPoint(x: gradientStartX, y: gradientStartY),
            endPoint: UnitPoint(x: gradientEndX, y: gradientEndY)
        )
    }
}

private extension Color {
    init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3: (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: (r, g, b) = (0, 0, 0)
        }
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}
