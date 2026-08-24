# Hi-fi reference exports

Drop Figma frame exports here and Claude will match the app to them screen by screen.

## How to export

In Figma: select the frame → Export → **PNG, 2x** → export.

Name each file for the screen it shows. Suggested set:

| File | Screen | Code |
|---|---|---|
| `01-welcome.png` | Welcome | `Features/Onboarding/WelcomeScreen.swift` |
| `02-camera-setup.png` | Camera setup | `Features/Onboarding/CameraSetupScreen.swift` |
| `03-live.png` | Live camera | `Features/Live/LiveCameraView.swift` |
| `04-photo.png` | Sort photo | `Features/Photo/PhotoSortView.swift` |
| `05-stats.png` | Stats | `Features/Stats/StatsView.swift` |
| `06-history.png` | History | `Features/History/HistoryView.swift` |
| `07-settings.png` | Settings | `Features/Settings/SettingsView.swift` |
| `08-bin-settings.png` | Bin settings | `Features/BinSettings/BinSettingsView.swift` |

Add any state variants as `-<state>` suffixes, e.g. `03-live-detected.png`,
`04-photo-empty.png`. More variants is better — idle vs. active states are exactly
what could not be confirmed for the top bar.

## Also worth writing down

- **Frame width in px**, if it is not 2732 (= 1366pt @2x, the 12.9" iPad landscape
  size the top-bar frame used). Point values are derived from this, so a wrong
  assumption scales every measurement.
- Anything that is deliberately *not* final, so it does not get implemented as-is.

## Why PNGs are enough

Colours, spacing, radii and type size are all measurable off a 2x export. What a PNG
cannot give is variable *names* (`Accents/Green`) or the intent behind a value — so
where something looks ambiguous, expect a question rather than a guess.

## Status

Matched against the design so far: the top bar (`899:2279`) 1:1, and the bin accent
palette app-wide (`BinPalette` in `Core/Detection/BinGuide.swift`). Every other screen
is unverified — no frame for it has been seen.
