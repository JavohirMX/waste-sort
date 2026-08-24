# Data Model: PCC Uncertainty Judge

**Feature**: `001-pcc-uncertainty-judge` | **Date**: 2026-08-24

## Entities

### PCCVerdictRecord (immutable, Codable, schema v1)

| Field | Type | Notes |
|---|---|---|
| schemaVersion | Int (const 1) | per-line evolution escape hatch |
| id | UUID | record identity |
| timestamp | Date | trigger time |
| sessionId | String? | detection session correlation |
| trackId | Int | tracker identity (dedupe key) |
| cropFile | String? | `crops/<uuid>.jpg` relative name; nil if crop failed |
| yoloLabel / yoloConfidence | String / Double | raw detector context |
| beliefUncertain / beliefMargin | Bool / Double | engine context |
| engineBinID | String | resolved live verdict (expected residual/fallback) |
| pipeline | String | "belief" \| "legacy" (which engine routed it) |
| outcome | Outcome enum | answered / timeout / error / skippedQuota / skippedUnavailable / skippedOffline / skippedDisabled / cropFailed |
| pccBinID | String? | mapped BinGuide id when answer mapped cleanly |
| pccRawBinLabel | String? | model's own label string (even unmapped) |
| mappingFailed | Bool | true when pccRawBinLabel ∉ taxonomy |
| material / reasoningSummary | String? | structured output extras |
| agreesWithEngine | Bool? | nil when unanswered |
| latencyMs / inputTokens / outputTokens | Int? | telemetry |
| quotaStateAtCall | String? | belowLimit / approaching / limitReached |
| modelId / reasoningLevel | String | provenance ("pcc", "moderate") |
| errorMessage | String? | outcome==error only |

### ArbiterRequest (internal)

trackId, deposit context (record prefix fields), deadline (trigger+10 s),
Task handle; states queued → inFlight → finished(record) / cancelled.

### JudgeStatus (derived, MainActor-published)

availability (.ready/.quotaLimited(reset)/.unavailable(reason)),
approachingLimit: Bool, breakerOpen: Bool — powers Settings row.

### PCCTriggerDecision (pure value)

shouldTrigger: Bool + SkipReason — computed from deposit facts, track state,
confirmation lock, settings, availability, breaker, dedupe map.

## File layout (Application Support/PCCJudge/)

```text
records.jsonl          # append-only, one PCCVerdictRecord per line
crops/<uuid>.jpg       # cropped item images referenced by cropFile
exports/<stamp>/       # built bundles: records.jsonl + crops/ + manifest.json
prune-bookmark.plist   # last-prune run marker (throttle maintenance)
```

Pruning: records older than 30 days whose ids are absent from any completed
export manifest are deleted along with their crops; runs opportunistically
off the frame path (e.g., on app foreground), throttled to once/hour.

## Mapping rules

pccBinID resolution order: exact `BinGuide` alias/id match → dirty-recyclable
overlay id → mappingFailed=true (record keeps raw label). Live routing NEVER
consumes pccBinID in v1 (spec FR-5).
