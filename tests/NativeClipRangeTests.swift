import Foundation

@main struct NativeClipRangeTests {
    static func main() {
        guard let range = NativeClipRange(start: 2, end: 5, duration: 18) else { print("FAIL valid clip range must be accepted"); exit(1) }
        precondition(range.start == 2 && range.end == 5)
        for (start, end, duration) in [(-1.0, 5.0, 18.0), (5, 2, 18), (0, 19, 18), (2, 2.01, 18), (.nan, 5, 18), (0, 5, .infinity)] {
            precondition(NativeClipRange(start: start, end: end, duration: duration) == nil)
        }
        print("Native clip range: finite ordered bounds and minimum duration PASS")
    }
}
