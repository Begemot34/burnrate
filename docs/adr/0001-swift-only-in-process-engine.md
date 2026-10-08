# 1. Swift-only, in-process engine

Status: Accepted (2026-10-08)

## Context

Burnrate shows one person's limits on one Mac. A separate server polling the services and
serving the app (or a web page) over a local port would mean two toolchains, a port, a process
to supervise and a connection state in the UI, for a single window.

## Decision

The engine lives in the Swift package as `BurnrateCore`: providers, scheduler, history, month
total and the API-price estimate. The app runs the engine in process, `burnratectl` runs the
same engine from the terminal. There is no server, port or web page, and no plan to
bring them back.

## Consequences

- One toolchain: Swift 6.2, SwiftPM, no Xcode project, no external packages.
- No remote or browser access; the app, the CLI and the widget are the only consumers.
- Testing goes through the injected `Deps` (transport, exec, clock) instead of a mock server.
- One app instance polls and writes; a second launch hands over to the running one.
