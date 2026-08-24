# Feature Specification: PCC Uncertainty Judge (Silent Second Opinion)

**Feature Branch**: `001-pcc-uncertainty-judge`

**Created**: 2026-08-24

**Status**: Draft

**Input**: User description: "Include Apple Private Cloud Compute in the kiosk app as a judge for items the belief engine is uncertain about. When an item is routed to residual because the pipeline is unsure, PCC should privately predict the correct bin and log the answer — without changing what visitors see — so the logs become training material to eventually teach YOLO. No live override, no retraining loop yet."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Uncertain deposits receive a silent expert second opinion (Priority: P1)

A visitor drops an ambiguous item (e.g., a foil-lined chip bag). The belief
engine is uncertain, so the kiosk guides them to residual exactly as today.
In the background — invisibly and without delaying anyone — the app sends the
cropped item image plus decision context to Apple's Private Cloud Compute
model, receives a structured verdict (bin + material + reasoning), and records
it alongside what YOLO/belief had decided.

**Why this priority**: This is the core value: every uncertain deposit starts
producing labeled comparison data. Nothing else in the feature matters until
this happens reliably.

**Independent Test**: Simulate a deposit that resolves through the
uncertainty→residual fallback path with a mocked arbiter; assert one verdict
record is produced containing YOLO label/confidence, belief margin, engine
verdict, PCC answer, agreement flag, latency, and outcome state. Live HUD,
CTA cues, and sounds are byte-identical to current behavior.

**Acceptance Scenarios**:

1. **Given** Apple Intelligence is available, quota is below limit, network is
   reachable, **When** a deposit resolves via the uncertainty→residual
   fallback path with no confirmation lock on that track, **Then** exactly one
   PCC request is issued per track and one `PCCVerdictRecord` is persisted
   within 15 seconds.
2. **Given** any PCC failure (timeout, network loss, quota exhausted, error),
   **When** the arbiter finishes or gives up, **Then** the failure is logged
   as a record with outcome state, `AppLog` entry written, and NO change to
   any user-visible behavior (no fabricated results ever).
3. **Given** a deposit that was decided confidently (decisive belief verdict
   or Foundation confirmation lock), **When** it completes, **Then** no PCC
   request is made.

---

### User Story 2 - Logged verdicts export as a teaching dataset (Priority: P2)

The operator/developer opens Settings → Developer and exports everything the
judge has collected: a JSONL file of verdict records plus the cropped item
images they refer to, ready to be consumed offline by future training work.

**Why this priority**: The logs are only valuable if they can leave the device
intact and self-describing; this is the "roots" of the eventual YOLO-teaching
loop.

**Independent Test**: Seed the store with N records via the mock arbiter,
run export, then validate the JSONL parses line-by-line into the record
schema and every referenced crop file exists in the export bundle.

**Acceptance Scenarios**:

1. **Given** ≥1 stored records, **When** export runs, **Then** a single
   shareable artifact is produced containing valid JSONL (one record per
   line, schema-versioned) and all referenced crops, importable with no
   manual cleanup.
2. **Given** zero stored records, **When** export runs, **Then** the user is
   told honestly that there is nothing to export (no empty-file confusion).

---

### User Story 3 - Quota and availability are stewarded, not discovered by crash (Priority: P3)

The judge consumes a finite daily per-iCloud-account quota. Before every call
the app checks availability and quota; when the limit is hit or the service is
unreachable, the judge pauses itself instead of burning failed requests, and
Settings shows honest status (ready / approaching limit / limit reached +
reset date / unavailable reason).

**Why this priority**: Protects the feature from silently dying mid-event day
and protects users from confusing failures; required for production but adds
no new data on its own.

**Independent Test**: With Xcode's simulated quota states (approaching /
limit reached), verify pre-call gating skips requests, a circuit breaker opens
after consecutive failures, and the status row reflects each state.

**Acceptance Scenarios**:

1. **Given** quota reports "limit reached", **When** uncertain deposits occur,
   **Then** no network calls are attempted and each attempt is recorded as
   skipped-quota until reset.
2. **Given** 3 consecutive arbiter failures, **When** another trigger fires,
   **Then** the circuit breaker holds calls for a cooldown window while still
   recording skip reasons.

---

### Edge Cases

- iOS 26.5 device / missing entitlement / Apple Intelligence off: judge is
  inert; availability surfaced in Settings; zero crashes, zero traps.
- Track vanishes before the response lands: response is matched to a dead
  track and still recorded (context fields note it), request not reissued.
- Same physical item deposited repeatedly: dedupe ensures one request per
  track identity; a genuinely new track may ask again.
- PCC answers a category outside BinGuide bins (e.g., "hazardous"): record
  preserves the raw answer plus a mapping-failed flag; live behavior unchanged.
- Crop extraction fails (item at frame edge): record attempt aborted with
  failure reason; no partial/garbage image shipped to the model.
- Offline (airplane mode): pre-call reachability/quota gate skips with
  reason; no retry storm.
- User toggles the judge OFF mid-session: in-flight request finishes and is
  recorded; no new triggers fire.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-1**: System MUST dispatch exactly one PCC arbitration request per
  tracked item whose deposit resolved through the uncertainty→residual
  fallback path, only when no Foundation-model confirmation lock exists for
  that track.
- **FR-2**: System MUST attach the cropped item image and structured decision
  context (YOLO label + confidence, belief margin/uncertainty reason, engine
  verdict) to every request.
- **FR-3**: System MUST request a structured verdict from PCC constrained to
  the project's bin taxonomy, preserving raw text when the constraint cannot
  be satisfied.
- **FR-4**: System MUST persist a versioned record per attempt containing:
  timestamp, track id, crop reference, YOLO/belief/engine context, PCC bin +
  material + reasoning summary, agreement flag vs engine verdict, latency,
  outcome (answered / timeout / error / skipped-reason), quota state, and
  model/reasoning-level identifiers.
- **FR-5**: System MUST NOT alter any user-visible behavior — overlays, CTA
  cues, counts, speech, haptics, photos, CSV stats — based on PCC output in
  this phase.
- **FR-6**: System MUST check availability and quota before each call, apply
  a ≤10 s timeout, cancel cleanly when tracks die, open a circuit breaker
  after 3 consecutive failures, and stop calling after quota-limit until reset.
- **FR-7**: System MUST expose a Settings toggle (Developer section) to
  enable/disable the judge, **defaulting to ON**, and a status row showing
  availability/quota/reset-date.
- **FR-8**: System MUST support exporting stored records + crops as a JSONL+
  images bundle from Settings, scoped by a user-chosen date range.
- **FR-9**: System MUST retain exported-format stability via a schema version
  field so future training tools can parse old exports.
- **FR-10**: System MUST auto-prune crops and their records older than 30
  days unless already included in a completed export; pruning runs as
  background maintenance, never on the frame path.
- **FR-11**: On OS versions below iOS 27 or without the PCC entitlement, the
  feature MUST compile and run as a no-op with accurate unavailability
  reporting.

### Key Entities *(include if feature involves data)*

- **PCCVerdictRecord**: one arbitration attempt; immutable; references crop
  asset by filename; carries full decision context, PCC answer, outcome, and
  schema version.
- **ArbiterRequest**: internal unit of work binding a track/deposit event to
  a pending PCC call; enforces dedupe and cancellation.
- **JudgeStatus**: derived availability + quota snapshot powering the
  Settings row and gating logic.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-1**: 100% of uncertainty→residual deposits produce a persisted record
  (answer or explicit failure/skip reason) whenever availability+quota+network
  permit — measured over a scripted fixture session replaying the bake-off
  scenarios.
- **SC-2**: Zero behavioral divergence: existing test suite passes untouched;
  live-verdict outputs for every scenario are identical with the judge ON or
  OFF.
- **SC-3**: Frame pipeline impact ≈ 0: trigger bookkeeping adds no measurable
  per-frame cost; all model work happens off the frame path.
- **SC-4**: Crash-free: no trap/exception can escape the judge under any
  combination of unavailable/quota/offline states (unit-proven via mocks).
- **SC-5**: Export round-trips: seeded stores export to valid JSONL where
  100% of lines parse against the documented schema and 100% of crop
  references resolve inside the bundle.

## Assumptions

- Kiosk hardware is Apple Intelligence-capable, iOS 27+, signed into iCloud
  (quota binds to that account); the PCC entitlement is attached to the App ID.
- Network at venue venues is normally available but MUST NOT be assumed
  during operation (offline = graceful skip).
- PCC latency (~4–8 s observed) is acceptable because nothing waits on it.
- Bali 3-stream regulations + dirty-recyclable overlay remain the taxonomy;
  PCC answers outside it are data, not routing.
- Judge calls use PCC reasoning level **moderate** (benchmark parity:
  13/13 accuracy at ~4–6 s); deep is a future tuning knob, not v1 scope.
- Exported records are marked so 30-day pruning never destroys data that has
  left the device.
- Future phases (audit sampling of confident items, live override, offline
  distillation) build on this record format but are out of scope here.
