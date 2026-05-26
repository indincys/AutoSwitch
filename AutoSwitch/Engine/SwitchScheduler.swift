import Foundation
import os.log

@MainActor
final class SwitchScheduler {
    private let logger = Logger(subsystem: "dev.autoswitch", category: "scheduler")
    private let inputSourceController: InputSourceControlling
    private var currentTask: Task<Void, Never>?
    private var pendingDecision: SwitchDecision?

    init(inputSourceController: InputSourceControlling) {
        self.inputSourceController = inputSourceController
    }

    func schedule(_ decision: SwitchDecision) {
        if inputSourceController.currentInputSourceIDValue == decision.targetInputSourceID {
            if pendingDecision?.targetInputSourceID == decision.targetInputSourceID {
                logger.info("target already selected; keeping pending verification")
                return
            }
            logger.info("target already selected; skipping schedule")
            currentTask?.cancel()
            currentTask = nil
            pendingDecision = nil
            return
        }

        if pendingDecision?.targetInputSourceID == decision.targetInputSourceID {
            logger.info("duplicate pending switch ignored for \(decision.targetInputSourceID, privacy: .public)")
            return
        }

        currentTask?.cancel()
        pendingDecision = decision
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }

            self.logger.info("scheduled switch to \(decision.targetInputSourceID, privacy: .public) because \(decision.reason, privacy: .public)")
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self.apply(decision)

            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self.verifyAndCorrect(decision)
            self.clearPendingDecision(decision)
        }
    }

    private func clearPendingDecision(_ decision: SwitchDecision) {
        guard pendingDecision == decision else { return }
        currentTask = nil
        pendingDecision = nil
    }

    private func apply(_ decision: SwitchDecision) {
        guard inputSourceController.currentInputSourceIDValue != decision.targetInputSourceID else {
            logger.info("target already selected")
            return
        }

        if inputSourceController.selectInputSource(id: decision.targetInputSourceID) {
            logger.info("applied target \(decision.targetInputSourceID, privacy: .public)")
        } else {
            logger.error("failed to apply target \(decision.targetInputSourceID, privacy: .public)")
        }
    }

    private func verifyAndCorrect(_ decision: SwitchDecision) {
        guard inputSourceController.currentInputSourceIDValue != decision.targetInputSourceID else {
            logger.info("verification matched target")
            return
        }

        logger.info("verification mismatch, attempting one correction")
        _ = inputSourceController.selectInputSource(id: decision.targetInputSourceID)
    }
}
