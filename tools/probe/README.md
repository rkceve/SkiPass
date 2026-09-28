# Feasibility probe (not shipped)

Before SkiPass was built, this probe checked that a third-party AutoFill credential provider can
supply a one-time code to Safari in the iOS Simulator, and recorded what the QuickType suggestion
looks like. It is kept as evidence and is not part of the app.

| Path | What |
|---|---|
| `ios/App`, `ios/AutoFill`, `ios/Shared` | `SkiPassProbe` app and `SkiPassProbeAutoFill` extension (always supplies a fixed code) |
| `UITests/ProbeAutoFillTests.swift` | `SkiPassProbeUITests`: enables the provider, opens the probe page in Safari, taps the suggestion |
| `site/index.html` | Probe page with one `autocomplete="one-time-code"` field, deployed to GitHub Pages by `.github/workflows/pages.yml` |

Run it with the `probe` workflow (`.github/workflows/probe.yml`, manual dispatch). It uploads a screen
recording, per-step screenshots and accessibility dumps.
