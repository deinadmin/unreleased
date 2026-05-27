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
    /// Bumped when the search field should become first responder again.
    private(set) var focusRequest = 0
    /// Bumped when the search field should resign first responder.
    private(set) var blurRequest = 0
    private(set) var isFieldFocused = false

    func activate(scope: Scope, placeholder: String, clearText: Bool = true) {
        self.scope = scope
        self.placeholder = placeholder
        if clearText { text = "" }
        isFieldFocused = false
        isActive = true
    }

    /// Re-focuses the search field without clearing the query.
    func requestFocus() {
        focusRequest += 1
    }

    func setFieldFocused(_ focused: Bool) {
        isFieldFocused = focused
    }

    /// Resigns search field focus without clearing the query or hiding search.
    func resignFocus(dismissKeyboard: Bool = true) {
        if dismissKeyboard {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
        isFieldFocused = false
        blurRequest += 1
    }

    /// Toolbar search: activate, focus, hide when empty, or blur when focused with a query.
    func activateOrFocus(scope: Scope, placeholder: String) {
        self.placeholder = placeholder

        guard isActive, self.scope == scope else {
            activate(scope: scope, placeholder: placeholder)
            return
        }

        if isFieldFocused {
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                deactivate()
            } else {
                resignFocus()
            }
        } else {
            requestFocus()
        }
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
        isFieldFocused = false
        isActive = false
        text = ""
    }

    func deactivateIfMatching(scope: Scope) {
        guard isActive, self.scope == scope else { return }
        deactivate()
    }
}
