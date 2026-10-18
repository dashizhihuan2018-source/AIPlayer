import Foundation

@main struct MPVEngineSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("usage: MPVEngineSmoke <owned-test-media>") }
        let media = URL(fileURLWithPath: CommandLine.arguments[1])
        guard FileManager.default.fileExists(atPath: media.path) else { fatalError("test media does not exist") }

        let engine = try MPVEngine()
        try engine.execute(.mute(true))
        // Leave the first EOF queued, then replace it. Draining must apply events in
        // order so the old EOF cannot mark the replacement item ended.
        try engine.load(media.path, position: 0.3)
        Thread.sleep(forTimeInterval: 0.7)
        try engine.load(media.path, position: 0.1)
        Thread.sleep(forTimeInterval: 0.05)
        engine.drainEvents()
        precondition(!engine.ended, "a queued EOF from the previous item leaked into replacement state")
        precondition(engine.lastError == nil, "a stale load error leaked into replacement state")

        // Pause the short fixture before the resume assertion. Otherwise it can
        // reach EOF while the duration polling loop is still observing startup.
        try engine.execute(.pause(true))
        try engine.load(media.path, position: 0.3)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline,
              engine.double("duration") <= 0 || engine.double("time-pos") < 0.25 {
            engine.drainEvents()
            Thread.sleep(forTimeInterval: 0.05)
        }
        let duration = engine.double("duration")
        precondition(duration > 0.3 && duration < 2, "libmpv did not parse/decode the owned test media")
        precondition(engine.double("time-pos") >= 0.25, "load start option did not preserve the requested resume position")
        precondition(engine.string("mpv-version").contains("mpv"), "libmpv version property unavailable")

        try engine.execute(.pause(false))
        let firstEOF = Date().addingTimeInterval(2)
        while Date() < firstEOF, !engine.ended {
            engine.drainEvents()
            Thread.sleep(forTimeInterval: 0.03)
        }
        precondition(engine.ended, "first EOF edge was not observed")
        try engine.execute(.seek(0.1))
        engine.drainEvents()
        precondition(!engine.ended, "seek did not clear sticky EOF")
        let secondEOF = Date().addingTimeInterval(2)
        while Date() < secondEOF, !engine.ended {
            engine.drainEvents()
            Thread.sleep(forTimeInterval: 0.03)
        }
        precondition(engine.ended, "second EOF edge after seek was not observed")

        // mpv_command(loadfile) accepts work before demux succeeds. Verify the
        // bridge-visible lifecycle reports the later asynchronous failure.
        let missing = media.deletingLastPathComponent().appendingPathComponent("missing-\(UUID().uuidString).wav")
        let missingEntryID = try engine.load(missing.path, position: nil)
        var asynchronousFailure: Int32?
        var missingLoaded = false
        let failureDeadline = Date().addingTimeInterval(2)
        while Date() < failureDeadline, asynchronousFailure == nil {
            for event in engine.drainEvents() {
                switch event {
                case .fileLoaded(let entryID) where entryID == missingEntryID: missingLoaded = true
                case .ended(let entryID, let error) where entryID == missingEntryID && error < 0: asynchronousFailure = error
                default: break
                }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        precondition(!missingLoaded, "missing media must never produce FILE_LOADED success")
        precondition(asynchronousFailure != nil, "accepted loadfile did not surface its asynchronous END_FILE error")
        try engine.execute(.stop)
        print("Native libmpv smoke: owned WAV decoded, EOF-seek-EOF and async load error PASS; duration=\(String(format: "%.3f", duration))s")
    }
}
