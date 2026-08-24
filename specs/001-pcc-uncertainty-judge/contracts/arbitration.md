# Contract: Verdict Arbitration

**Feature**: `001-pcc-uncertainty-judge` | **Date**: 2026-08-24
These signatures are the implementation contract; tests target them directly.

## Protocol seam (Swift)

```swift
nonisolated protocol VerdictArbitrating: Sendable {
    /// Submits one arbitration request. Returns immediately; result lands in
    /// the record store. Exactly one call per trackId is honored.
    func arbitrate(_ request: ArbiterRequestContext, crop: CGImage?) async

    /// Current gate state snapshot for Settings + pre-call checks.
    func currentStatus() -> JudgeStatusSnapshot
}

nonisolated struct ArbiterRequestContext: Sendable {
    let trackId: Int
    let sessionId: String?
    let yoloLabel: String
    let yoloConfidence: Double
    let beliefUncertain: Bool
    let beliefMargin: Double
    let engineBinID: String          // live verdict actually shown (residual)
    let pipeline: DecisionPipeline
    let triggeredAt: Date
}
```

Implementations:
- `PCCArbiterService` — real; FoundationModels PCC session, 10 s timeout,
  quota/availability gates, circuit breaker (3 consecutive failures → 120 s
  cooldown), writes `PCCVerdictRecord`s.
- `MockVerdictArbiter` — test double; scripted outcomes; asserts dedupe.

## Pure trigger policy

```swift
nonisolated enum PCCTriggerPolicy {
    struct Inputs: Sendable { /* deposit facts, track fields, confirmation
        lock presence, judgeEnabled, availability, breaker state,
        alreadyRequested(trackId) */ }
    static func decision(for inputs: Inputs) -> PCCTriggerDecision
}
```

Rules (spec FR-1/FR-6):
1. Trigger iff deposit resolved via uncertainty→residual fallback AND no
   confirmation lock on that track AND judge enabled AND availability .ready
   AND quota below limit AND breaker closed AND trackId not yet requested.
2. Otherwise return decision with explicit SkipReason (recorded verbatim).

## JSONL schema v1 (one line per PCCVerdictRecord)

```json
{"schemaVersion":1,"id":"UUID","timestamp":"ISO8601",
 "sessionId":"s","trackId":7,"cropFile":"crops/x.jpg"|null,
 "yoloLabel":"chip bag","yoloConfidence":0.42,
 "beliefUncertain":true,"beliefMargin":0.03,"engineBinID":"residual",
 "pipeline":"belief","outcome":"answered|timeout|error|skippedQuota|
   skippedUnavailable|skippedOffline|skippedDisabled|cropFailed",
 "pccBinID":"recyclable"|null,"pccRawBinLabel":"plastic packaging"|null,
 "mappingFailed":false,"material":"...","reasoningSummary":"...",
 "agreesWithEngine":false,"latencyMs":4123,"inputTokens":910,
 "outputTokens":142,"quotaStateAtCall":"belowLimit",
 "modelId":"pcc","reasoningLevel":"moderate","errorMessage":null}
```

Export bundle: `records.jsonl` (range-filtered) + `crops/` (referenced only)
+ `manifest.json` `{exportedAt, rangeStart, rangeEnd, recordCount,
schemaVersion}`.

## Invariants (tested)

- I1 One request per trackId per app run (dedupe map).
- I2 No outcome other than `answered` ever carries pccBinID/material.
- I3 Store append is synchronous under lock; safe from inference queue.
- I4 Export round-trip: every line parses as v1; every cropFile exists.
- I5 Prune never deletes records referenced by any export manifest.
- I6 All model-API throws are caught at the arbiter boundary; none escape.
