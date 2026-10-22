import Foundation

@main struct NativeBridgeTests {
    static func main() throws {
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            assertions += 1
            precondition(condition, message)
        }
        func rejects(_ body: () throws -> Void, _ message: String) {
            assertions += 1
            do {
                try body()
                preconditionFailure(message)
            } catch is NativeBridgeValidationError {
                // Expected validation refusal.
            } catch {
                preconditionFailure("Unexpected error for \(message): \(error)")
            }
        }

        let origin = URL(string: "http://127.0.0.1:18784/")!
        check(NativeBridgePolicy.isTrustedFrame(isMainFrame: true, sourceURL: origin), "exact app origin must be trusted")
        check(!NativeBridgePolicy.isTrustedFrame(isMainFrame: false, sourceURL: origin), "subframes must be refused")
        check(!NativeBridgePolicy.isTrustedFrame(isMainFrame: true, sourceURL: URL(string: "http://localhost:18784/")!), "localhost alias must be refused")
        check(!NativeBridgePolicy.isTrustedFrame(isMainFrame: true, sourceURL: URL(string: "https://127.0.0.1:18784/")!), "HTTPS lookalike must be refused")
        check(!NativeBridgePolicy.isTrustedFrame(isMainFrame: true, sourceURL: URL(string: "http://127.0.0.1:18785/")!), "wrong port must be refused")

        check(try NativeBridgePolicy.validateRequest(command: "capabilities", args: [:], authorizedLocalIDs: []) == .capabilities, "known command must validate")
        check(try NativeBridgePolicy.validateRequest(command: "ocr", args: [:], authorizedLocalIDs: []) == .ocr, "OCR must accept no path or arbitrary input")
        var manualGIFAccepted = false
        do { _ = try NativeBridgePolicy.validateRequest(command: "gifStart", args: ["fps": 10, "maximumWidth": 640], authorizedLocalIDs: []); manualGIFAccepted = true } catch {}
        check(manualGIFAccepted, "manual GIF start must not require a fixed duration")
        var gifFolderAccepted = false
        do { _ = try NativeBridgePolicy.validateRequest(command: "openGifFolder", args: [:], authorizedLocalIDs: []); gifFolderAccepted = true } catch {}
        check(gifFolderAccepted, "GIF output folder must have a dedicated safe route")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "openGifFolder", args: ["path": "/etc"], authorizedLocalIDs: []) }, "folder opener must not accept arbitrary paths")
        for width in [640, 1280, 1920, 3840] {
            var accepted = false
            do { _ = try NativeBridgePolicy.validateRequest(command: "gifStart", args: ["fps": 10, "maximumWidth": width], authorizedLocalIDs: []); accepted = true } catch {}
            check(accepted, "GIF resolution preset must validate")
        }
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "gifStart", args: ["fps": 10, "maximumWidth": 100_000], authorizedLocalIDs: []) }, "GIF must reject unbounded dimensions")
        for command in ["gifStop", "gifCancel"] {
            var accepted = false
            do { _ = try NativeBridgePolicy.validateRequest(command: command, args: [:], authorizedLocalIDs: []); accepted = true } catch {}
            check(accepted, "manual GIF must support stop and cancel")
            rejects({ _ = try NativeBridgePolicy.validateRequest(command: command, args: ["path": "/tmp/untrusted"], authorizedLocalIDs: []) }, "GIF commands must not accept caller paths")
        }
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "gifStart", args: ["fps": 10, "duration": 3], authorizedLocalIDs: []) }, "manual GIF must not accept a hidden fixed duration")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "gifStart", args: ["fps": 31], authorizedLocalIDs: []) }, "GIF frame rate must remain bounded")
        check(try NativeBridgePolicy.validateRequest(command: "captureGif", args: ["duration": 3.0, "fps": 10], authorizedLocalIDs: []) == .captureGIF(duration: 3, fps: 10), "bounded GIF settings must validate")
        var posterAccepted = false
        do { _ = try NativeBridgePolicy.validateRequest(command: "capturePoster", args: [:], authorizedLocalIDs: []); posterAccepted = true } catch {}
        check(posterAccepted, "poster capture must accept an empty request")
        var namedPosterAccepted = false
        do { _ = try NativeBridgePolicy.validateRequest(command: "capturePoster", args: ["title": "自有测试片名"], authorizedLocalIDs: []); namedPosterAccepted = true } catch {}
        check(namedPosterAccepted, "movie poster must accept the actual displayed video title")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "capturePoster", args: ["title": String(repeating: "x", count: 501)], authorizedLocalIDs: []) }, "poster title must be bounded")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "capturePoster", args: ["path": "/tmp/arbitrary"], authorizedLocalIDs: []) }, "poster capture must reject caller-supplied paths")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "captureGif", args: ["duration": 10.1, "fps": 10], authorizedLocalIDs: []) }, "overlong GIF capture must be refused")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "captureGif", args: ["duration": 3.0, "fps": 31], authorizedLocalIDs: []) }, "excessive GIF frame rate must be refused")
        check(try NativeBridgePolicy.validateRequest(command: "recordStart", args: [:], authorizedLocalIDs: []) == .recordStart, "record start must accept no JavaScript path")
        check(try NativeBridgePolicy.validateRequest(command: "recordStop", args: [:], authorizedLocalIDs: []) == .recordStop, "record stop must accept no JavaScript path")
        check(try NativeBridgePolicy.validateRequest(command: "mediaReady", args: [:], authorizedLocalIDs: []) == .mediaReady, "media readiness handshake must have no arguments")
        check(try NativeBridgePolicy.validateRequest(command: "mediaNotReady", args: [:], authorizedLocalIDs: []) == .mediaNotReady, "media teardown handshake must have no arguments")
        check(try NativeBridgePolicy.validateRequest(command: "pictureInPicture", args: ["enabled": true], authorizedLocalIDs: []) == .pictureInPicture(true), "native picture-in-picture must validate a boolean")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "pictureInPicture", args: ["enabled": "yes"], authorizedLocalIDs: []) }, "picture-in-picture must refuse non-boolean input")
        check(try NativeBridgePolicy.validateRequest(command: "getWindowState", args: [:], authorizedLocalIDs: []) == .getWindowState, "window state query must validate without arguments")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "getWindowState", args: ["fake": true], authorizedLocalIDs: []) }, "window state query must refuse extra arguments")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "mediaNotReady", args: ["fake": true], authorizedLocalIDs: []) }, "media teardown handshake must refuse extra arguments")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "shell", args: [:], authorizedLocalIDs: []) }, "unknown bridge command must be refused")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "getProperty", args: ["name": "path"], authorizedLocalIDs: []) }, "arbitrary property access must be refused")

        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "load", args: ["id": "not-authorized"], authorizedLocalIDs: []) }, "unknown local media id must be refused")
        check(try NativeBridgePolicy.validateRequest(command: "load", args: ["id": "media-1"], authorizedLocalIDs: ["media-1"]) == .loadLocal(id: "media-1", position: nil), "authorized opaque id must validate")
        check(try NativeBridgePolicy.validateRequest(command: "load", args: ["url": "https://media.example/movie.mkv", "position": 12.5], authorizedLocalIDs: []) == .loadURL(URL(string: "https://media.example/movie.mkv")!, position: 12.5), "HTTPS media URL must validate")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "load", args: ["url": "file:///etc/passwd"], authorizedLocalIDs: []) }, "file URL from JavaScript must be refused")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "load", args: ["url": "javascript:alert(1)"], authorizedLocalIDs: []) }, "javascript URL must be refused")

        check(try NativeBridgePolicy.validateRequest(command: "command", args: ["name": "seek", "value": 120.25], authorizedLocalIDs: []) == .engine(.seek(120.25)), "finite seek must validate")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "command", args: ["name": "seek", "value": -0.01], authorizedLocalIDs: []) }, "negative seek must be refused")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "command", args: ["name": "seek", "value": Double.infinity], authorizedLocalIDs: []) }, "non-finite seek must be refused")
        check(try NativeBridgePolicy.validateRequest(command: "command", args: ["name": "speed", "value": 0.25], authorizedLocalIDs: []) == .engine(.speed(0.25)), "lower speed bound must validate")
        check(try NativeBridgePolicy.validateRequest(command: "command", args: ["name": "speed", "value": 4.0], authorizedLocalIDs: []) == .engine(.speed(4.0)), "upper speed bound must validate")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "command", args: ["name": "speed", "value": 0.24], authorizedLocalIDs: []) }, "speed below bound must be refused")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "command", args: ["name": "speed", "value": 4.01], authorizedLocalIDs: []) }, "speed above bound must be refused")
        for angle in [0, 90, 180, 270] {
            check(try NativeBridgePolicy.validateRequest(command: "command", args: ["name": "rotation", "value": angle], authorizedLocalIDs: []) == .engine(.rotation(angle)), "quarter-turn rotation must validate")
        }
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "command", args: ["name": "rotation", "value": 45], authorizedLocalIDs: []) }, "non-quarter-turn rotation must be refused")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "command", args: ["name": "path", "value": "/tmp/movie"], authorizedLocalIDs: []) }, "unknown engine property must be refused")
        check(try NativeBridgePolicy.validateRequest(command: "command", args: ["name": "aspect", "value": "default"], authorizedLocalIDs: []) == .engine(.aspect("default")), "desktop original-aspect value must validate")
        check(try NativeBridgePolicy.validateRequest(command: "command", args: ["name": "aspect", "value": "cover"], authorizedLocalIDs: []) == .engine(.aspect("cover")), "desktop crop-fill value must validate")
        check(try NativeBridgePolicy.validateRequest(command: "command", args: ["name": "aspect", "value": "fill"], authorizedLocalIDs: []) == .engine(.aspect("fill")), "desktop stretch-fill value must validate")

        check(try NativeBridgePolicy.validateRequest(command: "setVideoRect", args: ["x": 10.0, "y": 20.0, "width": 640.0, "height": 360.0, "visible": true], authorizedLocalIDs: []) == .setVideoRect(VideoRectangle(x: 10, y: 20, width: 640, height: 360, visible: true)), "valid video rectangle must validate")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "setVideoRect", args: ["x": -1.0, "y": 0.0, "width": 10.0, "height": 10.0, "visible": true], authorizedLocalIDs: []) }, "negative video origin must be refused")
        rejects({ _ = try NativeBridgePolicy.validateRequest(command: "setVideoRect", args: ["x": 0.0, "y": 0.0, "width": 100_000.0, "height": 10.0, "visible": true], authorizedLocalIDs: []) }, "unbounded video rectangle must be refused")

        check(MPVCommandCompiler.compile(.pause(true)) == [.setFlag("pause", true)], "pause must map to the mpv pause property")
        check(MPVCommandCompiler.compile(.pause(nil)) == [.command(["cycle", "pause"])], "pause without value must toggle")
        check(MPVCommandCompiler.compile(.seek(42.5)) == [.setDouble("time-pos", 42.5)], "seek must use absolute time-pos")
        check(MPVCommandCompiler.compile(.rotation(90)) == [.setString("video-rotate", "90")], "rotation is a choice option and must use string conversion")
        check(MPVCommandCompiler.compile(.audioTrack(-1)) == [.setString("aid", "no")], "disabled audio track must map to no")
        check(MPVCommandCompiler.compile(.subtitleTrack(3)) == [.setString("sid", "3")], "subtitle track must map to sid")
        check(MPVCommandCompiler.compile(.aspect("auto")) == [.setString("video-aspect-override", "no"), .setDouble("panscan", 0), .setFlag("keepaspect", true)], "automatic aspect must clear override and crop")
        check(MPVCommandCompiler.compile(.aspect("cover")) == [.setString("video-aspect-override", "no"), .setDouble("panscan", 1), .setFlag("keepaspect", true)], "cover must crop to fill")
        check(MPVCommandCompiler.compile(.aspect("fill")) == [.setString("video-aspect-override", "no"), .setDouble("panscan", 0), .setFlag("keepaspect", false)], "fill must stretch to the video rectangle")
        check(MPVCommandCompiler.compile(.abLoopA(nil)) == [.setString("ab-loop-a", "no")], "cleared A point must disable the property")
        check(MPVCommandCompiler.compile(.loop(true)) == [.setString("loop-file", "inf")], "loop must map to loop-file")
        check(MPVCommandCompiler.compile(.hwdec(false)) == [.setString("hwdec", "no")], "hardware decode must be explicit")
        check(MPVCommandCompiler.compile(.hwdec(true)) == [.setString("hwdec", "auto-copy")], "hardware decode must keep frames CPU-readable for screenshots, OCR, GIF and poster")
        check(MPVCommandCompiler.compile(.frameBackStep) == [.command(["frame-back-step"])], "backward frame step must use mpv command")

        print("Native bridge validation: \(assertions) assertions passed")
    }
}
