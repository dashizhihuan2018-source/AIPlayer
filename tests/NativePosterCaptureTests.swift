import AppKit
import Foundation
import ImageIO
import Vision

@main struct NativePosterCaptureTests {
    static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-poster-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = PosterMetadata(title: "Owned test media", duration: 70, width: 640, height: 360)
        precondition(metadata.timestamps == [10, 20, 30, 40, 50, 60])
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 36, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = image.representation(using: .png, properties: [:])!
        var positions: [Double] = []
        var restores = 0
        let capture = NativePosterCapture(metadata: metadata, snapshot: { position, destination, done in
            positions.append(position)
            do { try png.write(to: destination); DispatchQueue.main.async { done(.success(())) } }
            catch { done(.failure(error)) }
        }, restore: { restores += 1 })
        var result: Result<Int, Error>?
        let output = directory.appendingPathComponent("poster.png")
        try capture.start(to: output) { result = $0 }
        let deadline = Date().addingTimeInterval(4)
        while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard case .success(let count)? = result else { print("FAIL six-frame poster must encode a real PNG"); exit(1) }
        precondition(count == 6 && positions == metadata.timestamps && restores == 1)
        let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        guard decoded.width == 1200 && decoded.height == 1800 else {
            print("FAIL movie poster must be portrait 1200 × 1800, got \(decoded.width) × \(decoded.height)")
            exit(1)
        }
        let barcode = VNDetectBarcodesRequest()
        barcode.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: decoded).perform([barcode])
        precondition(barcode.results?.contains { $0.payloadStringValue == "https://github.com/dashizhihuan2018-source/AIPlayer" } == true,
            "movie poster must contain the real, decodable project QR")
        if CommandLine.arguments.count > 1 {
            try Data(contentsOf: output).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }

        // Cancellation and a late snapshot callback must restore once, never
        // overwrite a preexisting user file, and never complete a second time.
        let protected = directory.appendingPathComponent("protected.png")
        let sentinel = Data("previous-user-file".utf8)
        try sentinel.write(to: protected)
        var pending: ((Result<Void, Error>) -> Void)?
        var cancelledCount = 0
        let cancelled = NativePosterCapture(metadata: metadata, snapshot: { _, _, done in pending = done }, restore: { restores += 1 })
        try cancelled.start(to: protected) { _ in cancelledCount += 1 }
        cancelled.cancel()
        pending?(.success(()))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(restores == 2 && cancelledCount == 1)
        let preserved = try Data(contentsOf: protected)
        precondition(preserved == sentinel)

        var timedOut: Result<Int, Error>?
        let timeout = NativePosterCapture(metadata: metadata, frameTimeout: 0.03, snapshot: { _, _, _ in }, restore: { restores += 1 })
        try timeout.start(to: protected) { timedOut = $0 }
        let timeoutDeadline = Date().addingTimeInterval(1)
        while timedOut == nil && Date() < timeoutDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard case .failure? = timedOut else { fatalError("stalled frame must time out") }
        precondition(restores == 3)

        var failed: Result<Int, Error>?
        let failure = NativePosterCapture(metadata: metadata, snapshot: { _, _, done in done(.failure(MediaToolError.message("owned test failure"))) }, restore: { restores += 1 })
        try failure.start(to: protected) { failed = $0 }
        guard case .failure? = failed else { fatalError("failed frame must fail poster") }
        precondition(restores == 4)
        let stillPreserved = try Data(contentsOf: protected)
        precondition(stillPreserved == sentinel)
        // Network posters use the already-decoded current frame, not six
        // disruptive remote seeks. Never pad a single frame into fake stills.
        var currentMetadata = metadata
        currentMetadata.captureTimes = [13]
        var currentPositions: [Double] = []
        var currentResult: Result<Int, Error>?
        let current = NativePosterCapture(metadata: currentMetadata, snapshot: { position, destination, done in
            currentPositions.append(position)
            do { try png.write(to: destination); done(.success(())) } catch { done(.failure(error)) }
        }, restore: {})
        try current.start(to: directory.appendingPathComponent("current.png")) { currentResult = $0 }
        let currentDeadline = Date().addingTimeInterval(4)
        while currentResult == nil && Date() < currentDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard case .success(1)? = currentResult, currentPositions == [13] else {
            print("FAIL current-frame movie poster must capture exactly one real frame without seeking")
            exit(1)
        }
        for duration in [0, -1, Double.nan, Double.infinity, 604_801] {
            let invalid = NativePosterCapture(metadata: PosterMetadata(title: "test", duration: duration, width: 640, height: 360), snapshot: { _, _, _ in fatalError("invalid input started decoding") }, restore: {})
            do { try invalid.start(to: protected) { _ in }; fatalError("invalid duration accepted") } catch {}
        }
        print("Native poster: six bounded timeline frames, real PNG, restore, cancellation, timeout, failure and guards PASS")
    }
}
