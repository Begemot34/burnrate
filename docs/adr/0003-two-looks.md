# 3. Two looks over the same data

Status: Accepted (2026-10-07)

## Context

The original web page had a deliberate "BLACK SITE" look: black, mono type, LED bars. The Mac app
inherited it. macOS 26 brought Liquid Glass, and a native menu bar panel and widget that ignore
the system look sit badly next to everything else on the desktop. Neither look was willing to go.

## Decision

The app has two looks over one `Store`: **Boring** follows the system (SF font and
symbols, accent colour, light or dark, Liquid Glass, Reduce Motion and Increase Contrast) and
**Cyberpunk** keeps the dark mono look, with the system accent instead of acid yellow.
Cyberpunk is the default. The choice is one `Look` value in UserDefaults, switched from the
toolbar, View ▸ Look (⌥⌘L) or Settings, and written into the widget snapshot so the widget
follows. Boring views live in `Views/Boring/`, Cyberpunk views in `Views/`; the widget has
`BoringWidget.swift` and `CyberWidget.swift`.

## Consequences

- Every surface (window, cards, menu panel, banner, widget) exists twice; a new field needs both.
- Everything the two must agree on (values, countdowns, levels, pace text, headline) is computed
  once in `BurnrateCore` (`Format`, `MenuSummary`, `Pace`), not in the views.
- Cyberpunk bundles Space Grotesk and JetBrains Mono (OFL), fetched at build time and listed in
  `THIRD_PARTY_NOTICES.md`; the widget ships its own copy of the mono face.
- The debug snapshot mode renders the chosen look, and Boring in both schemes, for visual checks.
