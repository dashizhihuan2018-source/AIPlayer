import Foundation

enum MPVInstruction: Equatable {
    case setString(String, String)
    case setDouble(String, Double)
    case setFlag(String, Bool)
    case command([String])
}

enum MPVCommandCompiler {
    static func compile(_ command: ValidatedEngineCommand) -> [MPVInstruction] {
        switch command {
        case .pause(let flag): return flag.map { [.setFlag("pause", $0)] } ?? [.command(["cycle", "pause"])]
        case .seek(let value): return [.setDouble("time-pos", value)]
        case .volume(let value): return [.setDouble("volume", value)]
        case .mute(let flag): return [.setFlag("mute", flag)]
        case .speed(let value): return [.setDouble("speed", value)]
        case .audioTrack(let id): return [.setString("aid", id < 0 ? "no" : String(id))]
        case .subtitleTrack(let id): return [.setString("sid", id < 0 ? "no" : String(id))]
        case .subtitleDelay(let value): return [.setDouble("sub-delay", value)]
        case .audioDelay(let value): return [.setDouble("audio-delay", value)]
        case .aspect(let value):
            switch value {
            case "auto", "default": return [.setString("video-aspect-override", "no"), .setDouble("panscan", 0), .setFlag("keepaspect", true)]
            case "cover": return [.setString("video-aspect-override", "no"), .setDouble("panscan", 1), .setFlag("keepaspect", true)]
            case "fill": return [.setString("video-aspect-override", "no"), .setDouble("panscan", 0), .setFlag("keepaspect", false)]
            default: return [.setString("video-aspect-override", value), .setDouble("panscan", 0), .setFlag("keepaspect", true)]
            }
        case .rotation(let value): return [.setString("video-rotate", String(value))]
        case .brightness(let value): return [.setDouble("brightness", value)]
        case .contrast(let value): return [.setDouble("contrast", value)]
        case .saturation(let value): return [.setDouble("saturation", value)]
        case .gamma(let value): return [.setDouble("gamma", value)]
        case .hue(let value): return [.setDouble("hue", value)]
        case .abLoopA(let value): return [value.map { .setDouble("ab-loop-a", $0) } ?? .setString("ab-loop-a", "no")]
        case .abLoopB(let value): return [value.map { .setDouble("ab-loop-b", $0) } ?? .setString("ab-loop-b", "no")]
        case .loop(let enabled): return [.setString("loop-file", enabled ? "inf" : "no")]
        case .deinterlace(let enabled): return [.setFlag("deinterlace", enabled)]
        case .hwdec(let enabled): return [.setString("hwdec", enabled ? "auto-copy" : "no")]
        case .frameStep: return [.command(["frame-step"])]
        case .frameBackStep: return [.command(["frame-back-step"])]
        case .stop: return [.command(["stop"])]
        }
    }
}
