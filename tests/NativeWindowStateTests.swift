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
        let size = NSSize(width: 1240, height: 820)
        precondition(NativeTitlebarDragController.isDragPoint(NSPoint(x: 620, y: 810), size: size, fullscreen: false))
        precondition(!NativeTitlebarDragController.isDragPoint(NSPoint(x: 120, y: 810), size: size, fullscreen: false), "traffic lights and web menu must not be intercepted")
        precondition(!NativeTitlebarDragController.isDragPoint(NSPoint(x: 1200, y: 810), size: size, fullscreen: false), "online resource actions must remain clickable")
        precondition(!NativeTitlebarDragController.isDragPoint(NSPoint(x: 620, y: 700), size: size, fullscreen: false), "video controls must remain interactive")
        precondition(!NativeTitlebarDragController.isDragPoint(NSPoint(x: 620, y: 810), size: size, fullscreen: true), "fullscreen must not be moved")
        let drag = NativeWindowDragSession(windowOrigin: NSPoint(x: -2069, y: 180), mouseOrigin: NSPoint(x: -1569, y: 900))
        precondition(drag.origin(at: NSPoint(x: -1469, y: 800)) == NSPoint(x: -1969, y: 80), "drag uses stable screen deltas across displays")
        precondition(drag.origin(at: NSPoint(x: -1619, y: 950)) == NSPoint(x: -2119, y: 230), "subsequent moves retain the original anchor")
        let power = NativePlaybackPower()
        power.update(enabled: true, playing: false)
        precondition(!power.isActive)
        power.update(enabled: true, playing: true)
        precondition(power.isActive, "real IOKit display assertion must be acquired")
        power.update(enabled: true, playing: true)
        precondition(power.isActive, "repeated ticks keep one assertion")
        power.update(enabled: true, playing: false)
        precondition(!power.isActive, "pause releases assertion")
        power.update(enabled: true, playing: true)
        power.update(enabled: false, playing: true)
        precondition(!power.isActive, "disabled setting releases assertion")
        power.update(enabled: true, playing: true)
        power.release()
        precondition(!power.isActive, "shutdown releases assertion")
        print("Native window state: duplicate guard, completion and AppKit failure recovery PASS")
    }
}
