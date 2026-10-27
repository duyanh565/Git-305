import CryptoKit
import Darwin
import Foundation

struct PatchTransactionReceipt: Equatable, Identifiable {
    let id: UUID
    let projectID: UUID
    let journalURL: URL
}

/// Trạng thái thực tế của các file game do một patch transaction quản lý.
/// Được xác định bằng cách so sánh SHA-256 của file hiện tại với digest đã lưu trong journal.
enum PatchFileState {
    /// Tất cả file đích hiện chứa bytes của aim/mod (replacementDigest) — patch đang BẬT.
    case patched
    /// Tất cả file đích hiện chứa bytes gốc của game (originalDigest),
    /// hoặc file không tồn tại trước khi patch (originalExisted=false) và hiện cũng vắng mặt.
    case original
    /// Có ít nhất một backup bị mất dù originalExisted=true — bị xóa ngoài app,
    /// không thể khôi phục an toàn.
    case backupMissing
    /// Bytes hiện tại không khớp cả hai digest — file bị chỉnh sửa ngoài app hoặc bị hỏng.
    case inconsistent
}

enum PatchTransaction {
    private enum Status: String, Codable {
        case prepared
        case applied
        case rolledBack
        case restored
    }

    private struct Record: Codable {
        let ruleID: UUID
        let bundleID: String
        let relativePath: String
        let containerFingerprint: Data
        let originalExisted: Bool
        let backupFilename: String?
        let originalDigest: Data?
        let replacementDigest: Data
    }

    private struct DirectoryRecord: Codable {
        let bundleID: String
        let relativePath: String
        let containerFingerprint: Data
    }

    private struct Journal: Codable {
        let schemaVersion: Int
        let transactionID: UUID
        let projectID: UUID
        let createdAt: Date
        var status: Status
        let records: [Record]
        let createdDirectories: [DirectoryRecord]?
    }

    private struct ResolvedRule {
        let rule: PatchRule
        let containerRoot: URL
        let target: URL
    }

    private struct ResolvedDirectory {
        let bundleID: String
        let relativePath: String
        let containerRoot: URL
        let target: URL
    }

    private static let schemaVersion = 1
    private static let journalFilename = "journal.plist"

    static func apply(
        project: PatchProject,
        backupRoot: URL,
        containerResolver: (String) throws -> URL,
        beforeWrite: ((Int) throws -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws -> PatchTransactionReceipt {
        guard !project.rules.isEmpty || !project.directories.isEmpty else {
            throw PatchPackageError.invalidProject
        }

        var roots: [String: URL] = [:]
        var resolvedRules: [ResolvedRule] = []
        var resolvedDirectories: [ResolvedDirectory] = []
        var targetKeys = Set<String>()

        func resolvedRoot(for bundleID: String) throws -> URL {
            if let cached = roots[bundleID] { return cached }
            let root = PatchPathValidator.canonicalFileURL(try containerResolver(bundleID))
            roots[bundleID] = root
            return root
        }

        var requestedDirectories = Set<String>()
        for directory in project.directories {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(directory.bundleID)
            guard bundleID == directory.bundleID else { throw PatchPackageError.invalidProject }
            requestedDirectories.insert(bundleID + "\0" + directory.relativePath)
        }
        for rule in project.rules {
            let components = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
                .split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                requestedDirectories.insert(
                    rule.bundleID + "\0" + components.prefix(count).joined(separator: "/")
                )
            }
        }

        for key in requestedDirectories.sorted(by: directoryKeySort) {
            let parts = key.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw PatchPackageError.invalidProject }
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(String(parts[0]))
            let relativePath = try PatchPathValidator.canonicalRelativePath(String(parts[1]))
            let root = try resolvedRoot(for: bundleID)
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: relativePath,
                containerRoot: root
            )
            try validateDirectoryTarget(
                target,
                relativePath: relativePath,
                containerRoot: root,
                fileManager: fileManager
            )
            resolvedDirectories.append(ResolvedDirectory(
                bundleID: bundleID,
                relativePath: relativePath,
                containerRoot: root,
                target: target
            ))
        }

        for rule in project.rules {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            guard bundleID == rule.bundleID else { throw PatchPackageError.invalidProject }
            let root = try resolvedRoot(for: bundleID)
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: rule.relativePath,
                containerRoot: root
            )
            let targetKey = target.path
            guard targetKeys.insert(targetKey).inserted else {
                throw PatchPackageError.duplicateTarget
            }
            try validateFileTarget(
                target,
                relativePath: rule.relativePath,
                containerRoot: root,
                allowMissingParents: true,
                fileManager: fileManager
            )
            resolvedRules.append(ResolvedRule(rule: rule, containerRoot: root, target: target))
        }

        let transactionID = UUID()
        let transactionDirectory = backupRoot
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
            .appendingPathComponent(transactionID.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        } catch {
            throw PatchPackageError.applyFailed
        }

        var records: [Record] = []
        let createdDirectories = resolvedDirectories.compactMap { resolved -> DirectoryRecord? in
            guard !fileManager.fileExists(atPath: resolved.target.path) else { return nil }
            return DirectoryRecord(
                bundleID: resolved.bundleID,
                relativePath: resolved.relativePath,
                containerFingerprint: containerFingerprint(resolved.containerRoot)
            )
        }
        do {
            for resolved in resolvedRules {
                let existed = fileManager.fileExists(atPath: resolved.target.path)
                let backupFilename = existed ? "\(resolved.rule.id.uuidString).original" : nil
                var originalDigest: Data?
                if let backupFilename {
                    let backupURL = transactionDirectory.appendingPathComponent(backupFilename)
                    try fileManager.copyItem(at: resolved.target, to: backupURL)
                    originalDigest = try digestFile(backupURL)
                }
                records.append(Record(
                    ruleID: resolved.rule.id,
                    bundleID: resolved.rule.bundleID,
                    relativePath: resolved.rule.relativePath,
                    containerFingerprint: containerFingerprint(resolved.containerRoot),
                    originalExisted: existed,
                    backupFilename: backupFilename,
                    originalDigest: originalDigest,
                    replacementDigest: digest(resolved.rule.replacementData)
                ))
            }
        } catch let error as PatchPackageError {
            try? fileManager.removeItem(at: transactionDirectory)
            throw error
        } catch {
            try? fileManager.removeItem(at: transactionDirectory)
            throw PatchPackageError.applyFailed
        }

        let journalURL = transactionDirectory.appendingPathComponent(journalFilename)
        var journal = Journal(
            schemaVersion: schemaVersion,
            transactionID: transactionID,
            projectID: project.id,
            createdAt: Date(),
            status: .prepared,
            records: records,
            createdDirectories: createdDirectories
        )
        do {
            try writeJournal(journal, to: journalURL)
        } catch {
            throw PatchPackageError.applyFailed
        }

        do {
            for resolved in resolvedDirectories where !fileManager.fileExists(atPath: resolved.target.path) {
                try fileManager.createDirectory(
                    at: resolved.target,
                    withIntermediateDirectories: false
                )
            }
            for (index, resolved) in resolvedRules.enumerated() {
                try beforeWrite?(index)
                try atomicWrite(
                    resolved.rule.replacementData,
                    to: resolved.target,
                    preservingExistingAttributes: true,
                    fileManager: fileManager
                )
                guard try digestFile(resolved.target) == records[index].replacementDigest else {
                    throw PatchPackageError.applyFailed
                }
            }
            journal.status = .applied
            try writeJournal(journal, to: journalURL)
            return PatchTransactionReceipt(
                id: transactionID,
                projectID: project.id,
                journalURL: journalURL
            )
        } catch {
            do {
                try restoreRecords(
                    records,
                    transactionDirectory: transactionDirectory,
                    roots: roots,
                    requirePatchedDigest: false,
                    createdDirectories: createdDirectories,
                    fileManager: fileManager
                )
                journal.status = .rolledBack
                try writeJournal(journal, to: journalURL)
            } catch {
                // Preserve the prepared journal and backups for explicit recovery.
            }
            throw PatchPackageError.applyFailed
        }
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        containerResolver: (String) throws -> URL,
        fileManager: FileManager = .default
    ) throws {
        var journal: Journal
        do {
            journal = try readJournal(receipt.journalURL)
        } catch {
            throw PatchPackageError.restoreFailed
        }
        guard journal.schemaVersion == schemaVersion,
              journal.transactionID == receipt.id,
              journal.projectID == receipt.projectID,
              journal.status == .applied || journal.status == .prepared
        else {
            throw PatchPackageError.restoreFailed
        }

        var roots: [String: URL] = [:]
        do {
            for record in journal.records where roots[record.bundleID] == nil {
                let root = PatchPathValidator.canonicalFileURL(try containerResolver(record.bundleID))
                guard containerFingerprint(root) == record.containerFingerprint else {
                    throw PatchPackageError.restoreFailed
                }
                roots[record.bundleID] = root
            }
            try restoreRecords(
                journal.records,
                transactionDirectory: receipt.journalURL.deletingLastPathComponent(),
                roots: roots,
                requirePatchedDigest: journal.status == .applied,
                createdDirectories: journal.createdDirectories ?? [],
                fileManager: fileManager
            )
            journal.status = .restored
            try writeJournal(journal, to: receipt.journalURL)

            // Once the original state has been verified and restored, the
            // transaction's private backup/staging artifacts are no longer
            // needed. The .3105 package itself remains in the library so the
            // same patch can be enabled again and receive a fresh backup.
            try? fileManager.removeItem(at: receipt.journalURL.deletingLastPathComponent())
        } catch {
            throw PatchPackageError.restoreFailed
        }
    }

    /// Removes only files written by this patch transaction. Every target is
    /// path-contained, the container fingerprint must match, and the current
    /// bytes must still match the patch digest before deletion. This is the
    /// account-protection path; it never deletes arbitrary files.
    static func deletePatchedTargets(
        receipt: PatchTransactionReceipt,
        containerResolver: (String) throws -> URL,
        fileManager: FileManager = .default
    ) throws {
        var journal: Journal
        do {
            journal = try readJournal(receipt.journalURL)
        } catch {
            throw PatchPackageError.restoreFailed
        }
        guard journal.schemaVersion == schemaVersion,
              journal.transactionID == receipt.id,
              journal.projectID == receipt.projectID,
              journal.status == .applied else {
            throw PatchPackageError.restoreFailed
        }

        var roots: [String: URL] = [:]
        for record in journal.records where roots[record.bundleID] == nil {
            let root = PatchPathValidator.canonicalFileURL(try containerResolver(record.bundleID))
            guard containerFingerprint(root) == record.containerFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            roots[record.bundleID] = root
        }

        // Validate every target before deleting any of them, avoiding partial
        // cleanup if one file has been changed independently.
        // QUAN TRỌNG: Nếu có file gốc để khôi phục (originalExisted=true),
        // NGHIÊM CẤM xóa — phải dùng restore() để phục hồi file gốc thay thế.
        // Chỉ được xóa khi originalExisted=false (file do patch tạo ra, không có gốc).
        var targets: [URL] = []
        for record in journal.records {
            guard let root = roots[record.bundleID] else { throw PatchPackageError.restoreFailed }
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: record.relativePath,
                containerRoot: root
            )
            // Có backup gốc → KHÔNG ĐƯỢC XÓA, phải restore.
            // deletePatchedTargets chỉ hợp lệ cho file originalExisted=false.
            if record.originalExisted {
                throw PatchPackageError.restoreFailed
            }
            // File không tồn tại → đã ở trạng thái gốc (không cần làm gì).
            // File tồn tại → chỉ xóa nếu bytes khớp replacementDigest (file do patch tạo).
            if fileManager.fileExists(atPath: target.path) {
                guard try digestFile(target) == record.replacementDigest else {
                    throw PatchPackageError.restoreFailed
                }
                targets.append(target)
            }
        }

        do {
            for target in targets {
                try fileManager.removeItem(at: target)
            }
            journal.status = .restored
            try writeJournal(journal, to: receipt.journalURL)
            try? fileManager.removeItem(at: receipt.journalURL.deletingLastPathComponent())
        } catch {
            throw PatchPackageError.restoreFailed
        }
    }

    /// Returns only a transaction whose filesystem writes completed successfully.
    /// Prepared journals are intentionally excluded because they may represent an
    /// interrupted transaction rather than an active patch.
    static func latestAppliedReceipt(
        projectID: UUID,
        backupRoot: URL,
        fileManager: FileManager = .default
    ) -> PatchTransactionReceipt? {
        let projectDirectory = backupRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard let directories = try? fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return directories.compactMap { directory -> (Journal, URL)? in
            let url = directory.appendingPathComponent(journalFilename)
            guard let journal = try? readJournal(url), journal.status == .applied else { return nil }
            return (journal, url)
        }
        .sorted { $0.0.createdAt > $1.0.createdAt }
        .first
        .map {
            PatchTransactionReceipt(
                id: $0.0.transactionID,
                projectID: $0.0.projectID,
                journalURL: $0.1
            )
        }
    }

    /// Returns target keys belonging to every currently active transaction,
    /// excluding the supplied project. Used to prevent two independent patch
    /// projects from overwriting the same file and breaking each other's restore.

    /// Returns project IDs whose currently-applied transactions touch at least
    /// one of the supplied target keys. Journals are the source of truth.
    static func activeProjectIDs(
        overlapping targetKeys: Set<String>,
        backupRoot: URL,
        excludingProjectID: UUID? = nil,
        fileManager: FileManager = .default
    ) -> Set<UUID> {
        guard !targetKeys.isEmpty,
              let projectDirectories = try? fileManager.contentsOfDirectory(
                at: backupRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return [] }

        var result = Set<UUID>()
        for projectDirectory in projectDirectories {
            guard let projectID = UUID(uuidString: projectDirectory.lastPathComponent),
                  projectID != excludingProjectID,
                  let transactions = try? fileManager.contentsOfDirectory(
                    at: projectDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ) else { continue }

            for transactionDirectory in transactions {
                let journalURL = transactionDirectory.appendingPathComponent(journalFilename)
                guard let journal = try? readJournal(journalURL),
                      journal.status == .applied else { continue }

                let journalKeys = Set(journal.records.compactMap { record -> String? in
                    guard let bundleID = try? PatchPathValidator.canonicalBundleIdentifier(record.bundleID),
                          let relativePath = try? PatchPathValidator.canonicalRelativePath(record.relativePath) else {
                        return nil
                    }
                    return bundleID + "\0" + relativePath
                })
                if !journalKeys.isDisjoint(with: targetKeys) {
                    result.insert(projectID)
                    break
                }
            }
        }
        return result
    }

    /// Returns every project ID with a currently applied transaction.
    /// Journals remain the source of truth, so stale UI/UserDefaults state is ignored.
    static func activeProjectIDs(
        backupRoot: URL,
        fileManager: FileManager = .default
    ) -> Set<UUID> {
        let targets = activeTargetKeys(backupRoot: backupRoot, fileManager: fileManager)
        guard !targets.isEmpty else { return [] }
        return activeProjectIDs(overlapping: targets, backupRoot: backupRoot, fileManager: fileManager)
    }

    static func activeTargetKeys(
        backupRoot: URL,
        excludingProjectID: UUID? = nil,
        fileManager: FileManager = .default
    ) -> Set<String> {
        guard let projectDirectories = try? fileManager.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result = Set<String>()
        for projectDirectory in projectDirectories {
            if let excludingProjectID, projectDirectory.lastPathComponent == excludingProjectID.uuidString {
                continue
            }
            guard let transactions = try? fileManager.contentsOfDirectory(
                at: projectDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for transactionDirectory in transactions {
                let journalURL = transactionDirectory.appendingPathComponent(journalFilename)
                guard let journal = try? readJournal(journalURL),
                      journal.status == .applied else { continue }
                for record in journal.records {
                    result.insert(record.bundleID + "\0" + record.relativePath)
                }
            }
        }
        return result
    }

    static func latestReceipt(
        projectID: UUID,
        backupRoot: URL,
        fileManager: FileManager = .default
    ) -> PatchTransactionReceipt? {
        let projectDirectory = backupRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard let directories = try? fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return directories.compactMap { directory -> (Journal, URL)? in
            let url = directory.appendingPathComponent(journalFilename)
            guard let journal = try? readJournal(url),
                  journal.status == .applied || journal.status == .prepared else { return nil }
            return (journal, url)
        }
        .sorted { $0.0.createdAt > $1.0.createdAt }
        .first
        .map {
            PatchTransactionReceipt(
                id: $0.0.transactionID,
                projectID: $0.0.projectID,
                journalURL: $0.1
            )
        }
    }

    static func requiredBundleIdentifiers(for receipt: PatchTransactionReceipt) throws -> [String] {
        let journal = try readJournal(receipt.journalURL)
        guard journal.schemaVersion == schemaVersion,
              journal.transactionID == receipt.id,
              journal.projectID == receipt.projectID else {
            throw PatchPackageError.restoreFailed
        }
        var seen = Set<String>()
        return (journal.records.map(\.bundleID)
            + (journal.createdDirectories ?? []).map(\.bundleID)).compactMap { bundleID in
                seen.insert(bundleID).inserted ? bundleID : nil
            }
    }

    /// Emergency cleanup path used when the original backup cannot be trusted.
    /// Removes only targets recorded by the journal and never writes unverified data.
    static func fallbackDeletePatchedTargets(
        receipt: PatchTransactionReceipt,
        containerResolver: (String) throws -> URL,
        fileManager: FileManager = .default
    ) throws {
        let journal = try readJournal(receipt.journalURL)
        guard journal.transactionID == receipt.id,
              journal.projectID == receipt.projectID else {
            throw PatchPackageError.restoreFailed
        }

        for record in journal.records {
            let root = PatchPathValidator.canonicalFileURL(try containerResolver(record.bundleID))
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: record.relativePath,
                containerRoot: root
            )
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }
    }

    private static func restoreRecords(
        _ records: [Record],
        transactionDirectory: URL,
        roots: [String: URL],
        requirePatchedDigest: Bool,
        createdDirectories: [DirectoryRecord],
        fileManager: FileManager
    ) throws {
        var resolvedTargets: [(Record, URL)] = []
        for record in records {
            guard let root = roots[record.bundleID],
                  containerFingerprint(root) == record.containerFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: record.relativePath,
                containerRoot: root
            )
            try validateFileTarget(
                target,
                relativePath: record.relativePath,
                containerRoot: root,
                allowMissingParents: !requirePatchedDigest,
                fileManager: fileManager
            )

            if requirePatchedDigest {
                guard fileManager.fileExists(atPath: target.path),
                      try digestFile(target) == record.replacementDigest else {
                    throw PatchPackageError.restoreFailed
                }
            }
            if record.originalExisted {
                guard let backupFilename = record.backupFilename,
                      let expectedDigest = record.originalDigest else {
                    throw PatchPackageError.restoreFailed
                }
                let backup = transactionDirectory.appendingPathComponent(backupFilename)
                guard fileManager.fileExists(atPath: backup.path),
                      try digestFile(backup) == expectedDigest else {
                    throw PatchPackageError.restoreFailed
                }
            }
            resolvedTargets.append((record, target))
        }

        for (record, target) in resolvedTargets.reversed() {
            if record.originalExisted {
                let backup = transactionDirectory.appendingPathComponent(record.backupFilename!)
                try atomicCopy(backup, to: target, fileManager: fileManager)
            } else if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }

        for directory in createdDirectories.reversed() {
            guard let root = roots[directory.bundleID],
                  containerFingerprint(root) == directory.containerFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: directory.relativePath,
                containerRoot: root
            )
            guard fileManager.fileExists(atPath: target.path) else { continue }
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw PatchPackageError.restoreFailed
            }
            let contents = try fileManager.contentsOfDirectory(atPath: target.path)
            if contents.isEmpty {
                try fileManager.removeItem(at: target)
            }
        }
    }

    private static func validateFileTarget(
        _ target: URL,
        relativePath: String,
        containerRoot: URL,
        allowMissingParents: Bool,
        fileManager: FileManager
    ) throws {
        let components = try PatchPathValidator.canonicalRelativePath(relativePath)
            .split(separator: "/")
            .map(String.init)
        var cursor = PatchPathValidator.canonicalFileURL(containerRoot)
        for component in components.dropLast() {
            cursor.appendPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: cursor.path) else {
                if allowMissingParents { break }
                throw PatchPackageError.applyFailed
            }
            let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
            guard values.isDirectory == true else {
                throw PatchPackageError.applyFailed
            }
        }
        if fileManager.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
            guard values.isDirectory != true else {
                throw PatchPackageError.applyFailed
            }
        }
    }

    private static func validateDirectoryTarget(
        _ target: URL,
        relativePath: String,
        containerRoot: URL,
        fileManager: FileManager
    ) throws {
        let components = try PatchPathValidator.canonicalRelativePath(relativePath)
            .split(separator: "/").map(String.init)
        var cursor = PatchPathValidator.canonicalFileURL(containerRoot)
        for component in components {
            cursor.appendPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: cursor.path) else { break }
            let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
            guard values.isDirectory == true else {
                throw PatchPackageError.applyFailed
            }
        }
        if fileManager.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw PatchPackageError.applyFailed
            }
        }
    }

    private static func directoryKeySort(_ lhs: String, _ rhs: String) -> Bool {
        let leftDepth = lhs.filter { $0 == "/" }.count
        let rightDepth = rhs.filter { $0 == "/" }.count
        return leftDepth == rightDepth ? lhs < rhs : leftDepth < rightDepth
    }

    private static func atomicWrite(
        _ data: Data,
        to target: URL,
        preservingExistingAttributes: Bool,
        fileManager: FileManager
    ) throws {
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".3105-patch-\(UUID().uuidString)")
        var attributes: [FileAttributeKey: Any] = [:]
        if preservingExistingAttributes,
           let current = try? fileManager.attributesOfItem(atPath: target.path) {
            if let permissions = current[.posixPermissions] { attributes[.posixPermissions] = permissions }
            if let protection = current[.protectionKey] { attributes[.protectionKey] = protection }
        }
        guard fileManager.createFile(atPath: staging.path, contents: nil, attributes: attributes) else {
            throw PatchPackageError.applyFailed
        }
        defer { try? fileManager.removeItem(at: staging) }

        let handle = try FileHandle(forWritingTo: staging)
        do {
            var offset = 0
            let chunkSize = 4 * 1_024 * 1_024
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                try handle.write(contentsOf: data[offset..<end])
                offset = end
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw PatchPackageError.applyFailed
        }
        guard rename(staging.path, target.path) == 0 else {
            throw PatchPackageError.applyFailed
        }
    }

    private static func atomicCopy(
        _ source: URL,
        to target: URL,
        fileManager: FileManager
    ) throws {
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".3105-restore-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        let handle = try FileHandle(forWritingTo: staging)
        try handle.synchronize()
        try handle.close()
        guard rename(staging.path, target.path) == 0 else {
            throw PatchPackageError.restoreFailed
        }
    }

    private static func writeJournal(_ journal: Journal, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(journal).write(to: url, options: .atomic)
    }

    private static func readJournal(_ url: URL) throws -> Journal {
        try PropertyListDecoder().decode(Journal.self, from: Data(contentsOf: url))
    }

    // MARK: - File state via hex comparison

    /// So sánh SHA-256 của từng file đích với digest đã ghi trong journal.
    /// Không dùng cache — đọc thực tế từ disk mỗi lần gọi.
    /// - Parameter receipt: Receipt của transaction (applied hoặc prepared).
    /// - Parameter containerResolver: Trả về container root URL cho một bundleID.
    /// - Returns: PatchFileState mô tả trạng thái thực tế của tất cả file game.
    static func fileState(
        receipt: PatchTransactionReceipt,
        containerResolver: (String) throws -> URL,
        fileManager: FileManager = .default
    ) -> PatchFileState {
        guard let journal = try? readJournal(receipt.journalURL),
              journal.schemaVersion == schemaVersion,
              journal.transactionID == receipt.id,
              journal.projectID == receipt.projectID,
              !journal.records.isEmpty
        else { return .inconsistent }

        let transactionDir = receipt.journalURL.deletingLastPathComponent()
        var patchedCount = 0
        var originalCount = 0

        for record in journal.records {
            // Resolve container root
            guard let containerRoot = try? containerResolver(record.bundleID),
                  containerFingerprint(containerRoot) == record.containerFingerprint,
                  let target = try? PatchPathValidator.resolveContainedTargetURL(
                      relativePath: record.relativePath,
                      containerRoot: containerRoot
                  )
            else { return .inconsistent }

            // Kiểm tra backup còn nguyên trước khi xét màu.
            // Nếu originalExisted=true mà backup mất → backupMissing (đỏ ngay).
            if record.originalExisted {
                guard let backupFilename = record.backupFilename,
                      let expectedOriginalDigest = record.originalDigest else {
                    return .inconsistent
                }
                let backupURL = transactionDir.appendingPathComponent(backupFilename)
                guard fileManager.fileExists(atPath: backupURL.path),
                      (try? digestFile(backupURL)) == expectedOriginalDigest
                else { return .backupMissing }
            }

            let targetExists = fileManager.fileExists(atPath: target.path)

            if !targetExists {
                // File không tồn tại trong game
                if !record.originalExisted {
                    // Patch đã tạo file từ đầu, hiện vắng mặt → trạng thái gốc
                    originalCount += 1
                } else {
                    // File gốc đã tồn tại nhưng bị ai xóa khỏi game ngoài app
                    return .inconsistent
                }
                continue
            }

            guard let currentDigest = try? digestFile(target) else { return .inconsistent }

            if currentDigest == record.replacementDigest {
                // Bytes aim/mod đang sống trong game
                patchedCount += 1
            } else if let origDigest = record.originalDigest, currentDigest == origDigest {
                // Bytes gốc của game đang hiện diện
                originalCount += 1
            } else if !record.originalExisted {
                // File không có gốc nhưng nay chứa bytes lạ
                return .inconsistent
            } else {
                // Bytes không khớp cả hai digest — bị chỉnh ngoài app
                return .inconsistent
            }
        }

        let total = journal.records.count
        if patchedCount == total  { return .patched }
        if originalCount == total { return .original }
        // Trạng thái hỗn hợp (một số file patched, một số đã khôi phục)
        return .inconsistent
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func digestFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    private static func containerFingerprint(_ url: URL) -> Data {
        digest(Data(PatchPathValidator.canonicalFileURL(url).path.utf8))
    }
}
