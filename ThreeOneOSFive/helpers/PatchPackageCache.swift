import CryptoKit
import Foundation

/// Persistent cache for repository patch packages.
///
/// A cached package is keyed by the repository identity plus the package's
/// version/hash/download URL. When the same package is requested again, the
/// app reuses the verified local bytes instead of downloading them again.
/// The cache lives in Application Support and is private to this app.
final class PatchPackageCache {
    static let shared = PatchPackageCache()

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let lock = NSLock()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("PatchPackageCache.v1", isDirectory: true)
    }

    func cachedData(for package: RepositoryPackage) -> Data? {
        guard let url = cachedURL(for: package) else { return nil }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else {
                remove(package)
                return nil
            }

            let summary = try PatchPackageCodec.inspect(data)
            if let expected = normalizedHash(package.sha256) {
                guard sha256(data) == expected else {
                    remove(package)
                    return nil
                }
            }

            return data
        } catch {
            remove(package)
            return nil
        }
    }

    func store(_ data: Data, for package: RepositoryPackage) throws {
        guard !data.isEmpty else { return }
        _ = try PatchPackageCodec.inspect(data)

        if let expected = normalizedHash(package.sha256), sha256(data) != expected {
            throw PackageRepositoryError.checksumMismatch
        }

        let url = try cacheURL(for: package)
        lock.lock()
        defer { lock.unlock() }

        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        let stagingURL = rootDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        try data.write(to: stagingURL, options: [.atomic])

        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: stagingURL, to: url)
    }

    func remove(_ package: RepositoryPackage) {
        guard let url = cachedURL(for: package) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: url)
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: rootDirectory)
    }

    func contains(_ package: RepositoryPackage) -> Bool {
        guard let url = cachedURL(for: package) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    private func cachedURL(for package: RepositoryPackage) -> URL? {
        guard let key = cacheKey(for: package) else { return nil }
        return rootDirectory.appendingPathComponent(key + ".patch", isDirectory: false)
    }

    private func cacheURL(for package: RepositoryPackage) throws -> URL {
        guard let url = cachedURL(for: package) else {
            throw PackageRepositoryError.invalidPackage
        }
        return url
    }

    private func cacheKey(for package: RepositoryPackage) -> String? {
        let identifier = package.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = package.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let download = package.downloadURL.absoluteString
        guard !identifier.isEmpty, !version.isEmpty, !download.isEmpty else {
            return nil
        }

        let raw = [identifier, version, package.sha256 ?? "", download]
            .joined(separator: "\n")
        return sha256(Data(raw.utf8))
    }

    private func normalizedHash(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit }) else {
            return nil
        }
        return value
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
