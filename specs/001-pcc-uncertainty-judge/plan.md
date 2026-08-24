# Implementation Plan: PCC Uncertainty Judge (Silent Second Opinion)

**Branch**: `001-pcc-uncertainty-judge` | **Date**: 2026-08-24 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-pcc-uncertainty-judge/spec.md`

## Summary

When a deposit resolves through the uncertainty→residual fallback path, the
app silently sends the cropped item image plus decision context to Apple's
Private Cloud Compute model (`PrivateCloudComputeLanguageModel`, iOS 27),
receives a structured verdict constrained to the BinGuide taxonomy, and
persists it as a versioned record beside what YOLO/belief decided. Nothing
user-visible changes. Records + crops export as a date-ranged JSONL bundle —
the foundation for future YOLO teaching. Availability/quota are checked
pre-call; failures are recorded, never fabricated over.

## Technical Context

**Language/Version**: Swift 6 (Xcode 27 SDK), iOS deployment target 26.5;
PCC paths gated `#available(iOS 27, *)`

**Primary Dependencies**: FoundationModels (`LanguageModelSession`,
`PrivateCloudComputeLanguageModel`, `@Generable` structured output,
`ContextOptions(reasoningLevel: .moderate)`); existing in-app: BeliefEngine,
ZoneDepositDetector, CategoryConfirmationCoordinator, ItemCropper,
DetectionSessionLogger patterns

**Storage**: Files under Application Support (`PCCJudge/records.jsonl` +
`crops/<uuid>.jpg`), lock-guarded sync writes mirroring
`DetectionSessionLogger`; no CoreData/UserDefaults beyond one toggle

**Testing**: Swift Testing (`import Testing`, `#expect`), mock arbiter behind
protocol; Xcode scheme "Simulated Apple Foundation Models Availability" for
quota states on device

**Target Platform**: Kiosk iPad/iPhone, Apple Intelligence-capable hardware,
iOS 27+ for judge features; 26.5 devices get inert no-op

**Performance Goals**: Zero added work on non-trigger frames; ≤1 PCC request
per uncertain deposit; verdict persisted within 15 s of deposit

**Constraints**: ≤10 s request timeout; circuit breaker after 3 consecutive
failures; no live-verdict influence whatsoever; no fabricated outputs;
entitlement-gated; quota pre-check before every call

**Scale/Scope**: Single kiosk; worst case ~a few hundred records/day;
30-day prune window; export bundles bounded by chosen date range

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Verify before done | PASS | Full suite + `swiftlint --strict` gates in tasks |
| II. Threading discipline | PASS | Config flows via `PipelineInputs` extension; judge runs detached off frame path; store keeps lock-guarded sync API |
| III. Silence is a bug / never fabricate | PASS | Every failure becomes an outcome-tagged record + `AppLog.vision`; no simulated fallback exists anywhere in the judge |
| IV. Single sources of truth | PASS | Bin mapping resolves through `BinGuide`; uncertainty facts read from `TrackedDetection`/belief fields only |
| V. Pure core, test-first | PASS | Trigger policy + record schema are pure `nonisolated` types; arbiter behind `VerdictArbitrating` protocol |
| VI. Performance invariants | PASS | Trigger evaluation is O(1) bookkeeping at deposit time (not per frame); no formatter allocation |
| VII. Privacy posture | PASS (amended) | PCC is the sole sanctioned egress; toggle ON-by-default documented in spec; `PrivacyInfo.xcprivacy` reviewed in tasks |

## Project Structure

### Documentation (this feature)

```text
specs/001-pcc-uncertainty-judge/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   └── arbitration.md   # VerdictArbitrating + JSONL schema v1 contract
└── tasks.md             # Phase 2 output (/speckit-tasks)
```

### Source Code (repository root)

```text
waste-sort/
├── Core/Intelligence/PCCJudge/
│   ├── PCCJudgeAvailability.swift     # availability+quota snapshot (mirrors FoundationCategoryAvailability)
│   ├── PCCTriggerPolicy.swift         # pure: should this deposit trigger? dedupe rules
│   ├── VerdictArbitrating.swift       # protocol seam + ArbiterRequest value type
│   ├── PCCArbiterService.swift        # real arbiter: session, timeout, breaker, quota gates
│   ├── PCCVerdictRecord.swift         # record type + JSONL row codec (schema v1)
│   ├── PCCRecordStore.swift           # append-only jsonl + crops dir + prune + query by range
│   └── PCCDatasetExporter.swift       # date-range export bundle builder
├── Features/Live/LiveYOLOCamera.swift # trigger hookup in handle(); PipelineInputs fields
├── Features/Settings/AppSettings.swift# pccJudgeEnabled (4-place pattern)
├── Features/Settings/SettingsView.swift# toggle + status row + export UI
└── waste-sort.entitlements            # com.apple.developer.private-cloud-compute
waste-sortTests/Core/Intelligence/PCCJudge/
├── PCCTriggerPolicyTests.swift
├── PCCArbiterServiceTests.swift       # mock transport: timeout/breaker/quota/cancel
├── PCCRecordStoreTests.swift          # roundtrip, prune, range query
└── PCCDatasetExporterTests.swift      # JSONL schema + crop presence
```

**Structure Decision**: Extends the existing single-target app; judge lives as
a sibling of the current Intelligence layer so it reuses cropper/prompt/store
idioms without touching the confirmation subsystem.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (none) | | |
