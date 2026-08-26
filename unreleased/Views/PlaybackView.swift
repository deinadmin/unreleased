import SwiftUI

struct PlaybackView: View {
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                qualitySection
                equalizerSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .bottomChromeAwarePadding(resting: 36)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playback Quality")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(PlaybackQuality.allCases.enumerated()), id: \.element.id) { index, quality in
                    PlaybackQualityRow(
                        quality: quality,
                        isSelected: player.playbackQuality == quality,
                        action: { player.playbackQuality = quality }
                    )

                    if index < PlaybackQuality.allCases.count - 1 {
                        Divider()
                            .padding(.leading, 56)
                    }
                }
            }
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
    }

    private var equalizerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            NavigationLink(value: EqualizerRoute()) {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("EQ")
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text("Customize the sound of all playback")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
    }
}

private struct PlaybackQualityRow: View {
    let quality: PlaybackQuality
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(quality.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(quality.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
