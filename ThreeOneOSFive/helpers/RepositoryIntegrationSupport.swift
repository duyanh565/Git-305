import Foundation

/// Lightweight presentation gate used by the imported 3105 repository UI.
/// It is intentionally independent of FLUXCORE navigation state.
struct OneShotPresentationGate: Equatable {
    private(set) var hasClaimed = false

    mutating func claim() -> Bool {
        guard !hasClaimed else { return false }
        hasClaimed = true
        return true
    }
}
