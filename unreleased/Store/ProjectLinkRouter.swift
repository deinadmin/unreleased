import Foundation
import Observation

/// Routes incoming project deep links to ContentView for navigation.
@Observable
final class ProjectLinkRouter {
    private static let webHost = "unreleased.top"
    private static let sharedPathComponent = "shared"

    var pendingOwnerID: String?
    var pendingProjectID: UUID?

    func receive(ownerID: String, projectID: UUID) {
        pendingOwnerID = ownerID
        pendingProjectID = projectID
    }

    /// Accepts both current Universal Links and legacy custom-scheme links.
    @discardableResult
    func receive(url: URL) -> Bool {
        let components = url.pathComponents.filter { $0 != "/" }

        if url.scheme?.lowercased() == "https",
           url.host?.lowercased() == Self.webHost,
           components.count == 3,
           components[0].lowercased() == Self.sharedPathComponent,
           let projectID = UUID(uuidString: components[2]) {
            receive(ownerID: components[1], projectID: projectID)
            return true
        }

        if url.scheme?.lowercased() == "unreleased",
           url.host?.lowercased() == "project",
           components.count == 2,
           let projectID = UUID(uuidString: components[1]) {
            receive(ownerID: components[0], projectID: projectID)
            return true
        }

        return false
    }

    static func shareURL(ownerID: String, projectID: UUID) -> URL {
        URL(string: "https://\(webHost)")!
            .appending(path: sharedPathComponent)
            .appending(path: ownerID)
            .appending(path: projectID.uuidString.lowercased())
    }

    func clear() {
        pendingOwnerID = nil
        pendingProjectID = nil
    }
}
