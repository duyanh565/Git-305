// FloatingButtonWindow.swift
// ThreeOneOSFive
// REQ 1: Floating draggable music button đã bị XÓA.
// FloatingWindowManager.shared.show() trong App.swift giờ là no-op.
// Nút nhạc di chuyển được thay bằng:
//   - Nút nhạc cố định góc trên phải (toolbar navigationBar)
//   - BubbleControlBar trong Home (nhạc + cài đặt, bubble style)

import UIKit

// MARK: - FloatingWindowManager (kept for API compatibility — show() is now a no-op)
final class FloatingWindowManager {
    static let shared = FloatingWindowManager()
    private init() {}

    private(set) var isMenuVisible: Bool = false

    /// No-op: floating draggable music button has been removed per REQ 1.
    /// Music control is now handled by the toolbar button and BubbleControlBar in DashboardView.
    func show() {
        // Intentionally empty — floating button removed
    }

    func hide() {
        // Intentionally empty
    }
}
