import FirebaseFirestore
import Foundation

enum FirestoreProjectCodec {
    static func encode(_ project: Project, ownerUsername: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "id": project.id.uuidString,
            "name": project.name,
            "gradient": encodeGradient(project.gradient),
            "tracks": project.tracks.map(encodeTrack),
            "createdDate": Timestamp(date: project.createdDate),
            "updatedDate": Timestamp(date: project.updatedDate),
        ]
        if let ownerUsername = ownerUsername ?? project.ownerUsername {
            payload["ownerUsername"] = ownerUsername
        }
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
            updatedDate: updated.dateValue(),
            ownerUsername: data["ownerUsername"] as? String
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
        if !track.versions.isEmpty {
            payload["versions"] = track.versions.map(encodeVersion)
            if let activeVersionID = track.activeVersionID {
                payload["activeVersionID"] = activeVersionID.uuidString
            }
        }
        // Waveform is analyzed once at import time and stored inline as a
        // compressed base64 string so every device can render it without
        // re-analyzing the audio stream.
        if let waveform = track.waveformData, !waveform.isEmpty,
           let encoded = WaveformCodec.encode(waveform) {
            payload["waveform"] = encoded
        }
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
        let waveform = (data["waveform"] as? String).flatMap(WaveformCodec.decode)
        let versions = (data["versions"] as? [[String: Any]] ?? []).compactMap(decodeVersion)
        let activeVersionID = (data["activeVersionID"] as? String).flatMap(UUID.init(uuidString:))

        return Track(
            id: id,
            title: title,
            fileName: fileName,
            fileSize: fileSize,
            duration: duration,
            addedDate: added.dateValue(),
            waveformData: waveform,
            storagePath: storagePath,
            isDownloaded: isDownloaded,
            notes: notes,
            versions: versions,
            activeVersionID: activeVersionID
        )
    }

    private static func encodeVersion(_ version: TrackVersion) -> [String: Any] {
        var payload: [String: Any] = [
            "id": version.id.uuidString,
            "fileName": version.fileName,
            "fileSize": version.fileSize,
            "duration": version.duration,
            "addedDate": Timestamp(date: version.addedDate),
            "isPublic": version.isPublic,
        ]
        if let name = version.name {
            payload["name"] = name
        }
        if let storagePath = version.storagePath {
            payload["storagePath"] = storagePath
        }
        if version.isDownloaded {
            payload["isDownloaded"] = true
        }
        if let waveform = version.waveformData, !waveform.isEmpty,
           let encoded = WaveformCodec.encode(waveform) {
            payload["waveform"] = encoded
        }
        return payload
    }

    private static func decodeVersion(_ data: [String: Any]) -> TrackVersion? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let fileName = data["fileName"] as? String
        else { return nil }

        let fileSize = data["fileSize"] as? Int64 ?? Int64(data["fileSize"] as? Int ?? 0)
        let duration = data["duration"] as? TimeInterval ?? (data["duration"] as? Double ?? 0)
        let addedDate = (data["addedDate"] as? Timestamp)?.dateValue() ?? Date()
        let waveform = (data["waveform"] as? String).flatMap(WaveformCodec.decode)

        return TrackVersion(
            id: id,
            name: data["name"] as? String,
            fileName: fileName,
            fileSize: fileSize,
            duration: duration,
            addedDate: addedDate,
            waveformData: waveform,
            storagePath: data["storagePath"] as? String,
            isDownloaded: data["isDownloaded"] as? Bool ?? false,
            isPublic: data["isPublic"] as? Bool ?? true
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
