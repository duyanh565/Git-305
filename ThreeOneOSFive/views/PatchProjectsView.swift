import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CryptoKit

// MARK: - UTType policy (unchanged)
private enum PatchPackagePickerPolicy {
    static let packageType = UTType(filenameExtension: "3105") ?? .data
    static let allowedContentTypes: [UTType] = [packageType, .data]
    static let copiesSelectedDocument = true
}

// MARK: - Online file model (unchanged)
struct OnlineFileItem: Codable, Identifiable {
    let id: String
    let title: String
    let filename: String
    let url: String
    let status: Bool
    let created_at: Int
    let sha256: String?
    let packageID: String?
    let displayName: String?
    let functionName: String?
    let category: String?
    let appTarget: String?
    let sortOrder: Int?
    let patchID: String?
    let categoryID: String?

    init(
        id: String,
        title: String,
        filename: String,
        url: String,
        status: Bool,
        created_at: Int,
        sha256: String? = nil,
        packageID: String? = nil,
        displayName: String? = nil,
        functionName: String? = nil,
        category: String? = nil,
        appTarget: String? = nil,
        sortOrder: Int? = nil,
        patchID: String? = nil,
        categoryID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.filename = filename
        self.url = url
        self.status = status
        self.created_at = created_at
        self.sha256 = sha256
        self.packageID = packageID
        self.displayName = displayName
        self.functionName = functionName
        self.category = category
        self.appTarget = appTarget
        self.sortOrder = sortOrder
        self.patchID = patchID
        self.categoryID = categoryID
    }

    enum CodingKeys: String, CodingKey {
        case id, title, filename, url, status, created_at, sha256
        case packageID = "package_id"
        case displayName = "display_name"
        case functionName = "function_name"
        case category
        case appTarget = "app_target"
        case sortOrder = "sort_order"
        case patchID = "patchID"
        case patch_id
        case categoryID = "categoryID"
        case category_id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        if let boolValue = try? c.decode(Bool.self, forKey: .status) {
            status = boolValue
        } else if let intValue = try? c.decode(Int.self, forKey: .status) {
            status = intValue == 1
        } else if let stringValue = try? c.decode(String.self, forKey: .status) {
            status = ["1", "true", "active", "enabled"].contains(stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        } else {
            status = false
        }
        created_at = try c.decodeIfPresent(Int.self, forKey: .created_at) ?? 0
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        packageID = try c.decodeIfPresent(String.self, forKey: .packageID)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        functionName = try c.decodeIfPresent(String.self, forKey: .functionName)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        appTarget = try c.decodeIfPresent(String.self, forKey: .appTarget)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder)
        patchID = try c.decodeIfPresent(String.self, forKey: .patchID) ?? c.decodeIfPresent(String.self, forKey: .patch_id) ?? id
        categoryID = (try c.decodeIfPresent(String.self, forKey: .categoryID)
            ?? c.decodeIfPresent(String.self, forKey: .category_id)
            ?? category)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(filename, forKey: .filename)
        try c.encode(url, forKey: .url)
        try c.encode(status, forKey: .status)
        try c.encode(created_at, forKey: .created_at)
        try c.encodeIfPresent(sha256, forKey: .sha256)
        try c.encodeIfPresent(packageID, forKey: .packageID)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(functionName, forKey: .functionName)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(appTarget, forKey: .appTarget)
        try c.encodeIfPresent(sortOrder, forKey: .sortOrder)
        try c.encodeIfPresent(patchID, forKey: .patchID)
        try c.encodeIfPresent(categoryID, forKey: .categoryID)
    }
}

// MARK: - Server display-name cache

struct PatchServerMetadata: Codable, Equatable {
    let patchID: String
    let categoryID: String
    let displayName: String
    let functionName: String
    let category: String
    let appTarget: String
    let sortOrder: Int
}

enum PatchDisplayNameStore {
    private static let key = "PatchProjects.serverDisplayNames.v1"
    private static let metadataKey = "PatchProjects.serverMetadata.v2"

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func save(_ file: OnlineFileItem) {
        let name = file.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty {
            var values = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            values["id:\(normalize(file.id))"] = name
            values["title:\(normalize(file.title))"] = name
            if let packageID = file.packageID, !packageID.isEmpty {
                values["package:\(normalize(packageID))"] = name
            }
            let filename = normalize(file.filename)
            if !filename.isEmpty { values["file:\(filename)"] = name }
            UserDefaults.standard.set(values, forKey: key)
        }

        // Persist routing/category metadata even when display_name is omitted.
        var metadata = UserDefaults.standard.dictionary(forKey: metadataKey) as? [String: [String: Any]] ?? [:]
        let entry: [String: Any] = [
            "patchID": file.patchID ?? file.id,
            "categoryID": (file.categoryID ?? file.category ?? "").uppercased(),
            "displayName": name,
            "functionName": file.functionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            "category": file.category?.uppercased() ?? "",
            "appTarget": file.appTarget?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            "sortOrder": file.sortOrder ?? 0
        ]
        if let packageID = file.packageID, !packageID.isEmpty {
            metadata["package:\(normalize(packageID))"] = entry
        }
        let normalizedFilename = normalize(file.filename)
        if !normalizedFilename.isEmpty {
            metadata["file:\(normalizedFilename)"] = entry
        }
        let normalizedTitle = normalize(file.title)
        if !normalizedTitle.isEmpty {
            metadata["title:\(normalizedTitle)"] = entry
        }
        metadata["id:\(normalize(file.id))"] = entry
        UserDefaults.standard.set(metadata, forKey: metadataKey)
    }

    static func name(for item: PatchLibraryItem) -> String? {
        let values = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        let packageID = normalize(item.summary.packageID.uuidString)
        if let name = values["package:\(packageID)"], !name.isEmpty { return name }
        let filename = normalize(item.packageURL.lastPathComponent)
        if let name = values["file:\(filename)"], !name.isEmpty { return name }
        if let projectName = item.project?.name {
            let title = normalize(projectName)
            if let name = values["title:\(title)"], !name.isEmpty { return name }
        }
        return nil
    }

    static func metadata(for item: PatchLibraryItem) -> PatchServerMetadata? {
        let values = UserDefaults.standard.dictionary(forKey: metadataKey) as? [String: [String: Any]] ?? [:]
        let packageID = normalize(item.summary.packageID.uuidString)
        let entry = values["package:\(packageID)"]
            ?? values["file:\(normalize(item.packageURL.lastPathComponent))"]
            ?? values["title:\(normalize(item.project?.name ?? item.packageURL.deletingPathExtension().lastPathComponent))"]
        guard let entry else { return nil }
        return PatchServerMetadata(
            patchID: (entry["patchID"] as? String) ?? "",
            categoryID: (entry["categoryID"] as? String) ?? ((entry["category"] as? String) ?? "").uppercased(),
            displayName: (entry["displayName"] as? String) ?? "",
            functionName: (entry["functionName"] as? String) ?? "",
            category: (entry["category"] as? String) ?? "",
            appTarget: (entry["appTarget"] as? String) ?? "",
            sortOrder: (entry["sortOrder"] as? Int) ?? 0
        )
    }
}

// MARK: - Online file fetcher (unchanged)
@MainActor
final class OnlineFileFetcher: ObservableObject {
    @Published var onlineFiles: [OnlineFileItem] = []
    @Published var isLoading: Bool = false
    private(set) var lastFetchSucceeded = false

    private var obfuscatedAPIURL: String {
        // Patch list API: GET https://appfluxcore.site/api/patches_list.php?app=3105
        let encryptedBytes: [UInt8] = [
            0x69, 0x75, 0x75, 0x71, 0x72, 0x3B, 0x2E, 0x2E, 0x60, 0x71, 0x71, 0x67, 0x6D, 0x74, 0x79, 0x62, 0x6E, 0x73, 0x64, 0x2F, 0x72, 0x68, 0x75, 0x64, 0x2E, 0x60, 0x71, 0x68, 0x2E, 0x71, 0x60, 0x75, 0x62, 0x69, 0x64, 0x72, 0x5E, 0x6D, 0x68, 0x72, 0x75, 0x2F, 0x71, 0x69, 0x71, 0x3E, 0x60, 0x71, 0x71, 0x3C, 0x32, 0x30, 0x31, 0x34
        ]
        let xorKey: UInt8 = 0x01
        let decryptedBytes = encryptedBytes.map { $0 ^ xorKey }
        return String(bytes: decryptedBytes, encoding: .utf8) ?? ""
    }

    func fetchServerFiles() async {
        guard let url = URL(string: obfuscatedAPIURL) else { return }
        isLoading = true
        lastFetchSucceeded = false
        defer { isLoading = false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode([OnlineFileItem].self, from: data)
            // Keep the same priority contract as Web Admin/API even if a proxy
            // or legacy endpoint returns the records in a different order.
            let active = decoded.filter { $0.status }.sorted { lhs, rhs in
                let leftOrder = lhs.sortOrder ?? 0
                let rightOrder = rhs.sortOrder ?? 0
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                if let leftID = Int(lhs.id), let rightID = Int(rhs.id), leftID != rightID {
                    return leftID < rightID
                }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
            for file in active { PatchDisplayNameStore.save(file) }
            onlineFiles = active
            lastFetchSucceeded = true
        } catch {
            log("online-files: fetch failed – \(error.localizedDescription)")
        }
    }

    /// Synchronizes every active server patch for the launch gate.
    ///
    /// A package already present in the local library is considered satisfied.
    /// Otherwise a validated per-server-id cache entry is reused before any
    /// network request is attempted. Downloads are atomic and, when the API
    /// supplies sha256, checksum verified before import.
    func preloadAllPatches(
        files: [OnlineFileItem],
        store: PatchProjectStore,
        progress: @escaping @MainActor (Int, Int, Int, String) -> Void,
        itemResult: @escaping @MainActor (OnlineFileItem, Bool) -> Void = { _, _ in }
    ) async -> Bool {
        guard !files.isEmpty else { return true }

        let localNames = await Task.detached(priority: .userInitiated) {
            let localItems = PatchProjectLibrary.load()
            return Set(localItems.map { item in
                var identities = [item.packageURL.deletingPathExtension().lastPathComponent]
                if let project = item.project {
                    identities.append(project.name)
                }
                return identities.map(Self.normalizedLocalIdentity)
            }.flatMap { $0 })
        }.value

        var completed = 0
        var failed = 0

        await reconcileMissingServerPackages(manifest: files)

        for file in files {
            if Task.isCancelled { return false }

            progress(completed, files.count, failed, file.title)

            let ok: Bool
            if isAlreadyInstalled(file: file, localNames: localNames) {
                log("startup-patch: local package found, skip download – \(file.title)")
                ok = true
            } else {
                ok = await synchronizePatch(file: file, store: store)
            }

            if ok {
                completed += 1
                markServerManaged(file)
            } else {
                failed += 1
            }

            itemResult(file, ok)
            progress(completed, files.count, failed, file.title)
        }

        // Launch readiness is an integrity gate: exposing the UI after only
        // some active server packages were imported would violate the startup
        // contract and leave patch state ambiguous.
        return !Task.isCancelled && failed == 0
    }

    private func reconcileMissingServerPackages(manifest: [OnlineFileItem]) async {
        let key = "PatchProjects.serverManagedPackageIDs.v1"
        let previous = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let current = Set(manifest.compactMap { normalizedPackageID($0.packageID) })
        guard !previous.isEmpty else {
            persistManagedPackageIDs(current, key: key)
            return
        }

        let missing = previous.subtracting(current)
        guard !missing.isEmpty else {
            persistManagedPackageIDs(current, key: key)
            return
        }

        let localItems = PatchProjectLibrary.load()
        for item in localItems {
            let packageID = item.summary.packageID.uuidString.lowercased()
            guard missing.contains(packageID) else { continue }

            do {
                if let receipt = DevicePatchService.latestAppliedReceipt(projectID: item.id) {
                    try DevicePatchService.restore(receipt: receipt)
                }
                try PatchProjectLibrary.delete(item)
                log("patch-sync: server source disappeared; local package deleted and patch disabled – \(packageID)")
            } catch {
                log("patch-sync: failed to remove missing package \(packageID): \(error.localizedDescription)")
            }
        }

        persistManagedPackageIDs(current, key: key)
    }

    private func removeManagedPackage(for file: OnlineFileItem) {
        guard let packageID = normalizedPackageID(file.packageID) else { return }
        guard let item = PatchProjectLibrary.load().first(where: {
            $0.summary.packageID.uuidString.lowercased() == packageID
        }) else { return }

        do {
            if let receipt = DevicePatchService.latestAppliedReceipt(projectID: item.id) {
                try DevicePatchService.restore(receipt: receipt)
            }
            try PatchProjectLibrary.delete(item)
            log("patch-sync: source not found; local package deleted and patch disabled – \(packageID)")
        } catch {
            log("patch-sync: failed to disable missing package \(packageID): \(error.localizedDescription)")
        }
    }

    private func markServerManaged(_ file: OnlineFileItem) {
        guard let packageID = normalizedPackageID(file.packageID) else { return }
        let key = "PatchProjects.serverManagedPackageIDs.v1"
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.insert(packageID)
        persistManagedPackageIDs(ids, key: key)
    }

    private func persistManagedPackageIDs(_ ids: Set<String>, key: String) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
    }

    private func normalizedPackageID(_ raw: String?) -> String? {
        guard let raw, let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private func synchronizePatch(
        file: OnlineFileItem,
        store: PatchProjectStore
    ) async -> Bool {
        if let cached = cachedStartupPackageURL(for: file),
           validateCachedPackage(cached, expectedSHA256: file.sha256) {
            log("startup-patch: using local download cache – \(file.title)")
            return await importLocalPackage(cached, store: store, removeCacheAfterSuccess: false)
        }

        guard let rawURL = file.url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https" else {
            log("startup-patch: invalid HTTPS URL – \(file.title)")
            return false
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true

        do {
            let (tmp, response) = try await URLSession(configuration: config).download(from: url)
            defer { try? FileManager.default.removeItem(at: tmp) }

            guard let http = response as? HTTPURLResponse else {
                return false
            }
            if http.statusCode == 404 || http.statusCode == 410 {
                removeManagedPackage(for: file)
                return false
            }
            guard (200..<300).contains(http.statusCode), isSafeRegularFile(tmp) else {
                return false
            }

            if let expected = normalizedSHA256(file.sha256) {
                guard try sha256(of: tmp) == expected else {
                    log("startup-patch: checksum mismatch – \(file.title)")
                    return false
                }
            }

            let cacheURL = startupCacheURL(for: file)
            try FileManager.default.createDirectory(
                at: startupCacheDirectory(),
                withIntermediateDirectories: true
            )
            try atomicReplace(source: tmp, destination: cacheURL)

            return await importLocalPackage(
                cacheURL,
                store: store,
                removeCacheAfterSuccess: false
            )
        } catch is CancellationError {
            return false
        } catch {
            log("startup-patch: \(file.title): \(error.localizedDescription)")
            return false
        }
    }

    private func importLocalPackage(
        _ packageURL: URL,
        store: PatchProjectStore,
        removeCacheAfterSuccess: Bool
    ) async -> Bool {
        guard isSafeRegularFile(packageURL) else { return false }

        store.importPackage(at: packageURL)
        let finished = await waitUntilImportFinishes(store: store, timeout: 45)
        // A password-protected package can finish the import operation by
        // presenting a password request while isBusy becomes false. It is not
        // actually installed yet, so retain the cache and report failure.
        let requiresPassword = store.passwordRequest != nil
        let ok = finished && !requiresPassword

        if ok && removeCacheAfterSuccess {
            try? FileManager.default.removeItem(at: packageURL)
        }
        return ok
    }

    private func isAlreadyInstalled(
        file: OnlineFileItem,
        localNames: Set<String>
    ) -> Bool {
        let filename = normalizedPackageFilename(file.filename, fallbackURL: file.url)
        if localNames.contains(Self.normalizedLocalIdentity(filename)) {
            return true
        }

        let titleIdentity = Self.normalizedLocalIdentity(file.title)
        return !titleIdentity.isEmpty && localNames.contains(titleIdentity)
    }

    private nonisolated static func normalizedLocalIdentity(_ raw: String) -> String {
        String(
            raw.unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map { Character($0) }
        ).lowercased()
    }

    private func normalizedPackageFilename(_ raw: String, fallbackURL: String) -> String {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = candidate.isEmpty
            ? (URL(string: fallbackURL)?.lastPathComponent ?? "Patch")
            : candidate
        return base.lowercased().hasSuffix(".3105") ? base : "\(base).3105"
    }

    private func startupCacheDirectory() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("StartupPatchCache.v1", isDirectory: true)
    }

    private func startupCacheURL(for file: OnlineFileItem) -> URL {
        let digest = SHA256.hash(data: Data(file.id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return startupCacheDirectory().appendingPathComponent("\(digest).3105")
    }

    private func cachedStartupPackageURL(for file: OnlineFileItem) -> URL? {
        let url = startupCacheURL(for: file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func validateCachedPackage(_ url: URL, expectedSHA256: String?) -> Bool {
        guard isSafeRegularFile(url) else { return false }
        guard let expected = normalizedSHA256(expectedSHA256) else { return true }
        return (try? sha256(of: url)) == expected
    }

    private func normalizedSHA256(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit }) else {
            return nil
        }
        return value
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
            if Task.isCancelled { throw CancellationError() }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isSafeRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]) else { return false }
        return values.isRegularFile == true &&
               values.isSymbolicLink != true &&
               (values.fileSize ?? 0) > 0
    }

    private func atomicReplace(source: URL, destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }

        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: staging, to: destination)
    }

    private func waitUntilImportFinishes(
        store: PatchProjectStore,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if !store.isBusy {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        return !store.isBusy
    }
}

// MARK: - Download All Patches state

/// Tracks the per-file progress of a batch download session.
struct PatchDownloadProgress: Identifiable {
    let id: String            // mirrors OnlineFileItem.id
    let title: String
    var fraction: Double      // 0.0 … 1.0
    var status: DownloadStatus

    enum DownloadStatus {
        case pending, downloading, importing, done, failed(String)
    }
}

// MARK: - Download All Sheet

struct OnlineFilesSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fetcher = OnlineFileFetcher()
    @ObservedObject var store: PatchProjectStore

    // Single-file state (existing behaviour)
    @State private var downloadingFileID: String?
    @State private var showSuccessToast = false

    // Batch download state (Feature 1)
    @State private var batchProgresses: [PatchDownloadProgress] = []
    @State private var isBatchRunning = false
    @State private var batchDoneCount = 0
    @State private var batchErrorCount = 0
    @State private var showBatchSummary = false

    // Auto-start: chỉ kích hoạt 1 lần ngay sau khi fetch xong
    @State private var autoStarted = false

    private var allDone: Bool { batchProgresses.allSatisfy { if case .done = $0.status { return true }; return false } }
    private var isSingleBusy: Bool { downloadingFileID != nil }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(red: 0.04, green: 0.05, blue: 0.07).ignoresSafeArea()
                GridBackgroundView(spacing: 25, lineColor: Color.cyan.opacity(0.05)).ignoresSafeArea()

                VStack(spacing: 0) {
                    if fetcher.isLoading {
                        Spacer()
                        VStack(spacing: 20) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.cyan)
                                .scaleEffect(1.5)
                            Text("Đang đồng bộ máy chủ...")
                                .font(.headline)
                                .foregroundColor(.cyan)
                        }
                        Spacer()
                    } else if fetcher.onlineFiles.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "cloud.slash")
                                .font(.system(size: 45))
                                .foregroundColor(.gray)
                            Text("Không có bản Patch nào trên Server")
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    } else {
                        // ── Download All button ──────────────────────────────
                        downloadAllButton
                            .padding(.horizontal, 16)
                            .padding(.top, 12)

                        // ── Batch progress list ──────────────────────────────
                        if isBatchRunning || !batchProgresses.isEmpty {
                            batchProgressSection
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                        }

                        // ── Individual file cards ───────────────────────────
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                ForEach(fetcher.onlineFiles) { file in
                                    onlineItemCardView(file)
                                }
                            }
                            .padding(16)
                            .padding(.top, showSuccessToast ? 60 : 10)
                        }
                    }
                }

                if showSuccessToast {
                    successToastView
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .zIndex(1)
                }
            }
            .navigationTitle("Download File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(Color.gray.opacity(0.7))
                    }
                }
            }
            .task {
                await fetcher.fetchServerFiles()
                // REQ 1: Auto-start handled by AutoPatchEngine (banner in top-right).
                // OnlineFilesSheetView is now only opened manually; batch auto-run removed here.
            }
            .alert("Tải Về Hoàn Tất", isPresented: $showBatchSummary) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Đã tải \(batchDoneCount) patch thành công" +
                     (batchErrorCount > 0 ? ", \(batchErrorCount) thất bại." : "."))
            }
        }
    }

    // MARK: Download All Button

    private var downloadAllButton: some View {
        Button {
            guard !isBatchRunning, !isSingleBusy else { return }
            startBatchDownload()
        } label: {
            HStack(spacing: 10) {
                if isBatchRunning {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "arrow.down.to.line.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                Text(isBatchRunning ? "Đang Tải Xuống…" : "Download All Patches")
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(isBatchRunning ? .white.opacity(0.7) : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: isBatchRunning
                        ? [Color.gray.opacity(0.4), Color.gray.opacity(0.3)]
                        : [Color.cyan.opacity(0.75), Color(red: 0.08, green: 0.45, blue: 0.75)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.clear, lineWidth: 0)
            )
        }
        .disabled(isBatchRunning || isSingleBusy || fetcher.onlineFiles.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: isBatchRunning)
    }

    // MARK: Batch Progress Section

    @ViewBuilder
    private var batchProgressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tiến Trình Tải Xuống")
                .font(.caption.weight(.semibold))
                .foregroundColor(.gray)

            ForEach(batchProgresses) { progress in
                batchProgressRow(progress)
            }
        }
        .padding(12)
        .background(Color(red: 0.10, green: 0.12, blue: 0.18).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        )
    }

    @ViewBuilder
    private func batchProgressRow(_ p: PatchDownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(p.title)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                batchStatusLabel(p.status)
            }
            ProgressView(value: p.fraction)
                .progressViewStyle(.linear)
                .tint(batchTint(p.status))
                .animation(.easeInOut(duration: 0.15), value: p.fraction)
        }
    }

    private func batchStatusLabel(_ status: PatchDownloadProgress.DownloadStatus) -> some View {
        Group {
            switch status {
            case .pending:
                Text("Chờ").font(.caption2).foregroundColor(.gray)
            case .downloading:
                Text("Đang tải").font(.caption2).foregroundColor(.cyan)
            case .importing:
                Text("Đang nhập").font(.caption2).foregroundColor(.yellow)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
            case .failed(let msg):
                Text(msg)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
    }

    private func batchTint(_ status: PatchDownloadProgress.DownloadStatus) -> Color {
        switch status {
        case .pending: return .gray
        case .downloading: return .cyan
        case .importing: return .yellow
        case .done: return .green
        case .failed: return .red
        }
    }

    // MARK: Batch Download Logic

    private func startBatchDownload() {
        let files = fetcher.onlineFiles
        guard !files.isEmpty else { return }
        isBatchRunning = true
        batchDoneCount = 0
        batchErrorCount = 0
        batchProgresses = files.map {
            PatchDownloadProgress(id: $0.id, title: $0.title, fraction: 0, status: .pending)
        }

        Task(priority: .userInitiated) {
            // PatchProjectStore is deliberately serialized: importPackage()
            // rejects a second import while the first transaction is busy.
            // Running these imports concurrently silently drops every import
            // after the first one. Downloads remain complete, but installation
            // is performed one package at a time and each import is awaited.
            for file in files {
                if Task.isCancelled { break }
                await downloadSingleForBatch(file)
            }
            await MainActor.run {
                isBatchRunning = false
                showBatchSummary = true
            }
        }
    }

    private func downloadSingleForBatch(_ file: OnlineFileItem) async {
        guard let rawURL = file.url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: rawURL) else {
            updateBatch(id: file.id, fraction: 0, status: .failed("URL không hợp lệ"))
            await MainActor.run { batchErrorCount += 1 }
            return
        }

        // Validate HTTPS
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            updateBatch(id: file.id, fraction: 0, status: .failed("URL phải HTTPS"))
            await MainActor.run { batchErrorCount += 1 }
            return
        }

        updateBatch(id: file.id, fraction: 0.05, status: .downloading)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true

        do {
            let (temporaryURL, response) = try await URLSession(configuration: config).download(from: url)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            updateBatch(id: file.id, fraction: 0.6, status: .importing)

            let fileName = file.filename.isEmpty ? url.lastPathComponent : file.filename
            let finalName = fileName.hasSuffix(".3105") ? fileName : "\(fileName).3105"
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(finalName)")

            try FileManager.default.copyItem(at: temporaryURL, to: dest)
            defer { try? FileManager.default.removeItem(at: dest) }

            let imported = await store.importPackageAndWait(at: dest)
            guard imported else {
                updateBatch(id: file.id, fraction: 0, status: .failed("Import thất bại"))
                await MainActor.run { batchErrorCount += 1 }
                return
            }

            log("batch-download: imported \(finalName)")
            updateBatch(id: file.id, fraction: 1.0, status: .done)
            await MainActor.run { batchDoneCount += 1 }

        } catch {
            let msg = (error as? URLError)?.localizedDescription ?? "Lỗi tải xuống"
            log("batch-download: failed \(file.filename) – \(error.localizedDescription)")
            updateBatch(id: file.id, fraction: 0, status: .failed(msg))
            await MainActor.run { batchErrorCount += 1 }
        }
    }

    @MainActor
    private func updateBatch(id: String, fraction: Double, status: PatchDownloadProgress.DownloadStatus) {
        guard let idx = batchProgresses.firstIndex(where: { $0.id == id }) else { return }
        batchProgresses[idx].fraction = fraction
        batchProgresses[idx].status = status
    }

    // MARK: Individual card (unchanged appearance, single download)

    private var successToastView: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26))
                .foregroundColor(.green)
                .background(Circle().fill(Color.white).frame(width: 14, height: 14))
            Text("Đã Tải File Xuống Và Patch Thành Công")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Color(red: 0.08, green: 0.15, blue: 0.1).opacity(0.95))
        .cornerRadius(30)
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(Color.clear, lineWidth: 0))
        .shadow(color: Color.green.opacity(0.4), radius: 15, x: 0, y: 5)
        .padding(.top, 16)
    }

    @ViewBuilder
    private func onlineItemCardView(_ file: OnlineFileItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 24))
                .foregroundColor(.cyan)
                .frame(width: 44, height: 44)
                .background(Color.cyan.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(file.title)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                Text(file.filename)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                downloadAndImport(file: file)
            } label: {
                if downloadingFileID == file.id {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.cyan)
                        .padding(8)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.cyan)
                        .background(Circle().fill(Color.black))
                }
            }
            .disabled(downloadingFileID != nil || isBatchRunning)
        }
        .padding(16)
        .background(Color(red: 0.10, green: 0.14, blue: 0.20).opacity(0.8))
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.clear, lineWidth: 0)
        )
    }

    // Existing single-file download (unchanged logic, migrated to async/await)
    private func downloadAndImport(file: OnlineFileItem) {
        guard let rawURL = file.url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: rawURL) else { return }
        downloadingFileID = file.id

        Task(priority: .userInitiated) {
            defer { downloadingFileID = nil }
            do {
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 45
                config.timeoutIntervalForResource = 120
                config.waitsForConnectivity = true
                let (temporaryURL, _) = try await URLSession(configuration: config).download(from: url)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }

                let fileName = file.filename.isEmpty ? url.lastPathComponent : file.filename
                let finalName = fileName.hasSuffix(".3105") ? fileName : "\(fileName).3105"
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString)-\(finalName)")

                try FileManager.default.copyItem(at: temporaryURL, to: dest)
                defer { try? FileManager.default.removeItem(at: dest) }

                store.importPackage(at: dest)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { showSuccessToast = true }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation(.easeOut(duration: 0.5)) { showSuccessToast = false }
            } catch {
                log("single-download: failed \(file.filename) – \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Main Patch Projects View

struct PatchProjectsView: View {
    /// Reports whether this tab is currently at its NavigationStack root.
    /// The parent uses this to derive Settings-button visibility without a
    /// second navigation model.
    @Binding var isAtRoot: Bool

    @StateObject private var store = PatchProjectStore()
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var selectedPatchCategory = "ALL"

    private let patchCategoryFilters = ["ALL", "MOD", "HOLO", "AIM", "MENU"]
    @StateObject private var patchState = PatchToggleStore()
    @ObservedObject private var autoPatch = AutoPatchEngine.shared
    @ObservedObject private var runtimeContent = RuntimeContentService.shared

    /// Mỗi configuration không xác định được đều giữ một group riêng.
    /// Không có group tổng hợp "Khác", vì việc gom các package khác nhau vào
    /// cùng một bucket làm mất khả năng hiển thị configuration độc lập.
    private var groups: [PatchAppGroup] {
        PatchAppGrouping.makeGroups(from: store.items)
    }

    private var visibleGroups: [PatchAppGroup] { groups }

    var body: some View {
        NavigationStack {
            ZStack {
                GlobalBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(minimum: 0), spacing: 4),
                                GridItem(.flexible(minimum: 0), spacing: 4)
                            ],
                            alignment: .center,
                            spacing: 4
                        ) {
                            ForEach(visibleGroups) { group in
                                NavigationLink {
                                    PatchAppDetailView(
                                        group: group,
                                        appearance: appearance,
                                        patchState: patchState
                                    )
                                } label: {
                                    PatchAppCard(group: group, appearance: appearance)
                                        .frame(maxWidth: .infinity)
                                        .aspectRatio(1, contentMode: .fit)
                                }
                                .simultaneousGesture(TapGesture().onEnded {
                                    isAtRoot = false
                                })
                                .buttonStyle(.plain)
                            }
                        }

                        if visibleGroups.isEmpty { emptyState }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 96)
                }

            }
            .navigationTitle(runtimeContent.patchRuntimeConfig.menuName)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                isAtRoot = true
            }
            .task {
                patchState.enforceLicensePolicy()
                // Load the local library first so existing patches are visible
                // immediately, then start AUTO against this same store.
                store.reload()
                // Trigger workspace collection so status dots reflect reality.
                OriginalFileCollector.collectNow()
                await RuntimeContentService.shared.refreshPatchRuntimeConfig()
                AutoPatchEngine.shared.configure(store: store)
                AutoPatchEngine.shared.trigger()

                // Poll the server manifest while this screen is active. Admin
                // changes become visible without rebuilding or relaunching the app.
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 30_000_000_000)
                    } catch {
                        break
                    }
                    guard !Task.isCancelled else { break }
                    await RuntimeContentService.shared.refreshPatchRuntimeConfig()
                    AutoPatchEngine.shared.trigger()
                }
            }
            .onChange(of: autoPatch.hasCompleted) { completed in
                guard completed else { return }
                // AUTO has finished importing; perform one final UI refresh
                // before the embedded spinner is removed.
                store.reload()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(appearance.resolvedAppButtonColor)
            Text("Chưa có chức năng")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Các nhóm FFM, FFTH, CAPCUT, PUBG và LIÊN QUÂN đã được chuẩn bị sẵn.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

// MARK: - Patch toggle state

@MainActor
final class PatchToggleStore: ObservableObject {
    @Published private(set) var enabledIDs: Set<UUID>
    @Published private(set) var busyIDs: Set<UUID> = []
    @Published private(set) var remainingSeconds: [UUID: Int] = [:]
    @Published var errorMessage: String?
    @Published private(set) var patchAccessBlocked = false

    private let storageKey = "PatchProjects.enabledPatchIDs.v2"
    private let deadlinesStorageKey = "PatchProjects.autoDisableDeadlines.v1"
    private var autoDisableTasks: [UUID: Task<Void, Never>] = [:]
    private var autoDisableDeadlines: [UUID: Date] = [:]
    private var autoDisableSettingsObserver: NSObjectProtocol?
    private var webPatchObserver: NSObjectProtocol?
    private var webPatchIDsDisabledObserver: NSObjectProtocol?
    private var webPatchIDsEnabledObserver: NSObjectProtocol?
    private var patchPolicyObserver: NSObjectProtocol?
    private var heartbeatTask: Task<Void, Never>?
    private let heartbeatDeviceID: String = {
        let key = "fluxcore.heartbeat.device_id"
        if let existing = UserDefaults.standard.string(forKey: key), UUID(uuidString: existing) != nil { return existing }
        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }()

    init() {
        let values = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        enabledIDs = Set(values.compactMap(UUID.init(uuidString:)))
        autoDisableDeadlines = Self.loadDeadlines()

        patchPolicyObserver = NotificationCenter.default.addObserver(
            forName: PatchAccessPolicy.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.enforceLicensePolicy()
                if let items = self?.currentItems { self?.reconcile(items) }
            }
        }

        autoDisableSettingsObserver = NotificationCenter.default.addObserver(
            forName: .fluxCoreAutoDisableSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A settings change starts a fresh configured interval for
                // already-enabled patches instead of retaining the old deadline.
                self.autoDisableDeadlines.removeAll()
                self.persistDeadlines()
                self.refreshAutoDisableSchedules()
            }
        }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self {
                    await self.sendPatchHeartbeat()
                } else {
                    return
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }

        // ── Web Patch Toggle observer (toàn bộ) ───────────────────────────
        webPatchObserver = NotificationCenter.default.addObserver(
            forName: .fluxCoreWebPatchToggled,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let enabled = notification.userInfo?["enabled"] as? Bool else { return }
            Task { @MainActor [weak self] in
                await self?.applyWebToggle(enabled: enabled)
            }
        }

        // ── Per-patch disable observer ─────────────────────────────────────
        webPatchIDsDisabledObserver = NotificationCenter.default.addObserver(
            forName: .fluxCoreWebPatchIDsDisabled,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let ids = notification.userInfo?["patch_ids"] as? [String] else { return }
            Task { @MainActor [weak self] in
                await self?.applyWebPatchIDs(serverIDs: ids, enabled: false)
            }
        }

        // ── Per-patch enable observer ──────────────────────────────────────
        webPatchIDsEnabledObserver = NotificationCenter.default.addObserver(
            forName: .fluxCoreWebPatchIDsEnabled,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let ids = notification.userInfo?["patch_ids"] as? [String] else { return }
            Task { @MainActor [weak self] in
                await self?.applyWebPatchIDs(serverIDs: ids, enabled: true)
            }
        }
    }

    /// Bật hoặc tắt toàn bộ patch theo lệnh từ web dashboard.
    ///
    /// - Tắt (enabled = false): restore tất cả patch đang ON → toggle OFF trong app.
    /// - Bật (enabled = true): apply lại tất cả patch từng bị tắt bởi web → toggle ON trong app.
    ///
    /// Lưu danh sách patch cần restore vào UserDefaults để bật lại đúng set.
    @MainActor
    private func applyWebToggle(enabled: Bool) async {
        let snapshotKey = "fluxcore.webToggle.pausedPatchIDs"

        if !enabled {
            // ── TẮT: restore toàn bộ patch đang bật ───────────────────────
            // Ghi lại danh sách patch đang ON để bật lại đúng sau
            let activeIDs = enabledIDs.map { $0.uuidString }
            UserDefaults.standard.set(activeIDs, forKey: snapshotKey)

            let itemsToRestore = currentItems.filter { enabledIDs.contains($0.id) }
            guard !itemsToRestore.isEmpty else { return }

            log("web-toggle: disabling \(itemsToRestore.count) patch(es) via web command")

            for item in itemsToRestore {
                guard !busyIDs.contains(item.id) else { continue }
                setEnabled(false, for: item)
                // Chờ mỗi item xong trước khi sang cái tiếp theo
                // (PatchProjectStore serialized - không thể concurrent)
                var waited = 0
                while busyIDs.contains(item.id) && waited < 100 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
            }

        } else {
            // ── BẬT: apply lại các patch đã bị tắt bởi web ────────────────
            let savedIDs = (UserDefaults.standard.stringArray(forKey: snapshotKey) ?? [])
                .compactMap(UUID.init(uuidString:))
            UserDefaults.standard.removeObject(forKey: snapshotKey)

            guard !savedIDs.isEmpty else { return }

            let itemsToApply = currentItems.filter { savedIDs.contains($0.id) && !$0.isLocked }
            guard !itemsToApply.isEmpty else { return }

            log("web-toggle: re-enabling \(itemsToApply.count) patch(es) via web command")

            for item in itemsToApply {
                guard !busyIDs.contains(item.id) else { continue }
                setEnabled(true, for: item)
                var waited = 0
                while busyIDs.contains(item.id) && waited < 150 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
            }
        }
    }

    /// Toggle từng patch riêng lẻ theo server patch ID.
    ///
    /// Server trả về patch_id = id từ bảng patches (chuỗi số nguyên).
    /// Map sang PatchLibraryItem qua PatchDisplayNameStore.metadata().patchID.
    @MainActor
    private func applyWebPatchIDs(serverIDs: [String], enabled: Bool) async {
        let snapshotKey = "fluxcore.webToggle.perPatch.pausedIDs"

        if !enabled {
            // Lưu lại để bật lại sau
            var saved = (UserDefaults.standard.stringArray(forKey: snapshotKey) ?? [])
            for sid in serverIDs where !saved.contains(sid) { saved.append(sid) }
            UserDefaults.standard.set(saved, forKey: snapshotKey)
        } else {
            // Xoá khỏi danh sách đã lưu
            var saved = (UserDefaults.standard.stringArray(forKey: snapshotKey) ?? [])
            saved.removeAll { serverIDs.contains($0) }
            UserDefaults.standard.set(saved, forKey: snapshotKey)
        }

        // Map server patch ID → PatchLibraryItem
        let targetItems = currentItems.filter { item in
            guard let meta = PatchDisplayNameStore.metadata(for: item) else { return false }
            return serverIDs.contains(meta.patchID)
        }
        guard !targetItems.isEmpty else { return }

        log("web-toggle-patch: \(enabled ? "enabling" : "disabling") \(targetItems.count) patch(es) via web per-patch command")

        for item in targetItems {
            // Chỉ tắt nếu đang bật; chỉ bật nếu đang tắt (tránh no-op gây lỗi)
            let shouldAct = enabled ? !isEnabled(item) : isEnabled(item)
            guard shouldAct, !busyIDs.contains(item.id), !item.isLocked else { continue }
            setEnabled(enabled, for: item)
            var waited = 0
            while busyIDs.contains(item.id) && waited < 150 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
        }
    }

    private func sendPatchHeartbeat() async {
        let categories = Set(currentItems.compactMap { item -> String? in
            guard enabledIDs.contains(item.id), DevicePatchService.latestAppliedReceipt(projectID: item.id) != nil,
                  let category = PatchDisplayNameStore.metadata(for: item)?.category.uppercased(),
                  ["AIM", "HOLO", "MOD", "MENU"].contains(category) else { return nil }
            return category
        }).sorted()
        let version = (Bundle.main.object(forInfoDictionaryKey: "AppReleaseDisplayVersion") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
        guard let url = URL(string: "https://appfluxcore.site/api/patch_heartbeat.php") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let device = UIDevice.current
        let deviceName  = String(device.name.prefix(120))
        let deviceModel = String(device.model.prefix(120))
        let iosVersion  = device.systemVersion
        // Elapsed seconds since the process was last launched (monotonic clock).
        let sessionSec  = max(0, Int(ProcessInfo.processInfo.systemUptime))
        let payload: [String: Any] = [
            "device_id":        heartbeatDeviceID,
            "active_categories": categories,
            "app_version":      String(version.prefix(80)),
            "device_name":      deviceName,
            "device_model":     deviceModel,
            "ios_version":      iosVersion,
            "session_seconds":  sessionSec
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["ok"] as? Bool == true else {
                log("patch-heartbeat: server rejected heartbeat")
                return
            }
        } catch {
            // Offline is non-fatal. The next interval retries without changing local Patch state.
            log("patch-heartbeat: offline/retry later — \(error.localizedDescription)")
        }
    }

    // ── Sync app toggle → WedProxy web ngay lập tức ─────────────────────────
    //
    // Mục đích: khi user tắt/bật patch trong app, trạng thái phải được ghi về
    // wedproxy_states.json trên server ngay lập tức (không chờ poll 10 giây).
    // Web dashboard sẽ phản ánh đúng thực tế; nếu user sau đó vào trang user.php,
    // họ thấy toggle đã đồng bộ.
    //
    // Endpoint: POST /api/user_wedproxy_toggle.php
    // Auth: key + csrf (CSRF dùng static sentinel vì đây là app-native call,
    //       server cần accept token đặc biệt "FLUXCORE_APP_NATIVE_CALL").
    private func syncPatchToggleToWeb(item: PatchLibraryItem, enabled: Bool) {
        guard let key = UserDefaults.standard.string(forKey: "saved_key"),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let meta = PatchDisplayNameStore.metadata(for: item),
              !meta.patchID.isEmpty else { return }

        let patchID  = meta.patchID
        let keyUpper = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        Task.detached(priority: .utility) {
            guard let url = URL(string: "https://appfluxcore.site/api/user_wedproxy_toggle.php") else { return }
            var req = URLRequest(url: url)
            req.httpMethod      = "POST"
            req.timeoutInterval = 8
            req.cachePolicy     = .reloadIgnoringLocalCacheData
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            let body: [String: Any] = [
                "key":      keyUpper,
                "patch_id": patchID,
                "enabled":  enabled,
                "csrf":     "FLUXCORE_APP_NATIVE_CALL"   // sentinel cho app-native call
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
            req.httpBody = data

            do {
                let (respData, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let msg = (try? JSONSerialization.jsonObject(with: respData) as? [String: Any])?["error"] as? String ?? "unknown"
                    log("web-sync: server error \(http.statusCode) — \(msg)")
                }
            } catch {
                // Non-fatal: app toggle đã hoàn tất; web sẽ tự đồng bộ qua poll tiếp theo.
                log("web-sync: offline — \(error.localizedDescription)")
            }
        }
    }

    func isEnabled(_ item: PatchLibraryItem) -> Bool {
        enabledIDs.contains(item.id)
    }

    func isBusy(_ item: PatchLibraryItem) -> Bool {
        busyIDs.contains(item.id)
    }

    /// The transaction journal is the source of truth for the actual filesystem
    /// state. UserDefaults is only a persistence hint for the UI.
    func reconcile(_ items: [PatchLibraryItem]) {
        currentItems = items
        var actualEnabled = enabledIDs
        let ids = Set(items.map(\.id))
        actualEnabled.subtract(ids)

        for item in items {
            if DevicePatchService.latestAppliedReceipt(projectID: item.id) != nil {
                actualEnabled.insert(item.id)
            } else {
                actualEnabled.remove(item.id)
            }
        }

        if actualEnabled != enabledIDs {
            enabledIDs = actualEnabled
            persist()
        }
        refreshAutoDisableSchedules()
        Task { await sendPatchHeartbeat() }
    }

    /// Changes the real patch state, not merely the visual toggle. ON creates a
    /// transaction and writes the replacement files. OFF restores the verified
    /// originals from that transaction. The UI state is committed only after the
    /// filesystem operation succeeds.
    func setEnabled(_ enabled: Bool, for item: PatchLibraryItem) {
        guard !busyIDs.contains(item.id) else { return }

        if enabled && PatchAccessPolicy.blocksNewPatches() {
            patchAccessBlocked = true
            errorMessage = "Key sắp hết hạn (≤ 3600 giây): không thể bật Patch mới."
            Task.detached(priority: .utility) {
                let result = PatchAccessPolicy.enforce()
                await MainActor.run { [weak self] in
                    self?.enabledIDs.subtract(result.restored)
                    self?.persist()
                    if !result.failed.isEmpty {
                        self?.errorMessage = "Đã khóa Patch mới; một số Patch cũ chưa thể khôi phục tự động."
                    }
                }
            }
            return
        }

        // Manual OFF always cancels a pending automatic restore for this patch.
        if !enabled {
            autoDisableTasks[item.id]?.cancel()
            autoDisableTasks[item.id] = nil
            autoDisableDeadlines[item.id] = nil
            remainingSeconds[item.id] = nil
            persistDeadlines()
        }
        guard let baseProject = item.project else {
            errorMessage = "Patch này đang bị khóa. Hãy mở khóa package trước khi bật."
            return
        }

        let projectID = item.id
        let itemSnapshot = item
        let baseProjectSnapshot = baseProject

        busyIDs.insert(projectID)
        errorMessage = nil

        let toggleTask = Task.detached(priority: .userInitiated) { () throws -> Set<UUID> in
            if enabled {
                let project: PatchProject
                if itemSnapshot.summary.schemaVersion >= 2 {
                    project = try PatchProjectLibrary.synchronizeWorkspace(item: itemSnapshot)
                } else {
                    project = baseProjectSnapshot
                }

                // Smart replacement: terminate only active patches that
                // conflict with the incoming target set, then apply the new
                // transaction. Unrelated active patches remain untouched.
                let deactivatedIDs = try DevicePatchService.deactivateConflictingPatches(
                    project: project,
                    excludingProjectID: projectID
                )

                // Replace an older transaction belonging to this same project
                // with a fresh backup of the current originals.
                if let previousReceipt = DevicePatchService.latestReceipt(projectID: projectID) {
                    try DevicePatchService.restore(receipt: previousReceipt)
                }

                _ = try DevicePatchService.apply(project: project)
                return deactivatedIDs
            } else {
                guard let receipt = DevicePatchService.latestReceipt(projectID: projectID) else {
                    return []
                }
                try DevicePatchService.restore(receipt: receipt)
                return []
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let deactivatedIDs = try await toggleTask.value

                if !deactivatedIDs.isEmpty {
                    self.markAutoDeactivated(deactivatedIDs)
                }

                self.finishToggle(projectID: projectID, enabled: enabled)
            } catch let error as PatchPackageError {
                self.failToggle(
                    projectID: projectID,
                    message: error.errorDescription ?? "Không thể thay đổi trạng thái patch."
                )
            } catch {
                self.failToggle(
                    projectID: projectID,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func markAutoDeactivated(_ projectIDs: Set<UUID>) {
        for id in projectIDs {
            enabledIDs.remove(id)
            autoDisableTasks[id]?.cancel()
            autoDisableTasks[id] = nil
            autoDisableDeadlines[id] = nil
            remainingSeconds[id] = nil
        }
        persistDeadlines()
        persist()

        if !projectIDs.isEmpty {
            FluxStatusNotificationCenter.shared.post(
                title: "Patch replaced",
                detail: "Conflicting patch automatically deactivated",
                isOn: false
            )
        }
    }

    func enforceLicensePolicy() {
        guard PatchAccessPolicy.blocksNewPatches() else {
            patchAccessBlocked = false
            return
        }

        patchAccessBlocked = true
        let enforcementTask = Task.detached(priority: .utility) {
            PatchAccessPolicy.enforce()
        }

        Task { @MainActor [weak self] in
            let result = await enforcementTask.value
            guard let self else { return }

            self.enabledIDs.subtract(result.restored)
            self.persist()
            if !result.failed.isEmpty {
                self.errorMessage = "Key sắp hết hạn; một số Patch cũ chưa thể khôi phục tự động."
            }
        }
    }

    func toggle(_ item: PatchLibraryItem) {
        setEnabled(!isEnabled(item), for: item)
    }

    func clearError() {
        errorMessage = nil
    }

    private func finishToggle(projectID: UUID, enabled: Bool) {
        if enabled {
            enabledIDs.insert(projectID)
            autoDisableDeadlines[projectID] = nil
        } else {
            enabledIDs.remove(projectID)
            autoDisableTasks[projectID]?.cancel()
            autoDisableTasks[projectID] = nil
            autoDisableDeadlines[projectID] = nil
            remainingSeconds[projectID] = nil
            persistDeadlines()
        }
        persist()
        busyIDs.remove(projectID)

        if enabled {
            scheduleAutoDisableIfNeeded(for: projectID)
        }

        FluxStatusNotificationCenter.shared.post(
            title: "Patch \(enabled ? "enabled" : "disabled")",
            detail: "Patch state updated successfully",
            isOn: enabled
        )
        // Gửi heartbeat cập nhật trạng thái tổng quát
        Task { await sendPatchHeartbeat() }

        // Sync ngay lên WedProxy để web dashboard phản ánh tức thì
        // Tìm item từ currentItems theo projectID để lấy metadata
        if let item = currentItems.first(where: { $0.id == projectID }) {
            syncPatchToggleToWeb(item: item, enabled: enabled)
        }
    }

    /// Schedules exactly one restore operation per enabled patch and maintains a
    /// live UI countdown. The persisted deadline survives relaunches.
    private func scheduleAutoDisableIfNeeded(for projectID: UUID) {
        autoDisableTasks[projectID]?.cancel()
        autoDisableTasks[projectID] = nil
        remainingSeconds[projectID] = nil

        let settings = AppearanceSettings.shared
        guard AutoDisablePatchPolicy.defaultEnabled && settings.autoDisablePatches else {
            autoDisableDeadlines[projectID] = nil
            persistDeadlines()
            return
        }

        let now = Date()
        let deadline = autoDisableDeadlines[projectID] ?? now.addingTimeInterval(
            min(max(settings.autoDisablePatchSeconds, 1), 20)
        )
        autoDisableDeadlines[projectID] = deadline
        persistDeadlines()

        autoDisableTasks[projectID] = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let remaining = Int(ceil(deadline.timeIntervalSinceNow))
                if remaining <= 0 {
                    self.remainingSeconds[projectID] = 0
                    self.autoDisableTasks[projectID] = nil
                    self.autoDisableDeadlines[projectID] = nil
                    self.persistDeadlines()

                    guard settings.autoDisablePatches,
                          let item = self.itemForAutoDisable(projectID),
                          self.isEnabled(item),
                          !self.isBusy(item) else {
                        self.remainingSeconds[projectID] = nil
                        return
                    }

                    self.setEnabled(false, for: item)
                    return
                }

                self.remainingSeconds[projectID] = remaining
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func itemForAutoDisable(_ projectID: UUID) -> PatchLibraryItem? {
        // The patch list is not retained by the store, so the current UI supplies
        // the concrete item through the helper below when scheduling is refreshed.
        currentItems.first { $0.id == projectID }
    }

    private var currentItems: [PatchLibraryItem] = []

    func updateAutoDisableItems(_ items: [PatchLibraryItem]) {
        currentItems = items
        refreshAutoDisableSchedules()
        Task { await sendPatchHeartbeat() }
    }

    private func refreshAutoDisableSchedules() {
        autoDisableTasks.values.forEach { $0.cancel() }
        autoDisableTasks.removeAll()

        guard AutoDisablePatchPolicy.defaultEnabled && AppearanceSettings.shared.autoDisablePatches else {
            remainingSeconds.removeAll()
            autoDisableDeadlines.removeAll()
            persistDeadlines()
            return
        }

        for projectID in enabledIDs {
            scheduleAutoDisableIfNeeded(for: projectID)
        }
    }

    private func failToggle(projectID: UUID, message: String) {
        busyIDs.remove(projectID)
        errorMessage = message
    }

    deinit {
        autoDisableTasks.values.forEach { $0.cancel() }
        if let observer = autoDisableSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = patchPolicyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = webPatchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = webPatchIDsDisabledObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = webPatchIDsEnabledObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func persistDeadlines() {
        let encoded = autoDisableDeadlines.reduce(into: [String: Double]()) { result, pair in
            result[pair.key.uuidString] = pair.value.timeIntervalSince1970
        }
        UserDefaults.standard.set(encoded, forKey: deadlinesStorageKey)
    }

    private static func loadDeadlines() -> [UUID: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: "PatchProjects.autoDisableDeadlines.v1") as? [String: Double] else {
            return [:]
        }
        return raw.reduce(into: [UUID: Date]()) { result, pair in
            if let id = UUID(uuidString: pair.key) {
                result[id] = Date(timeIntervalSince1970: pair.value)
            }
        }
    }

    private func persist() {
        UserDefaults.standard.set(
            enabledIDs.map(\.uuidString).sorted(),
            forKey: storageKey
        )
    }
}

// MARK: - Patch function info

private enum PatchInfoTopic: Identifiable {
    case function(PatchType)
    case patch(PatchType)

    var id: String {
        switch self {
        case .function(let type): return "function-\(type.rawValue)"
        case .patch(let type): return "patch-\(type.rawValue)"
        }
    }

    var type: PatchType {
        switch self {
        case .function(let type), .patch(let type): return type
        }
    }

    var titleKey: String {
        switch self {
        case .function: return "patch.info.function.title"
        case .patch: return "patch.info.patch.title"
        }
    }

    var descriptionKey: String {
        switch self {
        case .function(let type):
            switch type {
            case .aim: return "patch.info.aim.description"
            case .holo: return "patch.info.holo.description"
            case .mod: return "patch.info.mod.description"
            case .menu: return "patch.info.menu.description"
            }
        case .patch(let type):
            switch type {
            case .aim: return "patch.info.aim.toggle"
            case .holo: return "patch.info.holo.toggle"
            case .mod: return "patch.info.mod.toggle"
            case .menu: return "patch.info.menu.toggle"
            }
        }
    }
}

private struct PatchFunctionInfoSheet: View {
    let topic: PatchInfoTopic
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(appearance.resolvedAppButtonColor)
                    Text(language.text(topic.titleKey, topic.type.rawValue.uppercased()))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Button(language.text("common.close")) { dismiss() }
                        .buttonStyle(.bordered)
                        .tint(appearance.resolvedAppButtonColor)
                }

                Text(language.text(topic.descriptionKey))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Image(systemName: "hand.tap.fill")
                        .foregroundStyle(appearance.resolvedAppButtonColor)
                    Text(language.text("patch.info.badge_note"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(12)
                .background(
                    Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.clear, lineWidth: 0)
                }

                Spacer()
            }
            .padding(20)
        }
    }
}

// MARK: - App grouping

struct PatchAppGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIdentifiers: [String]
    let items: [PatchLibraryItem]
    let kind: PatchAppKind

    var packageNames: [String] {
        items.map { $0.packageURL.lastPathComponent }
    }

    /// Function channels are a dedicated UI concept for FFM/FFTH and any app
    /// whose remote patch metadata explicitly assigns a supported category.
    var aimItems: [PatchLibraryItem] {
        return items.filter { PatchAppGrouping.patchType(for: $0) == .aim }
    }

    var holoItems: [PatchLibraryItem] {
        return items.filter { PatchAppGrouping.patchType(for: $0) == .holo }
    }

    var modItems: [PatchLibraryItem] {
        return items.filter { PatchAppGrouping.patchType(for: $0) == .mod }
    }

    var menuItems: [PatchLibraryItem] {
        return items.filter { PatchAppGrouping.patchType(for: $0) == .menu }
    }

    var primaryBundleID: String? { bundleIdentifiers.first }

    static func == (lhs: PatchAppGroup, rhs: PatchAppGroup) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum PatchAppKind: String, CaseIterable {
    case ffm
    case ffth
    case capcut
    case pubg
    case lienQuan
    case locket
    case other

    var displayName: String {
        switch self {
        case .ffm: return "FFM"
        case .ffth: return "FFTH"
        case .capcut: return "CAPCUT"
        case .pubg: return "PUBG"
        case .lienQuan: return "LIÊN QUÂN"
        case .locket: return "LOCKET"
        case .other: return "Khác"
        }
    }

    var defaultBundleID: String? {
        switch self {
        case .ffm: return "com.dts.freefiremax"
        case .ffth: return "com.dts.freefireth"
        case .capcut: return "com.lemon.lvoverseas"
        case .pubg: return "com.tencent.ig"
        case .lienQuan: return "com.garena.game.kgvn"
        case .locket: return "com.locket.Locket"
        case .other: return nil
        }
    }
}

enum PatchAppGrouping {
    private static let predefined: [(kind: PatchAppKind, name: String)] = [
        (.ffm, "FFM"),
        (.ffth, "FFTH"),
        (.capcut, "CAPCUT"),
        (.pubg, "PUBG"),
        (.lienQuan, "LIÊN QUÂN"),
        (.locket, "LOCKET")
    ]

    static func makeGroups(from items: [PatchLibraryItem]) -> [PatchAppGroup] {
        var buckets: [String: [PatchLibraryItem]] = [:]
        var kinds: [String: PatchAppKind] = [:]
        var names: [String: String] = [:]
        var bundles: [String: [String]] = [:]

        // Always create the requested top-level buttons, even before a patch exists.
        for (kind, name) in predefined {
            let key = key(for: kind)
            buckets[key] = []
            kinds[key] = kind
            names[key] = name
            if let bundleID = kind.defaultBundleID {
                bundles[key] = [bundleID]
            }
        }

        for item in items {
            let raw = classificationName(for: item)
            let target = PatchDisplayNameStore.metadata(for: item)?.appTarget ?? ""
            let kind = classifyKind(target.isEmpty ? raw : target)
            let groupKey: String

            switch kind {
            case .ffm: groupKey = key(for: .ffm)
            case .ffth: groupKey = key(for: .ffth)
            case .capcut: groupKey = key(for: .capcut)
            case .pubg: groupKey = key(for: .pubg)
            case .lienQuan: groupKey = key(for: .lienQuan)
            case .locket: groupKey = key(for: .locket)
            case .other:
                groupKey = canonicalOtherKey(target.isEmpty ? raw : target)
            }

            buckets[groupKey, default: []].append(item)
            kinds[groupKey] = kind

            if names[groupKey] == nil {
                names[groupKey] = target.isEmpty ? displayName(for: raw, item: item) : target
            }

            for bundleID in item.project?.allBundleIdentifiers ?? [] where !bundleID.isEmpty {
                if !(bundles[groupKey] ?? []).contains(bundleID) {
                    bundles[groupKey, default: []].append(bundleID)
                }
            }
        }

        return buckets.compactMap { key, groupedItems in
            guard let kind = kinds[key], let name = names[key] else { return nil }
            let sortedItems = groupedItems.sorted {
                let leftMetadata = PatchDisplayNameStore.metadata(for: $0)
                let rightMetadata = PatchDisplayNameStore.metadata(for: $1)
                let leftOrder = leftMetadata?.sortOrder ?? 0
                let rightOrder = rightMetadata?.sortOrder ?? 0
                if leftOrder != rightOrder { return leftOrder < rightOrder }

                // Match Web Admin/API tie-breaking: server patch ID ascending.
                // Only use the display name as a fallback for legacy local patches
                // that have no numeric server ID.
                let leftID = Int(leftMetadata?.patchID ?? "") ?? Int.max
                let rightID = Int(rightMetadata?.patchID ?? "") ?? Int.max
                if leftID != rightID { return leftID < rightID }
                return PatchAppGrouping.displayName(for: $0).localizedCaseInsensitiveCompare(
                    PatchAppGrouping.displayName(for: $1)
                ) == .orderedAscending
            }

            return PatchAppGroup(
                id: key,
                name: name,
                bundleIdentifiers: bundles[key] ?? [],
                items: sortedItems,
                kind: kind
            )
        }
        .sorted { lhs, rhs in
            let order: [PatchAppKind] = [.ffm, .ffth, .capcut, .pubg, .lienQuan, .locket, .other]
            let li = order.firstIndex(of: lhs.kind) ?? order.count
            let ri = order.firstIndex(of: rhs.kind) ?? order.count
            if li != ri { return li < ri }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func displayName(for item: PatchLibraryItem) -> String {
        if let remote = PatchDisplayNameStore.metadata(for: item),
           !remote.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return remote.displayName
        }
        return item.project?.name ?? item.packageURL.deletingPathExtension().lastPathComponent
    }

    static func patchType(for item: PatchLibraryItem) -> PatchType {
        if let category = PatchDisplayNameStore.metadata(for: item)?.category {
            switch category.uppercased() {
            case "AIM": return .aim
            case "HOLO": return .holo
            case "MOD": return .mod
            case "MENU": return .menu
            default: break
            }
        }
        return PatchType.classify(classificationName(for: item))
    }

    static func classificationName(for item: PatchLibraryItem) -> String {
        if let remote = PatchDisplayNameStore.metadata(for: item) {
            let function = remote.functionName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !function.isEmpty { return function }
            if !remote.displayName.isEmpty { return remote.displayName }
        }
        let project = item.project?.name ?? ""
        let filename = item.packageURL.deletingPathExtension().lastPathComponent
        return project.isEmpty ? filename : "\(project) \(filename)"
    }

    private static func classifyKind(_ raw: String) -> PatchAppKind {
        let compact = normalizedCompact(raw)

        // FFTH and FFM are intentionally checked separately and never merged.
        if containsToken(compact, token: "ffth") { return .ffth }
        if containsToken(compact, token: "ffm") { return .ffm }
        if compact.contains("capcut") { return .capcut }
        if compact.contains("pubg") { return .pubg }
        if compact.contains("lienquan") { return .lienQuan }
        if compact.contains("locket") { return .locket }
        return .other
    }

    private static func canonicalOtherKey(_ value: String) -> String {
        let normalized = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter {
                !["aim", "holo", "mod", "patch", "3105"].contains($0.lowercased())
            }

        let result = normalized.joined(separator: " ").lowercased()
        return result.isEmpty ? "other" : "other-\(result)"
    }

    private static func key(for kind: PatchAppKind) -> String {
        "system-\(kind.rawValue)"
    }

    private static func normalizedCompact(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "")
            .lowercased()
    }

    private static func containsToken(_ compact: String, token: String) -> Bool {
        compact.contains(token)
    }

    private static func displayName(for raw: String, item: PatchLibraryItem) -> String {
        switch classifyKind(raw) {
        case .ffm: return "FFM"
        case .ffth: return "FFTH"
        case .capcut: return "CAPCUT"
        case .pubg: return "PUBG"
        case .lienQuan: return "LIÊN QUÂN"
        case .locket: return "LOCKET"
        case .other:
            if let name = item.project?.name,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
            return item.packageURL.deletingPathExtension().lastPathComponent
        }
    }
}

// MARK: - App card

private struct PatchAppCard: View {
    private static let locketCoverPageURL = "https://ibb.co/8Lq2Dmd8"
    private static let locketCoverImageURL = "https://i.ibb.co/pBcZv1RX/IMG-8870.jpg"

    let group: PatchAppGroup
    @ObservedObject var appearance: AppearanceSettings

    @ViewBuilder
    private var appCardIcon: some View {
        if group.kind == .locket {
            if let localURL = DynamicAssetRouter.assetURL(for: "system-locket") {
                AsyncImage(url: localURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            } else if let url = URL(string: Self.locketCoverImageURL) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            } else {
                Image(systemName: "heart.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
        } else {
            InstalledAppIconView(bundleID: group.primaryBundleID)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            appCardIcon
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.clear, lineWidth: 0)
                }
                .shadow(color: appearance.resolvedAppButtonColor.opacity(0.16), radius: 12, y: 5)
                .appLaunchIconGlow()

            Text(group.name)
                .font(.system(size: 13, weight: appearance.fontWeight.swiftUI, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

        }
                .frame(
            minWidth: 160,
            idealWidth: 174,
            maxWidth: 180,
            minHeight: 160,
            idealHeight: 174,
            maxHeight: 180
        )
        .padding(10)
        .background(cardBackground)
        .overlay(cardBorder)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Color.black.opacity(0.28), radius: 12, y: 5)
        .opacity(appearance.globalOpacity)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        appearance.resolvedAppButtonColor.opacity(0.08),
                        Color.black.opacity(max(appearance.cardFillOpacity, 0.58)),
                        Color.black.opacity(0.78)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .stroke(
                Color.white.opacity(0.72),
                lineWidth: 1.2
            )
    }


}

private struct InstalledAppIconView: View {
    let bundleID: String?
    @ObservedObject private var appearance = AppearanceSettings.shared

    private var suppliedIconURL: URL? {
        guard let bundleID else { return nil }

        switch bundleID {
        case "com.dts.freefireth":
            return URL(string: "https://i.ibb.co/27CQSgHV/IMG-8638.png")
        case "com.dts.freefiremax":
            return URL(string: "https://i.ibb.co/jZMDVKPs/IMG-8637.png")
        case "com.lemon.lvoverseas":
            return URL(string: "https://i.ibb.co/Gv6DThXB/IMG-8639.jpg")
        case "com.tencent.ig":
            return URL(string: "https://i.ibb.co/5Xvm4Nc6/IMG-8640.jpg")
        case "com.garena.game.kgvn":
            return URL(string: "https://i.ibb.co/3mr8wR8m/IMG-8641.jpg")
        default:
            return nil
        }
    }

    @ViewBuilder
    private var fallbackIcon: some View {
        if let bundleID, let image = iconForBundleID(bundleID) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        appearance.resolvedAppButtonColor.opacity(0.28),
                        Color.black.opacity(0.50)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "app.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
            }
        }
    }

    private var cachedIconURL: URL? {
        guard let bundleID else { return nil }
        switch bundleID {
        case "com.dts.freefireth": return AssetPreloadService.cachedURL(key: "icon.ffth")
        case "com.dts.freefiremax": return AssetPreloadService.cachedURL(key: "icon.ffm")
        case "com.lemon.lvoverseas": return AssetPreloadService.cachedURL(key: "icon.capcut")
        case "com.tencent.ig": return AssetPreloadService.cachedURL(key: "icon.pubg")
        case "com.garena.game.kgvn": return AssetPreloadService.cachedURL(key: "icon.lienquan")
        default: return nil
        }
    }

    var body: some View {
        Group {
            if let cachedIconURL {
                Image(uiImage: UIImage(contentsOfFile: cachedIconURL.path) ?? UIImage())
                    .resizable()
                    .scaledToFill()
            } else if let suppliedIconURL {
                AsyncImage(url: suppliedIconURL, transaction: Transaction(animation: .easeOut(duration: 0.20))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        fallbackIcon
                    case .empty:
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(appearance.resolvedAppButtonColor.opacity(0.12))
                            ProgressView()
                                .tint(appearance.resolvedAppButtonColor)
                                .scaleEffect(0.75)
                        }
                    @unknown default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .clipped()
        .accessibilityLabel(bundleID ?? "Application icon")
    }
}

// MARK: - App detail

private struct PatchAppDetailView: View {
    let group: PatchAppGroup
    @ObservedObject var appearance: AppearanceSettings
    @ObservedObject var patchState: PatchToggleStore
    @ObservedObject private var autoPatch = AutoPatchEngine.shared
    @ObservedObject private var runtimeContent = RuntimeContentService.shared
    @Namespace private var selectorNamespace
    @ObservedObject private var functionSettings = PatchFunctionSettings.shared
    @Environment(\.appLanguage) private var language
    @State private var selectedType: PatchType = .mod
    @State private var openResult: String?
    @State private var infoTopic: PatchInfoTopic?
    @State private var dotRefreshID = UUID()
    @Environment(\.scenePhase) private var scenePhase

    /// FFM/FFTH expose the four function channels. Other applications expose
    /// the channel selector only when patch metadata assigns a known category.
    private var usesFunctionChannels: Bool {
        if group.kind == .ffm || group.kind == .ffth { return true }
        return group.items.contains {
            let category = PatchDisplayNameStore.metadata(for: $0)?.category.uppercased() ?? ""
            return ["MOD", "HOLO", "AIM", "MENU"].contains(category)
        }
    }

    private var selectedItems: [PatchLibraryItem] {
        // REQ 4: .other always shows all its patches — they are fully toggleable.
        // FFM/FFTH use the MOD/HOLO/AIM/MENU channel filter.
        // All other known apps (CAPCUT, PUBG, LIÊN QUÂN) expose patches directly.
        guard usesFunctionChannels else { return group.items }
        switch selectedType {
        case .mod:  return group.modItems
        case .holo: return group.holoItems
        case .aim:  return group.aimItems
        case .menu: return group.menuItems
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // No opaque panel is painted behind the patch detail; the same
            // GlobalBackground continues underneath every patch surface.
            GlobalBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader
                    if usesFunctionChannels {
                        typeSelector
                    }
                    patchUtilityButtons
                    requirementsSection
                }
                .padding(16)
                .padding(.bottom, 92)
            }

            openAppBar
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .zIndex(100)
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $infoTopic) { topic in
            PatchFunctionInfoSheet(topic: topic)
                .presentationDetents([.height(330), .medium])
                .presentationDragIndicator(.visible)
        }
        .alert("Không thể mở ứng dụng", isPresented: Binding(
            get: { openResult != nil },
            set: { if !$0 { openResult = nil } }
        )) {
            Button("OK", role: .cancel) { openResult = nil }
        } message: {
            Text(openResult ?? "Ứng dụng chưa được cài đặt hoặc không thể mở.")
        }
        .task {
            patchState.reconcile(group.items)
            // Ensure workspace folders exist so dot shows green for OFF patches.
            OriginalFileCollector.collectNow()
            dotRefreshID = UUID()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                dotRefreshID = UUID()
                patchState.reconcile(group.items)
            }
        }
        .alert("Không thể thay đổi patch", isPresented: Binding(
            get: { patchState.errorMessage != nil },
            set: { if !$0 { patchState.clearError() } }
        )) {
            Button("OK", role: .cancel) { patchState.clearError() }
        } message: {
            Text(patchState.errorMessage ?? "Không thể thay đổi trạng thái patch.")
        }
    }

    private var patchUtilityButtons: some View {
        HStack(spacing: 6) {
            runtimeLinkButton(
                title: runtimeContent.patchRuntimeConfig.dnsButtonText,
                urlString: runtimeContent.patchRuntimeConfig.dnsLink,
                systemImage: "network"
            )
            runtimeLinkButton(
                title: runtimeContent.patchRuntimeConfig.videoButtonText,
                urlString: runtimeContent.patchRuntimeConfig.videoLink,
                systemImage: "play.rectangle.fill"
            )
        }
    }

    @ViewBuilder
    private func runtimeLinkButton(title: String, urlString: String, systemImage: String) -> some View {
        if let url = URL(string: urlString),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           url.host != nil {
            Button {
                UIApplication.shared.open(url)
            } label: {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.88))
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
            }
        }
    }

    private var detailHeader: some View {
        // REQ 4: .other kind gets a dedicated "Khác" tech icon instead of an app icon
        let isOther = group.kind == .other
        let otherAccent = Color(red: 1.0, green: 0.72, blue: 0.10)  // amber gold for "Khác"
        let cr = appearance.appButtonStyle.cornerRadius(appearance.cardCornerRadius)

        return HStack(spacing: 14) {
            if isOther {
                // Tech icon for the "Khác" / unknown patch bucket
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [otherAccent.opacity(0.30), otherAccent.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(otherAccent)
                        .shadow(color: otherAccent.opacity(0.60), radius: 10)
                }
                .frame(width: 74, height: 74)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.clear, lineWidth: 0)
                }
                .shadow(color: otherAccent.opacity(0.30), radius: 12, y: 4)
            } else {
                InstalledAppIconView(bundleID: group.primaryBundleID)
                    .frame(width: 74, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.clear, lineWidth: 0)
                    }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(group.name)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                if isOther {
                    // REQ 4: Explain the "Khác" bucket
                    Text("Patch không xác định loại")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(otherAccent.opacity(0.72))
                        .lineLimit(1)
                } else if let bundle = group.primaryBundleID {
                    Text(bundle)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }

                Text(group.items.isEmpty ? "Chưa có patch" : "\(group.items.count) patch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOther ? otherAccent : appearance.resolvedAppButtonColor)
            }
            Spacer()
        }
        .padding(14)
        .background(
            Color.white.opacity(0.045),
            in: RoundedRectangle(cornerRadius: cr, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cr, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        }
    }

    // MARK: - Connected MOD / HOLO / AIM / MENU selector

    private var typeSelector: some View {
        HStack(spacing: 8) {
            ForEach(PatchType.allCases) { type in
                typeSelectorButton(for: type)
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.30))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(appearance.resolvedAppButtonColor.opacity(0.24), lineWidth: 0.8)
        }
        .shadow(color: appearance.resolvedAppButtonColor.opacity(0.14), radius: 14, y: 6)
    }

    private func typeIconName(_ type: PatchType) -> String {
        switch type {
        case .mod:  return "wrench.adjustable.fill"
        case .holo: return "dot.radiowaves.up.forward"
        case .aim:  return "scope"
        case .menu: return "slider.horizontal.3"
        }
    }

    @ViewBuilder
    private func typeSelectorButton(for type: PatchType) -> some View {
        let isSelected = selectedType == type
        let accent = AppTheme.aimHoloBlue
        let visualOpacity = functionSettings.opacity(for: type) * appearance.functionSelectorOpacity

        Button {
            withAnimation(
                appearance.animationsEnabled
                    ? .spring(response: 0.24 * appearance.animationDurationMultiplier, dampingFraction: 0.82)
                    : nil
            ) {
                selectedType = type
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: typeIconName(type))
                    .font(.system(size: 12, weight: .bold))
                Text(RuntimeContentService.shared.patchRuntimeConfig.categoryName(for: type.rawValue).uppercased())
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .tracking(0.55)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(
                        isSelected
                            ? accent.opacity(0.88)
                            : Color.white.opacity(0.055)
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(
                        isSelected
                            ? accent.opacity(0.72)
                            : Color.white.opacity(0.12),
                        lineWidth: isSelected ? 1.0 : 0.7
                    )
            }
            .shadow(
                color: isSelected ? accent.opacity(0.32) : .clear,
                radius: 10
            )
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(visualOpacity)
        .scaleEffect(isSelected ? 1.0 : 0.985)
        .accessibilityLabel(type.rawValue)
    }

    private var requirementsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.075)))

                Text("Menu Patch")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(.white)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.075),
                                Color.black.opacity(0.52)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.28), radius: 8, y: 4)

            if selectedItems.isEmpty {
                Text(
                    usesFunctionChannels
                        ? "Chưa có patch \(selectedType.rawValue) cho \(group.name)."
                        : "Chưa có patch cho \(group.name)."
                )
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.50))
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 7) {
                    ForEach(selectedItems) { item in
                        patchRequirementRow(item)
                            .id("\(item.id.uuidString)-\(dotRefreshID.uuidString)")
                    }
                }
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.24))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.7)
                }
            }
        }
    }

    // MARK: - Patch status dot color (hex-based, no cache)
    //
    // Màu được xác định bằng cách so sánh SHA-256 thực tế của file game với
    // digest đã ghi trong journal — KHÔNG dùng journal status hay @State cache.
    // Gọi lại mỗi khi toggle thay đổi hoặc app foreground.
    //
    // 🟡 VÀNG       : bytes file game == replacementDigest (aim/mod đang chạy)
    // 🟢 XANH LÁ   : bytes file game == originalDigest VÀ backup còn nguyên
    //                 (hoặc lần đầu vào app: chưa patch, workspace folder tồn tại)
    // 🔴 ĐỎ         : backup bị xóa ngoài app, bytes lạ, hoặc lỗi đọc file
    /// Nguồn sự thật duy nhất cho màu và nhãn của chấm trạng thái patch.
    /// Gọi DevicePatchService.fileState() một lần duy nhất (SHA-256 thực tế từ disk).
    ///
    /// Mapping:
    ///   .patched            → 🟡 vàng  / "Đã thay thế patch"
    ///   .original           → 🟢 xanh  / "Đã thay thế patch gốc"  (gồm cả lần đầu vào app)
    ///   .backupMissing      → 🔴 đỏ   / "File patch đã bị xoá"
    ///   .inconsistent       → 🔴 đỏ   / "File patch đã bị xoá"
    private func patchStatusDot(for item: PatchLibraryItem) -> (color: Color, label: String) {
        switch DevicePatchService.fileState(projectID: item.id) {
        case .patched:
            // 🟡 Patch đang hoạt động — file game chứa bytes mod
            return (.yellow, "Đang patch")
        case .original:
            // 🟢 File gốc — chưa patch hoặc đã restore thành công
            return (.green, "Chưa patch")
        case .backupMissing:
            // 🔴 Backup bị xoá ngoài app — không thể restore
            return (.red, "Mất backup")
        case .inconsistent:
            // 🔴 Bytes không khớp — file bị chỉnh sửa ngoài app
            return (.red, "Lỗi file")
        }
    }

    private func patchRequirementRow(_ item: PatchLibraryItem) -> some View {
        let busy = patchState.isBusy(item)
        let enabled = patchState.isEnabled(item)
        let itemType = PatchAppGrouping.patchType(for: item)
        let visualOpacity = functionSettings.opacity(for: itemType)
        let (dotColor, dotLabel) = patchStatusDot(for: item)

        return HStack(spacing: 9) {
            Image(systemName: item.isLocked ? "lock.doc.fill" : "bolt.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(appearance.resolvedAppButtonColor)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(PatchAppGrouping.displayName(for: item))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(
                    busy ? "Đang xử lý…" :
                    enabled ? "Đang bật" : "Đang tắt"
                )
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(
                    busy ? appearance.resolvedAppButtonColor :
                    enabled ? appearance.resolvedAppButtonColor : .white.opacity(0.40)
                )
            }

            Spacer(minLength: 4)

            if AutoDisablePatchPolicy.defaultEnabled && appearance.autoDisablePatches && enabled,
               let remaining = patchState.remainingSeconds[item.id] {
                Text("\(remaining)s")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle((Color(hex: appearance.patchCountdownColorHex) ?? appearance.resolvedAppButtonColor)
                        .opacity(appearance.patchCountdownOpacity))
            }

            // ── Status dot + label — hiển thị ngay bên cạnh Toggle ──
            // Label + màu phản ánh fileState() thực tế (SHA-256), không dùng cache hay journal.
            // • "Đã thay thế patch"      → 🟡 .patched      (file game chứa bytes của patch)
            // • "Đã thay thế patch gốc" → 🟢 .original     (file gốc đang hiện diện, kể cả lần đầu vào app)
            // • "File patch đã bị xoá"  → 🔴 .backupMissing / .inconsistent
            VStack(spacing: 2) {
                Text(dotLabel)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(dotColor)
                    .lineLimit(1)
                    .fixedSize()
                    .animation(.easeInOut(duration: 0.25), value: dotLabel)

                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: dotColor.opacity(0.70), radius: 4)
                    .animation(.easeInOut(duration: 0.25), value: dotColor)
            }

            ZStack {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { enabled },
                        set: { patchState.setEnabled($0, for: item) }
                    )
                )
                .labelsHidden()
                .tint(appearance.resolvedAppButtonColor)
                .disabled(item.isLocked || busy || patchState.patchAccessBlocked)

                if busy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(appearance.resolvedAppButtonColor)
                        .scaleEffect(0.65)
                }
            }
            .frame(width: 42, height: 28)
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 43)
        .background(Color.clear)
        .opacity(0.35 + (0.65 * visualOpacity))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(height: 0.6)
                .padding(.leading, 44)
        }
    }

    private var openAppBar: some View {
        Button {
            guard let bundleID = group.primaryBundleID,
                  !bundleID.isEmpty else {
                openResult = "Chức năng này chưa có package identifier của ứng dụng đích."
                return
            }

            guard openApplicationForBundleID(bundleID) else {
                openResult = "Ứng dụng chưa được cài đặt hoặc LaunchServices không thể mở package này."
                FluxStatusNotificationCenter.shared.post(
                    title: "App launch failed",
                    detail: group.name,
                    isOn: false
                )
                return
            }

            FluxStatusNotificationCenter.shared.post(
                title: "App launched",
                detail: group.name,
                isOn: true
            )
        } label: {
            ZStack {
                // Keep the action label centered. Loading state is intentionally
                // not rendered inside this button.
                HStack(spacing: 9) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .black))
                    Text(" Mở Ứng Dụng ")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .tracking(1.0)
                }
                .frame(maxWidth: .infinity, alignment: .center)

                HStack {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .opacity(0.65)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.02, green: 0.42, blue: 0.92))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.18, green: 0.58, blue: 1.0).opacity(0.96),
                                        Color(red: 0.02, green: 0.42, blue: 0.92).opacity(0.98),
                                        Color(red: 0.00, green: 0.28, blue: 0.72).opacity(1.0)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
            )
            .overlay {
                // Keep the action surface clean: no visible border. The glow is
                // rendered outside the surface as a soft shadow below.
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.clear, lineWidth: 0)
            }
            .shadow(
                color: appearance.appButtonGlowEnabled
                    ? (Color(hex: appearance.appButtonGlowColorHex) ?? appearance.resolvedAppButtonColor)
                        .opacity(0.58 * appearance.appButtonGlowIntensity)
                    : .clear,
                radius: appearance.appButtonGlowEnabled
                    ? CGFloat(appearance.appButtonGlowRadius)
                    : 0,
                y: 5
            )
            .shadow(color: .black.opacity(0.50), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("Mở ứng dụng")
        .animation(.easeInOut(duration: 0.18), value: group.id)
    }

    private func count(for type: PatchType) -> Int {
        switch type {
        case .mod: return group.modItems.count
        case .holo: return group.holoItems.count
        case .aim: return group.aimItems.count
        case .menu: return group.menuItems.count
        }
    }
}

// MARK: - Grid background
// Uses the shared GridBackgroundView declared in ContentView.swift.

// MARK: - Unlock view (unchanged)

private struct PatchUnlockView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PatchProjectStore
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(language.text("patch.password"), text: $password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .onSubmit(unlock)
                        .onChange(of: password) { _ in store.clearUnlockError() }
                    if let errorKey = store.unlockErrorKey {
                        Text(language.text(errorKey))
                            .font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text(language.text("patch.password_once_message"))
                }
            }
            .navigationTitle(language.text("patch.unlock"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("patch.unlock"), action: unlock)
                        .disabled(password.isEmpty || store.isBusy)
                }
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        store.unlock(password: password)
    }
}

// MARK: - Patch Detail View (unchanged)

private struct PatchProjectDetailView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: PatchProjectStore
    let projectID: UUID
    @State private var showApplyConfirmation = false
    @State private var showRestoreConfirmation = false
    @State private var isWorking = false
    @State private var actionAlert: PatchStoreAlert?
    /// Đồng bộ từ KeyAuthManager.fetchWebPatchState() qua UserDefaults.
    /// false = web admin đã tắt chức năng apply patch cho key/thiết bị này.
    @AppStorage("web_patch_apply_enabled") private var patchApplyEnabled: Bool = true

    private var item: PatchLibraryItem? { store.items.first(where: { $0.id == projectID }) }
    private var receipt: PatchTransactionReceipt? { DevicePatchService.latestReceipt(projectID: projectID) }

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.07).ignoresSafeArea()
            GridBackgroundView(spacing: 25, lineColor: Color.white.opacity(0.04)).ignoresSafeArea()

            List {
                if let item, let project = item.project {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox.fill")
                                .font(.system(size: 20)).foregroundColor(.cyan)
                                .frame(width: 32, height: 32)
                                .background(Color.cyan.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                    .font(.body.weight(.semibold)).foregroundColor(.white)
                                Text(item.summary.isPasswordProtected
                                     ? language.text("patch.password_locked")
                                     : language.text("patch.no_password"))
                                    .font(.caption).foregroundColor(.gray)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color(red: 0.12, green: 0.12, blue: 0.18).opacity(0.4))

                    Section {
                        // Banner khi admin tắt patch qua web dashboard
                        if !patchApplyEnabled {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.shield.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.orange)
                                Text("Patch đang bị khóa bởi Admin")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.orange)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }

                        Button { showApplyConfirmation = true } label: {
                            HStack {
                                Label("Áp Dụng Patch", systemImage: "checkmark.shield.fill")
                                    .foregroundStyle(patchApplyEnabled
                                        ? LinearGradient(
                                            colors: [Color(red: 0.3, green: 1.0, blue: 0.55), Color.green],
                                            startPoint: .leading, endPoint: .trailing)
                                        : LinearGradient(
                                            colors: [Color.gray.opacity(0.5), Color.gray.opacity(0.4)],
                                            startPoint: .leading, endPoint: .trailing))
                                Spacer()
                                if isWorking {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.green)
                                        .scaleEffect(0.8)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(isWorking || !patchApplyEnabled)

                        Button(role: .destructive) { showRestoreConfirmation = true } label: {
                            Label("Khôi Phục File Gốc", systemImage: "arrow.uturn.backward.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(isWorking || receipt == nil)
                    } header: {
                        Text("Hành Động")
                    }
                    .listRowBackground(Color(red: 0.12, green: 0.12, blue: 0.18).opacity(0.4))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(item?.project?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Xác nhận Kích Hoạt", isPresented: $showApplyConfirmation, titleVisibility: .visible) {
            Button("Kích Hoạt") { apply() }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("patch.apply_confirm_message"))
        }
        .confirmationDialog("Xác nhận Khôi Phục", isPresented: $showRestoreConfirmation, titleVisibility: .visible) {
            Button("Khôi Phục", role: .destructive) { restore() }
            Button(language.text("common.cancel"), role: .cancel) {}
        }
        .alert(item: $actionAlert) { alert in
            Alert(
                title: Text(language.text(alert.titleKey)),
                message: Text(language.text(alert.message(language: language))),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
    }

    private func apply() {
        guard patchApplyEnabled else {
            actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.apply")
            return
        }
        guard let item, let baseProject = item.project else { return }
        isWorking = true
        Task(priority: .userInitiated) {
            do {
                let project = item.summary.schemaVersion >= 2
                    ? try PatchProjectLibrary.synchronizeWorkspace(item: item)
                    : baseProject
                _ = try DevicePatchService.apply(project: project)
                await MainActor.run {
                    store.reload()
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.applied_message")
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: error.localizationKey,
                        messageArgument: error.localizationArgument
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.apply")
                }
            }
        }
    }

    private func restore() {
        guard let receipt else { return }
        isWorking = true
        Task(priority: .userInitiated) {
            do {
                try DevicePatchService.restore(receipt: receipt)
                await MainActor.run {
                    store.reload()
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.restored_message")
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: error.localizationKey,
                        messageArgument: error.localizationArgument
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore")
                }
            }
        }
    }
}
