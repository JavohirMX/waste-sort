import SwiftUI

/// Overlay drawn on the destination segment after a throw is scored.
nonisolated enum ThrowFeedback: Equatable {
    case correct(binID: String)
    case incorrect(binID: String)

    var targetBinID: String {
        switch self {
        case .correct(let binID), .incorrect(let binID):
            binID
        }
    }

    var insertionEdge: Edge {
        switch self {
        case .correct: .top
        case .incorrect: .leading
        }
    }

    var bin: BinInfo {
        BinGuide.bin(id: targetBinID)
    }

    static func from(_ deposit: ZoneDeposit) -> ThrowFeedback {
        from(isCorrect: deposit.isCorrect, zoneBinID: deposit.zoneBinID)
    }

    static func from(isCorrect: Bool, zoneBinID: String) -> ThrowFeedback {
        isCorrect ? .correct(binID: zoneBinID) : .incorrect(binID: zoneBinID)
    }

    static func from(_ cue: ThrowFeedbackCue) -> ThrowFeedback {
        from(isCorrect: cue.isCorrect, zoneBinID: cue.zoneBinID)
    }
}

/// Newest throw wins: a later `present` invalidates any in-flight dismiss.
nonisolated struct ThrowFeedbackGate: Equatable {
    private(set) var feedback: ThrowFeedback?
    private(set) var token: UInt64 = 0
    private(set) var objectID: UUID?
    private(set) var persistWhilePresent = false

    mutating func present(
        _ feedback: ThrowFeedback,
        objectID: UUID = UUID(),
        persistWhilePresent: Bool = false
    ) -> UInt64 {
        token += 1
        self.feedback = feedback
        self.objectID = objectID
        self.persistWhilePresent = persistWhilePresent
        return token
    }

    mutating func dismissIfCurrent(token: UInt64) {
        guard self.token == token else { return }
        clear()
    }

    mutating func dismiss(objectID: UUID) {
        guard self.objectID == objectID else { return }
        clear()
    }

    mutating func markEphemeral() {
        persistWhilePresent = false
    }

    private mutating func clear() {
        feedback = nil
        objectID = nil
        persistWhilePresent = false
    }
}
