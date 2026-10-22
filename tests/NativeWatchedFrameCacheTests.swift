import AppKit

@main struct NativeWatchedFrameCacheTests {
    static func main() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 2400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = bitmap.cgImage!
        let cache = NativeWatchedFrameCache()
        precondition(cache.beginSample(at: .nan) == nil)
        precondition(cache.beginSample(at: -1) == nil)
        let first = cache.beginSample(at: 0)!
        precondition(cache.beginSample(at: 10) == nil, "only one asynchronous sample at a time")
        try cache.complete(first, at: 0, image: image)
        precondition(cache.frames.count == 1 && cache.frames[0].image.width <= 1200 && cache.frames[0].image.height <= 1200)
        precondition(cache.beginSample(at: 4) == nil, "bounded sampling cadence")
        for time in stride(from: 5.0, through: 40.0, by: 5) {
            let token = cache.beginSample(at: time)!
            try cache.complete(token, at: time, image: image)
        }
        precondition(cache.frames.count == 6 && cache.frames.map(\.time) == [15, 20, 25, 30, 35, 40])
        let stale = cache.beginSample(at: 45)!
        cache.reset()
        try cache.complete(stale, at: 45, image: image)
        precondition(cache.frames.isEmpty, "late callback from a previous media must not enter a new media cache")
        let fresh = cache.beginSample(at: 0)!
        cache.fail(fresh)
        precondition(cache.beginSample(at: 0) != nil, "failed capture can retry without waiting for playback to advance")
        print("Watched-frame cache: cadence, single flight, six-frame bound, portrait size, media isolation and retry PASS")
    }
}
