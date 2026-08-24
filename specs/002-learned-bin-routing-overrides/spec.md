# Spec: Learned Bin-Routing Corrections (PCC Policy Pack)

**Branch**: `002-learned-bin-routing-overrides` · **Parent feature**: 001-pcc-uncertainty-judge
**Constitution check**: PASS — pure analyzer core (V), no live-verdict influence without explicit human apply (I, III), single source of truth preserved by decorating `BinGuide` only (IV), PCC remains sole egress (VII).

## Problem

The PCC judge logs every uncertain→residual deposit with what YOLO believed and
what PCC concluded. Today that dataset is write-only: a human must eyeball
exports to notice that the model systematically misroutes an item class
(e.g. chip bags → recyclable while PCC says residual every time). The loop from
"logged evidence" to "changed behavior" is manual and lossy.

## Goal

Mine the judge records for statistically dominant disagreements and let the
operator apply them as reviewed bin-routing overrides with one tap.

## User story

**US1 — Operator applies learned corrections**
As a kiosk operator, when I open Settings → PCC second opinion → Learned
corrections, I see suggestions derived from recorded judgments ("chip_bag:
residual · 14 judgments · 86% agree"), each with an Apply button. Applied
corrections take effect immediately in guidance/scoring and are listed below,
removable at any time. Removing one instantly restores the static mapping.

### Acceptance scenarios

1. Given ≥12 answered judgments for a class whose dominant PCC bin differs from
   its static BinGuide mapping with ≥75% agreement, When the corrections list is
   computed, Then exactly one suggestion appears for that class, classified
   into-residual or lateral.
2. Given a class whose dominant PCC bin equals its static mapping, When
   suggestions are computed, Then no suggestion appears (the misroute was the
   uncertainty fallback, not routing).
3. Given 14 answered judgments for a class statically mapped to residual where
   PCC dominantly says clean_inorganic (85%), When suggestions are computed,
   Then no out-of-residual suggestion appears; with ≥30 judgments at ≥85%
   agreement it does.
4. Given ties in dominant-bin counts, skipped/mapping-failed/empty-label
   records are excluded from all statistics.
5. Given an applied override for class X, When any code resolves routing via
   `BinGuide.info(for:)`, Then X resolves to the overridden bin until removed;
   removal restores the static map immediately.
6. Overrides persist across app restarts.

## Functional requirements

- **FR-1**: The analyzer is a pure function `[PCCVerdictRecord] → [SuggestedOverride]`;
  only `outcome == .answered && !mappingFailed && pccBinID != nil` records count.
- **FR-2**: Suggestion thresholds: into-residual and lateral need
  `minSamples ≥ 12` and `dominance ≥ 0.75`; out-of-residual needs
  `minSamples ≥ 30` and `dominance ≥ 0.85`. Thresholds come from `WasteSortConfig`.
- **FR-3**: A tie between two PCC bins yields no suggestion.
- **FR-4**: Applied overrides persist (`UserDefaults`, JSON, ISO-8601 dates) and
  carry their evidence snapshot (sampleCount, agreementRate, appliedAt).
- **FR-5**: `BinGuide.info(for:)` consults applied overrides before the static
  switch; invalid override targets fall back to static behavior. Static lookup
  stays reachable for the analyzer via `staticInfo(for:)`.
- **FR-6**: The Settings section lists suggestions with evidence, Apply per row,
  and applied rows with swipe-to-remove + "Remove all".
- **FR-7**: No automatic application ever: nothing changes guidance without an
  explicit operator tap (constitution III).

## Out of scope

YOLO weight retraining, OTA model delivery, backend upload, auto-apply modes.
