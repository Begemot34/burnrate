# 5. Desktop widget without an App Group

Status: Accepted (2026-10-07)

## Context

A WidgetKit extension must be sandboxed and normally shares data with its app through an App
Group container. App Groups are tied to a Team ID; Burnrate is distributed as source, built by
each user with SwiftPM and signed ad-hoc (`codesign -s -`), so there is no Team ID and no
provisioning. Xcode is not part of the build either, and SwiftPM has no extension target type.

## Decision

The app writes `~/Library/Application Support/burnrate/widget.json` (every 30 s when the content
changed, at least every 5 min) and the extension reads it through a home-relative read-only
temporary-exception entitlement (`Widget.entitlements`). The widget never touches the network.
`WidgetSnapshot` resolves the real home with `getpwuid`, since `NSHomeDirectory()` inside the
sandbox is the container. The extension is a SwiftPM executable target compiled with
`-application-extension` and linked with `-e _NSExtensionMain`, packed by `mac/build-app.sh` into
`Contents/PlugIns/BurnrateWidget.appex`, signed before the outer bundle. The app wakes
the widget only when the alert level or look changes or 15 min passed (reload budget).

## Consequences

- Works without an Apple developer account; `BUNDLE_ID=... make mac` keeps the pair in sync.
- Temporary-exception entitlements rule out the App Store; that was never the plan.
- The widget depends on the app: it keeps the last snapshot and marks it stale after 30 min.
- It only launches from a real install location (`~/Applications`), not from a hidden build dir;
  `scripts/install.sh` registers it with `pluginkit`.
- A `WidgetSnapshot` change must keep old files decodable: the widget may run an older build.
