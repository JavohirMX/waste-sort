# AGENTS.md — Read this before touching anything

This file exists because this codebase was audited, de-raced, and restructured
deliberately. Every rule below exists because breaking it caused a real bug
here, not because a style guide said so. Follow it.

**Stack:** SwiftUI kiosk app (iOS 26.5), YOLOv8-seg via UltralyticsYOLO SPM,
AprilTag bin-lid detection via SwiftAprilTag, AVFoundation recording.
Build: Xcode with iOS 26.5+ SDK (`xcodebuild-beta`).

---

## 1. Verify before you claim done

```bash
# Unit tests (Swift Testing) — MUST pass. Note: deployment target is iOS 26.5,
# so only 26.5+/27.x simulators are valid destinations.
xcodebuild test -project waste-sort.xcodeproj -scheme waste-sort \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'

# Lint — MUST have zero errors (warnings are triaged, see .swiftlint.yml).
swiftlint lint --strict
```

If you cannot run these, say so explicitly in your summary. Never write
"tests pass" without having run them.

## 2. The threading model — the #1 way to break this app

There are two worlds that touch the same data:

- **Main thread / MainActor**: all SwiftUI, `AppSettings`, `RecordingController`
  phase machine, `ZoneStore`, stores.
- **YOLO inference queue**: `LiveYOLOCamera.Coordinator.handle()` runs here once
  per frame (~30 Hz). Also `DetectionSessionLogger.record()`,
  `DetectionLogStore.append()`, `BarcodeFrameScanner`.

Rules that are load-bearing:

1. **Never add a plain mutable property read by both sides.** Config flows from
   main → inference queue through `PipelineInputs`, an immutable struct swapped
   atomically under `inputsLock` in `Coordinator` (see `LiveYOLOCamera.swift`).
   Extend that struct; don't invent side channels.
2. **Tracker/deposit-detector knobs are set inside `handle()`**, on the queue
   that owns those objects — not from `updateUIView`.
3. **Recording state crosses queues only via `RecordingPhaseMirror`**
   (lock-guarded copy of `phase`). Don't read `recording.isRecording` from the
   camera queue; read `phaseMirror.current`.
4. **`DetectionLogStore` and `DetectionSessionLogger` lock their state**
   (`stateLock`). Their sync API is intentional — do NOT convert them to actors;
   `append()` must stay callable synchronously from the inference queue or event
   ordering breaks.
5. `VideoFrameColorProxy`, `AprilTagDetector` use dual locks (fast path vs UI
   polling). Preserve the split; the comments explain why.

## 3. Error handling: silence is a bug

- **No bare `try?` on failure paths that matter.** Use `AppLog.<category>` —
  categories: `.ui`, `.pipeline`, `.recording`, `.persistence`, `.vision`.
  A swallowed error here once left lid-gating dead forever with zero signal.
- **No `print()`.** Ever. It ships in release builds and is invisible in Console.
- User-facing save/export failures must reach `statusMessage` honestly
  (see `completionStatusMessage()` — "Files export failed" is deliberate).
- If a component can be permanently broken at init (e.g. AprilTag detector),
  surface it in the UI (pattern: `configurationFailureReason` +
  `TagFailureBanner`), don't just log.

## 4. Single sources of truth (do not duplicate)

| Truth | Do not duplicate |
|---|---|
| `BinGuide` (names, colors, aliases, normalization) | Overlay video styling (`OverlayBinStyle` derives from it), CSV rows, HUD |
| `BeliefEngine` (bin verdicts + uncertainty) | Any other confidence-vote/argmax logic; `TrackedDetection.advisedBinID` is the only advice resolver for CTA, HUD, and photo counts |
| `applyThresholds(_ settings:)` in `LiveYOLOCamera` | Inline `setConfidenceThreshold` triplets anywhere |
| `RuntimeSettings` snapshot | Reading `AppSettings.shared` off-main |
| `TimestampFormatters` | Allocating `DateFormatter` on any per-frame path (it cost real fps once) |
| `HapticsService` / `SpeechAnnouncer` | Raw `UIImpactFeedbackGenerator` / `AVSpeechSynthesizer` calls in views |

When adding a category/bin, change `BinGuide` only. Everything else follows.

## 5. File shape & conventions

- God files are how this codebase rotted the first time. Soft caps live in
  `.swiftlint.yml` (`file_length` warn 600 / error 1000). If you push a file
  past the warning, split by responsibility (see how `RecordingController`
  became controller + `PhotoLibrarySaver` + `RecordingRecoveryService` +
  `VideoRotationMath`; and `DetectionSessionLogger`).
- Pure logic goes in `Core/` as `nonisolated` enums/structs with explicit
  timestamp/config parameters — that's what makes it unit-testable
  (`CTAArrowPath`, `VideoRotationMath`, `BinGuide` are the models to copy).
- Tests use **Swift Testing** (`import Testing`, `@Suite`, `#expect`) — not
  XCTest. Existing suites live mirroring `Core/` structure.
- New persisted settings: follow the `Keys` enum + `WasteSortConfig.default*` +
  `loadBool/loadDouble` + `resetToDefaults()` pattern in `AppSettings.swift`.
  All four places or it's broken.
- Views never contain tag-numbering math, threshold application, or CSV row
  building. If you're about to put domain logic in a view file, stop.

## 6. The Ultralytics adapter seam

`YOLOViewPredictorAccess` (Mirror-based) and `YOLOViewCameraSwitcher` are the
ONLY files allowed to touch package internals. The package is pinned
(`upToNextMajorVersion` from 8.9.13) precisely because these lookups break on
renames — if they return nil after an upgrade, detection degrades instead of
crashing. Keep it that way; don't scatter more reflection elsewhere.

## 7. Apple-framework features already integrated

Don't re-implement these, extend them:

- **Speech guidance**: `SpeechAnnouncer` (+ `GuidancePhrases`), toggle
  `settings.voiceGuidanceEnabled`. Interrupts rather than queues utterances.
- **Haptics**: `HapticsService` — CoreHaptics patterns per bin, warning buzz
  for wrong-bin deposits, UIFeedbackGenerator fallback.
- **TipKit**: `SettingsAccessTip` reveals the long-press gesture; retires via
  donated event. Configure happens once in `WasteSortApp.init`.
- **PCC judge** (`Core/Intelligence/PCCJudge/`): silent Private Cloud Compute
  second opinion for uncertain→residual deposits; log-only, never touches live
  verdicts. iOS-27-gated behind `PCCJudgeABI` dlsym probes; quota/breaker
  discipline built in. Setup + export workflow:
  `specs/001-pcc-uncertainty-judge/quickstart.md`.
- **PCC judge** (`Core/Intelligence/PCCJudge/`): silent Private Cloud Compute
  second opinion for uncertain→residual deposits; log-only, never touches live
  verdicts. iOS-27-gated behind `PCCJudgeABI` dlsym probes; quota/breaker
  discipline built in. Setup + export workflow:
  `specs/001-pcc-uncertainty-judge/quickstart.md`.
- **App Intents**: `SortlaShortcuts` (toggle recording, voice guidance, cycle
  model). All hop to MainActor singletons.
- **Vision barcodes**: `BarcodeFrameScanner` (own serial queue, 0.5 s throttle,
  drop-when-busy) → `BarcodeHintChip`. Offline by design — hints are honest
  ("sort by packaging"), there is NO product-name database. Don't add network
  lookups without discussing privacy posture first.

## 8. Performance invariants

- Per-frame paths (`handle`, `captureOutput`, compositor): zero allocations of
  formatters/scanners/engines. Reuse cached statics.
- `updateUIView` runs every detection frame. Anything added there runs at
  inference rate. Guard-by-design (idempotent setters, change checks like
  `lastAppliedCaptureControls`), never guard-by-comment alone.
- Barcode/AprilTag passes self-throttle and drop frames when busy. Keep that
  policy; queuing stale frames is worse than skipping them.

## 9. Known debt (fine to leave, not fine to grow)

- `ZoneDepositDetector` (~500 lines) is the last god class in Core. Well-tested;
  split carefully or not at all.
- `RecordingController` (~700 lines) still owns phase machine + watchdogs;
  further extraction welcome (auto-start policy next).
- Control Center widget requires a widget-extension target + App Group
  entitlement — deliberately deferred (signing implications). Siri shortcuts
  cover hands-free use today.
- Swift 6 mode / complete concurrency checking is the goal now that the races
  are fixed; expect warnings to become errors when flipping the switch.

## 10. House rules

- Branch from latest `main`. Commit in logical units; keep behavior-preserving
  refactors separate from features (history shows how).
- No secrets, no network calls, no analytics: this kiosk runs fully on-device
  and `PrivacyInfo.xcprivacy` declares exactly three required-reason API
  categories. Keep it accurate when touching defaults/file APIs/disk space.
- When you disagree with a rule above, update this file with your reasoning —
  but only after your change proves the old rule wrong.
