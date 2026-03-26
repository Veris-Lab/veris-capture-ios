import Foundation

enum CaptureSessionState {
    case idle
    case deviceProfiling
    case awaitingFace
    case qualityGating
    case accumulating
    case escalating
    case deciding
    case resultPackaging
    case complete
}

final class StateManager {
    private(set) var currentState: CaptureSessionState = .idle

    func transition(to state: CaptureSessionState) {
        currentState = state
    }
}
