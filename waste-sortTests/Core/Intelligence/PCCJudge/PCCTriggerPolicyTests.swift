import Testing
@testable import waste_sort

@Suite("PCC trigger policy")
struct PCCTriggerPolicyTests {
    private func inputs(
        wasUncertainFallback: Bool = true,
        confirmationLocked: Bool = false,
        judgeEnabled: Bool = true,
        availabilityIsReady: Bool = true,
        quotaLimited: Bool = false,
        breakerOpen: Bool = false,
        alreadyRequested: Bool = false
    ) -> PCCTriggerPolicy.Inputs {
        PCCTriggerPolicy.Inputs(
            wasUncertainFallback: wasUncertainFallback,
            confirmationLocked: confirmationLocked,
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
