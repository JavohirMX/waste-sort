# Plan: Learned Bin-Routing Corrections

## Approach

Read-side feature over the existing judge dataset. Three new units, one
decoration, one UI section:

1. **`PCCPolicyAnalyzer`** (pure, `Core/Intelligence/PCCJudge/`): groups answered
   judgments by normalized class, finds the dominant PCC bin, classifies
   direction against the *static* mapping (`BinGuide.staticInfo(for:)`), and
   applies asymmetric thresholds from `WasteSortConfig`. Emits
   `SuggestedOverride` values sorted by sampleCount desc then id.
2. **`AppliedBinOverrides`** (`@unchecked Sendable`, NSLock-guarded like
   `PCCRecordStore`): UserDefaults-backed JSON store (`appliedBinOverrides.v1`,
   ISO-8601 via `PCCRecordCodec`). `binID(forClass:)` normalizes before lookup.
3. **`BinGuide` decoration**: `info(for:)` checks an override provider set once
   at app init (`nonisolated(unsafe)` reference; the store itself is
   lock-guarded so inference-queue reads are safe). Static switch renamed
   `staticInfo(for:)`; `info` = override-or-static. `bin(id:)` untouched.
4. **Settings**: "Learned corrections" block inside `pccJudgeSection`: Analyze
   button → suggestions list (evidence + Apply), applied list with swipe delete
   and Remove all.

## Key decisions

- Suggestions compare against **static** mapping, not the recorded
  `engineBinID` (which is always residual for judged deposits).
- Override targets resolve through `bin(id:)`; unknown/invalid targets are
  ignored at lookup time (fail-safe to static).
- No schema changes: records already carry `yoloLabel`.
- Threading: provider closure reads only lock-guarded store state; set-once at
  app init means no torn reads of the reference itself.

## Risks

- `info(for:)` is called with bin names too ("organic"); overrides keyed by
  class names could shadow those lookups. Mitigation: analyzer only emits for
  labels seen in real detections; operators see exactly what they apply.
- Tiny samples early → few suggestions; documented in spec, not a bug.

## Test strategy

Swift Testing suites mirroring Core layout: analyzer rules (exclusions,
dominance, ties, directions, thresholds, sorting), override store
(apply/remove/persist round-trip via isolated defaults suite), and BinGuide
precedence (override wins, removal restores, invalid target falls back) with
defer-restore of the provider.
