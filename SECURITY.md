# Security

TokenTide reads an OAuth token that can act on your Claude account, so here is exactly what it does with it.

## What it touches

| Resource | Access | Why |
|---|---|---|
| Keychain item `Claude Code-credentials` (via `/usr/bin/security`) | read | To get the OAuth access token and plan tier that Claude Code stored |
| `~/.claude/projects/**/*.jsonl` | read | To get Claude Code token counts and the model mix |
| `https://api.anthropic.com/api/oauth/usage` and `/api/oauth/profile` | HTTPS GET | To get limit percentages, reset times and the plan |
| App `UserDefaults` (`io.github.ychu824.TokenTide`) | read and write | Stores the widget position and the last limit percentages and reset times |

**Nothing else.** There is no analytics, no telemetry, no update checker and no third-party host.

## How the token is protected

- **Same Keychain access as Claude Code.** TokenTide reads the item with `security find-generic-password`, exactly as Claude Code does. The item's access list already trusts that tool, so there's no extra prompt. This means any process running as you can read this token the same way. That's a property of how Claude Code stores it, and TokenTide neither widens nor narrows it.
- **Kept in memory only.** The token is never logged, displayed, written to disk or put into a URL. Error messages never include it.
- **One host.** All requests go through a single function (`Net.get` in `TokenTide.swift`). It builds URLs only for `https://api.anthropic.com` and uses an *ephemeral* `URLSession`, which means no disk cache, no cookies and no credential storage. It refuses redirects, so the `Authorization` header can't be forwarded to another host, and it rejects any response that doesn't come from that host.
- **No token refresh.** TokenTide never refreshes or rewrites the token, so it can't corrupt Claude Code's stored credentials.
- **Minimal persistence.** Only the displayed numbers are cached (`[{id, pct, resetsAt}]`), never the raw API response. That data is not secret, so it is minimized rather than encrypted.

## Why it isn't sandboxed

The App Sandbox would block both data sources: reading another app's Keychain item and reading `~/.claude`. TokenTide ships with the hardened runtime and is notarized by Apple instead.

## Verify it yourself

- **Read the code.** The whole app is one file, `TokenTide.swift`. Run `grep -n "Net.get\|SecItem\|UserDefaults" TokenTide.swift` to find every network call, Keychain read and write in a few seconds.
- **Check a downloaded build.** Confirm the checksum, signature and notarization:

  ```bash
  shasum -a 256 -c SHA256SUMS.txt
  codesign -dv --verbose=4 TokenTide.app                    # Developer ID Application: Yucheng Hu (H63486AZ9Y)
  spctl --assess --type execute --verbose=2 TokenTide.app   # source=Notarized Developer ID
  ```

  Or build it yourself from the tagged source with `./build.sh`.

- **Watch the traffic.** Run Little Snitch or LuLu, and you should only ever see `api.anthropic.com`.

## Reporting a vulnerability

Please use **GitHub → Security → Report a vulnerability** (private advisory) instead of a public issue.
