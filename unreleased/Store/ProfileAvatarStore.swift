import Foundation
import FirebaseFirestore
import FirebaseStorage
import ImageIO
import SwiftUI
import UIKit

/// Owns the one decoded profile image used throughout the app.
///
/// A small disk copy is shown immediately on launch, then the remote URL is
/// revalidated once. Individual views never start their own image request.
@Observable
@MainActor
final class ProfileAvatarStore {
    private(set) var image: UIImage?
    private(set) var isLoading = false

    private var activeKey: String?
    private var activeUserID: String?
    @ObservationIgnored private var profileListener: ListenerRegistration?

    /// Watches the cloud profile so an avatar changed on another device appears
    /// immediately. Firebase Auth's `photoURL` is only a fallback because its
    /// locally cached user object does not receive remote profile edits.
    func observe(userID: String?, fallbackPhotoURL: URL?) {
        profileListener?.remove()
        profileListener = nil

        guard let userID else {
            Task { await load(userID: nil, photoURL: nil) }
            return
        }

        let profile = CloudPaths.userProfileDocument(userID: userID)
        profileListener = profile.addSnapshotListener { [weak self] snapshot, error in
            if let error {
                print("ProfileAvatarStore: profile listener error — \(error)")
            }

            let remoteURL = (snapshot?.data()?["avatarURL"] as? String).flatMap(URL.init(string:))
            Task { @MainActor [weak self] in
                guard let self else { return }
                let photoURL: URL?
                if let remoteURL {
                    photoURL = remoteURL
                } else if let storageURL = await storagePhotoURL(userID: userID) {
                    photoURL = storageURL
                } else {
                    photoURL = fallbackPhotoURL
                }
                await load(userID: userID, photoURL: photoURL)
            }
        }
    }

    /// Finds avatars uploaded by builds that predate the Firestore profile URL.
    /// The Storage modification timestamp is a stable cache-busting version.
    private func storagePhotoURL(userID: String) async -> URL? {
        let reference = CloudPaths.profilePhotoReference(userID: userID)
        do {
            async let url = reference.downloadURL()
            async let metadata = reference.getMetadata()
            let (downloadURL, objectMetadata) = try await (url, metadata)
            guard let updated = objectMetadata.updated else { return downloadURL }

            var components = URLComponents(url: downloadURL, resolvingAgainstBaseURL: false)
            var queryItems = components?.queryItems ?? []
            queryItems.removeAll { $0.name == "v" }
            queryItems.append(URLQueryItem(
                name: "v",
                value: String(Int(updated.timeIntervalSince1970 * 1_000))
            ))
            components?.queryItems = queryItems
            return components?.url ?? downloadURL
        } catch {
            return nil
        }
    }

    func load(userID: String?, photoURL: URL?) async {
        guard let userID, let photoURL else {
            activeKey = nil
            activeUserID = nil
            image = nil
            isLoading = false
            return
        }

        let key = "\(userID)|\(photoURL.absoluteString)"
        guard activeKey != key else { return }
        if activeUserID != userID {
            image = nil
        }
        activeUserID = userID
        activeKey = key
        isLoading = image == nil

        if let cached = await Self.cachedImage(userID: userID, matching: photoURL) {
            guard activeKey == key else { return }
            image = cached.image
            isLoading = false
        }

        do {
            var request = URLRequest(url: photoURL)
            request.cachePolicy = .reloadRevalidatingCacheData
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            if let statusCode = (response as? HTTPURLResponse)?.statusCode,
               !(200 ..< 300).contains(statusCode) {
                throw URLError(.badServerResponse)
            }
            guard let decoded = await Self.downsample(data: data, maxPixelSize: 768)
            else { throw URLError(.cannotDecodeContentData) }
            guard activeKey == key else { return }

            image = decoded.image
            isLoading = false
            await Self.persist(image: decoded, userID: userID, photoURL: photoURL)
        } catch is CancellationError {
            // A sign-out or account switch superseded this request.
        } catch {
            guard activeKey == key else { return }
            isLoading = false
        }
    }

    func setImage(_ image: UIImage?) {
        self.image = image
        isLoading = false
    }

    private nonisolated static func cachedImage(userID: String, matching url: URL) async -> SendableImage? {
        await Task.detached(priority: .userInitiated) {
            let defaultsKey = "profileAvatar.cachedURL.\(userID)"
            guard UserDefaults.standard.string(forKey: defaultsKey) == url.absoluteString,
                  let data = try? Data(contentsOf: cacheURL(userID: userID))
            else { return nil }
            return decode(data: data, maxPixelSize: 768)
        }.value
    }

    private nonisolated static func downsample(data: Data, maxPixelSize: CGFloat) async -> SendableImage? {
        await Task.detached(priority: .userInitiated) {
            decode(data: data, maxPixelSize: maxPixelSize)
        }.value
    }

    private nonisolated static func persist(image: SendableImage, userID: String, photoURL: URL) async {
        await Task.detached(priority: .utility) {
            guard let data = image.image.jpegData(compressionQuality: 0.82) else { return }
            try? FileManager.default.createDirectory(
                at: cacheURL(userID: userID).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: cacheURL(userID: userID), options: .atomic)
            UserDefaults.standard.set(photoURL.absoluteString, forKey: "profileAvatar.cachedURL.\(userID)")
        }.value
    }

    private nonisolated static func decode(data: Data, maxPixelSize: CGFloat) -> SendableImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return SendableImage(image: UIImage(cgImage: cgImage))
    }

    private nonisolated static func cacheURL(userID: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "ProfileAvatars", directoryHint: .isDirectory)
            .appending(path: "\(userID).image")
    }
}

private struct SendableImage: @unchecked Sendable {
    let image: UIImage
}
