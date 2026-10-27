import Foundation

enum ExploitSupportPolicy {
    /// UI/application compatibility policy.
    /// This is intentionally separate from kernel/exploit applicability:
    /// a version can be displayed as supported even when no native exploit
    /// backend is applicable to that OS release.
    static let supportedLegacyIOSRange = "10.0–17.x"
    static let verifiedIOS17Range = "17.0–17.7.x"
    static let verifiedIOS18Range = "18.0–18.7.1"
    static let verifiedIOS26Range = "26.0–26.6.2"

    static let explicitlySupportedIOS26 = (major: 26, minor: 6, patch: 2)

    static let verifiedIOS27Builds: [(beta: Int, publicBeta: Int?, build: String)] = [
        (1, nil, "24A5355q"),
        (2, nil, "24A5370h"),
        (3, 1, "24A5380h"),
        (4, 2, "24A5390f")
    ]

    static func iOS27BetaNumber(for build: String) -> Int? {
        verifiedIOS27Builds.first { $0.build == build }?.beta
    }

    static func iOS27PublicBetaNumber(for build: String) -> Int? {
        verifiedIOS27Builds.first { $0.build == build }?.publicBeta
    }

    /// Kernel exploit applicability is deliberately narrower than the public
    /// compatibility policy. Do not use this method to decide whether the UI
    /// should display "Device Supported".
    static func supportsKernelExploit(major: Int, minor: Int, patch: Int) -> Bool {
        guard minor >= 0, patch >= 0 else { return false }

        if major == 17 {
            return minor <= 7
        }

        if major == 18 {
            return minor < 7 || (minor == 7 && patch <= 1)
        }

        return false
    }

    /// Public support status used by AppState/UI.
    ///
    /// iOS 10 through iOS 17 are explicitly accepted by policy, independent
    /// of exploit applicability. iOS 26.6.2 is also explicitly accepted.
    /// Existing iOS 18, 26.0–26.6.1 and verified iOS 27 beta support remains
    /// intact.
    static func isSupported(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        guard major >= 0, minor >= 0, patch >= 0 else { return false }

        // Explicit application compatibility override: iOS 10.x–17.x.
        if (10...17).contains(major) {
            return true
        }

        if major == 18 {
            return minor < 7 || (minor == 7 && patch <= 1)
        }

        if major == 26 {
            return minor < 6 || (minor == 6 && patch <= 2)
        }

        guard major == 27, minor == 0, patch == 0 else { return false }
        return iOS27BetaNumber(for: build) != nil
    }
}
