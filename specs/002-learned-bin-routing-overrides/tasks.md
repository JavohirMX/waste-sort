# Tasks: Learned Bin-Routing Corrections

- [x] T1 [US1] Tests-first: `PCCPolicyAnalyzerTests` — exclusions (non-answered,
      mappingFailed, empty label), grouping, dominance math, tie rejection,
      no-op suppression vs static map, direction classification, asymmetric
      thresholds (14@0.85 out-of-residual rejected; 30@0.85 accepted), sort order.
- [x] T2 [US1] Tests-first: `AppliedBinOverridesTests` — apply/evidence snapshot,
      binID(forClass:) normalization, remove restores nil, removeAll, persistence
      round-trip across instances on a shared defaults suite.
- [x] T3 [US1] Tests-first: `BinGuideOverrideTests` — provider precedence,
      invalid target fallback, staticInfo parity with legacy switch.
- [x] T4 [US1] Implement `PCCPolicyAnalyzer.swift` + `AppliedBinOverrides.swift`;
      add `WasteSortConfig.defaultPCC{Suggestion,OutOfResidual}{MinSamples,Dominance}`.
- [x] T5 [US1] Decorate `BinGuide.info(for:)` with override provider +
      `staticInfo(for:)`; wire provider in `WasteSortApp.init`.
- [x] T6 [US1] Settings "Learned corrections" block (analyze button, suggestion
      rows w/ Apply, applied rows w/ swipe-remove + Remove all).
- [x] T7 Gates: full suite green + swiftlint 0 errors.
- [x] T8 Docs: AGENTS.md §7 (dedupe), README, quickstart addendum.
