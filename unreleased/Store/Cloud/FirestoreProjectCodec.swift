import FirebaseFirestore
import Foundation

enum FirestoreProjectCodec {
    static func encode(_ project: Project) -> [String: Any] {
        var payload: [String: Any] = [
            "id": project.id.uuidString,
            "name": project.name,
            "gradient": encodeGradient(project.gradient),
            "tracks": project.tracks.map(encodeTrack),
            "createdDate": Timestamp(date: project.createdDate),
            "updatedDate": Timestamp(date: project.updatedDate),
        ]
        if let coverStoragePath = project.coverStoragePath {
            payload["coverStoragePath"] = coverStoragePath
        } else {
            payload["coverStoragePath"] = FieldValue.delete()
        }
        if let accentColorHex = project.accentColorHex {
            payload["accentColorHex"] = accentColorHex
        }
        if let coverGradientColors = project.coverGradientColors {
            payload["coverGradientColors"] = coverGradientColors
        } else {
            payload["coverGradientColors"] = FieldValue.delete()
        }
        return payload
    }

    static func decode(_ document: DocumentSnapshot) -> Project? {
        guard let data = document.data(),
              let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let name = data["name"] as? String,
              let gradientData = data["gradient"] as? [String: Any],
              let gradient = decodeGradient(gradientData),
              let created = data["createdDate"] as? Timestamp,
              let updated = data["updatedDate"] as? Timestamp
        else { return nil }

        let trackMaps = data["tracks"] as? [[String: Any]] ?? []
        let tracks = trackMaps.compactMap(decodeTrack)

        return Project(
            id: id,
            name: name,
            gradient: gradient,
            coverImageFileName: (data["coverStoragePath"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent },
            coverStoragePath: data["coverStoragePath"] as? String,
            accentColorHex: data["accentColorHex"] as? String,
            coverGradientColors: data["coverGradientColors"] as? [String],
            tracks: tracks,
            createdDate: created.dateValue(),
            updatedDate: updated.dateValue()
        )
    }

    // MARK: - Track

    private static func encodeTrack(_ track: Track) -> [String: Any] {
        var payload: [String: Any] = [
            "id": track.id.uuidString,
            "title": track.title,
            "fileName": track.fileName,
            "fileSize": track.fileSize,
            "duration": track.duration,
            "addedDate": Timestamp(date: track.addedDate),
        ]
        if let storagePath = track.storagePath {
            payload["storagePath"] = storagePath
        }
        if track.isDownloaded {
            payload["isDownloaded"] = true
        }
        if !track.notes.isEmpty {
            payload["notes"] = track.notes
        }
        // Waveform is derived from audio — analyzed locally after cache/download, not stored in Firestore.
        return payload
    }

    private static func decodeTrack(_ data: [String: Any]) -> Track? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let title = data["title"] as? String,
              let fileName = data["fileName"] as? String,
              let added = data["addedDate"] as? Timestamp
        else { return nil }

        let fileSize = data["fileSize"] as? Int64 ?? Int64(data["fileSize"] as? Int ?? 0)
        let duration = data["duration"] as? TimeInterval ?? (data["duration"] as? Double ?? 0)
        let storagePath = data["storagePath"] as? String
        let isDownloaded = data["isDownloaded"] as? Bool ?? false
        let notes = data["notes"] as? String ?? ""

        return Track(
            id: id,
            title: title,
            fileName: fileName,
            fileSize: fileSize,
            duration: duration,
            addedDate: added.dateValue(),
            waveformData: nil,
            storagePath: storagePath,
            isDownloaded: isDownloaded,
            notes: notes
        )
    }

    // MARK: - Gradient

    private static func encodeGradient(_ gradient: GradientTheme) -> [String: Any] {
        [
            "colors": gradient.colors,
            "startX": gradient.startX,
            "startY": gradient.startY,
            "endX": gradient.endX,
            "endY": gradient.endY,
        ]
    }

    private static func decodeGradient(_ data: [String: Any]) -> GradientTheme? {
        guard let colors = data["colors"] as? [String],
              let startX = data["startX"] as? Double,
              let startY = data["startY"] as? Double,
              let endX = data["endX"] as? Double,
              let endY = data["endY"] as? Double
        else { return nil }

        return GradientTheme(
            colors: colors,
            startX: startX,
            startY: startY,
            endX: endX,
            endY: endY
        )
    }
}
