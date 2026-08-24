# Sortla (waste-sort) Constitution

## Core Principles

### I. Verify Before You Claim Done
Work is not done until `xcodebuild test` (Swift Testing suite) passes on an
iOS 26.5+ simulator destination AND `swiftlint lint --strict` reports zero
errors. Claims of "tests pass" without having run them are prohibited. If the
environment cannot run verification, say so explicitly in the summary.

### II. Two-World Threading Discipline
The app has two worlds: **MainActor** (SwiftUI, AppSettings, stores,
RecordingController) and the **YOLO inference queue**
(`LiveYOLOCamera.Coordinator.handle()` at ~30 Hz). Load-bearing rules:
1. No plain mutable property may be read by both sides. Main→queue config
   flows ONLY through `PipelineInputs`, an immutable struct swapped atomically
   under `inputsLock`. Extend that struct; never invent side channels.
2. Tracker/deposit-detector knobs are set inside `handle()` on the queue that
   owns them, never from `updateUIView`.
3. Recording state crosses queues only via `RecordingPhaseMirror`.
4. `DetectionLogStore` / `DetectionSessionLogger` keep their intentional
   lock-guarded sync APIs; do NOT convert to actors.
5. Long-running async work (e.g., cloud-model calls) MUST run detached from
   the frame pipeline with timeouts and cancellation; per-frame latency is
   sacrosanct.

### III. Silence Is a Bug; Never Fabricate
- No bare `try?` on failure paths that matter; use `AppLog.<category>`
  (.ui/.pipeline/.recording/.persistence/.vision).
- No `print()`. Ever.
- User-facing failures surface honestly (`statusMessage`, failure banners).
- **A failing intelligence backend MUST NEVER yield invented output.** A
  simulated/random/heuristic fallback that mimics confidence is prohibited;
  degrade to the deterministic pipeline and record the failure instead.
  (Lesson: random "High (97.4%)" fallbacks masked every PCC error.)

### IV. Single Sources of Truth
| Truth | Do not duplicate |
|---|---|
| `BinGuide` | bin names/colors/aliases/normalization anywhere else |
| `BeliefEngine` verdicts + uncertainty | any other confidence-vote/argmax logic; `TrackedDetection.advisedBinID` is the only advice resolver |
| `applyThresholds(_:)` in `LiveYOLOCamera` | inline threshold triplets |
| `RuntimeSettings` snapshot | reading `AppSettings.shared` off-main |
| `TimestampFormatters` | per-frame `DateFormatter` allocation |
Adding a category/bin means changing `BinGuide` only.

### V. Pure Core, Test-First
Domain logic lives in `Core/` as `nonisolated` enums/structs with explicit
timestamp/config parameters. Tests use Swift Testing (`import Testing`,
`@Suite`, `#expect`) mirroring `Core/` structure. External intelligence
services sit behind small protocols so trigger logic, dedupe, circuit
breakers, and persistence are unit-testable without hardware or network.

### VI. Performance Invariants
Per-frame paths allocate zero formatters/scanners/engines. `updateUIView`
runs at inference rate: additions must be idempotent with change checks.
Auxiliary passes self-throttle and drop-when-busy; queuing stale frames is
prohibited.

### VII. Privacy Posture: On-Device by Default
The kiosk runs fully on-device: no secrets, no analytics. **Network egress is
prohibited EXCEPT through Apple-managed Private Cloud Compute**, which is
key-free, end-to-end verified, never stores prompts, and is gated behind:
explicit user-facing toggle, the `com.apple.developer.private-cloud-compute`
entitlement, availability/quota checks before each call, and an accurate
`PrivacyInfo.xcprivacy`. Any other networking requires a constitution
amendment first.

## Additional Constraints

- **Deployment target**: iOS 26.5. iOS 27-only APIs (FoundationModels PCC)
  MUST be gated with `#available(iOS 27, *)` and degrade gracefully to the
  existing belief-engine behavior on older OSes.
- **Entitlements**: PCC code paths assume the managed entitlement is attached
  to the App ID; absence is treated as unavailability, never a crash.
- **Quota discipline**: PCC has a daily per-user limit. Features MUST check
  availability/quota before calling, dedupe requests per item, apply timeouts
  (~10 s) and a consecutive-failure circuit breaker, and treat
  `quotaLimitReached` as a disable-until-reset condition.
- **File shape**: soft caps in `.swiftlint.yml`; split by responsibility when
  exceeded. Views contain no domain math. New persisted settings follow the
  four-place `Keys`/`WasteSortConfig.default*`/load/reset pattern.
- **Package seams**: only `YOLOViewPredictorAccess`/`YOLOViewCameraSwitcher`
  touch Ultralytics package internals.

## Development Workflow

- Spec-driven development (Spec Kit) governs feature-scale changes:
  specify → clarify → plan → tasks → analyze → implement.
- Branch from latest `main`. Behavior-preserving refactors stay separate from
  features. Commits are logical units.
- Quality gates (blocking): full test suite green + `swiftlint --strict`
  clean. Device-only behaviors (PCC, camera) get mock-based unit coverage;
  hardware paths are exercised manually and noted honestly.

## Governance

This constitution supersedes ad-hoc practices; `AGENTS.md` is its runtime
companion and inherits these rules. Amendments require: documented rationale
in this file, a semantic version bump (MAJOR: principle removal/redefinition;
MINOR: new principle/material expansion; PATCH: clarifications), and a Sync
Impact Report. All plans include a Constitution Check gate; violations block
implementation.

**Version**: 1.0.0 | **Ratified**: 2026-08-24 | **Last Amended**: 2026-08-24
