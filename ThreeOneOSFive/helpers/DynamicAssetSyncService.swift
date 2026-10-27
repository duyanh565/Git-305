import Foundation
import CryptoKit

/// Additional, data-driven asset synchronizer.
///
/// This service is intentionally scoped to the application's own container.
/// It does not discover or mutate files inside other applications.
/// Existing startup patch synchronization remains unchanged; this service adds
/// supplemental remote/bundled assets (icons and optional patch packages).
actor DynamicAssetSyncService {
    static let shared = DynamicAssetSyncService()

    enum AssetKind: String, Codable, Sendable {
        case icon
        case patchPackage
        case archive
    }

    struct ManifestAsset: Codable, Hashable, Sendable {
        let id: String
        let kind: AssetKind
        let fileName: String
        let url: URL?
        let sha256: String?
        let targetIdentifier: String?
        let enabled: Bool

        init(
            id: String,
            kind: AssetKind,
            fileName: String,
            url: URL? = nil,
            sha256: String? = nil,
            targetIdentifier: String? = nil,
            enabled: Bool = true
        ) {
            self.id = id
            self.kind = kind
            self.fileName = fileName
            self.url = url
            self.sha256 = sha256
            self.targetIdentifier = targetIdentifier
            self.enabled = enabled
        }
    }

    struct Manifest: Codable, Sendable {
        let schemaVersion: Int
        let assets: [ManifestAsset]
    }

    struct SyncResult: Sendable {
        let succeeded: [String]
        let failed: [String]
    }

    enum SyncError: Error, LocalizedError {
        case invalidManifest
        case invalidAssetID
        case invalidFileName
        case unsupportedURL
        case downloadFailed
        case invalidHTTPStatus(Int)
        case checksumMismatch
        case emptyFile
        case unsafeArchive

        var errorDescription: String? {
            switch self {
            case .invalidManifest: return "Dynamic asset manifest is invalid."
            case .invalidAssetID: return "Dynamic asset identifier is invalid."
            case .invalidFileName: return "Dynamic asset filename is invalid."
            case .unsupportedURL: return "Dynamic asset URL is unsupported."
            case .downloadFailed: return "Dynamic asset download failed."
            case .invalidHTTPStatus(let code): return "Dynamic asset server returned HTTP \(code)."
            case .checksumMismatch: return "Dynamic asset checksum verification failed."
            case .emptyFile: return "Dynamic asset is empty."
            case .unsafeArchive: return "Dynamic asset archive was rejected."
            }
        }
    }

    private let fileManager = FileManager.default
    private let directoryName = "DynamicAssets.v1"
    private let manifestName = "DynamicAssets.json"

    private var rootDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private var manifestURL: URL {
        rootDirectory.appendingPathComponent(manifestName)
    }

    private init() {}

    /// Synchronizes the bundled manifest. A remote manifest can be introduced
    /// later without changing the storage or validation contract.
    func sync() async -> SyncResult {
        do {
            try createRootIfNeeded()
            let manifest = try loadManifest()
            try validate(manifest)

            var succeeded: [String] = []
            var failed: [String] = []

            await withTaskGroup(of: (String, Bool).self) { group in
                for asset in manifest.assets where asset.enabled && asset.kind != .patchPackage {
                    group.addTask { [weak self] in
                        guard let self else { return (asset.id, false) }
                        do {
                            try await self.sync(asset)
                            return (asset.id, true)
                        } catch {
                            log("dynamic-assets: \(asset.id): \(error.localizedDescription)")
                            return (asset.id, false)
                        }
                    }
                }

                for await (id, ok) in group {
                    if ok {
                        succeeded.append(id)
                    } else {
                        failed.append(id)
                    }
                }
            }

            succeeded.sort()
            failed.sort()
            log("dynamic-assets: sync complete success=\(succeeded.count) failed=\(failed.count)")
            return SyncResult(succeeded: succeeded, failed: failed)
        } catch {
            log("dynamic-assets: manifest failure: \(error.localizedDescription)")
            return SyncResult(succeeded: [], failed: ["manifest"])
        }
    }

    private func sync(_ asset: ManifestAsset) async throws {
        let destination = try validatedDestination(for: asset)
        if fileManager.fileExists(atPath: destination.path) {
            if let expected = normalizedHash(asset.sha256) {
                let actual = try sha256(of: destination)
                if actual != expected {
                    try fileManager.removeItem(at: destination)
                } else {
                    return
                }
            } else {
                return
            }
        }

        if let url = asset.url {
            guard url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty else {
                throw SyncError.unsupportedURL
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            configuration.waitsForConnectivity = false

            let (temporaryURL, response) = try await URLSession(configuration: configuration)
                .download(from: url)

            defer { try? fileManager.removeItem(at: temporaryURL) }

            guard let http = response as? HTTPURLResponse else {
                throw SyncError.downloadFailed
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SyncError.invalidHTTPStatus(http.statusCode)
            }

            let values = try temporaryURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) > 0 else {
                throw SyncError.emptyFile
            }

            if let expected = normalizedHash(asset.sha256) {
                let actual = try sha256(of: temporaryURL)
                guard actual == expected else {
                    throw SyncError.checksumMismatch
                }
            }

            try atomicInstall(source: temporaryURL, destination: destination)
            return
        }

        guard let bundled = Bundle.main.url(
            forResource: asset.fileName,
            withExtension: nil
        ) else {
            throw SyncError.downloadFailed
        }

        let values = try bundled.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0 else {
            throw SyncError.emptyFile
        }

        if let expected = normalizedHash(asset.sha256) {
            let actual = try sha256(of: bundled)
            guard actual == expected else {
                throw SyncError.checksumMismatch
            }
        }

        try atomicInstall(source: bundled, destination: destination)
    }

    private func createRootIfNeeded() throws {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
    }

    private func loadManifest() throws -> Manifest {
        if fileManager.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
            return try JSONDecoder().decode(Manifest.self, from: data)
        }

        guard let bundled = Bundle.main.url(
            forResource: manifestName,
            withExtension: nil
        ) else {
            return Manifest(schemaVersion: 1, assets: [])
        }

        let data = try Data(contentsOf: bundled, options: .mappedIfSafe)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private func validate(_ manifest: Manifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw SyncError.invalidManifest
        }

        var identifiers = Set<String>()
        for asset in manifest.assets {
            let id = asset.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, identifiers.insert(id).inserted else {
                throw SyncError.invalidAssetID
            }

            _ = try validatedFileName(asset.fileName)

            if let url = asset.url {
                guard url.scheme?.lowercased() == "https", url.host != nil else {
                    throw SyncError.unsupportedURL
                }
            }

            if let hash = asset.sha256, !hash.isEmpty {
                guard normalizedHash(hash) != nil else {
                    throw SyncError.checksumMismatch
                }
            }
        }
    }

    private func validatedDestination(for asset: ManifestAsset) throws -> URL {
        let name = try validatedFileName(asset.fileName)
        return rootDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private func validatedFileName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw SyncError.invalidFileName
        }
        guard name.count <= 255 else {
            throw SyncError.invalidFileName
        }
        return name
    }

    private func normalizedHash(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit })
        else { return nil }
        return value
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func atomicInstall(source: URL, destination: URL) throws {
        let temporaryDestination = rootDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryDestination) }

        try fileManager.copyItem(at: source, to: temporaryDestination)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryDestination, to: destination)
    }

    nonisolated static func cachedURL(forID id: String) -> URL? {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("DynamicAssets.v1", isDirectory: true)

        guard let name = Self.filename(forID: id) else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static func filename(forID id: String) -> String? {
        switch id {
        case "icon.locket":
            return "locket.jpg"
        default:
            return nil
        }
    }
}
