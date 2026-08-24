# Research: PCC Uncertainty Judge

**Feature**: `001-pcc-uncertainty-judge` | **Date**: 2026-08-24

## R1. The correct iOS 27 way to call PCC

**Decision**: `LanguageModelSession(model: PrivateCloudComputeLanguageModel())`
from FoundationModels; unified API with on-device `SystemLanguageModel`.

- Verified against Apple docs + WWDC26 session 319 ("Build with the new Apple
  Foundation Model on Private Cloud Compute"):
  - Availability: switch over `model.availability`
    (`available` / `unavailable(.deviceNotEligible)` /
    `.systemNotReady` / other) before any call.
  - Quota: `model.quotaUsage.isLimitReached`,
    `.status` → `.belowLimit(info)` with `info.isApproachingLimit`,
    `resetDate`, `limitIncreaseSuggestion.show()` for upgrade UI.
  - Errors: `PrivateCloudComputeLanguageModel.Error.quotaLimitRaised/_reached`
    thrown mid-session when daily allotment exhausted; treat as
    disable-until-reset, NOT retryable.
  - Reasoning levels: `ContextOptions(reasoningLevel: .moderate)` etc.;
    reasoning segments don't appear in response content.
  - Context: 32K tokens vs 4K on-device; image attachments supported.
  - Requires network; docs recommend falling back to on-device model on
    network failure — for this feature we *skip and record* instead, because
    a silent on-device answer would contaminate the "what would PCC say?"
    dataset.
- **Entitlement**: `com.apple.developer.private-cloud-compute`, managed,
  applied via developer portal (Accessing Private Cloud Compute page).
  Account approval is confirmed; the entitlement must still be attached to
  the App ID/target for it to reach provisioning.

## R2. Why previous attempts crashed (post-mortem)

From `/Users/mohamedmorad/Developer/PCC-Test/apps/trash-sort`:

1. **Empty entitlements files** — PCC never truly available; availability
   checks failed or init/quota access trapped outside debugger (the code's
   own comments admit traps at `PCCVisionClassifierService.swift:26`).
2. **Fabricated fallback** — every caught error flowed into
   `simulateVisualClassification`, returning random sample items labeled
   "High (97.4%)" (`isSimulated: true` barely surfaced). This is the
   "errors in background, weird output" report. Constitution III now bans
   this pattern outright.
3. **No quota/breaker discipline** — repeated failing calls, no cooldown.

**Decision**: judge treats unavailability as a recorded skip; there is no
code path that invents an answer.

## R3. Benchmark evidence (why PCC is the judge)

13-image head-to-head (`PCC-Test`, `fm respond --model pcc|system`, Aug 2026):
PCC 100% object/policy/material accuracy, zero critical hallucinations;
on-device AFM 61.5%/38.5%/46.2% incl. composting-styrofoam-class errors.
Latency AFM ~2.4 s vs PCC ~4.5 s avg (max 7.7 s). Conclusion: PCC verdicts
are trustworthy labels for uncertain items; latency is irrelevant under the
log-only policy (nobody waits).

## R4. Trigger seam

**Decision**: evaluate triggers in `LiveYOLOCamera.Coordinator.handle()`
after deposit computation, not inside `ZoneDepositDetector`.

- Detector is pure Core without frame-image access; crops need the frame
  CGImage (same reason confirmation.update takes `frameImage:` closure).
- Deposit results already carry trackID; tracker holds YOLO label/confidence +
  belief fields; ConfirmationFrame exposes per-track lock state.
- Policy inputs are snapshot values → pure `PCCTriggerPolicy` decision, then
  one detached task per accepted request. Zero per-frame cost when no deposit.

## R5. Persistence & export shape

**Decision**: append-only JSONL + JPEG crops in Application Support; date-
range export builds a bundle (records.jsonl + crops/ + manifest.json).
Mirrors `DetectionSessionLogger` file idioms (stateLock-guarded sync append,
directory rotation not needed at kiosk volumes). JSONL chosen over CoreData:
training-tool friendly, diffable, schema-versioned per line (FR-9).

## R6. Dedupe semantics

Track identity = tracker track id within its lifetime; one request per id.
New track after respawn may re-ask (acceptable: different crop/moment).
In-flight map prevents double-fire while pending; toggle-off mid-session lets
in-flight finish (record kept) and blocks new triggers.

## Open questions remaining

None — clarified 2026-08-24: default ON; prune >30 days unless exported;
user-chosen date-range export; moderate reasoning level.
