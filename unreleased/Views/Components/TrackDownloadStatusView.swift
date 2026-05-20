import SwiftUI

/// Progress spinner or downloaded icon shown beside track metadata.
struct TrackDownloadStatusView: View {
    @Environment(ProjectStore.self) private var store
    let track: Track

    var body: some View {
        if store.isDownloading(track.id) {
            ProgressView()
                .scaleEffect(0.55)
                .frame(width: 12, height: 12)
        } else if store.isTrackDownloaded(track) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
