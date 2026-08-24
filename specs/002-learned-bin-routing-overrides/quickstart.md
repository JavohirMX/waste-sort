# Quickstart: Learned Bin-Routing Corrections

Prereq: the PCC judge (specs/001) has been running and recording judgments.

## Using it

1. Let the kiosk run. Every uncertain→residual deposit becomes evidence.
2. Settings → PCC second opinion → **Learned corrections** → *Analyze judge records*.
3. Review suggestions. Each row shows the class, its static bin, PCC's dominant
   bin, judgment count, and agreement rate. Tap **Apply** to route that class to
   PCC's dominant bin from then on.
4. Applied corrections appear below; swipe one to remove it, or use
   **Remove all**. Removal instantly restores the static mapping.

## Thresholds

| Direction | Min judgments | Agreement |
|---|---|---|
| Into residual / lateral | 12 | ≥75% |
| Out of residual | 30 | ≥85% |

Tunable via `WasteSortConfig.defaultPCCSuggestion*` /
`defaultPCCOutOfResidual*` in `AppSettings.swift`.

## Notes

- Suggestions only appear when PCC's dominant bin differs from the class's
  static `BinGuide` mapping — classes the fallback misroutes but whose static
  routing is already correct produce no suggestion.
- Overrides affect guidance, scoring, and deposit acceptance everywhere
  (`BinGuide.info(for:)` is the single resolution point).
- The underlying records/crops are untouched; exports keep working.
