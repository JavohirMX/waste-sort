# Spec 003 (APPROVED PLAN — not yet implemented)

## Confident-Verdict Audit: PCC double-checks sure answers too

**Approved decisions (user, this session):**
- Audit **all** confident deposits (no sampling). Uncertain→residual deposits
  keep first priority — processed first each frame so quota starvation can
  only ever hit audits, never the primary path.
- **Log-only**: when PCC disagrees with a confident verdict, nothing on screen
  changes. Disagreements enrich the learned-corrections analyzer (it already
  mines all answered records against the static mapping).
- Branch from the spec-002 line when picked up.

## Design (settled during research)

- `PCCTriggerPolicy.decision()` becomes path-aware:
  - uncertain path unchanged (`confirmationLocked` still blocks, skips recorded);
  - new audit path when `confidentAuditEnabled` — `confirmationLocked`
    deliberately NOT a blocker (verifying confirmed verdicts is the point);
  - shared gates: enabled / availability / quota / breaker / dedupe.
- `LiveYOLOCamera.evaluatePCCJudgments`: stable-sort deposits uncertain-first;
  iterate ALL deposits; context gets `beliefUncertain: deposit.wasUncertain`
  and `engineBinID: deposit.classKey` (the advised bin — already correct for
  confident deposits). Crops map already covers all deposits.
- `AppSettings`: `pccConfidentAuditEnabled` four-place plumbing +
  `WasteSortConfig.defaultPCCConfidentAuditEnabled = true`.
- `SettingsView`: "Audit confident verdicts" toggle; footer + empty-state copy
  ("logs unsure items and audits confident ones").
- **No schema migration**: v1 records already carry `beliefUncertain` and a
  generic `engineBinID`; `answered(from:)` already computes
  `agreesWithEngine` against whatever bin was advised.
- Tests: policy audit paths (trigger / ignores confirmationLocked / still
  quota+breaker gated / off → legacy behavior); record agreement-vs-advised-bin
  case; analyzer pins that confident records are mined.
- Docs: AGENTS.md §7, README, RUNBOOK Part B.

## Known tradeoff (accepted)

All-confident multiplies PCC call volume ~3–10×. Exhaustion shows up as
`skippedQuota` records in exports. If chronic, add a 1-in-N sampling knob
(~10-line change on top).
