import Foundation
import SwiftUI
import UIKit

// MARK: - Gradient Theme

struct GradientTheme: Codable, Hashable, Sendable {
    let colors: [String]
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double

    var startPoint: UnitPoint { UnitPoint(x: startX, y: startY) }
    var endPoint: UnitPoint { UnitPoint(x: endX, y: endY) }

    var swiftUIColors: [Color] { colors.map { Color(hex: $0) } }

    var gradient: LinearGradient {
        LinearGradient(colors: swiftUIColors, startPoint: startPoint, endPoint: endPoint)
    }

    static let presets: [GradientTheme] = [
        GradientTheme(colors: ["#FF6FD8", "#C46FFF"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#7EB8F0", "#8EC5FC"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#FF9A9E", "#FAD0C4"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#96FBC4", "#F9F586"], startX: 0.5, startY: 0, endX: 0.5, endY: 1),
        GradientTheme(colors: ["#667EEA", "#764BA2"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#4FACFE", "#00F2FE"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#FFD200", "#F7971E"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#F953C6", "#B91D73"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#A18CD1", "#FBC2EB"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#11998E", "#38EF7D"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#2980B9", "#8E44AD"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#FFECD2", "#FCB69F"], startX: 0, startY: 1, endX: 1, endY: 0),
        GradientTheme(colors: ["#D4FC79", "#96E6A1"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#E0C3FC", "#8EC5FC"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#F77062", "#FE5196"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#43E97B", "#38F9D7"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#FA709A", "#FEE140"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#30CFD0", "#330867"], startX: 0, startY: 0, endX: 1, endY: 1),
        GradientTheme(colors: ["#89F7FE", "#66A6FF"], startX: 0, startY: 0, endX: 1, endY: 1),
    ]

    static func random() -> GradientTheme {
        presets.randomElement() ?? presets[0]
    }

    /// Square edge-to-edge artwork for lock screen / Control Center.
    /// No corner radius — the system applies its own mask; rounded corners leave black gaps.
    @MainActor
    func artworkImage(size: CGFloat = 600) -> UIImage? {
        let renderer = ImageRenderer(
            content: Rectangle()
                .fill(gradient)
                .frame(width: size, height: size)
        )
        renderer.scale = 2
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

// MARK: - Track

struct Track: Identifiable, Codable, Sendable {
    var id: UUID
    var title: String
    var fileName: String
    var fileSize: Int64
    var duration: TimeInterval
    var addedDate: Date
    /// Normalized amplitude values (0…1) for each waveform bar. Analyzed once at
    /// import and synced to Firestore (compressed) so every device can render it.
    var waveformData: [Float]?
    /// Cloud Storage object path (e.g. `users/{uid}/audio/{trackId}.m4a`). Nil until uploaded.
    var storagePath: String?
    /// User-pinned offline copy in Downloads (distinct from playback cache).
    var isDownloaded: Bool
    var notes: String

    init(
        id: UUID = UUID(),
        title: String,
        fileName: String,
        fileSize: Int64 = 0,
        duration: TimeInterval = 0,
        addedDate: Date = Date(),
        waveformData: [Float]? = nil,
        storagePath: String? = nil,
        isDownloaded: Bool = false,
        notes: String = ""
    ) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.fileSize = fileSize
        self.duration = duration
        self.addedDate = addedDate
        self.waveformData = waveformData
        self.storagePath = storagePath
        self.isDownloaded = isDownloaded
        self.notes = notes
    }

    var fileExtension: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "m4a" : ext
    }

    var formattedDuration: String {
        guard duration > 0 else { return "--:--" }
        let total = Int(duration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedFileSize: String {
        let bytes = Double(fileSize)
        if bytes < 1_000 { return "\(Int(bytes)) B" }
        if bytes < 1_000_000 { return String(format: "%.0f KB", bytes / 1_000) }
        return String(format: "%.1f MB", bytes / 1_000_000)
    }

    var formattedAddedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: addedDate, relativeTo: Date())
    }
}

// MARK: - Project

struct Project: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var gradient: GradientTheme
    /// Local filename in the app's CoverImages directory. Nil when using gradient only.
    var coverImageFileName: String?
    /// Firebase Storage path for the cover image. Nil until uploaded.
    var coverStoragePath: String?
    /// Hex accent used for the active track and notes editor (e.g. `#667EEA`).
    var accentColorHex: String?
    /// Two hex colors extracted from the cover image for the vinyl gradient. Nil when using a preset gradient.
    var coverGradientColors: [String]?
    var tracks: [Track]
    var createdDate: Date
    var updatedDate: Date
    /// Non-nil when this project is shared from another user. Nil for own projects.
    var ownerID: String?
    /// Denormalized display username of the owner. Set for shared projects when decoded from Firestore.
    var ownerUsername: String?
    /// Whether the owner has link-sharing enabled. Nil until first fetched; only meaningful for shared projects.
    var linkEnabled: Bool?

    var isShared: Bool { ownerID != nil }

    init(
        id: UUID = UUID(),
        name: String = "untitled project",
        gradient: GradientTheme = .random(),
        coverImageFileName: String? = nil,
        coverStoragePath: String? = nil,
        accentColorHex: String? = nil,
        coverGradientColors: [String]? = nil,
        tracks: [Track] = [],
        createdDate: Date = Date(),
        updatedDate: Date = Date(),
        ownerID: String? = nil,
        ownerUsername: String? = nil,
        linkEnabled: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.gradient = gradient
        self.coverImageFileName = coverImageFileName
        self.coverStoragePath = coverStoragePath
        self.accentColorHex = accentColorHex
        self.coverGradientColors = coverGradientColors
        self.tracks = tracks
        self.createdDate = createdDate
        self.updatedDate = updatedDate
        self.ownerID = ownerID
        self.ownerUsername = ownerUsername
        self.linkEnabled = linkEnabled
    }

    var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    var formattedDuration: String {
        if tracks.isEmpty { return "0 min" }
        let total = Int(totalDuration)
        let minutes = total / 60
        if minutes == 0 { return "< 1 min" }
        return "\(minutes) min"
    }

    var trackCountText: String {
        tracks.count == 1 ? "1 track" : "\(tracks.count) tracks"
    }

    var usesCoverImage: Bool {
        coverImageFileName != nil || coverStoragePath != nil
    }
}

// MARK: - Color hex helper

extension UIImage {
    @MainActor
    func squareArtworkImage(size: CGFloat = 600) -> UIImage? {
        let renderer = ImageRenderer(
            content: Image(uiImage: self)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipped()
        )
        renderer.scale = 2
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3:
            (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }
}
