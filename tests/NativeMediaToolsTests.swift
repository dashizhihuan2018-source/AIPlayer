import AppKit
import Foundation
import ImageIO

@main struct MediaToolsTests {
    static func main() throws {
        precondition(GIFCaptureSettings(duration: 3, fps: 10) != nil)
        for (duration, fps) in [(0.0,10), (11,10), (Double.nan,10), (3,0), (3,31)] {
            precondition(GIFCaptureSettings(duration: duration, fps: fps) == nil)
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 240,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 240).fill()
        ("AIPlayer LOCAL OCR 2026" as NSString).draw(at: NSPoint(x: 30, y: 90), withAttributes: [
            .font: NSFont.systemFont(ofSize: 46, weight: .bold), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let image = bitmap.cgImage!
        let text = try NativeMediaTools.recognize(image)
        precondition(text.contains("LOCAL OCR 2026"), "actual OCR failed: \(text)")
        let resized = try NativeMediaTools.resized(image, maximumWidth: 640)
        precondition(resized.width == 640 && resized.height <= 240)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("test.gif")
        let writer = try GIFFrameWriter(url: output, frameCount: 2, fps: 10)
        try writer.append(image); try writer.append(image); try writer.finish()
        let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
        precondition(CGImageSourceGetCount(source) == 2)
        precondition(CGImageSourceCreateImageAtIndex(source, 0, nil)!.width == 640, "default GIF resolution remains 640px")
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        let gif = properties[kCGImagePropertyGIFDictionary] as! NSDictionary
        precondition(abs((gif[kCGImagePropertyGIFUnclampedDelayTime] as! NSNumber).doubleValue - 0.1) < 0.001)
        do { try writer.append(image); preconditionFailure("append after finish accepted") } catch {}
        let tools = NativeMediaTools { target in
            try bitmap.representation(using: .png, properties: [:])!.write(to: target)
        }
        let capturedText = try tools.recognizeCurrentFrame()
        precondition(capturedText.contains("LOCAL OCR 2026"))
        var completed: Result<Int, Error>?
        let timed = directory.appendingPathComponent("timed.gif")
        try tools.captureGIF(to: timed, settings: GIFCaptureSettings(duration: 0.2, fps: 10)!) { completed = $0 }
        let deadline = Date().addingTimeInterval(2)
        while completed == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let completedFrames = try completed!.get()
        precondition(completedFrames == 2)
        precondition(CGImageSourceGetCount(CGImageSourceCreateWithURL(timed as CFURL, nil)!) == 2)
        let protected = directory.appendingPathComponent("existing.gif")
        let sentinel = Data("previous-user-file".utf8)
        try sentinel.write(to: protected)
        var collision: Result<Int, Error>?
        do {
            try tools.captureGIF(to: protected, settings: GIFCaptureSettings(duration: 0.2, fps: 10)!) { collision = $0 }
            let collisionDeadline = Date().addingTimeInterval(2)
            while collision == nil && Date() < collisionDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            if case .success? = collision { preconditionFailure("GIF must not overwrite an existing user file") }
        } catch {}
        let afterCollision = try Data(contentsOf: protected)
        precondition(afterCollision == sentinel)
        var cancellation: Result<Int, Error>?
        try tools.captureGIF(to: directory.appendingPathComponent("cancelled.gif"), settings: GIFCaptureSettings(duration: 1, fps: 10)!) { cancellation = $0 }
        tools.cancelCapture()
        precondition(!tools.isCapturing && cancellation != nil)
        let preservedData = try Data(contentsOf: protected)
        precondition(preservedData == sentinel, "cancel must preserve existing save target")
        var sequence = 0
        var captureDirectories = Set<URL>()
        let moving = NativeMediaTools { target in
            captureDirectories.insert(target.deletingLastPathComponent())
            sequence += 1
            let frame = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: frame)
            (sequence % 2 == 0 ? NSColor.blue : NSColor.red).setFill()
            NSRect(x: 0, y: 0, width: 32, height: 24).fill()
            NSGraphicsContext.restoreGraphicsState()
            try frame.representation(using: .png, properties: [:])!.write(to: target)
        }
        var manual: Result<Int, Error>?
        let manualURL = directory.appendingPathComponent("manual.gif")
        try moving.startGIF(to: manualURL, fps: 10) { manual = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(3.2))
        precondition(moving.isCapturing && manual == nil, "manual GIF must continue past the old three-second boundary")
        precondition(moving.capturedFrameCount >= 30 && moving.captureDuration >= 3)
        moving.finishCapture()
        let finishDeadline = Date().addingTimeInterval(5)
        while manual == nil && Date() < finishDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let manualCount = try manual!.get()
        let manualSource = CGImageSourceCreateWithURL(manualURL as CFURL, nil)!
        precondition(CGImageSourceGetCount(manualSource) == manualCount && manualCount >= 30)
        let firstPixel = NSBitmapImageRep(cgImage: CGImageSourceCreateImageAtIndex(manualSource, 0, nil)!).colorAt(x: 2, y: 2)!
        let secondPixel = NSBitmapImageRep(cgImage: CGImageSourceCreateImageAtIndex(manualSource, 1, nil)!).colorAt(x: 2, y: 2)!
        precondition(firstPixel != secondPixel, "GIF must contain distinct real source frames")
        var duration = 0.0
        for index in 0..<manualCount {
            let properties = CGImageSourceCopyPropertiesAtIndex(manualSource, index, nil)! as NSDictionary
            duration += ((properties[kCGImagePropertyGIFDictionary] as! NSDictionary)[kCGImagePropertyGIFUnclampedDelayTime] as! NSNumber).doubleValue
        }
        precondition(abs(duration - moving.captureDuration) < 0.1, "manual GIF timing must track actual recording duration")
        var immediate: Result<Int, Error>?
        let immediateURL = directory.appendingPathComponent("immediate.gif")
        try moving.startGIF(to: immediateURL, fps: 10, maximumWidth: 3840) { immediate = $0 }
        moving.finishCapture()
        let immediateDeadline = Date().addingTimeInterval(5)
        while immediate == nil && Date() < immediateDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let immediateCount = try immediate!.get()
        precondition(immediateCount == 1, "immediate stop should save its first frame")
        let smallImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(immediateURL as CFURL, nil)!, 0, nil)!
        precondition(smallImage.width == 32 && smallImage.height == 24, "4K selection must not upscale a small source")
        let cancelledURL = directory.appendingPathComponent("manual-cancelled.gif")
        var manualCancelled: Result<Int, Error>?
        try moving.startGIF(to: cancelledURL, fps: 10) { manualCancelled = $0 }
        moving.cancelCapture()
        precondition(!moving.isCapturing && manualCancelled != nil && !FileManager.default.fileExists(atPath: cancelledURL.path))
        let encodingCancelledURL = directory.appendingPathComponent("encoding-cancelled.gif")
        var encodingCallbacks = 0
        try moving.startGIF(to: encodingCancelledURL, fps: 10) { _ in encodingCallbacks += 1 }
        moving.finishCapture()
        precondition(moving.isProcessingGIF && !moving.isCapturing)
        do {
            try moving.startGIF(to: directory.appendingPathComponent("overlap.gif"), fps: 10) { _ in }
            preconditionFailure("a second GIF must not replace one that is encoding")
        } catch {}
        moving.cancelCapture()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(encodingCallbacks == 1 && !moving.isProcessingGIF)
        precondition(!FileManager.default.fileExists(atPath: encodingCancelledURL.path))
        precondition(captureDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "completed/cancelled GIF frame caches must be removed")
        func fourKFrame(_ red: Bool) -> CGImage {
            let context = CGContext(data: nil, width: 3840, height: 2160, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(red ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 3840, height: 2160))
            for row in 0..<12 {
                for column in 0..<24 {
                    let hue = CGFloat((row * 24 + column + (red ? 0 : 80)) % 288) / 288
                    context.setFillColor(NSColor(calibratedHue: hue, saturation: 0.8, brightness: 0.9, alpha: 1).cgColor)
                    context.fill(CGRect(x: column * 160, y: row * 180, width: 154, height: 174))
                }
            }
            return context.makeImage()!
        }
        func assertFourKGIF(_ url: URL, frames: Int) {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            precondition(CGImageSourceGetCount(source) == frames)
            for index in 0..<frames {
                let image = CGImageSourceCreateImageAtIndex(source, index, nil)!
                precondition(image.width == 3840 && image.height == 2160, "4K input must produce actual 3840 × 2160 GIF frames")
            }
        }
        let fourKURL = directory.appendingPathComponent("native-four-k.gif")
        let fourKWriter = try GIFFrameWriter(url: fourKURL, frameCount: 2, fps: 10, maximumWidth: 3840)
        try autoreleasepool { try fourKWriter.append(fourKFrame(true)); try fourKWriter.append(fourKFrame(false)); try fourKWriter.finish() }
        assertFourKGIF(fourKURL, frames: 2)
        var fourKSnapshots = 0
        let fourKTools = NativeMediaTools { target in
            fourKSnapshots += 1
            let image = fourKFrame(fourKSnapshots % 2 == 0)
            let destination = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination))
        }
        let sampled4KURL = directory.appendingPathComponent("sampled-four-k.gif")
        var fourKResult: Result<Int, Error>?
        try fourKTools.startGIF(to: sampled4KURL, fps: 10, maximumWidth: 3840) { fourKResult = $0 }
        let capture4KDeadline = Date().addingTimeInterval(10)
        while fourKTools.capturedFrameCount < 2 && Date() < capture4KDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(fourKTools.capturedFrameCount >= 2)
        fourKTools.finishCapture()
        let encode4KDeadline = Date().addingTimeInterval(15)
        while fourKResult == nil && Date() < encode4KDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let fourKFrames = try fourKResult!.get()
        assertFourKGIF(sampled4KURL, frames: fourKFrames)
        let slowURL = directory.appendingPathComponent("slow-sampling.gif")
        let slowTools = NativeMediaTools { target in
            Thread.sleep(forTimeInterval: 0.16) // Simulate costly original-resolution screenshot encoding.
            try bitmap.representation(using: .png, properties: [:])!.write(to: target)
        }
        var slowResult: Result<Int, Error>?
        let slowStart = Date()
        try slowTools.startGIF(to: slowURL, fps: 10) { slowResult = $0 }
        let slowCaptureDeadline = Date().addingTimeInterval(3)
        while slowTools.capturedFrameCount < 3 && Date() < slowCaptureDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let slowWallDuration = Date().timeIntervalSince(slowStart)
        precondition(abs(slowTools.captureDuration - slowWallDuration) < 0.04, "recording UI must not count frames/fps when capture is slow")
        slowTools.finishCapture()
        let slowDeadline = Date().addingTimeInterval(5)
        while slowResult == nil && Date() < slowDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let slowFrames = try slowResult!.get()
        let slowSource = CGImageSourceCreateWithURL(slowURL as CFURL, nil)!
        var slowEncodedDuration = 0.0
        for index in 0..<slowFrames {
            let properties = CGImageSourceCopyPropertiesAtIndex(slowSource, index, nil)! as NSDictionary
            let delay = ((properties[kCGImagePropertyGIFDictionary] as! NSDictionary)[kCGImagePropertyGIFUnclampedDelayTime] as! NSNumber).doubleValue
            precondition(delay >= 0.02)
            slowEncodedDuration += delay
        }
        precondition(abs(slowEncodedDuration - slowWallDuration) < 0.06, "slow high-resolution captures must not produce a fast-forwarded GIF")
        var pendingSamples: [(Result<CGImage, Error>) -> Void] = []
        let asynchronous = NativeMediaTools(snapshot: { _ in preconditionFailure("GIF must not use the synchronous PNG path") }, gifSnapshot: { _, done in pendingSamples.append(done) })
        var asyncResult: Result<Int, Error>?
        let asyncURL = directory.appendingPathComponent("async.gif")
        try asynchronous.startGIF(to: asyncURL, fps: 20) { asyncResult = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(pendingSamples.count == 1, "only one capture may be in flight, even when a provider is slow")
        asynchronous.finishCapture()
        precondition(asyncResult == nil && asynchronous.isProcessingGIF && !asynchronous.isCapturing, "stop must await the last background sample")
        pendingSamples.removeFirst()(.success(image))
        let asyncDeadline = Date().addingTimeInterval(5)
        while asyncResult == nil && Date() < asyncDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let asyncFrames = try asyncResult!.get()
        precondition(asyncFrames == 1 && FileManager.default.fileExists(atPath: asyncURL.path))
        var staleReplies = 0
        let staleURL = directory.appendingPathComponent("async-cancelled.gif")
        try asynchronous.startGIF(to: staleURL, fps: 20) { _ in staleReplies += 1 }
        let staleSample = pendingSamples.removeFirst()
        asynchronous.cancelCapture()
        let nextURL = directory.appendingPathComponent("async-next.gif")
        var nextResult: Result<Int, Error>?
        try asynchronous.startGIF(to: nextURL, fps: 20) { nextResult = $0 }
        asynchronous.finishCapture()
        staleSample(.success(image))
        pendingSamples.removeFirst()(.success(image))
        let nextDeadline = Date().addingTimeInterval(5)
        while nextResult == nil && Date() < nextDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let nextFrames = try nextResult!.get()
        precondition(staleReplies == 1 && nextFrames == 1 && !FileManager.default.fileExists(atPath: staleURL.path), "stale background replies must not publish or corrupt a subsequent capture")
        print("Native media tools: OCR, fixed/manual/async GIF, single-flight, pending-stop, stale cancellation, timing, 4K and no-overwrite PASS")
    }
}
