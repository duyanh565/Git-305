import Foundation

/// Stable identifier mapping for dynamic UI assets.
///
/// Matching is deliberately identifier-based. It never walks another
/// application's UIKit hierarchy or mutates another application's container.
enum DynamicAssetRouter {
    struct Binding: Hashable, Sendable {
        let targetIdentifier: String
        let assetID: String
    }

    private static let bindings: [Binding] = [
        .init(targetIdentifier: "system-locket", assetID: "icon.locket"),
        .init(targetIdentifier: "patch.app.locket", assetID: "icon.locket"),
        .init(targetIdentifier: "locket", assetID: "icon.locket"),
        .init(targetIdentifier: "com.locket.Locket", assetID: "icon.locket")
    ]

    static func assetID(for identifier: String) -> String? {
        let normalized = normalize(identifier)
        return bindings.first {
            normalize($0.targetIdentifier) == normalized
        }?.assetID
    }

    static func assetURL(for identifier: String) -> URL? {
        guard let id = assetID(for: identifier) else { return nil }
        return DynamicAssetSyncService.cachedURL(forID: id)
    }

    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}
