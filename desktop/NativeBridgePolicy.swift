import Foundation

enum NativeBridgeValidationError: Error, LocalizedError, Equatable {
    case untrustedFrame
    case unknownCommand(String)
    case invalidArguments(String)
    case unauthorizedLocalID
    case unsupportedURL

    var errorDescription: String? {
        switch self {
        case .untrustedFrame: return "Native request refused outside the trusted app frame."
        case .unknownCommand(let command): return "Unsupported native command: \(command)"
        case .invalidArguments(let detail): return "Invalid native command arguments: \(detail)"
        case .unauthorizedLocalID: return "Local media authorization is missing or expired."
        case .unsupportedURL: return "Only HTTP and HTTPS media URLs are accepted."
        }
    }
}

struct VideoRectangle: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let visible: Bool
}

enum ValidatedEngineCommand: Equatable {
    case pause(Bool?)
    case seek(Double)
    case volume(Double)
    case mute(Bool)
    case speed(Double)
    case audioTrack(Int)
    case subtitleTrack(Int)
    case subtitleDelay(Double)
    case audioDelay(Double)
    case aspect(String)
    case rotation(Int)
    case brightness(Double)
    case contrast(Double)
    case saturation(Double)
    case gamma(Double)
    case hue(Double)
    case abLoopA(Double?)
    case abLoopB(Double?)
    case loop(Bool)
    case deinterlace(Bool)
    case hwdec(Bool)
    case frameStep
    case frameBackStep
    case stop
}

enum ValidatedNativeRequest: Equatable {
    case capabilities
    case openFiles
    case loadLocal(id: String, position: Double?)
    case loadURL(URL, position: Double?)
    case engine(ValidatedEngineCommand)
    case getState
    case setVideoRect(VideoRectangle)
    case hideVideo
    case importSubtitle
    case screenshot
    case fullscreen
    case ocr
    case captureGIF(duration: Double, fps: Int)
    case gifStart(fps: Int, maximumWidth: Int)
    case gifStop
    case gifCancel
    case openGifFolder
    case capturePoster
    case recordStart
    case recordStop
    case mediaReady
    case mediaNotReady
    case pictureInPicture(Bool)
    case getWindowState
}

enum NativeBridgePolicy {
    static let maximumMediaPosition = 604_800.0
    static let maximumVideoCoordinate = 16_384.0

    static func isTrustedFrame(isMainFrame: Bool, sourceURL: URL?) -> Bool {
        guard isMainFrame, let sourceURL else { return false }
        return sourceURL.scheme == "http"
            && sourceURL.host == "127.0.0.1"
            && sourceURL.port == DesktopPolicy.port
            && sourceURL.user == nil
            && sourceURL.password == nil
    }

    static func validateRequest(
        command: String,
        args: [String: Any],
        authorizedLocalIDs: Set<String>
    ) throws -> ValidatedNativeRequest {
        switch command {
        case "capabilities": try requireEmpty(args, named: command); return .capabilities
        case "openFiles": try requireEmpty(args, named: command); return .openFiles
        case "getState": try requireEmpty(args, named: command); return .getState
        case "hideVideo": try requireEmpty(args, named: command); return .hideVideo
        case "importSubtitle": try requireEmpty(args, named: command); return .importSubtitle
        case "screenshot": try requireEmpty(args, named: command); return .screenshot
        case "fullscreen": try requireEmpty(args, named: command); return .fullscreen
        case "ocr": try requireEmpty(args, named: command); return .ocr
        case "gifStop": try requireEmpty(args, named: command); return .gifStop
        case "gifCancel": try requireEmpty(args, named: command); return .gifCancel
        case "openGifFolder": try requireEmpty(args, named: command); return .openGifFolder
        case "gifStart":
            guard Set(args.keys) == ["fps", "maximumWidth"] else { throw invalidValue(command) }
            let width = try requiredInteger(args["maximumWidth"], named: "maximumWidth", range: 640...3840)
            guard [640, 1280, 1920, 3840].contains(width) else { throw invalidValue(command) }
            return .gifStart(fps: try requiredInteger(args["fps"], named: "fps", range: 1...30), maximumWidth: width)
        case "capturePoster": try requireEmpty(args, named: command); return .capturePoster
        case "recordStart": try requireEmpty(args, named: command); return .recordStart
        case "recordStop": try requireEmpty(args, named: command); return .recordStop
        case "mediaReady": try requireEmpty(args, named: command); return .mediaReady
        case "mediaNotReady": try requireEmpty(args, named: command); return .mediaNotReady
        case "getWindowState": try requireEmpty(args, named: command); return .getWindowState
        case "pictureInPicture":
            guard Set(args.keys) == ["enabled"] else { throw invalidValue(command) }
            return .pictureInPicture(try requiredBool(args["enabled"], named: "enabled"))
        case "captureGif":
            guard Set(args.keys) == ["duration", "fps"] else { throw invalidValue(command) }
            return .captureGIF(
                duration: try requiredNumber(args["duration"], named: "duration", range: 0.2...10),
                fps: try requiredInteger(args["fps"], named: "fps", range: 1...30)
            )
        case "load": return try validateLoad(args, authorizedLocalIDs: authorizedLocalIDs)
        case "command": return .engine(try validateEngineCommand(args))
        case "setVideoRect": return .setVideoRect(try validateVideoRectangle(args))
        default: throw NativeBridgeValidationError.unknownCommand(command)
        }
    }

    private static func validateLoad(_ args: [String: Any], authorizedLocalIDs: Set<String>) throws -> ValidatedNativeRequest {
        let position = try optionalNumber(args["position"], named: "position", range: 0...maximumMediaPosition)
        let id = args["id"] as? String
        let urlText = args["url"] as? String
        guard (id == nil) != (urlText == nil) else {
            throw NativeBridgeValidationError.invalidArguments("load requires exactly one of id or url")
        }
        if let id {
            guard !id.isEmpty, authorizedLocalIDs.contains(id) else {
                throw NativeBridgeValidationError.unauthorizedLocalID
            }
            return .loadLocal(id: id, position: position)
        }
        guard let text = urlText, text.count <= 8_192, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else {
            throw NativeBridgeValidationError.unsupportedURL
        }
        return .loadURL(url, position: position)
    }

    private static func validateVideoRectangle(_ args: [String: Any]) throws -> VideoRectangle {
        let x = try requiredNumber(args["x"], named: "x", range: 0...maximumVideoCoordinate)
        let y = try requiredNumber(args["y"], named: "y", range: 0...maximumVideoCoordinate)
        let width = try requiredNumber(args["width"], named: "width", range: 0...maximumVideoCoordinate)
        let height = try requiredNumber(args["height"], named: "height", range: 0...maximumVideoCoordinate)
        guard let visible = args["visible"] as? Bool else {
            throw NativeBridgeValidationError.invalidArguments("visible must be boolean")
        }
        return VideoRectangle(x: x, y: y, width: width, height: height, visible: visible)
    }

    private static func validateEngineCommand(_ args: [String: Any]) throws -> ValidatedEngineCommand {
        guard let name = args["name"] as? String else {
            throw NativeBridgeValidationError.invalidArguments("command name is required")
        }
        let value = args["value"]
        switch name {
        case "pause":
            if value == nil || value is NSNull { return .pause(nil) }
            guard let flag = value as? Bool else { throw invalidValue(name) }
            return .pause(flag)
        case "seek": return .seek(try requiredNumber(value, named: name, range: 0...maximumMediaPosition))
        case "volume": return .volume(try requiredNumber(value, named: name, range: 0...100))
        case "mute": return .mute(try requiredBool(value, named: name))
        case "speed": return .speed(try requiredNumber(value, named: name, range: 0.25...4))
        case "audioTrack": return .audioTrack(try requiredInteger(value, named: name, range: -1...Int(Int32.max)))
        case "subtitleTrack": return .subtitleTrack(try requiredInteger(value, named: name, range: -1...Int(Int32.max)))
        case "subtitleDelay": return .subtitleDelay(try requiredNumber(value, named: name, range: -60...60))
        case "audioDelay": return .audioDelay(try requiredNumber(value, named: name, range: -60...60))
        case "aspect":
            guard let aspect = value as? String, ["auto", "default", "cover", "fill", "16:9", "4:3", "21:9", "1:1"].contains(aspect) else { throw invalidValue(name) }
            return .aspect(aspect)
        case "rotation":
            let angle = try requiredInteger(value, named: name, range: 0...270)
            guard angle % 90 == 0 else { throw invalidValue(name) }
            return .rotation(angle)
        case "brightness": return .brightness(try requiredNumber(value, named: name, range: -100...100))
        case "contrast": return .contrast(try requiredNumber(value, named: name, range: -100...100))
        case "saturation": return .saturation(try requiredNumber(value, named: name, range: -100...100))
        case "gamma": return .gamma(try requiredNumber(value, named: name, range: -100...100))
        case "hue": return .hue(try requiredNumber(value, named: name, range: -100...100))
        case "abLoopA": return .abLoopA(try optionalNumber(value, named: name, range: 0...maximumMediaPosition))
        case "abLoopB": return .abLoopB(try optionalNumber(value, named: name, range: 0...maximumMediaPosition))
        case "loop": return .loop(try requiredBool(value, named: name))
        case "deinterlace": return .deinterlace(try requiredBool(value, named: name))
        case "hwdec": return .hwdec(try requiredBool(value, named: name))
        case "frameStep": try requireNoValue(value, named: name); return .frameStep
        case "frameBackStep": try requireNoValue(value, named: name); return .frameBackStep
        case "stop": try requireNoValue(value, named: name); return .stop
        default: throw NativeBridgeValidationError.unknownCommand(name)
        }
    }

    private static func invalidValue(_ name: String) -> NativeBridgeValidationError {
        .invalidArguments("invalid value for \(name)")
    }

    private static func requireEmpty(_ args: [String: Any], named name: String) throws {
        guard args.isEmpty else { throw invalidValue(name) }
    }

    private static func requireNoValue(_ value: Any?, named name: String) throws {
        guard value == nil || value is NSNull else { throw invalidValue(name) }
    }

    private static func requiredBool(_ value: Any?, named name: String) throws -> Bool {
        guard let result = value as? Bool else { throw invalidValue(name) }
        return result
    }

    private static func requiredInteger(_ value: Any?, named name: String, range: ClosedRange<Int>) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw invalidValue(name) }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, double >= Double(range.lowerBound), double <= Double(range.upperBound) else { throw invalidValue(name) }
        return Int(double)
    }

    private static func requiredNumber(_ value: Any?, named name: String, range: ClosedRange<Double>) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw invalidValue(name) }
        let result = number.doubleValue
        guard result.isFinite, range.contains(result) else { throw invalidValue(name) }
        return result
    }

    private static func optionalNumber(_ value: Any?, named name: String, range: ClosedRange<Double>) throws -> Double? {
        guard value != nil, !(value is NSNull) else { return nil }
        return try requiredNumber(value, named: name, range: range)
    }
}
