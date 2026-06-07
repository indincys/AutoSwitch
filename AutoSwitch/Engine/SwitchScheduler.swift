import Foundation
import os.log

@MainActor
final class SwitchScheduler {
    private let logger = Logger(subsystem: "dev.autoswitch", category: "scheduler")
    private let inputSourceController: InputSourceControlling
    private let activationDelayNanoseconds: UInt64
    private var currentTask: Task<Void, Never>?
    private var pendingDecision: SwitchDecision?
    private var suspensionDepth = 0

    init(
        inputSourceController: InputSourceControlling,
        activationDelayNanoseconds: UInt64 = InputSourceActivationStrategy.defaultReactivationDelayNanoseconds
    ) {
        self.inputSourceController = inputSourceController
        self.activationDelayNanoseconds = activationDelayNanoseconds
    }

    func suspendAutomaticSwitching(reason: String) {
        suspensionDepth += 1
        currentTask?.cancel()
        currentTask = nil
        pendingDecision = nil
        logger.info("automatic switching suspended: \(reason, privacy: .public)")
    }

    func resumeAutomaticSwitching(reason: String) {
        if suspensionDepth > 0 {
            suspensionDepth -= 1
        }
        logger.info("automatic switching resumed: \(reason, privacy: .public)")
    }

    func schedule(_ decision: SwitchDecision) {
        guard suspensionDepth == 0 else {
            logger.info(
                "automatic switching suspended; ignored \(decision.targetInputSourceID, privacy: .public) because \(decision.reason, privacy: .public)"
            )
            return
        }

        let shouldReactivate = InputSourceActivationStrategy.canReactivateInputMode(
            targetID: decision.targetInputSourceID,
            inputSourceController: inputSourceController
        )

        if inputSourceController.currentInputSourceIDValue == decision.targetInputSourceID, !shouldReactivate {
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
            await self.apply(decision)

            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self.verifyAndCorrect(decision)
            self.clearPendingDecision(decision)
        }
    }

    private func clearPendingDecision(_ decision: SwitchDecision) {
        guard pendingDecision == decision else { return }
        currentTask = nil
        pendingDecision = nil
    }

    private func apply(_ decision: SwitchDecision) async {
        if InputSourceActivationStrategy.canReactivateInputMode(
            targetID: decision.targetInputSourceID,
            inputSourceController: inputSourceController
        ) {
            if await InputSourceActivationStrategy.activate(
                targetID: decision.targetInputSourceID,
                inputSourceController: inputSourceController,
                delayNanoseconds: activationDelayNanoseconds
            ) {
                logger.info("reactivated target \(decision.targetInputSourceID, privacy: .public)")
            } else {
                logger.error("failed to reactivate target \(decision.targetInputSourceID, privacy: .public)")
            }
            return
        }

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

    private func verifyAndCorrect(_ decision: SwitchDecision) async {
        guard inputSourceController.currentInputSourceIDValue != decision.targetInputSourceID else {
            logger.info("verification matched target")
            return
        }

        logger.info("verification mismatch, attempting one correction")
        _ = await InputSourceActivationStrategy.activate(
            targetID: decision.targetInputSourceID,
            inputSourceController: inputSourceController,
            delayNanoseconds: activationDelayNanoseconds
        )
    }
}
