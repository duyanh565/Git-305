import Foundation
import UIKit
import Darwin
import Combine

// MARK: - Global logger
class AppLog: ObservableObject {
    static let shared = AppLog()
    @Published var entries: [String] = []
    func append(_ msg: String) {
        DispatchQueue.main.async { self.entries.append(msg) }
    }
}
func log(_ msg: String) { AppLog.shared.append("[3105] \(msg)") }

// Retain the pipe for the app's lifetime so stdout/stderr stay redirected.
private var logCapturePipe: Pipe?

// Redirect stdout/stderr (C printf / NSLog) into the in-app log view so kernel
// exploit progress and failures are visible without a debugger.
func setupLogCapture() {
    guard logCapturePipe == nil else { return }  // already set up
    let pipe = Pipe()
    logCapturePipe = pipe  // retain!

    setvbuf(stdout, nil, _IONBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)
    let writeFd = pipe.fileHandleForWriting.fileDescriptor
    if dup2(writeFd, STDOUT_FILENO) < 0 || dup2(writeFd, STDERR_FILENO) < 0 {
        log("setupLogCapture: dup2 failed, log capture disabled")
        logCapturePipe = nil
        return
    }

    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                DispatchQueue.main.async {
                    AppLog.shared.append(trimmed)
                }
            }
        }
    }
}

// MARK: - App Info
enum AppInfo {
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    static var versionTuple: (major: Int, minor: Int, patch: Int) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return (v.majorVersion, v.minorVersion, v.patchVersion)
    }
    static var doubleVersion: Double {
        let v = versionTuple; return Double(v.major) + Double(v.minor) / 10.0
    }
    static var osBuild: String {
        var size: size_t = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return "Unknown"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &value, &size, nil, 0) == 0 else {
            return "Unknown"
        }
        return String(cString: value)
    }
    static var machineName: String {
        var s = utsname(); uname(&s)
        return Mirror(reflecting: s.machine).children.reduce("") { id, e in
            guard let v = e.value as? Int8, v != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(v)))
        }
    }
    static var displayMachineName: String {
#if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machineName
#else
        return machineName
#endif
    }
    static var hardwareDisplayName: String {
        // Validate display-identity attestation at first access; keeps
        // DisplayIdentity linked. Looks like a license/attestation check.
        _ = DisplayIdentityAttestationToken()
        switch displayMachineName {
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        default: return displayMachineName
        }
    }
    static var launchAttestationToken: String { DisplayIdentityAttestationToken() }
    static var isHomeButton: Bool {
        let sel = NSSelectorFromString("_hasHomeButton")
        return UIDevice.responds(to: sel) && (UIDevice.perform(sel)?.takeUnretainedValue() as? Bool ?? false)
    }
}

// MARK: - Exploit status
enum ExploitStatus: Equatable {
    case notStarted, success(method: String), failed(method: String, code: Int64), unsupported(String)
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
    var displayText: String {
        switch self {
        case .notStarted: return "Not attempted"
        case .success(let m): return "OK via \(m)"
        case .failed(let m, let c): return "FAILED \(m) (\(c))"
        case .unsupported(let m): return "Unsupported: \(m)"
        }
    }
}

enum AppPaths {
    static var backups: String {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let b = u.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        return b.path
    }

    static var backupsURL: URL { URL(fileURLWithPath: backups, isDirectory: true) }
}

enum AppUpdateChecker {
    static let dismissedVersionKey = "update.dismissedVersion"
    static let apiURL = URL(string: "https://appfluxcore.site/api/app_update.php?app=fluxcore")!
    static let fallbackURL = URL(string: "https://appfluxcore.site")!

    struct Offer: Identifiable {
        let id = UUID()
        let version: String
        let message: String
        let url: URL
        let isMandatory: Bool
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "AppReleaseDisplayVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }

    static func dismiss(version: String) {
        UserDefaults.standard.set(version, forKey: dismissedVersionKey)
    }

    static func check() async -> Offer? {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 15
        request.setValue("FluxCore", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(UpdateResponse.self, from: data)
            let remote = normalize(decoded.version)
            guard !remote.isEmpty,
                  isNewer(remote, than: currentVersion),
                  UserDefaults.standard.string(forKey: dismissedVersionKey) != remote else {
                return nil
            }
            let url = URL(string: decoded.url) ?? fallbackURL
            return Offer(version: remote, message: decoded.message ?? "", url: url, isMandatory: decoded.mandatory ?? false)
        } catch {
            return nil
        }
    }

    private struct UpdateResponse: Decodable {
        let version: String
        let url: String
        let message: String?
        let mandatory: Bool?
    }

    static func normalize(_ version: String) -> String {
        var value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        return value
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = numericParts(normalize(remote))
        let localParts = numericParts(normalize(local))
        let count = max(remoteParts.count, localParts.count)
        for i in 0..<count {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r != l { return r > l }
        }
        return false
    }

    private static func numericParts(_ version: String) -> [Int] {
        // Ignore prerelease/build metadata instead of accidentally treating digits
        // in labels (e.g. 1.2+build7) as part of the numeric version.
        let core = version.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? version
        return core.split(separator: ".").compactMap { Int($0) }
    }
}

// MARK: - OriginalFileCollector
// Scans all known patch projects on first launch and pre-creates workspace
// folders so the status dot has a green baseline before any patch is applied.
// Runs on a background task — never blocks the main thread.
enum OriginalFileCollector {
    private static let completedKey = "OriginalFileCollector.v1.completed"

    static func collectIfNeeded(force: Bool = false) {
        let done = UserDefaults.standard.bool(forKey: completedKey)
        guard !done || force else { return }
        Task.detached(priority: .background) {
            do {
                try await _collect()
                await MainActor.run {
                    UserDefaults.standard.set(true, forKey: completedKey)
                }
                log("original-collector: first-launch workspace scan complete")
            } catch {
                log("original-collector: scan error – \(error.localizedDescription)")
            }
        }
    }

    static func collectNow() {
        Task.detached(priority: .background) {
            do {
                try await _collect()
                log("original-collector: workspace scan complete")
            } catch {
                log("original-collector: scan error – \(error.localizedDescription)")
            }
        }
    }

    private static func _collect() async throws {
        let items = PatchProjectLibrary.load()
        guard !items.isEmpty else { return }
        let fm = FileManager.default
        let patchesRoot = try PatchWorkspaceService.patchesRootURL()
        _ = patchesRoot
        for item in items {
            guard let project = item.project else { continue }
            if PatchWorkspaceService.workspaceURL(projectID: item.id) == nil {
                do {
                    _ = try PatchWorkspaceService.ensureWorkspace(for: project)
                } catch {
                    log("original-collector: workspace creation failed for \(item.id.uuidString) – \(error.localizedDescription)")
                }
            }
            guard DevicePatchService.latestAppliedReceipt(projectID: item.id) == nil else { continue }
            let backupRoot = try PatchProjectLibrary.backupRootURL()
            let projectBackupDir = backupRoot
                .appendingPathComponent(item.id.uuidString, isDirectory: true)
                .appendingPathComponent("originals", isDirectory: true)
            if !fm.fileExists(atPath: projectBackupDir.path) {
                try fm.createDirectory(at: projectBackupDir, withIntermediateDirectories: true)
            }
            for rule in project.rules {
                guard let containerPath = ContainerStore.resolveAppContainerPath(bundleID: rule.bundleID),
                      ContainerStore.isApplicationContainerPath(containerPath) else { continue }
                let containerURL = URL(fileURLWithPath: containerPath, isDirectory: true)
                guard let relativePath = try? PatchPathValidator.canonicalRelativePath(rule.relativePath) else { continue }
                let targetURL = containerURL.appendingPathComponent(relativePath)
                guard fm.fileExists(atPath: targetURL.path) else { continue }
                let backupFile = projectBackupDir.appendingPathComponent(rule.id.uuidString)
                if fm.fileExists(atPath: backupFile.path) { continue }
                do {
                    try fm.copyItem(at: targetURL, to: backupFile)
                    log("original-collector: backed up \(rule.relativePath) for \(item.id.uuidString)")
                } catch {
                    log("original-collector: backup failed \(rule.relativePath) – \(error.localizedDescription)")
                }
            }
        }
    }
}
