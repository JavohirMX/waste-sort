# RUNBOOK — From zero to PCC-trained YOLO

The complete A→Z for making the self-learning loop work 100%: enable Private
Cloud Compute, collect evidence, apply learned corrections, and eventually
retrain YOLO on what PCC taught you. Written for `com.mohamedmorad.sortla`.

---

## Part A — Make PCC work (one-time, ~30 min)

### A1. Attach the entitlement to your App ID

The app already ships `waste-sort.entitlements` with
`com.apple.developer.private-cloud-compute`, but the entitlement must also be
enabled on the App ID at Apple or signing fails / the API traps at runtime.

1. Sign in at <https://developer.apple.com> → Certificates, Identifiers &
   Profiles → **Identifiers**.
2. Find the App ID for `com.mohamedmorad.sortla` (create it if missing —
   explicit App ID, not wildcard).
3. Scroll to the capability list and enable **Private Cloud Compute** (you
   already requested and received approval; this step attaches it).
4. If you use manual profiles: regenerate the provisioning profile now.
   Automatic signing picks it up on next build.

### A2. Build environment

- Xcode 27 beta (you have `27A5194q`) with the iOS 27 SDK.
- Signing team selected on the waste-sort target
  (Signing & Capabilities → Team). The entitlements file is referenced by both
  build configurations already.

### A3. Device checklist (simulators will NOT do)

| Requirement | Why |
|---|---|
| iPhone 15 Pro or newer / M-series iPad | Apple Intelligence hardware gate |
| iOS 27 beta installed | `PrivateCloudComputeLanguageModel` is an iOS 27 API |
| Apple Intelligence enabled in Settings | PCC rides the same infrastructure |
| Signed into iCloud | Personal Apple Intelligence request context |
| Siri & device language supported | AFM/PCC language availability |
| ≥7 GB free storage | Apple Intelligence models |
| Wi-Fi/cellular data | The entire point — this is the one network call |

### A4. Install and verify

```bash
cd waste-sort
xcodebuild -project waste-sort.xcodeproj -scheme waste-sort \
  -destination 'platform=iOS Simulator,id=2FA80E01-2CEA-41FB-B8FC-0F8478EED9A3' \
  -configuration Debug build
```

Run on device from Xcode, then: **Settings → PCC second opinion** and read the
Status row:

| Status | Meaning | Action |
|---|---|---|
| Ready | dlsym probes + model session OK | Nothing — go collect data |
| Approaching limit / Limit, resets HH:mm | Quota pressure | Fine; judge throttles itself |
| Unavailable (reason) | No Apple Intelligence / offline / unsupported OS | Fix per Part A table above |

Toggle **Silent PCC judge** stays ON (default).

### A5. Smoke test (5 min) — use the PCC photo screen

The fastest, most direct check: **Sort photo → PCC smoke test** (the photo-sort
screen is now a pure-PCC diagnostic — no on-device model runs).

1. Pick ANY gallery image of a waste item.
2. On this beta: run the **text-only probe** first — a green result proves
   PCC connectivity, quota, and the entitlement channel end-to-end (the exact
   production pipeline: gates, breaker, store recording). Image judgments are
   opt-in ("Attempt image judgments" toggle) because the beta traps on
   attachments; flip it only to re-test after a beta update.
3. If you get the orange card instead, the failure text tells you which gate
   failed (quota / unavailable / timeout) and what to fix — that is the honest
   answer to "is PCC working on this device".
4. Cross-check: Settings → export today → the bundle should contain a
   `records.jsonl` line with `"pipeline":"photo-smoke"`.

Live-path check (optional): point the kiosk at something genuinely ambiguous —
a foil-lined chip bag. The item must be guided to RESIDUAL via the *unsure*
path; only those deposits trigger a judgment. Wait ~15 s (nothing on screen
changes by design), then export and look for a `"pipeline":"belief"` line.

### A6. Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| App crashes on first judgment after upgrade | Entitlement not attached to the installed profile | Redo A1, delete app, reinstall |
| Status "unavailable (device)" on real hardware | Apple Intelligence off / unsupported hardware / beta expired | A3 checklist |
| Records show `skippedQuota` all day | Daily quota exhausted | Expected under heavy testing; resumes after reset time shown in Status |
| Records show `.error("gate: breaker open")` streaks | Three consecutive transport failures tripped the breaker | It auto-closes after 120 s; check network |
| `mappingFailed:true` lines | Model returned a label outside the taxonomy | Data, not a bug — kept for analysis |
| App crashes when PCC receives an image | **iOS 27 beta bug**: the runtime declares `.vision` but traps (EXC_BAD_ACCESS) on any image attachment — CGImage and file-URL variants confirmed; text-only calls work | Keep "Attempt image judgments" OFF in the smoke screen; use the text-only probe. Re-test after each beta, then re-enable |

---

## Part B — Collect evidence (ongoing)

- The judge fires **only** when the belief engine is unsure enough that guidance
  falls back to residual. Deliberately feed those items: foil bags, multilayer
  sachets, greasy containers, composite packaging, anything the demo hesitates on.
- Every judgment stores: crop JPEG, YOLO's label + confidence, belief margin,
  PCC's bin verdict + rationale, latency, quota state.
- **30-day prune**: records/crops older than 30 days are deleted on foreground
  unless they are part of an export bundle. Export before you lose them — or
  just export weekly (recommended cadence below).
- Storage: crops are ≤448 px JPEGs; thousands of judgments ≈ low MBs.

## Part C — Export & archive (weekly, 2 min)

1. Settings → pick range (default = last 7 days) → **Export judgments for range**.
2. **Share exported bundle** → Save to Files / AirDrop to your Mac.
3. Keep bundles forever — they are prune-immune (manifest-protected) and they
   are the raw material for every future training run.

Bundle layout:

```
<stamp>/            e.g. 20260825T101500Z/
├── records.jsonl   one JSON object per judgment (schema v1)
├── crops/          the cropped item images referenced by records
└── manifest.json   range + exported record ids (prune protection)
```

## Part D — Apply learned corrections (weekly, 5 min)

This is the loop that improves behavior *today*, no training required.

1. Settings → **Analyze judge records**.
2. Review each suggestion: `class · static bin → suggested bin · N judgments · X% agree`.
3. Tap **Apply** where the evidence convinces you. Guidance/scoring/deposit
   acceptance change immediately.
4. Wrong? Swipe the applied row to remove — instant restore.

Thresholds (tunable in `AppSettings.swift → WasteSortConfig`):

| Direction | Min judgments | Agreement |
|---|---|---|
| Into residual, or lateral moves | 12 | ≥75% |
| Out of residual (risky direction) | 30 | ≥85% |

Expect the list to be sparse at first — that means the thresholds are doing
their job, not that the loop is broken.

---

## Part E — Train YOLO on PCC data

Two honest tracks. Track E1 works today with zero new code. Track E2 is the
real detector upgrade and needs one small feature first.

### E1. Crop classifier from exports (works today)

Your exports are cropped item images labeled by a stronger teacher (PCC's bin).
Perfect for a classification fine-tune — and for measuring drift.

```bash
# 1. Organize the bundle into an ImageFolder dataset (script in repo)
python3 scripts/prepare_cls_dataset.py ~/Downloads/20260825T101500Z -o dataset

# 2. Train (any machine with Python 3.10+, pip install ultralytics)
yolo classify train data=dataset model=yolov8n-cls.pt epochs=50 imgsz=224

# 3. Read the val confusion matrix before trusting anything
```

Rules:
- Split is by capture session, so near-duplicate crops can't leak between
  train and val.
- Only proceed if val accuracy clears ~85% *and* confusions make physical
  sense (dirty_recyclable ↔ clean_inorganic confusion is expected;
  organic ↔ metal confusion means bad labels).
- What this model is for **v1**: offline drift measurement ("is the kiosk
  seeing more things PCC calls residual than last month?") and pre-screening
  future crops. Wiring it into the app as a second-stage verifier is a new
  feature — don't sneak it in without a spec.

### E2. Detection/segmentation retrain (the real deal)

Detection-grade retraining needs **full frames + boxes**, and current logs are
crops-only by design (privacy-minimal). The bridge is small and well-scoped:

**Spec 003 sketch (the one missing feature):**
When PCC answers, additionally persist the full camera frame + the detection
box (behind a separate opt-in toggle, same 30-day prune + export protection).
That turns every judgment into a ready-made detection annotation: frame + box +
teacher bin.

**Then the pipeline is standard:**

1. Collect ≥300 annotated frames per class-of-interest (PCC does the labeling,
   you spot-check ~10% in Roboflow/CVAT using the crop as reference).
2. Fine-tune:
   ```bash
   yolo segment train data=bali.yaml model=yolov8n-seg.pt epochs=100 imgsz=640
   ```
3. Convert to Core ML:
   ```bash
   yolo export model=runs/segment/train/weights/best.pt format=coreml imgsz=640
   ```
4. Ship as a candidate, never as default:
   - Rename to `bestv4.0.mlpackage`, drop into `waste-sort/Resources/Models/`.
   - Add `case bestv40 = "bestv4.0"` to `WasteSortModel`
     (`Features/Settings/WasteSortModel.swift`) — synchronized groups pick up
     the mlpackage automatically.
   - Build, install, select v4.0 in Settings (model selection is runtime-live).
5. **Bake-off gate** (constitution I): same physical items, back-to-back runs
   v3.5 vs v4.0; score verdict agreement with PCC + misroute count. Promote
   v4.0 to `WasteSortConfig.defaultModelName` only if it wins. Old packages
   stay in Resources so any kiosk can roll back instantly.

### E3. Never do these

- On-device `MLUpdateTask` weight updates (overfits from tiny samples,
  unverifiable — constitution III).
- Promoting a retrained model without the bake-off.
- Deleting old `.mlpackage`s from Resources.

---

## Part F — Cadence & success metrics

Weekly 15-minute ritual: export (C) → analyze/apply (D) → glance at metrics.

| Metric | Where | Healthy trend |
|---|---|---|
| Answered rate | records.jsonl outcome tags | Rising vs skippedQuota/error |
| Agreement rate per class | analyzer captions | Stable/rising; sudden drop = model or lighting drift |
| Suggestions applied | Settings list | Slowly growing, rarely removed |
| Residual fallback rate | session CSVs | Falling as corrections accumulate |

You are "at 100%" when: status shows Ready on the kiosk, weekly exports land on
your Mac, every eligible suggestion has been reviewed, and the bake-off gate
has promoted (or consciously rejected) your first retrained model.
