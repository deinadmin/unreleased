import SwiftUI

struct AboutView: View {
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                appHeader
                    .padding(.top, 32)
                    .padding(.bottom, 36)

                developerSection
                    .padding(.horizontal, 20)

                openSourceSection
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
            }
            .bottomChromeAwarePadding(resting: 40)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - App header

    private var appHeader: some View {
        VStack(spacing: 6) {
            Image("AppIconDisplay")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 80, height: 80)
                .clipShape(.rect(cornerRadius: 18))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                .padding(.bottom, 6)
                .accessibilityLabel("unreleased app icon")

            Text("unreleased")
                .font(.system(size: 22, weight: .bold))

            Text("Version \(appVersion)")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Developer section

    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Developer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Carl Steen")
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                        Text("Design & Development")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()
                    .padding(.leading, 56)

                Link(destination: URL(string: "https://github.com/deinadmin")!) {
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .center)

                        Text("@deinadmin on GitHub")
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Open source section

    private var openSourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Source Libraries")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(openSourceLibraries.enumerated()), id: \.element.name) { index, lib in
                    OpenSourceLibraryRow(library: lib)

                    if index < openSourceLibraries.count - 1 {
                        Divider()
                            .padding(.leading, 16)
                    }
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

// MARK: - Library model

private struct OpenSourceLibrary {
    let name: String
    let description: String
    let license: String
    let url: URL
}

private let openSourceLibraries: [OpenSourceLibrary] = [
    .init(
        name: "Firebase iOS SDK",
        description: "Auth, Firestore, Cloud Storage & Messaging",
        license: "Apache 2.0",
        url: URL(string: "https://github.com/firebase/firebase-ios-sdk")!
    ),
    .init(
        name: "Google Sign-In for iOS",
        description: "Google account authentication",
        license: "Apache 2.0",
        url: URL(string: "https://github.com/google/GoogleSignIn-iOS")!
    ),
    .init(
        name: "ColorThiefSwift",
        description: "Dominant color extraction from images",
        license: "MIT",
        url: URL(string: "https://github.com/yamoridon/ColorThiefSwift")!
    ),
    .init(
        name: "DominantColors",
        description: "Color palette analysis from images",
        license: "MIT",
        url: URL(string: "https://github.com/DenDmitriev/DominantColors")!
    ),
]

// MARK: - Library row

private struct OpenSourceLibraryRow: View {
    let library: OpenSourceLibrary

    var body: some View {
        Link(destination: library.url) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(library.description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(library.license)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(.tertiarySystemBackground), in: Capsule())
                        .foregroundStyle(.secondary)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
