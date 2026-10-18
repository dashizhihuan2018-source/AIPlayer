import Foundation

@main struct NativeOpenMediaQueueTests {
    static func main() {
        let queue = NativeOpenMediaQueue()
        let first = NativeOpenMediaItem.local(id: "bookmark-1", name: "A.mkv")
        let second = NativeOpenMediaItem.local(id: "bookmark-2", name: "B.mp4")
        precondition(queue.enqueue([first]) == nil, "items must wait for the page handshake")
        precondition(queue.enqueue([second]) == nil, "multiple early deliveries must remain buffered")
        precondition(queue.markReady() == [first, second], "handshake must flush all buffered items once")
        precondition(queue.markReady() == nil, "a second handshake must not duplicate delivery")

        let remote = NativeOpenMediaItem.remote(id: "url-1", name: "Stream", url: "https://media.example/live.m3u8")
        precondition(queue.enqueue([remote]) == [remote], "ready page must receive later items immediately")
        queue.markNotReady()
        precondition(!queue.isReady, "SPA teardown must synchronously mark native delivery unavailable")
        precondition(queue.enqueue([first]) == nil, "navigation must buffer until the new page is ready")
        precondition(queue.markReady() == [first], "new page handshake must flush navigation-time items")

        let localJSON = first.bridgeValue
        precondition(localJSON["id"] as? String == "bookmark-1")
        precondition(localJSON["name"] as? String == "A.mkv")
        precondition(localJSON["kind"] as? String == "local")
        precondition(localJSON["url"] == nil && localJSON["path"] == nil, "local delivery must never expose a path")
        let remoteJSON = remote.bridgeValue
        precondition(remoteJSON["kind"] as? String == "url")
        precondition(remoteJSON["url"] as? String == "https://media.example/live.m3u8")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let media = temporary.appendingPathComponent("中文 dual-track.mkv")
        try! Data("owned fixture".utf8).write(to: media)
        precondition(NativeMediaFilePolicy.isReadableRegularFile(media), "readable MKV with Unicode name must be accepted")
        precondition(!NativeMediaFilePolicy.isReadableRegularFile(temporary), "directories must be rejected")

        print("Native open-media queue: handshake, navigation buffering, safe payload and readable Unicode MKV PASS")
    }
}
