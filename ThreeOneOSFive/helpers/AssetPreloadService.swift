import Foundation
import SwiftUI
import UIKit
import AVFoundation

/// Centralized startup asset cache. Downloads are concurrent, atomic, and
/// recoverable: a failed remote asset never prevents the application from
/// opening when a usable local/bundled fallback exists.
actor AssetPreloadService {
    static let shared = AssetPreloadService()

    struct RemoteAsset: Sendable {
        let key: String
        let url: URL
        let fileExtension: String
    }

    private let fm = FileManager.default
    private let cacheFolderName = "AssetCache.v2"

    /// Add future remote icons/video/images here. The registry is intentionally
    /// data-driven so new assets do not require changes to the UI.
    private var remoteAssets: [RemoteAsset] {
        [
            .init(key: "icon.ffth", url: URL(string: "https://i.ibb.co/27CQSgHV/IMG-8638.png")!, fileExtension: "png"),
            .init(key: "icon.ffm", url: URL(string: "https://i.ibb.co/jZMDVKPs/IMG-8637.png")!, fileExtension: "png"),
            .init(key: "icon.capcut", url: URL(string: "https://i.ibb.co/Gv6DThXB/IMG-8639.jpg")!, fileExtension: "jpg"),
            .init(key: "icon.pubg", url: URL(string: "https://i.ibb.co/5Xvm4Nc6/IMG-8640.jpg")!, fileExtension: "jpg"),
            .init(key: "icon.lienquan", url: URL(string: "https://i.ibb.co/3mr8wR8m/IMG-8641.jpg")!, fileExtension: "jpg"),
        ]
    }

    private var cacheDirectory: URL {
        fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(cacheFolderName, isDirectory: true)
    }

    private func destination(for asset: RemoteAsset) -> URL {
        cacheDirectory.appendingPathComponent(
            "\(asset.key.replacingOccurrences(of: ".", with: "_")).\(asset.fileExtension)"
        )
    }

    func cachedURL(forKey key: String) -> URL? {
        guard let asset = remoteAssets.first(where: { $0.key == key }) else { return nil }
        let url = destination(for: asset)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    func preloadAll() async {
        do {
            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            log("asset-cache: cannot create cache directory: \(error.localizedDescription)")
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for asset in remoteAssets {
                group.addTask { [weak self] in
                    await self?.preload(asset)
                }
            }
        }

        await cacheBundledVisualAssets()
        // Video/audio assets are intentionally not preloaded at launch.
    }


    /// Creates a local first-frame image for video backgrounds. SwiftUI can
    /// display this immediately while AVPlayer decodes the first video frame,
    /// eliminating the black flash during page creation/navigation.
    private func cacheFirstFrames(for keys: [String]) async {
        for key in keys {
            guard let asset = remoteAssets.first(where: { $0.key == key }),
                  let videoURL = cachedURL(forKey: key) else { continue }

            let frameURL = cacheDirectory.appendingPathComponent(
                "\(asset.key.replacingOccurrences(of: ".", with: "_"))_firstframe.png"
            )
            guard !fm.fileExists(atPath: frameURL.path) else { continue }

            let avAsset = AVAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: avAsset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1440, height: 1440)

            do {
                let image = try generator.copyCGImage(at: .zero, actualTime: nil)
                guard let data = UIImage(cgImage: image).pngData() else { continue }
                try data.write(to: frameURL, options: .atomic)
            } catch {
                log("asset-cache: first frame \(key): \(error.localizedDescription)")
            }
        }
    }

    private func preload(_ asset: RemoteAsset) async {
        let destination = destination(for: asset)

        // Existing file is accepted as cache. Downloads use a temporary file
        // and an atomic move, so interrupted downloads cannot poison the cache.
        if fm.fileExists(atPath: destination.path) {
            return
        }

        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            configuration.waitsForConnectivity = false

            let (temporaryURL, response) =
                try await URLSession(configuration: configuration).download(from: asset.url)

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                log("asset-cache: HTTP failure for \(asset.key)")
                return
            }

            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: temporaryURL, to: destination)
        } catch is CancellationError {
            log("asset-cache: cancelled \(asset.key)")
        } catch {
            log("asset-cache: \(asset.key): \(error.localizedDescription)")
        }
    }

    /// Materializes common bundle image resources into the same cache namespace.
    /// SF Symbols themselves are system resources and do not need downloading.
    private func cacheBundledVisualAssets() async {
        let extensions = ["png", "jpg", "jpeg", "webp", "heic", "mp4", "mov"]
        guard let resourceURL = Bundle.main.resourceURL else { return }

        let enumerator = fm.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let item = enumerator?.nextObject() as? URL {
            guard extensions.contains(item.pathExtension.lowercased()) else { continue }
            do {
                let values = try item.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }

                let key = "bundle_" + item.lastPathComponent.replacingOccurrences(of: " ", with: "_")
                let destination = cacheDirectory.appendingPathComponent(key)
                guard !fm.fileExists(atPath: destination.path) else { continue }
                try fm.copyItem(at: item, to: destination)
            } catch {
                log("asset-cache: bundled \(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Synchronous lookup for SwiftUI views. Only returns an already-cached URL.
    nonisolated static func cachedURL(key: String) -> URL? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AssetCache.v2", isDirectory: true)
        let mapping: [String: String] = [
            "icon.ffth": "icon_ffth.png",
            "icon.ffm": "icon_ffm.png",
            "icon.capcut": "icon_capcut.jpg",
            "icon.pubg": "icon_pubg.jpg",
            "icon.lienquan": "icon_lienquan.jpg",
            "background.static": "background_static.mov",
            "background.dynamic": "background_dynamic.mp4",
            "background.extra": "background_extra.mp4",
            "audio.background": "audio_background.mp3"
        ]
        guard let name = mapping[key] else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns an already-generated video first frame. Never performs I/O that
    /// can trigger a network request, making this safe for SwiftUI body creation.
    nonisolated static func cachedFirstFrameURL(key: String) -> URL? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AssetCache.v2", isDirectory: true)
        let mapping: [String: String] = [
            "animeStatic": "background_static_firstframe.png",
            "animeDynamic": "background_dynamic_firstframe.png"
        ]
        guard let name = mapping[key] else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
