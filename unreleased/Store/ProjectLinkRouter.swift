import Foundation
import Observation

/// Routes incoming project deep links to ContentView for navigation.
@Observable
final class ProjectLinkRouter {
    var pendingOwnerID: String?
    var pendingProjectID: UUID?

    func receive(ownerID: String, projectID: UUID) {
        pendingOwnerID = ownerID
        pendingProjectID = projectID
    }

    func clear() {
        pendingOwnerID = nil
        pendingProjectID = nil
    }
}
