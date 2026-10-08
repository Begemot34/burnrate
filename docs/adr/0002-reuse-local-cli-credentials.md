# 2. Reuse the credentials local CLIs already hold

Status: Accepted (2026-10-07)

## Context

Claude Code and Codex subscriptions have no public usage API with API keys. The CLIs on the Mac
are already logged in: Claude Code keeps an OAuth token in the Keychain item
`Claude Code-credentials`, Codex keeps `~/.codex/auth.json` and speaks a documented app-server
protocol. Asking users to copy tokens by hand would be fragile and risky; running our own OAuth
flow would duplicate what the CLIs do and need a client registration.

## Decision

Burnrate reads what is there and never refreshes or writes it. Claude: the Keychain item is read
with `/usr/bin/security` (already on the item's access list, so no prompt) and sent to the
undocumented `api.anthropic.com/api/oauth/usage`. Codex: `codex app-server` is asked over JSON-RPC
(`account/rateLimits/read`), so the token stays inside Codex; only with `"unofficial": true` does
Burnrate read `auth.json` and call `chatgpt.com/backend-api/wham/usage`; the newest session log is
the fallback. OpenRouter uses an API key from the Keychain or `env_file` (`docs/adr/0006`); Replicate uses only
the web session cookie, because its API has no billing and the cookie also names the account. Higgsfield is read through
its CLI. Every provider error passes through `Scrub` before it reaches a card.

## Consequences

- Zero setup for the subscription cards; an expired login shows a hint and keeps the last values.
- The undocumented endpoints and the cookie path can break without notice; the card then errors
  and the rest keeps working.
- The code must never log tokens; tests inject fake credentials and never touch the Keychain.
- Child processes are resolved on a PATH that includes Homebrew, since Finder launches get a bare one.
