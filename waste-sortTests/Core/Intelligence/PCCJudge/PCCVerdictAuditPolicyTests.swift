import Foundation
import Testing

@testable import waste_sort

@Suite("PCC verdict audit policy")
struct PCCVerdictAuditPolicyTests {
    @Test("an item the camera has barely seen is not worth a crop")
    func immatureTracksAreSkipped() {
        #expect(
            PCCVerdictAuditPolicy.decision(framesSeen: 1, pccEnabled: true, alreadyRequested: false)
                == .skip(.immature)
        )
        #expect(
            PCCVerdictAuditPolicy.decision(framesSeen: 2, pccEnabled: true, alreadyRequested: false)
                == .skip(.immature)
        )
    }

    @Test("three consecutive frames of YOLO saying something earns a judgment")
    func matureTracksTrigger() {
        #expect(
            PCCVerdictAuditPolicy.decision(framesSeen: 3, pccEnabled: true, alreadyRequested: false)
                == .trigger
        )
        #expect(
            PCCVerdictAuditPolicy.decision(framesSeen: 90, pccEnabled: true, alreadyRequested: false)
                == .trigger
        )
    }

    @Test("a track already judged never triggers a second call")
    func dedupeWins() {
        #expect(
            PCCVerdictAuditPolicy.decision(framesSeen: 30, pccEnabled: true, alreadyRequested: true)
                == .skip(.alreadyRequested)
        )
    }

    @Test("with PCC switched off nothing fires, whatever the track looks like")
    func disabledWins() {
        #expect(
            PCCVerdictAuditPolicy.decision(framesSeen: 30, pccEnabled: false, alreadyRequested: false)
                == .skip(.disabled)
        )
    }
}
