import AppKit
import Foundation

func configureImmersivePlayerWindow(_ window: NSWindow) {
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.backgroundColor = .black
}

struct NativeWindowTransitionGate {
    private(set) var isFullscreenTransitioning = false

    mutating func beginFullscreenTransition() -> Bool {
        guard !isFullscreenTransitioning else { return false }
        isFullscreenTransitioning = true
        return true
    }

    mutating func finishFullscreenTransition() {
        isFullscreenTransitioning = false
    }

    mutating func failFullscreenTransition() {
        isFullscreenTransitioning = false
    }
}

final class NativeWindowFailureDelegate: NSObject, NSWindowDelegate {
    var onFullscreenTransitionFailure: (() -> Void)?

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        onFullscreenTransitionFailure?()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        onFullscreenTransitionFailure?()
    }
}
