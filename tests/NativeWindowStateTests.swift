import AppKit
import Foundation

@main struct NativeWindowStateTests {
    static func main() {
        var gate = NativeWindowTransitionGate()
        precondition(gate.beginFullscreenTransition(), "first fullscreen transition must start")
        precondition(gate.isFullscreenTransitioning, "transition must be observable")
        precondition(!gate.beginFullscreenTransition(), "duplicate fullscreen request must be rejected")
        gate.finishFullscreenTransition()
        precondition(!gate.isFullscreenTransitioning, "didEnter/didExit must clear transition state")
        precondition(gate.beginFullscreenTransition(), "a completed transition must allow the next toggle")
        gate.failFullscreenTransition()
        precondition(!gate.isFullscreenTransitioning, "failed AppKit transition must reopen the gate")

        let delegate = NativeWindowFailureDelegate()
        var failureCallbacks = 0
        delegate.onFullscreenTransitionFailure = { failureCallbacks += 1 }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        delegate.windowDidFailToEnterFullScreen(window)
        delegate.windowDidFailToExitFullScreen(window)
        precondition(failureCallbacks == 2, "both real NSWindowDelegate failure callbacks must be relayed")
        configureImmersivePlayerWindow(window)
        precondition(window.styleMask.contains(.fullSizeContentView), "video must extend behind the native title bar")
        precondition(window.titlebarAppearsTransparent, "the player must not retain a solid website-like title strip")
        precondition(window.titleVisibility == .hidden, "the in-video title replaces the system title text")
        print("Native window state: duplicate guard, completion and AppKit failure recovery PASS")
    }
}
