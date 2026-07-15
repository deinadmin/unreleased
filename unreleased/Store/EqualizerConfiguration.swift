import Foundation

struct EqualizerBand: Identifiable, Sendable {
    let id: Int
    let frequency: Float
    let label: String
    let character: String

    static let all: [EqualizerBand] = [
        .init(id: 0, frequency: 60, label: "60", character: "Sub"),
        .init(id: 1, frequency: 150, label: "150", character: "Bass"),
        .init(id: 2, frequency: 400, label: "400", character: "Warmth"),
        .init(id: 3, frequency: 1_000, label: "1k", character: "Body"),
        .init(id: 4, frequency: 2_400, label: "2.4k", character: "Presence"),
        .init(id: 5, frequency: 6_000, label: "6k", character: "Clarity"),
        .init(id: 6, frequency: 14_000, label: "14k", character: "Air"),
    ]
}

enum EqualizerPreset: String, CaseIterable, Identifiable, Sendable {
    case flat
    case bassBoost
    case vocal
    case warm
    case bright
    case acoustic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: "Flat"
        case .bassBoost: "Bass Boost"
        case .vocal: "Vocal"
        case .warm: "Warm"
        case .bright: "Bright"
        case .acoustic: "Acoustic"
        }
    }

    var gains: [Float] {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0]
        case .bassBoost: [6, 4.5, 2, 0, -1, -1, 0]
        case .vocal: [-2, -1, 0, 2.5, 4, 2, 0]
        case .warm: [3.5, 3, 2, 0.5, -1, -2, -2]
        case .bright: [-2, -1, 0, 1, 2.5, 4, 5]
        case .acoustic: [1.5, 2, 1, -0.5, 2, 2.5, 1.5]
        }
    }
}

struct CustomEqualizerPreset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var gains: [Float]

    init(id: UUID = UUID(), title: String, gains: [Float]) {
        self.id = id
        self.title = title
        self.gains = gains
    }
}
