import Foundation

@main struct NativeLoadTrackerTests {
    static func main() {
        var tracker = NativeLoadTracker()
        let first = tracker.begin(entryID: 101)
        let second = tracker.begin(entryID: 202)
        precondition(first.superseded == nil && second.superseded == first.token)
        precondition(tracker.consume(.fileLoaded(entryID: 101)) == nil, "superseded FILE_LOADED must not resolve the new request")
        precondition(tracker.consume(.ended(entryID: 101, error: -13)) == nil, "superseded END_FILE must not fail the new request")
        precondition(tracker.consume(.fileLoaded(entryID: 202)) == .loaded(second.token), "matching FILE_LOADED must resolve current request")

        let third = tracker.begin(entryID: 303)
        precondition(tracker.consume(.ended(entryID: 303, error: -13)) == .failed(third.token, -13), "matching load error must reject current request")
        let fourth = tracker.begin(entryID: 404)
        precondition(tracker.timeout(generation: third.token.generation) == nil, "stale timeout must not reject current request")
        precondition(tracker.timeout(generation: fourth.token.generation) == .timedOut(fourth.token), "current timeout must resolve once")
        precondition(tracker.timeout(generation: fourth.token.generation) == nil, "timeout must not resolve twice")

        var boundaryTracker = NativeLoadTracker()
        let boundary = boundaryTracker.begin(entryID: 505).token
        var order: [String] = []
        let boundaryResolution = NativeLoadTimeoutCoordinator.resolveAfterDrain(
            drain: {
                order.append("drain")
                _ = boundaryTracker.consume(.fileLoaded(entryID: boundary.entryID))
            },
            timeout: {
                order.append("timeout")
                return boundaryTracker.timeout(generation: boundary.generation)
            }
        )
        precondition(order == ["drain", "timeout"], "queued mpv events must drain before timeout arbitration")
        precondition(boundaryResolution == nil, "queued FILE_LOADED must win the timer boundary and prevent a false timeout")
        print("Native load tracker: supersede, stale-event isolation, FILE_LOADED, error and drain-before-timeout PASS")
    }
}
