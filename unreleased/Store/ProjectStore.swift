import Foundation
import Observation
import AVFoundation
import SwiftUI

@Observable
final class ProjectStore {
    var projects: [Project] = []

    private let dataURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("projects.json")
    }()

    var audioFilesURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("AudioFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    init() {
        load()
    }

    // MARK: - Project CRUD

    func addProject(_ project: Project) {
        projects.insert(project, at: 0)
        save()
    }

    func updateProject(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = project
        updated.updatedDate = Date()
        projects[index] = updated
        save()
    }

    func deleteProject(_ project: Project) {
        project.tracks.forEach { deleteAudioFile(fileName: $0.fileName) }
        projects.removeAll { $0.id == project.id }
        save()
    }

    // MARK: - Track CRUD

    func addTrack(_ track: Track, to projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].tracks.append(track)
        projects[index].updatedDate = Date()
        save()
    }

    func deleteTrack(_ track: Track, from projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].tracks.removeAll { $0.id == track.id }
        projects[index].updatedDate = Date()
        deleteAudioFile(fileName: track.fileName)
        save()
    }

    func moveTrack(in projectID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].tracks.move(fromOffsets: source, toOffset: destination)
        projects[index].updatedDate = Date()
        save()
    }

    // MARK: - Audio Import

    func importAudioFile(from sourceURL: URL) async throws -> Track {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.lowercased()
        let fileName = "\(UUID().uuidString).\(ext)"
        let destURL = audioFilesURL.appendingPathComponent(fileName)

        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: destURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0

        let asset = AVURLAsset(url: destURL)
        let duration: TimeInterval
        do {
            let cmDuration = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cmDuration)
        } catch {
            duration = 0
        }

        let rawTitle = sourceURL.deletingPathExtension().lastPathComponent
        let title = rawTitle.isEmpty ? "Untitled" : rawTitle

        // Analyze waveform concurrently with other imports.
        let waveform = await WaveformAnalyzer.analyze(url: destURL, targetBars: 200)

        return Track(
            title: title,
            fileName: fileName,
            fileSize: fileSize,
            duration: duration,
            waveformData: waveform.isEmpty ? nil : waveform
        )
    }

    /// Re-analyzes waveform for a track that was imported before this feature existed.
    func analyzeWaveformIfNeeded(for track: Track, in projectID: UUID) {
        guard track.waveformData == nil else { return }
        let url = audioFileURL(for: track)
        Task {
            let waveform = await WaveformAnalyzer.analyze(url: url, targetBars: 200)
            guard !waveform.isEmpty,
                  let pIdx = projects.firstIndex(where: { $0.id == projectID }),
                  let tIdx = projects[pIdx].tracks.firstIndex(where: { $0.id == track.id })
            else { return }
            projects[pIdx].tracks[tIdx].waveformData = waveform
            save()
        }
    }

    func audioFileURL(for track: Track) -> URL {
        audioFilesURL.appendingPathComponent(track.fileName)
    }

    // MARK: - Persistence

    private func deleteAudioFile(fileName: String) {
        let url = audioFilesURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: dataURL, options: .atomicWrite)
        } catch {
            print("ProjectStore: save failed — \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: dataURL.path) else { return }
        do {
            let data = try Data(contentsOf: dataURL)
            projects = try JSONDecoder().decode([Project].self, from: data)
        } catch {
            print("ProjectStore: load failed — \(error)")
        }
    }
}
