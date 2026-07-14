import Observation
import SwiftUI

@Observable
@MainActor
final class MiniPlayerVisibility {
    enum Reason: Hashable {
        case enlargedProfilePhoto
        case deleteTracks
    }

    private(set) var hiddenReasons = Set<Reason>()

    var isHidden: Bool { !hiddenReasons.isEmpty }

    func hide(for reason: Reason) {
        guard !hiddenReasons.contains(reason) else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            hiddenReasons.insert(reason)
        }
    }

    func show(for reason: Reason) {
        guard hiddenReasons.contains(reason) else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            hiddenReasons.remove(reason)
        }
    }
}
