import Foundation

struct PatchLibraryItem: Identifiable, Sendable {
    let summary: PatchPackageSummary
    var project: PatchProject?
    var contentKey: Data?
    var packageURL: URL

    var id: UUID { summary.packageID }
    var isLocked: Bool { project == nil }
    var workspaceURL: URL? {
        PatchWorkspaceService.workspaceURL(projectID: id)
    }
}

struct PatchPasswordRequest: Identifiable, Sendable {
    let summary: PatchPackageSummary
    var id: UUID { summary.packageID }
}

enum PatchProjectLibrary {
    static func packageRootURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("PatchProjects", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func backupRootURL(fileManager: FileManager = .default) throws -> URL {
        let root = try packageRootURL(fileManager: fileManager)
            .appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func load(fileManager: FileManager = .default) -> [PatchLibraryItem] {
        guard let root = try? packageRootURL(fileManager: fileManager),
              let urls = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else { return [] }

        var byID: [UUID: PatchLibraryItem] = [:]
        for url in urls where url.pathExtension.lowercased() == "3105" {
            do {
                let data = try readPackage(at: url)
                let summary = try PatchPackageCodec.inspect(data)
                let decoded: DecodedPatchPackage?
                if let contentKey = try PatchKeyStore.load(for: summary) {
                    decoded = try PatchPackageCodec.decode(data, contentKey: contentKey)
                } else if summary.isPasswordProtected {
                    decoded = nil
                } else {
                    decoded = try PatchPackageCodec.decode(data, password: nil)
                }
                let item = PatchLibraryItem(
                    summary: summary,
                    project: decoded?.project,
                    contentKey: decoded?.contentKey,
                    packageURL: url
                )
                if summary.schemaVersion >= 2, let project = decoded?.project {
                    do {
                        _ = try PatchWorkspaceService.ensureWorkspace(for: project)
                    } catch {
                        log("patch: workspace unavailable for \(project.id.uuidString)")
                    }
                }
                byID[summary.packageID] = item
            } catch {
                log("patch: skipped invalid local package \(url.lastPathComponent)")
            }
        }
        return byID.values.sorted {
            ($0.project?.updatedAt ?? .distantPast) > ($1.project?.updatedAt ?? .distantPast)
        }
    }

    /// Performs a strict integrity pass over every local .3105 package.
    ///
    /// Unlike `load()`, which intentionally skips malformed entries so the
    /// library UI can remain usable, startup uses this method as a hard gate:
    /// every package must be structurally valid, decryptable when its key is
    /// available, and have a valid workspace when it contains a v2 project.
    @discardableResult
    static func validateAllLocalPackages(
        fileManager: FileManager = .default
    ) throws -> Int {
        let root = try packageRootURL(fileManager: fileManager)
        let urls = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let packages = urls.filter { $0.pathExtension.lowercased() == "3105" }

        var seenIDs = Set<UUID>()
        for url in packages {
            let data = try readPackage(at: url)
            let summary = try PatchPackageCodec.inspect(data)
            guard seenIDs.insert(summary.packageID).inserted else {
                throw PatchPackageError.invalidProject
            }

            if let contentKey = try PatchKeyStore.load(for: summary) {
                let decoded = try PatchPackageCodec.decode(data, contentKey: contentKey)
                if summary.schemaVersion >= 2 {
                    _ = try PatchWorkspaceService.ensureWorkspace(for: decoded.project)
                }
            } else if summary.isPasswordProtected {
                // A locked package is structurally valid. Its payload cannot
                // be decrypted until the user supplies the stored package key.
                continue
            } else {
                let decoded = try PatchPackageCodec.decode(data, password: nil)
                if summary.schemaVersion >= 2 {
                    _ = try PatchWorkspaceService.ensureWorkspace(for: decoded.project)
                }
            }
        }

        return packages.count
    }

    static func readPackage(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isDirectory != true,
              values.isSymbolicLink != true,
              values.isRegularFile == true else {
            throw PatchPackageError.invalidProject
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func save(
        data: Data,
        projectName: String,
        existingURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination: URL
        if let existingURL {
            destination = existingURL
        } else {
            let root = try packageRootURL(fileManager: fileManager)
            let baseName = sanitizedFilename(projectName)
            destination = try uniquePackageURL(
                in: root,
                baseName: baseName,
                fileManager: fileManager
            )
        }
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        return destination
    }

    /// Allocates a package filename safely on case-insensitive filesystems.
    /// A package with the same human-readable name is never overwritten during
    /// a new import/create operation; collisions are split into -2, -3, ...
    private static func uniquePackageURL(
        in root: URL,
        baseName: String,
        fileManager: FileManager
    ) throws -> URL {
        let existingNames = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.caseInsensitiveCompare("3105") == .orderedSame }
        .map { $0.deletingPathExtension().lastPathComponent.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) }

        var suffix = 1
        while true {
            let stem = suffix == 1 ? baseName : "\(baseName)-\(suffix)"
            let normalizedStem = stem.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let candidate = root
                .appendingPathComponent(stem, isDirectory: false)
                .appendingPathExtension("3105")

            let pathExists = fileManager.fileExists(atPath: candidate.path)
            let nameCollides = existingNames.contains(normalizedStem)

            if !pathExists && !nameCollides {
                return candidate
            }
            suffix += 1
            if suffix > 100_000 {
                throw PatchPackageError.invalidProject
            }
        }
    }

    static func installImportedPackage(
        data: Data,
        decoded: DecodedPatchPackage,
        summary: PatchPackageSummary,
        existingURL: URL?,
        fileManager: FileManager = .default
    ) throws {
        let previousData = try existingURL.map { try readPackage(at: $0) }
        var savedURL: URL?
        do {
            savedURL = try save(
                data: data,
                projectName: decoded.project.name,
                existingURL: existingURL,
                fileManager: fileManager
            )
            if summary.schemaVersion >= 2 {
                _ = try PatchWorkspaceService.replaceWorkspace(
                    with: decoded.project,
                    fileManager: fileManager
                )
            } else {
                try? PatchWorkspaceService.deleteWorkspace(
                    projectID: decoded.project.id,
                    fileManager: fileManager
                )
            }
        } catch {
            if let previousData, let existingURL {
                try? previousData.write(
                    to: existingURL,
                    options: [.atomic, .completeFileProtection]
                )
            } else if let savedURL, fileManager.fileExists(atPath: savedURL.path) {
                try? fileManager.removeItem(at: savedURL)
            }
            throw error
        }
    }

    static func delete(_ item: PatchLibraryItem, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: item.packageURL.path) {
            try fileManager.removeItem(at: item.packageURL)
        }
        try? PatchWorkspaceService.deleteWorkspace(projectID: item.id, fileManager: fileManager)
        try? PatchKeyStore.delete(for: item.summary)
    }

    static func synchronizeWorkspace(
        item: PatchLibraryItem,
        fileManager: FileManager = .default
    ) throws -> PatchProject {
        guard item.summary.schemaVersion >= 2,
              let baseProject = item.project,
              let contentKey = item.contentKey else {
            throw PatchPackageError.invalidProject
        }
        let workspace = try PatchWorkspaceService.ensureWorkspace(
            for: baseProject,
            fileManager: fileManager
        )
        let project = try PatchWorkspaceService.snapshot(
            baseProject: baseProject,
            workspaceURL: workspace,
            fileManager: fileManager
        )
        let original = try readPackage(at: item.packageURL)
        let updated = try PatchPackageCodec.update(
            original,
            project: project,
            contentKey: contentKey,
            schemaVersion: PatchPackageCodec.latestSchemaVersion
        )
        _ = try save(
            data: updated,
            projectName: project.name,
            existingURL: item.packageURL,
            fileManager: fileManager
        )
        return project
    }

    private static func sanitizedFilename(_ rawName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = rawName.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80)
        return result.isEmpty ? "Patch" : String(result)
    }
}
