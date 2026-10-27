import AppKit
import Foundation
import IOKit.pwr_mgt

/// Full-size WKWebView consumes mouseDown before AppKit's titlebar can drag.
/// Route only the non-interactive native top strip, never the whole video.
final class NativeTitlebarDragController {
    private var monitor: Any?
    private var drag: NativeWindowDragSession?
    static func isDragPoint(_ point: NSPoint, size: NSSize, fullscreen: Bool) -> Bool {
        !fullscreen && point.x >= 160 && point.x < size.width - 360
            && point.y >= size.height - 28 && point.y < size.height
    }
    init(window: NSWindow) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self, weak window] event in
            guard let self, let window else { return event }
            if let drag = self.drag {
                guard event.window === window, !window.styleMask.contains(.fullScreen) else {
                    self.drag = nil; return event
                }
                if event.type == .leftMouseDragged {
                    window.setFrameOrigin(drag.origin(at: window.convertPoint(toScreen: event.locationInWindow)))
                    return nil
                }
                if event.type == .leftMouseUp { self.drag = nil; return nil }
            }
            guard event.type == .leftMouseDown else { return event }
            guard event.window === window, window.attachedSheet == nil,
                  let content = window.contentView,
                  Self.isDragPoint(content.convert(event.locationInWindow, from: nil), size: content.bounds.size,
                                   fullscreen: window.styleMask.contains(.fullScreen)) else { return event }
            if event.clickCount == 2 { window.zoom(nil) }
            else { self.drag = NativeWindowDragSession(windowOrigin: window.frame.origin,
                                                       mouseOrigin: window.convertPoint(toScreen: event.locationInWindow)) }
            return nil
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

/// Screen-space anchors remain stable as the window moves under the pointer.
struct NativeWindowDragSession {
    let windowOrigin: NSPoint
    let mouseOrigin: NSPoint
    func origin(at mouse: NSPoint) -> NSPoint {
        NSPoint(x: windowOrigin.x + mouse.x - mouseOrigin.x,
                y: windowOrigin.y + mouse.y - mouseOrigin.y)
    }
}

/// Prevent automatic idle display sleep only; never change lock settings or
/// defeat an explicit lock, lid close, or user-initiated sleep.
final class NativePlaybackPower {
    private var assertion: IOPMAssertionID = 0
    var isActive: Bool { assertion != 0 }
    func update(enabled: Bool, playing: Bool) {
        guard enabled && playing else { release(); return }
        guard !isActive else { return }
        var identifier: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                      IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                      "AIPlayer active playback" as CFString, &identifier) == kIOReturnSuccess {
            assertion = identifier
        }
    }
    func release() {
        if isActive { IOPMAssertionRelease(assertion); assertion = 0 }
    }
    deinit { release() }
}

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
