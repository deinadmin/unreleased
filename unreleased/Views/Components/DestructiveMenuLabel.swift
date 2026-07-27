import SwiftUI

/// Keeps destructive menu glyphs red even when the surrounding native menu
/// uses the primary label color instead of the app accent.
struct DestructiveMenuLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let image = UIImage(systemName: systemImage)?
                .withTintColor(.systemRed, renderingMode: .alwaysOriginal) {
                Image(uiImage: image)
            }
        }
    }
}
