# Quickstart: PCC Uncertainty Judge

**Feature**: `001-pcc-uncertainty-judge`

## One-time setup (developer machine / kiosk device)

1. Entitlement: open `waste-sort.xcodeproj` → target waste-sort → Signing &
   Capabilities → "+ Capability" → Private Cloud Compute (requires the
   account-approved entitlement). Confirm `com.apple.developer.private-cloud-
   compute` appears in entitlements and provisioning regenerates.
2. Device: physical iPhone/iPad, iOS 27+, Apple Intelligence enabled,
   signed into iCloud (daily quota binds to this account). Simulator cannot
   exercise PCC.
3. Network: venue Wi-Fi with egress to Apple PCC endpoints.

## Verify the judge works

- Settings → Developer → "PCC second opinion (judge)" toggle: ON by default;
  status row shows Ready / Approaching limit (+reset date) / Limit reached /
  Unavailable(reason).
- Drop an ambiguous item (foil chip bag works well): kiosk guides to residual
  exactly as before; within ~15 s a record appears in
  `Application Support/PCCJudge/records.jsonl` with outcome=answered and a
  crop under `crops/`. Nothing else on screen changes.

## Test quota paths without burning quota

Xcode → Product → Scheme → Edit Scheme → Run → Options:
- "Approaching Quota Usage Limit" → status row turns amber; calls continue.
- "Quota Usage Limit Reached" → no network calls; new deposits record
  outcome=skippedQuota; status shows reset date.

## Export the dataset

Settings → Developer → Export PCC judgments → pick date range → share sheet
produces `<stamp>/` bundle (records.jsonl + crops/ + manifest.json).
Validate locally:

```bash
jq -c . records.jsonl | wc -l            # == manifest.recordCount
jq -r .cropFile records.jsonl | grep -v null | while read f; do test -f "$f" || echo "missing $f"; done
```

## Failure triage

| Symptom | Meaning |
|---|---|
| outcome=skippedUnavailable | entitlement missing / AI off / ineligible OS |
| outcome=error + errorMessage | inspect AppLog.vision; breaker opens after 3 |
| No records at all | check toggle ON, availability row, and that deposits actually route via uncertain→residual |
