# HANDOFF — PCC Photo Smoke Test & Vision Diagnosis

**Audience:** the next engineer (or operator-curious human) picking up this
branch. Read this top to bottom and you will know exactly what happened, why
the code looks the way it does, and what to do when Apple ships the next beta.

**Status: RESOLVED & FAST.** PCC vision works end-to-end. Measured latency at
the production image size is ~1–2 s on device and ~1.3 s on the simulator.
Everything below documents the week it very much did not work, because the
reasons it did not work will come back with every future beta cycle.

---

## 1. TL;DR

| Question | Answer |
|---|---|
| What broke? | Any image sent to Apple's `PrivateCloudComputeLanguageModel` crashed the app (`EXC_BAD_ACCESS`) on iOS 27 beta ≤ 4 |
| Why? | Toolchain/OS beta mismatch: app built with the **Xcode 27 beta 1 seed SDK** (`27A5194q`) running on a device on **iOS 27 beta 4**. This framework has a documented history of exactly this crash class when Xcode and OS betas drift apart |
| How was it proven? | Bisection: text-only probe ✅, entitlement verified in binary + profile ✅, capability flags declared `vision` ✅, every attachment variant (CGImage, file URL) 💥 — then version match fixed it |
| What protects users meanwhile? | `PCCVisionGate` — image attempts are opt-in (default OFF). A Mach trap cannot be caught in Swift; the only defense is not making the call |
| What made it fast? | The smoke screen was sending 1024 px crops; the live judge sends 448 px. Measured: 1024 px = 6–8 s (straddles timeouts), 448 px = **~1.3 s**. Both now use the same config constants |
| Current state | Text probe, image judgment, and on-device cross-check all work; records land in the same store/export pipeline as the live judge |

---

## 2. Context: what the PCC judge is

The kiosk (this app) classifies waste on-device with YOLOv8. When the belief
engine is *uncertain* and the item is headed to residual, a silent second
opinion is requested from Apple's **Private Cloud Compute** (PCC) — the same
server model that powers Apple Intelligence features. Contract rules that
govern everything (see `AGENTS.md` and `specs/001-pcc-uncertainty-judge/`):

- **Log-only.** The judge never changes a live verdict. It records evidence so
  humans can later mine routing corrections (spec 002) or audit confident
  verdicts (spec 003 plan, pending).
- **No fabricated answers (Constitution III).** Every failure — timeout, quota,
  breaker, unparseable output — becomes an honest record. No code path invents
  an answer when the model fails.
- **PCC is the only network egress** in the app (Constitution VII).
- iOS-27-only symbols are weak-imported behind `#available(iOS 27)` +
  `canImport(FoundationModels)`; the deployment target is iOS 26.5.

The **photo smoke screen** (`PhotoSortView`) exists because you cannot debug
PCC from the live kiosk flow: it isolates one gallery photo → one judge call,
through the exact production pipeline (same service, same transport, same
records), with no YOLO/belief engine involved.

---

## 3. The investigation, compressed

Chronological bisection, each step eliminating a variable:

1. **Crash on first real use.** `EXC_BAD_ACCESS (code=1, address=0x0)` inside
   the FoundationModels prompt builder, exactly at the `Attachment(...)`
   construction. Under lldb it pauses; standalone it kills the app. A Mach
   trap — **not catchable in Swift**, no error to handle.
2. **Signing/entitlement ruled out.** `codesign -d --entitlements` showed
   `com.apple.developer.private-cloud-compute=true` in the binary AND the
   embedded provisioning profile authorized it. Twice.
3. **Transport hardened** (`a9e6937`): plain-text `respond`, strict one-line
   output contract parsed in-app, image normalized to 8-bit sRGB JPEG temp
   file. Still trapped.
4. **Text-only probe added** (`454611f`): the sentinel `yoloLabel =
   PCCTextProbe.label` makes the transport send the same prompt builder with
   NO attachment. On device: **probe answered, image trapped** → fault
   isolated to the attachment path itself.
5. **Capability preflight added**: `model.capabilities.contains(.vision)`
   before ever attaching an image. On device the preflight *passed* (runtime
   declared `vision`) and the trap happened anyway — the beta lied.
6. **Opt-in gate** (`441846d`): since a trap cannot be caught, image attempts
   became opt-in via `PCCVisionGate` (UserDefaults-backed, default OFF). The
   app became un-crashable while still able to re-test after beta updates.
7. **Web research** surfaced the precedent: identical `EXC_BAD_ACCESS` on
   `LanguageModelSession` during the iOS 26 beta cycle, resolved only when
   developers **matched Xcode beta and OS beta versions** (Apple Dev Forums
   thread 796056, and the ModelManager 1026 thread). Our Xcode was the
   WWDC26 *seed* (beta 1) against a beta 4 device — three betas drifted.
8. **User updated both** (Xcode 27 beta 6 + matching device beta): trap gone.
   PCC answered image prompts with a *clean framework error* instead —
   "The prompt contains content that the model cannot process."
9. **Simulator reproduction** (`8ea006b` era): created an iOS 27 sim device,
   ran a throwaway diagnostic suite (live network calls — never committed).
   **PCC vision works in the simulator on beta 6.** Synthetic 96 px: ~2–3 s.
   Real photo at production crop: ~1.3 s. The device-side "content" error
   remained device/content-specific — see §6.
10. **Latency fix** (`9b95e03`): the smoke screen was cropping at 1024 px —
    heavier than the live judge's 448 px. Measured both: 1024 px = 6–8 s and
    straddled the 10 s timeout (one timeout, one 7.7 s answer); 448 px =
    1.3 s. Smoke screen now uses the production crop constants; timeout
    raised 10 → 20 s as headroom.

**Lesson to keep:** when FoundationModels misbehaves on a beta, first check
the Xcode/OS beta pairing before blaming the code or the feature.

---

## 4. How the pieces fit

```
PhotoSortView (diagnostic UI, Features/Photo/)
  ├─ judge        = PCCArbiterService(store:)            → defaultTransport (PCC)
  ├─ afmJudge     = PCCArbiterService(store:,transport:)  → onDeviceTransport (AFM)
  ├─ smokeJudge(context, crop)  → one recorded attempt, returned to UI
  ├─ runTextProbe()             → yoloLabel = PCCTextProbe.label (no attachment)
  └─ runAFMCrossCheck()         → same image, pipeline "photo-smoke-afm"

PCCTransports.swift (Core/Intelligence/PCCJudge/)
  ├─ PCCTextProbe          — ungated sentinel label ("text_probe")
  ├─ PCCVisionGate         — ungated opt-in switch (UserDefaults, default OFF)
  └─ PCCTransportFactory
       ├─ defaultTransport()   — PCC: vision gate → capability check → session
       ├─ onDeviceTransport()  — AFM: availability check → session
       ├─ sendAndParse(...)    — shared prompt + strict one-line contract parse
       ├─ preparedImageURL(...)— shared 8-bit sRGB JPEG temp-file normalization
       ├─ visionGateFailure()  — the two-layer preflight
       └─ parseVerdict(...)    — longest-token-first bin parsing; no guess on miss

PCCArbiterService.swift — gates (quota/breaker/dedupe), timeout race,
                          record store writes, judge()/smokeJudge() core
```

Design points worth knowing:

- **One shared `sendAndParse`** is used by *both* transports. The only
  variable between "PCC" and "on-device" is the model — that is what makes the
  cross-check button a controlled experiment.
- **Records are honest and distinguishable.** Smoke records carry pipelines
  `photo-smoke` (PCC) and `photo-smoke-afm` (cross-check);
  `PCCVerdictRecord.isDiagnostic` (pipeline contains "smoke") excludes them
  from learned-correction mining and Settings stats, so diagnostics can never
  become routing evidence.
- **`PCCVisionGate` is deliberately ungated** (outside the iOS 27 `#if`) so
  diagnostic UI on any OS can read/flip it. It exists because `EXC_BAD_ACCESS`
  cannot be caught — the only safe default on a lying beta is OFF.
- **The text probe is the crash-safe health check.** Same session shape, same
  builder, no attachment. If it answers, connectivity + quota + entitlement
  channel are proven good.

---

## 5. Measured numbers (iOS 27 beta 6 sim, throwaway diagnostic)

| Payload | Transport | Latency | Outcome |
|---|---|---|---|
| 96 px synthetic square | PCC | 1.5–3.4 s | answered |
| Real photo, 448–512 px crop (production shape) | PCC | **~1.3 s** | answered |
| Real photo, 1024 px crop | PCC | 6.3–7.7 s (1 timeout @10 s) | answered/timeout |
| Real photo, any crop | AFM (on-device) | 2.9–6.4 s | answered |

Device (user report, beta 6): **~1–2 s** on gallery photos. The ~20× gap
between 448 px and 1024 px is why the smoke screen must never drift from the
production crop constants again.

---

## 6. Open items

1. **Device "content cannot be processed"** — seen once on the user's device
   before the crop/timeout fix. If it ever reappears, the failure card now
   records the **concrete framework error case** and the **cross-check**
   button decides: on-device answers → PCC-pipeline issue (file Feedback with
   the case name + sysdiagnose); both fail → the photo trips guardrails, try
   another image.
2. **`PCCVisionGate` default is OFF by design.** After N consecutive green
   device runs on a stable beta, flip the default in `PCCTransports.swift`
   and update the smoke-screen copy.
3. **Circuit breaker (3 failures → 120 s cooldown) applies to smoke runs
   too.** If you are iterating failures, the screen will honestly say the
   breaker is open — wait it out rather than reinstalling.
4. **Spec 003 (confident-verdict audit)** is approved and parked at
   `specs/003-confident-verdict-audit/PLAN.md` — the reason this branch
   exists is so that work starts on a proven PCC path.

## 7. Beta-update protocol (repeat this every beta)

1. Update Xcode **and** the device to the *same* beta. Mismatch = the crash
   class that started all this.
2. Clean build folder (stale incremental builds once produced fake AMFI
   "security policy issue" launch denials).
3. Smoke screen → **Run text-only probe** (must be green first).
4. Flip **Attempt image judgments** ON → judge one gallery photo.
5. Green → optionally flip the gate default; flaky/red → leave OFF, capture
   the recorded error case, file Feedback with sysdiagnose.

## 8. Practical notes

- **PCC works in the iOS 27 simulator now** (Apple fixed it mid-cycle) — you
  can iterate without a device. The Mac needs Apple Intelligence; entitlement
  comes from the project's `.entitlements` (no provisioning on sim).
- **Test destinations change per Xcode install.** After a toolchain swap,
  re-check `xcrun simctl list devices available`; the old simulator UDID may
  vanish (and `xcodebuildmcp` may need a restart to see new ones).
- **After installing a new Xcode:** `sudo xcode-select -s
  /Applications/Xcode-<version>.app/Contents/Developer` — otherwise swiftlint
  crashes (`sourcekitdInProc failed`) and every LSP in every editor degrades.
  Restart editors afterwards; language servers cache the toolchain.
- **LSP "No such module UIKit/Testing" noise is permanent** — standalone
  indexing has no iOS build context. `xcodebuild` is truth (AGENTS.md §1).
- Records live at `Library/Application Support/PCCJudge/records.jsonl` inside
  the app container (`xcrun simctl get_app_container <sim> <bundle-id> data`
  on sim); export via Settings → Share.

## 9. File map

| File | Role |
|---|---|
| `waste-sort/Features/Photo/PhotoSortView.swift` | The diagnostic screen: status, capabilities row, vision toggle, probe + cross-check buttons, judgment cards |
| `waste-sort/Core/Intelligence/PCCJudge/PCCTransports.swift` | Both transports, shared prompt/parse, vision gate, probe sentinel |
| `waste-sort/Core/Intelligence/PCCJudge/PCCArbiterService.swift` | Service: gates, timeout race, records, `smokeJudge` |
| `waste-sort/Core/Intelligence/PCCJudge/PCCVerdictRecord.swift` | Record schema v1, `isDiagnostic` |
| `waste-sort/Features/Settings/AppSettings.swift` | `WasteSortConfig` constants (timeout, breaker, crop size…) |
| `RUNBOOK.md` | Operator guide (setup, entitlement attach, troubleshooting matrix) |
| `specs/001…`, `specs/002…`, `specs/003…/PLAN.md` | Feature history and next planned work |

Commits on this branch, in order: `914ffb0` (smoke screen) → `a9e6937`
(conservative transport) → `454611f` (preflight + probe) → `441846d` (opt-in
vision gate) → `8ea006b` (cross-check + full error detail) → `9b95e03`
(production crop + 20 s timeout).
