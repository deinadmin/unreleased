import SwiftUI

/// Progress spinner or downloaded icon shown beside track metadata.
struct TrackDownloadStatusView: View {
    @Environment(ProjectStore.self) private var store
    let track: Track

    var body: some View {
        if store.isDownloading(track.id) || store.isTrackDownloaded(track) {
            DownloadCircleIndicator(
                symbolPointSize: 11,
                isDownloading: store.isDownloading(track.id),
                isFilled: store.isTrackDownloaded(track),
                iconColor: .secondary
            )
        }
    }
}
