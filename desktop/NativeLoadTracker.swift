import Foundation

enum NativeLoadLifecycleEvent: Equatable {
    case startFile(entryID: Int64)
    case fileLoaded(entryID: Int64)
    case ended(entryID: Int64, error: Int32)
    case seek
    case playbackRestart
}

struct NativeLoadToken: Equatable {
    let generation: UInt64
    let entryID: Int64
}

enum NativeLoadResolution: Equatable {
    case loaded(NativeLoadToken)
    case failed(NativeLoadToken, Int32)
    case timedOut(NativeLoadToken)
}

enum NativeLoadTimeoutCoordinator {
    static func resolveAfterDrain(
        drain: () -> Void,
        timeout: () -> NativeLoadResolution?
    ) -> NativeLoadResolution? {
        drain()
        return timeout()
    }
}

struct NativeLoadTracker {
    private var nextGeneration: UInt64 = 1
    private var pending: NativeLoadToken?

    mutating func begin(entryID: Int64) -> (token: NativeLoadToken, superseded: NativeLoadToken?) {
        let previous = pending
        let token = NativeLoadToken(generation: nextGeneration, entryID: entryID)
        nextGeneration &+= 1
        pending = token
        return (token, previous)
    }

    mutating func consume(_ event: NativeLoadLifecycleEvent) -> NativeLoadResolution? {
        guard let pending else { return nil }
        switch event {
        case .fileLoaded(let entryID) where entryID == pending.entryID:
            self.pending = nil
            return .loaded(pending)
        case .ended(let entryID, let error) where entryID == pending.entryID:
            self.pending = nil
            return .failed(pending, error)
        default:
            return nil
        }
    }

    mutating func timeout(generation: UInt64) -> NativeLoadResolution? {
        guard let pending, pending.generation == generation else { return nil }
        self.pending = nil
        return .timedOut(pending)
    }
}
