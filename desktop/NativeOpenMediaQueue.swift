import Foundation

enum NativeMediaFilePolicy {
    static let commonExtensions: Set<String> = [
        "3gp", "aac", "ac3", "aiff", "alac", "ape", "asf", "avi", "flac", "flv",
        "m2ts", "m3u", "m3u8", "m4a", "m4v", "mka", "mkv", "mov", "mp3", "mp4",
        "mpeg", "mpg", "ogg", "ogm", "opus", "rm", "rmvb", "ts", "wav", "webm", "wma", "wmv"
    ]

    static func isReadableRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }
}

struct NativeOpenMediaItem: Equatable {
    let id: String
    let name: String
    let kind: String
    let url: String?

    static func local(id: String, name: String) -> NativeOpenMediaItem {
        NativeOpenMediaItem(id: id, name: name, kind: "local", url: nil)
    }

    static func remote(id: String, name: String, url: String) -> NativeOpenMediaItem {
        NativeOpenMediaItem(id: id, name: name, kind: "url", url: url)
    }

    var bridgeValue: [String: Any] {
        var value: [String: Any] = ["id": id, "name": name, "kind": kind]
        if let url { value["url"] = url }
        return value
    }
}

/// Buffers Finder/menu/drop media until the current page explicitly installs
/// its event listener and sends the mediaReady handshake.
final class NativeOpenMediaQueue {
    private var ready = false
    private var pending: [NativeOpenMediaItem] = []
    var isReady: Bool { ready }

    func enqueue(_ items: [NativeOpenMediaItem]) -> [NativeOpenMediaItem]? {
        guard !items.isEmpty else { return nil }
        if ready { return items }
        pending.append(contentsOf: items)
        return nil
    }

    func markReady() -> [NativeOpenMediaItem]? {
        ready = true
        guard !pending.isEmpty else { return nil }
        let delivery = pending
        pending.removeAll(keepingCapacity: false)
        return delivery
    }

    func markNotReady() { ready = false }
    func resetReadiness() { markNotReady() }
}
