import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class AppSearchState {
    enum Scope: Equatable {
        case library
        case project(UUID)
    }

    private(set) var isActive = false
    var text = ""
    private(set) var scope: Scope = .library
    private(set) var placeholder = "Search your library"

    func activate(scope: Scope, placeholder: String) {
        self.scope = scope
        self.placeholder = placeholder
        text = ""
        isActive = true
    }

    func deactivate(dismissKeyboard: Bool = true) {
        if dismissKeyboard {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
        isActive = false
        text = ""
    }

    func deactivateIfMatching(scope: Scope) {
        guard isActive, self.scope == scope else { return }
        deactivate()
    }
}
