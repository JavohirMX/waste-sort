# Tasks: PCC Uncertainty Judge (Silent Second Opinion)

**Input**: Design documents from `/specs/001-pcc-uncertainty-judge/`
**Prerequisites**: plan.md ✓ spec.md ✓ research.md ✓ data-model.md ✓ contracts/ ✓ quickstart.md ✓

**Tests**: Included — the constitution mandates Swift Testing coverage; every
story lists its tests first where practical.

**Format**: `[ID] [P?] [Story?] Description` — [P] = parallelizable with its
siblings, [Story] = US1/US2/US3.

## Phase 1: Setup (Shared Infrastructure)

- [ ] T001 Attach `com.apple.developer.private-cloud-compute` to
  waste-sort target entitlements; verify provisioning regenerates without
  error (device build only).
- [ ] T002 Create `Core/Intelligence/PCCJudge/` group + add files to both
  targets (app + tests) in the Xcode project.

## Phase 2: Foundational (Blocking Prerequisites)

- [ ] T003 [P] Implement `PCCJudgeAvailability.swift` — `#available(iOS 27)`
  gate wrapping `PrivateCloudComputeLanguageModel().availability` +
  `quotaUsage` into a nonisolated snapshot enum (ready / quotaLimited(reset) /
  unavailable(reason)); mirrors FoundationCategoryAvailability patterns.
  No traps: availability checked before any property touch.
- [ ] T004 [P] Define contract types in `VerdictArbitrating.swift`:
  protocol + `ArbiterRequestContext` + `JudgeStatusSnapshot`
  (signatures per specs/.../contracts/arbitration.md).
- [ ] T005 [P] Implement `PCCVerdictRecord.swift`: immutable Codable record,
  Outcome enum, JSONL row codec (schema v1), BinGuide mapping helper
  returning (mappedID?, rawLabel, mappingFailed).
- [ ] T006 Implement `PCCRecordStore.swift`: Application Support layout,
  stateLock-guarded synchronous append (inference-queue safe), crops writer,
  date-range query, 30-day prune honoring export manifests (I5), throttle
  bookmark.
- [ ] T007 Extend settings plumbing four-place style:
  `Keys.pccJudgeEnabled`, `WasteSortConfig.defaultPCCJudgeEnabled = true`,
  load/reset in AppSettings, `RuntimeSettings` field; extend `PipelineInputs`
  with judge config so it reaches `handle()` atomically (Constitution II).

**Checkpoint**: pure types + store compile; no behavior change anywhere.

## Phase 3: User Story 1 — Silent second opinion on uncertain deposits 🎯 MVP

### Tests for User Story 1

- [ ] T008 [P] [US1] `PCCTriggerPolicyTests.swift`: triggers exactly on the
  uncertainty→residual fallback path without confirmation lock; explicit
  skip-reason for decisive verdicts, confirmation locks, disabled toggle,
  dedupe hits, breaker open, unavailable/quota (rule table from contract).
- [ ] T009 [P] [US1] `PCCArbiterServiceTests.swift` (mock transport):
  timeout at 10 s → outcome .timeout; thrown errors → .error + AppLog spy;
  3 consecutive failures open breaker (I-invariants I1/I2/I6); track-death
  cancellation still records; toggle-off mid-flight records and blocks new.

### Implementation for User Story 1

- [ ] T010 [US1] Implement `PCCTriggerPolicy.swift` (pure decision per
  contract rules) — make T008 pass.
- [ ] T011 [US1] Implement `PCCArbiterService.swift` behind the protocol:
  detached task per accepted request, `LanguageModelSession(model:
  PrivateCloudComputeLanguageModel())`, image attachment + context prompt,
  `@Generable` structured verdict (bin label/material/reasoning),
  `ContextOptions(reasoningLevel: .moderate)`, quota pre-check, circuit
  breaker, catch-all at boundary — make T009 pass. NO fabricated fallbacks.
- [ ] T012 [US1] Wire trigger evaluation into
  `LiveYOLOCamera.Coordinator.handle()` after deposit computation: crop via
  ItemCropper from frame image, policy check, submit to arbiter; O(1)
  bookkeeping, zero work when no qualifying deposit (SC-3). Config only via
  PipelineInputs (Constitution II).
- [ ] T013 [US1] Device smoke pass (manual, noted in summary): ambiguous
  item → residual guidance unchanged; record lands ≤15 s; HUD/CTA/speech/
  haptics byte-identical with judge ON vs OFF (SC-2).

**Checkpoint**: US1 independently demonstrable with mock in unit tests;
live-verdict outputs provably unchanged by existing suite passing untouched.

## Phase 4: User Story 2 — Teaching-dataset export

### Tests for User Story 2

- [ ] T014 [P] [US2] `PCCDatasetExporterTests.swift`: seeded store → range-
  filtered bundle; every line parses as schema v1; every cropFile resolves
  (I4); empty range → honest empty-result error; manifest fields correct;
  exported ids recorded for prune protection (I5 round-trip).

### Implementation for User Story 2

- [ ] T015 [US2] Implement `PCCDatasetExporter.swift`: build bundle dir
  (records.jsonl + referenced crops + manifest.json), mark included record
  ids as exported; surface honest failure via statusMessage (Constitution III).

**Checkpoint**: US2 testable end-to-end against seeded stores.

## Phase 5: User Story 3 — Quota/availability stewardship UI

### Tests for User Story 3

- [ ] T016 [P] [US3] Store tests for prune/range/query edge cases if not
  covered by T006 implementation notes (empty store, corrupt line skipped
  with log, prune spares exported).

### Implementation for User Story 3

- [ ] T017 [US3] SettingsView Developer section: judge toggle (bound through
  MainActor settings → RuntimeSettings refresh path), JudgeStatus row
  (ready/approaching amber/limit red+reset/unavailable reason, breaker flag),
  export control with DatePicker range feeding exporter + share sheet
  (pattern-match existing file-export UX).
- [ ] T018 [US3] Foreground maintenance hook: throttled prune call (never on
  frame path); PrivacyInfo.xcprivacy review note if file APIs change.

**Checkpoint**: All three stories complete.

## Phase 6: Polish & Verification (quality gates)

- [ ] T019 Run full suite: `xcodebuild test … -destination 'platform=iOS
  Simulator,name=iPhone 17 Pro,OS=26.5'` green (existing 321+ new tests);
  confirm zero modifications to existing expectation files (SC-2 evidence).
- [ ] T020 `swiftlint lint --strict` zero errors; file_length soft caps
  respected (split if warned).
- [ ] T021 Update AGENTS.md §7 (Apple-framework features) with one-line PCC
  judge entry pointing at specs/001…/quickstart.md; README bake-off section
  gains a "silent second opinion" paragraph.

## Dependencies & Execution Order

T001→T002→(T003..T007 parallel-ish)→US1 tests(T008,T009)→US1 impl(T010–T013)
→US2(T014→T015)∥US3(T016∥T017,T018)→gates(T019–T021).
US2/US3 depend only on Phase 2 foundations; they may start after T006/T007.

## Parallel Opportunities

[T003,T004,T005], [T008,T009], [T014,T016] are independent batches.
