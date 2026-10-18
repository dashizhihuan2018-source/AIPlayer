import AVFoundation
import Foundation

@main struct NativeClipExporterTests {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("usage: NativeClipExporterTests <owned-mp4> <owned-unsupported-mkv>") }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let original = try Data(contentsOf: source, options: .mappedIfSafe)
        let draft = try NativeToolDraft(kind: .recording)
        defer { draft.close() }
        let exporter = NativeClipExporter()
        var result: Result<Void, Error>?
        exporter.start(source: source, range: NativeClipRange(start: 2, end: 5, duration: 18)!, to: draft.fileURL) { result = $0 }
        try wait({ result }).get()
        let asset = AVURLAsset(url: draft.fileURL)
        precondition(abs(asset.duration.seconds - 3) < 0.15, "exported clip must have the selected three-second duration")
        let reader = try AVAssetReader(asset: asset)
        let track = asset.tracks(withMediaType: .video).first!
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        precondition(reader.startReading())
        var frames = 0
        while let _ = output.copyNextSampleBuffer() { frames += 1 }
        precondition(reader.status == .completed && frames > 30, "exported clip must fully decode")
        let after = try Data(contentsOf: source, options: .mappedIfSafe)
        precondition(original == after, "clip export must not alter the source")

        let unsupported = try NativeToolDraft(kind: .recording)
        var unsupportedResult: Result<Void, Error>?
        NativeClipExporter().start(source: URL(fileURLWithPath: CommandLine.arguments[2]), range: NativeClipRange(start: 2, end: 5, duration: 18)!, to: unsupported.fileURL) { unsupportedResult = $0 }
        guard case .failure = try wait({ unsupportedResult }) else { fatalError("unsupported fixture must not claim successful range export") }
        unsupported.close()
        let cancelled = try NativeToolDraft(kind: .recording)
        let cancellation = NativeClipExporter()
        var cancellationResult: Result<Void, Error>?
        cancellation.cancel()
        cancellation.start(source: source, range: NativeClipRange(start: 2, end: 5, duration: 18)!, to: cancelled.fileURL) { cancellationResult = $0 }
        guard case .failure = try wait({ cancellationResult }) else { fatalError("cancelled export must not complete") }
        cancelled.close()
        precondition(!FileManager.default.fileExists(atPath: cancelled.directory.path))
        print("Native clip export: actual MP4 three-second range, full frame decode, unchanged source, unsupported MKV error and cancellation PASS")
    }
    private static func wait(_ read: () -> Result<Void, Error>?) throws -> Result<Void, Error> {
        let deadline = Date().addingTimeInterval(12)
        while read() == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard let result = read() else { throw MediaToolError.message("owned clip test timed out") }
        return result
    }
}
