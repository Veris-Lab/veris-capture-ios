import Foundation

final class PipelineCoordinator {
    let context: SessionContext
    let policy: SessionPolicy
    private let stateManager: StateManager

    init(context: SessionContext, policy: SessionPolicy, stateManager: StateManager) {
        self.context = context
        self.policy = policy
        self.stateManager = stateManager
    }

    func onSessionStarted() { stateManager.transition(to: .deviceProfiling) }
    func onCameraReady() { stateManager.transition(to: .awaitingFace) }
    func onQualityGateRunning() { stateManager.transition(to: .qualityGating) }
    func onAccumulating() { stateManager.transition(to: .accumulating) }
    func onEscalating() { stateManager.transition(to: .escalating) }
    func onDeciding() { stateManager.transition(to: .deciding) }
    func onResultPackaging() { stateManager.transition(to: .resultPackaging) }
    func onComplete() { stateManager.transition(to: .complete) }
}
