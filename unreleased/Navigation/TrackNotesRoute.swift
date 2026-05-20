import Foundation
import SwiftUI

struct TrackNotesRoute: Hashable {
    let trackID: UUID
    let projectID: UUID
}

private struct NavigateToTrackNotesKey: EnvironmentKey {
    static let defaultValue: (UUID, UUID) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var navigateToTrackNotes: (UUID, UUID) -> Void {
        get { self[NavigateToTrackNotesKey.self] }
        set { self[NavigateToTrackNotesKey.self] = newValue }
    }
}
