import Testing
@testable import waste_sort

@Suite("PCC trigger policy")
struct PCCTriggerPolicyTests {
    private func inputs(
        wasUncertainFallback: Bool = true,
        confirmationLocked: Bool = false,
        confidentAuditEnabled: Bool = false,
        judgeEnabled: Bool = true,
        availabilityIsReady: Bool = true,
        quotaLimited: Bool = false,
        breakerOpen: Bool = false,
        alreadyRequested: Bool = false
    ) -> PCCTriggerPolicy.Inputs {
        PCCTriggerPolicy.Inputs(
            wasUncertainFallback: wasUncertainFallback,
            confirmationLocked: confirmationLocked,
            confidentAuditEnabled: confidentAuditEnabled,
            judgeEnabled: judgeEnabled,
            availabilityIsReady: availabilityIsReady,
            quotaLimited: quotaLimited,
            breakerOpen: breakerOpen,
            alreadyRequested: alreadyRequested
        )
    }

    @Test("Qualifying uncertain fallback triggers")
    func trigger() {
        #expect(PCCTriggerPolicy.decision(for: inputs()) == .trigger)
    }

    @Test("Every gate rejects with its named reason (contract rule table)")
    func gates() {
        #expect(
            PCCTriggerPolicy.decision(for: inputs(judgeEnabled: false)) == .skip(.disabled)
        )
        #expect(
            PCCTriggerPolicy.decision(for: inputs(wasUncertainFallback: false))
                == .skip(.notUncertainFallback)
        )
        #expect(
            PCCTriggerPolicy.decision(for: inputs(confirmationLocked: true)) == .skip(.confirmationLocked)
        )
        #expect(
            PCCTriggerPolicy.decision(for: inputs(availabilityIsReady: false))
                == .skip(.unavailable("service not ready"))
        )
        #expect(
            PCCTriggerPolicy.decision(for: inputs(quotaLimited: true)) == .skip(.quotaLimited)
        )
        #expect(
            PCCTriggerPolicy.decision(for: inputs(breakerOpen: true)) == .skip(.breakerOpen)
        )
        #expect(
            PCCTriggerPolicy.decision(for: inputs(alreadyRequested: true)) == .skip(.alreadyRequested)
        )
    }

    @Test("Audit path: confident verdict triggers when audit is on (spec 003)")
    func auditTriggers() {
        #expect(
            PCCTriggerPolicy.decision(
                for: inputs(wasUncertainFallback: false, confidentAuditEnabled: true)
            ) == .trigger
        )
    }

    @Test("Audit path deliberately ignores confirmationLocked")
    func auditIgnoresConfirmationLock() {
        #expect(
            PCCTriggerPolicy.decision(
                for: inputs(
                    wasUncertainFallback: false,
                    confirmationLocked: true,
                    confidentAuditEnabled: true
                )
            ) == .trigger
        )
    }

    @Test("Uncertain path still refuses confirmationLocked even with audits on")
    func uncertainStillRespectsLock() {
        #expect(
            PCCTriggerPolicy.decision(
                for: inputs(confirmationLocked: true, confidentAuditEnabled: true)
            ) == .skip(.confirmationLocked)
        )
    }

    @Test("Audit off restores legacy behavior for confident deposits")
    func auditOffIsLegacy() {
        #expect(
            PCCTriggerPolicy.decision(for: inputs(wasUncertainFallback: false))
                == .skip(.notUncertainFallback)
        )
    }

    @Test("Audit path is still gated by quota, breaker, and dedupe")
    func auditSharedGates() {
        let base = (wasUncertainFallback: false, confidentAuditEnabled: true)
        #expect(
            PCCTriggerPolicy.decision(
                for: inputs(wasUncertainFallback: base.wasUncertainFallback, confidentAuditEnabled: true, quotaLimited: true)
            ) == .skip(.quotaLimited)
        )
        #expect(
            PCCTriggerPolicy.decision(
                for: inputs(wasUncertainFallback: base.wasUncertainFallback, confidentAuditEnabled: true, breakerOpen: true)
            ) == .skip(.breakerOpen)
        )
        #expect(
            PCCTriggerPolicy.decision(
                for: inputs(wasUncertainFallback: base.wasUncertainFallback, confidentAuditEnabled: true, alreadyRequested: true)
            ) == .skip(.alreadyRequested)
        )
        #expect(
            PCCTriggerPolicy.decision(
                for: inputs(wasUncertainFallback: base.wasUncertainFallback, confidentAuditEnabled: true, judgeEnabled: false)
            ) == .skip(.disabled)
        )
    }

    @Test("Disabled wins before every other gate so toggling off is absolute")
    func disabledPrecedence() {
        let everythingWrong = inputs(
            wasUncertainFallback: false,
            confirmationLocked: true,
            judgeEnabled: false,
            availabilityIsReady: false,
            quotaLimited: true,
            breakerOpen: true,
            alreadyRequested: true
        )
        #expect(PCCTriggerPolicy.decision(for: everythingWrong) == .skip(.disabled))
    }
}
