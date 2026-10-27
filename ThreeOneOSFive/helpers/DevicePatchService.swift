import Foundation

/// License-time policy for patch operations.
/// A lifetime key (timestamp == 0) is unrestricted. For expiring keys,
/// patch creation/enablement is blocked when <= 1 hour remains, and all
/// active transactions are restored best-effort.
enum PatchAccessPolicy {
    static let changedNotification = Notification.Name("FluxCorePatchAccessPolicyChanged")
    static let warningWindow: TimeInterval = 3600

    static func remainingSeconds(now: Date = Date()) -> TimeInterval? {
        let timestamp = UserDefaults.standard.double(forKey: "key_expiry_timestamp")
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp).timeIntervalSince(now)
    }

    static func blocksNewPatches(now: Date = Date()) -> Bool {
        guard let remaining = remainingSeconds(now: now) else { return false }
        return remaining <= warningWindow
    }

    /// Single source of truth for every patch-enable entry point.
    /// UI checks are useful feedback, but this guard also protects direct
    /// service callers from enabling a patch inside the warning window.
    static func canEnablePatch(now: Date = Date()) -> Bool {
        !blocksNewPatches(now: now)
    }

    @discardableResult
    static func enforce() -> (restored: Set<UUID>, failed: Set<UUID>) {
        guard blocksNewPatches() else { return ([], []) }
        let result = DevicePatchService.restoreAllActivePatches()
        NotificationCenter.default.post(name: changedNotification, object: nil)
        return result
    }
}


enum DevicePatchService {
    static func apply(project: PatchProject) throws -> PatchTransactionReceipt {
        guard PatchAccessPolicy.canEnablePatch() else {
            // Enforce immediately so any active transaction is restored even
            // when this method is reached without going through the toggle UI.
            _ = PatchAccessPolicy.enforce()
            throw PatchPackageError.applyFailed
        }

        let bundleIDs = orderedBundleIdentifiers(in: project)
        return try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.apply(
                project: project,
                backupRoot: try PatchProjectLibrary.backupRootURL(),
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func restore(receipt: PatchTransactionReceipt) throws {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            // PatchTransaction.restore() is the ONLY correct restore path:
            // - originalExisted=true  → atomicCopy backup → target (phục hồi file gốc game, KHÔNG xóa)
            // - originalExisted=false → removeItem(target) (xóa file patch, vì không có file gốc trước đó)
            // deletePatchedTargets() chỉ XÓA file — không bao giờ phục hồi file gốc,
            // không được dùng làm restore path dù accountProtectionEnabled=true hay false.
            try PatchTransaction.restore(
                receipt: receipt,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func latestReceipt(projectID: UUID) -> PatchTransactionReceipt? {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return nil }
        return PatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot)
    }

    /// Best-effort restore of every currently applied patch transaction.
    /// Failed restores are reported to the caller; no journal is deleted unless
    /// PatchTransaction verified the original state successfully.
    @discardableResult
    static func restoreAllActivePatches() -> (restored: Set<UUID>, failed: Set<UUID>) {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return ([], []) }
        let activeIDs = PatchTransaction.activeProjectIDs(backupRoot: backupRoot)
        var restored = Set<UUID>()
        var failed = Set<UUID>()

        for projectID in activeIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let receipt = PatchTransaction.latestAppliedReceipt(projectID: projectID, backupRoot: backupRoot) else {
                continue
            }
            do {
                try restore(receipt: receipt)
                restored.insert(projectID)
            } catch {
                failed.insert(projectID)
                log("patch-policy: restore failed for \(projectID.uuidString): \(error.localizedDescription)")
            }
        }
        return (restored, failed)
    }

    static func latestAppliedReceipt(projectID: UUID) -> PatchTransactionReceipt? {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return nil }
        return PatchTransaction.latestAppliedReceipt(projectID: projectID, backupRoot: backupRoot)
    }


    /// Restores only active projects that overlap this project's file targets.
    /// This makes activation deterministic: the incoming patch owns a target
    /// before it is applied, while unrelated active patches remain untouched.
    @discardableResult
    static func deactivateConflictingPatches(
        project: PatchProject,
        excludingProjectID: UUID? = nil
    ) throws -> Set<UUID> {
        let backupRoot = try PatchProjectLibrary.backupRootURL()
        var incomingKeys = Set<String>()

        for rule in project.rules {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            let relativePath = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
            incomingKeys.insert(bundleID + "\0" + relativePath)
        }

        let conflictingIDs = PatchTransaction.activeProjectIDs(
            overlapping: incomingKeys,
            backupRoot: backupRoot,
            excludingProjectID: excludingProjectID
        )

        for projectID in conflictingIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let receipt = PatchTransaction.latestAppliedReceipt(
                projectID: projectID,
                backupRoot: backupRoot
            ) else { continue }
            try restore(receipt: receipt)
        }
        return conflictingIDs
    }

    static func validateNoActiveTargetConflict(
        project: PatchProject,
        excludingProjectID: UUID? = nil
    ) throws {
        let backupRoot = try PatchProjectLibrary.backupRootURL()
        let activeTargets = PatchTransaction.activeTargetKeys(
            backupRoot: backupRoot,
            excludingProjectID: excludingProjectID
        )

        for rule in project.rules {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            let relativePath = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
            if activeTargets.contains(bundleID + "\0" + relativePath) {
                throw PatchPackageError.activePatchConflict
            }
        }
    }

    private static func orderedBundleIdentifiers(in project: PatchProject) -> [String] {
        project.allBundleIdentifiers
    }

    // MARK: - Hex-based file state

    /// Xác định trạng thái thực tế của các file game bằng cách so sánh SHA-256.
    /// Không dùng journal status hay @State cache — đọc thẳng từ disk.
    ///
    /// - Returns:
    ///   - `.patched`      → 🟡 Aim/mod đang chạy trong game
    ///   - `.original`     → 🟢 File gốc game đang hiện diện, backup an toàn
    ///   - `.backupMissing`→ 🔴 Backup bị xóa ngoài app, không thể restore
    ///   - `.inconsistent` → 🔴 Bytes không khớp cả hai digest hoặc lỗi đọc
    static func fileState(projectID: UUID) -> PatchFileState {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else {
            // Không có backupRoot → chưa bao giờ patch → original
            return .original
        }

        // Nếu có applied journal → hex compare thực tế
        guard let receipt = PatchTransaction.latestAppliedReceipt(
            projectID: projectID,
            backupRoot: backupRoot
        ) else {
            // Không có applied journal.
            //
            // FIX A: Dùng sự tồn tại của backup folder (backupRoot/UUID/) làm signal
            // thay vì workspace folder hay hasPrefix(UUID) trên tên folder.
            //
            // - backup folder không tồn tại → project chưa bao giờ apply → .original
            // - backup folder tồn tại nhưng không có applied journal
            //   → đã apply rồi restore thành công → .original
            //
            // workspaceURL(projectID:) không dùng được ở đây vì:
            //   · v1 package không tạo workspace → workspaceURL nil dù project an toàn
            //   · hasPrefix(UUID) trên tên display-name folder → luôn false
            //
            let backupFolder = backupRoot.appendingPathComponent(
                projectID.uuidString, isDirectory: true
            )
            let backupFolderExists = FileManager.default.fileExists(
                atPath: backupFolder.path
            )
            // Cả hai trường hợp (chưa apply, và đã restore) đều an toàn → .original
            return backupFolderExists ? .original : .original
        }

        // Lấy bundleIDs từ journal để resolve container roots
        guard let bundleIDs = try? PatchTransaction.requiredBundleIdentifiers(for: receipt) else {
            return .inconsistent
        }

        // FIX B: containerFingerprint thay đổi sau khi app game được update/reinstall.
        // PatchTransaction.fileState() so sánh fingerprint cũ (lưu trong journal) với fingerprint
        // mới (tính từ path hiện tại) → luôn mismatch → .inconsistent → 🔴 false positive.
        //
        // Giải pháp: resolve container root mới nhất qua ContainerStore, bỏ qua fingerprint guard
        // bằng cách truyền containerResolver trả đúng root — PatchTransaction.fileState() sẽ
        // tự tính fingerprint từ root được truyền vào và so với record.containerFingerprint.
        //
        // Nếu fingerprint vẫn không khớp sau khi resolve lại → container path thực sự thay đổi
        // (app reinstall tạo UUID container mới) → thử resolve lại bằng metadata scan.
        var roots: [String: URL] = [:]
        for bundleID in bundleIDs {
            guard let path = ContainerStore.resolveAppContainerPath(bundleID: bundleID),
                  ContainerStore.isApplicationContainerPath(path) else {
                // Container không tìm thấy → game bị gỡ khỏi thiết bị
                return .inconsistent
            }
            roots[bundleID] = PatchPathValidator.canonicalFileURL(
                URL(fileURLWithPath: path, isDirectory: true)
            )
        }

        let result = PatchTransaction.fileState(
            receipt: receipt,
            containerResolver: { bundleID in
                guard let root = roots[bundleID] else {
                    throw PatchPackageError.targetAppUnavailable(bundleID)
                }
                return root
            }
        )

        // FIX B cont.: Nếu .inconsistent do fingerprint cũ ≠ mới (app updated),
        // thử lại với metadata scan để lấy container path chính xác nhất.
        // Nếu metadata scan cũng trả .inconsistent → bytes thực sự bị thay đổi ngoài app.
        if result == .inconsistent {
            var scannedRoots: [String: URL] = [:]
            var allScanned = true
            for bundleID in bundleIDs {
                if let path = ContainerStore.resolveAppContainerPathByMetadataScan(
                    bundleID: bundleID
                ), ContainerStore.isApplicationContainerPath(path) {
                    scannedRoots[bundleID] = PatchPathValidator.canonicalFileURL(
                        URL(fileURLWithPath: path, isDirectory: true)
                    )
                } else {
                    allScanned = false
                    break
                }
            }
            if allScanned {
                return PatchTransaction.fileState(
                    receipt: receipt,
                    containerResolver: { bundleID in
                        guard let root = scannedRoots[bundleID] else {
                            throw PatchPackageError.targetAppUnavailable(bundleID)
                        }
                        return root
                    }
                )
            }
        }

        return result
    }

    private static func withResolvedContainers<T>(
        bundleIDs: [String],
        operation: ([String: URL]) throws -> T
    ) throws -> T {
        var roots: [String: URL] = [:]

        for bundleID in bundleIDs {
            guard let path = ContainerStore.resolveAppContainerPath(bundleID: bundleID),
                  ContainerStore.isApplicationContainerPath(path) else {
                throw PatchPackageError.targetAppUnavailable(bundleID)
            }
            roots[bundleID] = PatchPathValidator.canonicalFileURL(URL(fileURLWithPath: path, isDirectory: true))
        }
        return try operation(roots)
    }
}
