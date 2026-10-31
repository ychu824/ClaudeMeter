# Security

TokenTide reads an OAuth token that can act on your Claude account, so here is exactly what it does with it.

## What it touches

| Resource | Access | Why |
|---|---|---|
| Keychain item `Claude Code-credentials` | read | To get the OAuth access token and plan tier that Claude Code stored |
| `~/.claude/projects/**/*.jsonl` | read | To get Claude Code token counts and the model mix |
| `https://api.anthropic.com/api/oauth/usage` and `/api/oauth/profile` | HTTPS GET | To get limit percentages, reset times and the plan |
| App `UserDefaults` (`io.github.ychu824.TokenTide`) | read and write | Stores the widget position and the last limit percentages and reset times |

**Nothing else.** There is no analytics, no telemetry, no update checker and no third-party host.

## How the token is protected

- **Scoped Keychain grant.** TokenTide reads the token through the Security framework, so the macOS prompt and your *Always Allow* apply only to TokenTide's code signature. Release builds are signed with a Developer ID, so the grant survives updates. Earlier versions shelled out to `/usr/bin/security`, and granting *that* would have let any process read the token silently. If you allowed it back then, remove `security` from the item's access list in **Keychain Access → Claude Code-credentials → Access Control**.
- **No surprise prompts.** Background refreshes read the Keychain non-interactively. If macOS would need to ask (for example after Claude Code re-creates its Keychain item), the widget shows a status line instead, and the dialog appears only when you choose **Allow Keychain Access…** from the right-click menu. The token is read once and re-read only after a 401.
- **Kept in memory only.** The token is never logged, displayed, written to disk or put into a URL. Error messages never include it.
- **One host.** All requests go through a single function (`Net.get` in `TokenTide.swift`). It builds URLs only for `https://api.anthropic.com` and uses an *ephemeral* `URLSession`, which means no disk cache, no cookies and no credential storage. It refuses redirects, so the `Authorization` header can't be forwarded to another host, and it rejects any response that doesn't come from that host.
- **No token refresh.** TokenTide never refreshes or rewrites the token, so it can't corrupt Claude Code's stored credentials.
- **Minimal persistence.** Only the displayed numbers are cached (`[{id, pct, resetsAt}]`), never the raw API response. That data is not secret, so it is minimized rather than encrypted.

## Why it isn't sandboxed

The App Sandbox would block both data sources: reading another app's Keychain item and reading `~/.claude`. TokenTide ships with the hardened runtime and is notarized by Apple instead.

## Verify it yourself

- **Read the code.** The whole app is one file, `TokenTide.swift`. Run `grep -n "Net.get\|SecItem\|UserDefaults" TokenTide.swift` to find every network call, Keychain read and write in a few seconds.
- **Check a downloaded build.** Confirm a release was built by this repository's GitHub Actions from the tagged source:

  ```bash
  gh attestation verify TokenTide-vX.Y.Z.zip --repo ychu824/TokenTide
  ```

- **Watch the traffic.** Run Little Snitch or LuLu, and you should only ever see `api.anthropic.com`.

## Reporting a vulnerability

Please use **GitHub → Security → Report a vulnerability** (private advisory) instead of a public issue.
