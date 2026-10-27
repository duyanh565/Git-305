import Foundation

/// Canonical iOS/iPadOS version-to-build database used for exact compatibility
/// lookups. A version may map to multiple builds, and a build may intentionally
/// map to multiple lifecycle stages (for example, an RC build reused as the
/// final release build).
public enum IOSReleaseChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case beta
    case releaseCandidate
}

public struct IOSVersion: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int?

    public init(major: Int, minor: Int, patch: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String {
        if let patch { return "\(major).\(minor).\(patch)" }
        return "\(major).\(minor)"
    }

    public static func parse(_ value: String) -> IOSVersion? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^iOS\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^iPadOS\\s+", with: "", options: .regularExpression)

        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 3 else { return nil }

        let numbers = components.compactMap { Int($0) }
        guard numbers.count == components.count, numbers.allSatisfy({ $0 >= 0 }) else {
            return nil
        }

        return IOSVersion(
            major: numbers[0],
            minor: numbers[1],
            patch: numbers.count == 3 ? numbers[2] : nil
        )
    }

    public static func < (lhs: IOSVersion, rhs: IOSVersion) -> Bool {
        let lp = lhs.patch ?? 0
        let rp = rhs.patch ?? 0
        return (lhs.major, lhs.minor, lp) < (rhs.major, rhs.minor, rp)
    }
}

public struct IOSVersionBuildRecord: Hashable, Codable, Sendable {
    public let version: IOSVersion
    public let build: String
    public let channel: IOSReleaseChannel
    public let sequence: Int?
    public let label: String

    public init(
        version: IOSVersion,
        build: String,
        channel: IOSReleaseChannel = .stable,
        sequence: Int? = nil,
        label: String? = nil
    ) {
        self.version = version
        self.build = build
        self.channel = channel
        self.sequence = sequence
        self.label = label ?? version.description
    }

    public var isBeta: Bool { channel == .beta }
    public var isReleaseCandidate: Bool { channel == .releaseCandidate }
    public var isStable: Bool { channel == .stable }
}

public enum IOSVersionBuildDatabaseError: Error, LocalizedError, Sendable {
    case invalidVersion(String)
    case invalidBuild(String)
    case versionNotFound(String)
    case buildNotFound(String)
    case mappingNotFound(version: String, build: String)
    case invalidDatabase([String])

    public var errorDescription: String? {
        switch self {
        case .invalidVersion(let value):
            return "Invalid iOS version: \(value)"
        case .invalidBuild(let value):
            return "Invalid Apple build string: \(value)"
        case .versionNotFound(let value):
            return "No mapping found for iOS version: \(value)"
        case .buildNotFound(let value):
            return "No mapping found for build: \(value)"
        case .mappingNotFound(let version, let build):
            return "No mapping found for iOS \(version) with build \(build)"
        case .invalidDatabase(let issues):
            return "iOS version/build database is invalid: \(issues.joined(separator: "; "))"
        }
    }
}

public struct IOSVersionBuildValidationReport: Sendable {
    public let issues: [String]

    public var isValid: Bool { issues.isEmpty }
    public var error: IOSVersionBuildDatabaseError? {
        issues.isEmpty ? nil : .invalidDatabase(issues)
    }
}

/// Exact, deterministic version/build mapping database.
///
/// Important:
/// - Never use a single `[String: String]` dictionary for this dataset.
/// - Multiple builds can belong to one OS version.
/// - One build can legitimately occur under multiple lifecycle labels.
/// - Lookups are exact after whitespace normalization.
public enum IOSVersionBuildDatabase {
    public static let records: [IOSVersionBuildRecord] = [
        // MARK: iOS 17
        .init(version: .init(major: 17, minor: 0), build: "21A329"),
        .init(version: .init(major: 17, minor: 0, patch: 1), build: "21A340"),
        .init(version: .init(major: 17, minor: 0, patch: 2), build: "21A350"),
        .init(version: .init(major: 17, minor: 0, patch: 2), build: "21A351"),
        .init(version: .init(major: 17, minor: 0, patch: 3), build: "21A360"),
        .init(version: .init(major: 17, minor: 1), build: "21B74"),
        .init(version: .init(major: 17, minor: 1), build: "21B80"),
        .init(version: .init(major: 17, minor: 1, patch: 1), build: "21B91"),
        .init(version: .init(major: 17, minor: 1, patch: 2), build: "21B101"),
        .init(version: .init(major: 17, minor: 2), build: "21C62"),
        .init(version: .init(major: 17, minor: 2, patch: 1), build: "21C66"),
        .init(version: .init(major: 17, minor: 3), build: "21D50"),
        .init(version: .init(major: 17, minor: 3, patch: 1), build: "21D61"),
        .init(version: .init(major: 17, minor: 4), build: "21E219"),
        .init(version: .init(major: 17, minor: 4, patch: 1), build: "21E236"),
        .init(version: .init(major: 17, minor: 4, patch: 1), build: "21E237"),
        .init(version: .init(major: 17, minor: 5), build: "21F79"),
        .init(version: .init(major: 17, minor: 5, patch: 1), build: "21F90"),
        .init(version: .init(major: 17, minor: 6), build: "21G80"),
        .init(version: .init(major: 17, minor: 6, patch: 1), build: "21G93"),
        .init(version: .init(major: 17, minor: 6, patch: 1), build: "21G101"),
        .init(version: .init(major: 17, minor: 7), build: "21H16"),
        .init(version: .init(major: 17, minor: 7, patch: 1), build: "21H216"),
        .init(version: .init(major: 17, minor: 7, patch: 2), build: "21H221"),

        // MARK: iOS 18
        .init(version: .init(major: 18, minor: 0), build: "22A3354"),
        .init(version: .init(major: 18, minor: 0, patch: 1), build: "22A3370"),
        .init(version: .init(major: 18, minor: 1), build: "22B83"),
        .init(version: .init(major: 18, minor: 1, patch: 1), build: "22B91"),
        .init(version: .init(major: 18, minor: 2), build: "22C152"),
        .init(version: .init(major: 18, minor: 2, patch: 1), build: "22C161"),
        .init(version: .init(major: 18, minor: 3), build: "22D63"),
        .init(version: .init(major: 18, minor: 3, patch: 1), build: "22D72"),
        .init(version: .init(major: 18, minor: 3, patch: 2), build: "22D82"),
        .init(version: .init(major: 18, minor: 4), build: "22E240"),
        .init(version: .init(major: 18, minor: 4, patch: 1), build: "22E252"),
        .init(version: .init(major: 18, minor: 5), build: "22F76"),
        .init(version: .init(major: 18, minor: 6), build: "22G86"),
        .init(version: .init(major: 18, minor: 6, patch: 1), build: "22G90"),
        .init(version: .init(major: 18, minor: 6, patch: 2), build: "22G100"),
        .init(version: .init(major: 18, minor: 7), build: "22H20"),
        .init(version: .init(major: 18, minor: 7, patch: 1), build: "22H31"),
        .init(version: .init(major: 18, minor: 7, patch: 2), build: "22H124"),
        .init(version: .init(major: 18, minor: 7, patch: 3), build: "22H217"),
        .init(version: .init(major: 18, minor: 7, patch: 4), build: "22H218"),
        .init(version: .init(major: 18, minor: 7, patch: 5), build: "22H311"),
        .init(version: .init(major: 18, minor: 7, patch: 6), build: "22H320"),
        .init(version: .init(major: 18, minor: 7, patch: 7), build: "22H333"),
        .init(version: .init(major: 18, minor: 7, patch: 7), build: "22H340"),
        .init(version: .init(major: 18, minor: 7, patch: 8), build: "22H352"),
        .init(version: .init(major: 18, minor: 7, patch: 9), build: "22H355"),
        .init(version: .init(major: 18, minor: 7, patch: 10), build: "22H374"),

        // MARK: iOS 26
        .init(version: .init(major: 26, minor: 0), build: "23A341"),
        .init(version: .init(major: 26, minor: 0), build: "23A345"),
        .init(version: .init(major: 26, minor: 0, patch: 1), build: "23A355"),
        .init(version: .init(major: 26, minor: 1), build: "23B85"),
        .init(version: .init(major: 26, minor: 2), build: "23C55"),
        .init(version: .init(major: 26, minor: 2, patch: 1), build: "23C71"),
        .init(version: .init(major: 26, minor: 3), build: "23D127"),
        .init(version: .init(major: 26, minor: 3, patch: 1), build: "23D8133"),
        .init(version: .init(major: 26, minor: 4), build: "23E246"),
        .init(version: .init(major: 26, minor: 4, patch: 1), build: "23E254"),
        .init(version: .init(major: 26, minor: 4, patch: 2), build: "23E261"),
        .init(version: .init(major: 26, minor: 5), build: "23F77"),
        .init(version: .init(major: 26, minor: 5, patch: 1), build: "23F81"),
        .init(version: .init(major: 26, minor: 5, patch: 2), build: "23F84"),
        .init(version: .init(major: 26, minor: 6), build: "23G71"),
        .init(version: .init(major: 26, minor: 6, patch: 1), build: "23G83"),
        .init(version: .init(major: 26, minor: 6, patch: 2), build: "23G90"),
        .init(version: .init(major: 26, minor: 7), build: "23H24"),

        // MARK: iOS 27 beta / RC / stable
        .init(version: .init(major: 27, minor: 0), build: "24A5355q", channel: .beta, sequence: 1, label: "27.0 beta 1"),
        .init(version: .init(major: 27, minor: 0), build: "24A5370h", channel: .beta, sequence: 2, label: "27.0 beta 2"),
        .init(version: .init(major: 27, minor: 0), build: "24A5380h", channel: .beta, sequence: 3, label: "27.0 beta 3"),
        .init(version: .init(major: 27, minor: 0), build: "24A5390f", channel: .beta, sequence: 4, label: "27.0 beta 4"),
        .init(version: .init(major: 27, minor: 0), build: "24A5408d", channel: .beta, sequence: 5, label: "27.0 beta 5"),
        .init(version: .init(major: 27, minor: 0), build: "24A5418b", channel: .beta, sequence: 6, label: "27.0 beta 6"),
        .init(version: .init(major: 27, minor: 0), build: "24A5424a", channel: .beta, sequence: 7, label: "27.0 beta 7"),
        .init(version: .init(major: 27, minor: 0), build: "24A5430a", channel: .beta, sequence: 8, label: "27.0 beta 8"),
        .init(version: .init(major: 27, minor: 0), build: "24A435", channel: .releaseCandidate, label: "27.0 RC"),
        .init(version: .init(major: 27, minor: 0), build: "24A437", channel: .releaseCandidate, label: "27.0 RC mới"),
        .init(version: .init(major: 27, minor: 0), build: "24A437", channel: .stable, label: "27.0 chính thức"),
        .init(version: .init(major: 27, minor: 2), build: "24B5084k", channel: .beta, sequence: 1, label: "27.2 beta 1"),
        .init(version: .init(major: 27, minor: 2), build: "24B5089g", channel: .beta, sequence: 2, label: "27.2 beta 2")
    ]

    private static let versionIndex: [IOSVersion: [IOSVersionBuildRecord]] = {
        Dictionary(grouping: records, by: \.version)
    }()

    private static let buildIndex: [String: [IOSVersionBuildRecord]] = {
        Dictionary(grouping: records, by: \.build)
    }()

    private static let labelIndex: [String: [IOSVersionBuildRecord]] = {
        Dictionary(grouping: records, by: { normalizeLabel($0.label) })
    }()

    private static let buildPattern = try! NSRegularExpression(
        pattern: #"^[0-9]{2}[A-Z][0-9]{2,6}[a-z]?$"#
    )

    public static func records(forVersion version: IOSVersion) -> [IOSVersionBuildRecord] {
        versionIndex[version, default: []]
    }

    public static func records(forVersion versionString: String) throws -> [IOSVersionBuildRecord] {
        let normalized = versionString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^iOS\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^iPadOS\\s+", with: "", options: .regularExpression)

        if let labeled = labelIndex[normalizeLabel(normalized)] {
            return labeled
        }

        guard let version = IOSVersion.parse(normalized) else {
            throw IOSVersionBuildDatabaseError.invalidVersion(versionString)
        }

        let result = records(forVersion: version)
        guard !result.isEmpty else {
            throw IOSVersionBuildDatabaseError.versionNotFound(versionString)
        }
        return result
    }

    public static func records(forBuild build: String) throws -> [IOSVersionBuildRecord] {
        let normalized = normalizeBuild(build)
        guard isValidBuildSyntax(normalized) else {
            throw IOSVersionBuildDatabaseError.invalidBuild(build)
        }

        let result = buildIndex[normalized, default: []]
        guard !result.isEmpty else {
            throw IOSVersionBuildDatabaseError.buildNotFound(build)
        }
        return result
    }

    public static func record(version: IOSVersion, build: String) throws -> IOSVersionBuildRecord {
        let normalizedBuild = normalizeBuild(build)
        guard isValidBuildSyntax(normalizedBuild) else {
            throw IOSVersionBuildDatabaseError.invalidBuild(build)
        }

        guard let result = versionIndex[version]?.first(where: { $0.build == normalizedBuild }) else {
            throw IOSVersionBuildDatabaseError.mappingNotFound(
                version: version.description,
                build: normalizedBuild
            )
        }
        return result
    }

    public static func resolve(_ value: String) throws -> [IOSVersionBuildRecord] {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw IOSVersionBuildDatabaseError.invalidVersion(value)
        }

        if let byLabel = labelIndex[normalizeLabel(normalized)] {
            return byLabel
        }

        let normalizedBuild = normalizeBuild(normalized)
        if isValidBuildSyntax(normalizedBuild),
           let byBuild = buildIndex[normalizedBuild],
           !byBuild.isEmpty {
            return byBuild
        }

        return try records(forVersion: normalized)
    }

    /// Validates syntax, duplicate records, index consistency, and release-stage
    /// constraints. This does not make claims about exploit support.
    public static func validate() -> IOSVersionBuildValidationReport {
        var issues: [String] = []
        var exactRecordKeys = Set<String>()
        for record in records {
            let versionKey = record.version.description
            let key = "\(versionKey)|\(record.build)|\(record.channel.rawValue)|\(record.sequence.map(String.init) ?? "-")|\(record.label)"

            if !exactRecordKeys.insert(key).inserted {
                issues.append("Duplicate record: \(key)")
            }

            guard IOSVersion.parse(versionKey) != nil else {
                issues.append("Invalid version: \(versionKey)")
                continue
            }

            let range = NSRange(record.build.startIndex..<record.build.endIndex, in: record.build)
            if buildPattern.firstMatch(in: record.build, options: [], range: range) == nil {
                issues.append("Invalid build syntax: \(record.build)")
            }

            if record.channel == .beta && record.sequence == nil {
                issues.append("Beta record without sequence: \(record.label)")
            }

            if record.channel != .beta && record.sequence != nil {
                issues.append("Non-beta record has sequence: \(record.label)")
            }
        }

        for (version, indexedRecords) in versionIndex {
            let direct = records.filter { $0.version == version }
            if Set(indexedRecords) != Set(direct) {
                issues.append("Version index mismatch: \(version)")
            }
        }

        for (build, indexedRecords) in buildIndex {
            let direct = records.filter { $0.build == build }
            if Set(indexedRecords) != Set(direct) {
                issues.append("Build index mismatch: \(build)")
            }
        }

        for (label, indexedRecords) in labelIndex {
            let direct = records.filter { normalizeLabel($0.label) == label }
            if Set(indexedRecords) != Set(direct) {
                issues.append("Label index mismatch: \(label)")
            }
        }

        // The supplied dataset intentionally maps 24A437 to both the final RC
        // and the official 27.0 release. That is valid and must not be flagged.
        let rcFinalBuild = records.filter {
            $0.label == "27.0 RC mới" && $0.build == "24A437"
        }
        let stableFinalBuild = records.filter {
            $0.label == "27.0 chính thức" && $0.build == "24A437"
        }
        if rcFinalBuild.count != 1 || stableFinalBuild.count != 1 {
            issues.append("Expected shared 27.0 RC/final mapping for build 24A437 is missing")
        }

        return IOSVersionBuildValidationReport(issues: issues)
    }

    /// Throws only when the static database itself is malformed.
    public static func validateOrThrow() throws {
        let report = validate()
        if let error = report.error {
            throw error
        }
    }

    private static func normalizeBuild(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidBuildSyntax(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return buildPattern.firstMatch(in: value, options: [], range: range) != nil
    }

    private static func normalizeLabel(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }
}
