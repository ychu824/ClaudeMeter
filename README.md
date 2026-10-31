# TokenTide

A tiny always-on-top macOS widget that shows how much of your Claude plan is left.

<p>
  <img src="docs/collapsed.png" height="110" alt="Collapsed: ring gauge">
  &nbsp;&nbsp;
  <img src="docs/expanded.png" height="160" alt="Expanded on hover: full panel">
</p>

**At rest** it's a small clay-tinted circle with two rings:

- the outer ring is the 5-hour window
- the inner ring is the 7-day window
- the number in the center is the 5-hour % left

**Hover** over it and it morphs into the full panel. Move the pointer away and it shrinks back.

## Install

**Download (recommended):** grab `TokenTide-vX.Y.Z.zip` from [Releases](https://github.com/ychu824/TokenTide/releases), unzip it, and move `TokenTide.app` to `/Applications`. It's signed with a Developer ID and notarized by Apple, so it opens with a double-click.

**Or build from source:** needs Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/ychu824/TokenTide.git && cd TokenTide
./build.sh && open TokenTide.app
```

You need **macOS 13+** and [Claude Code](https://claude.com/claude-code), signed in at least once, because TokenTide reuses its login.

On first launch, macOS asks whether **TokenTide** may use the `Claude Code-credentials` Keychain item. Choose **Always Allow**. To start it automatically, right-click the widget → **Launch at Login**.

## Security & privacy

TokenTide reads the OAuth token Claude Code keeps in your Keychain, so it's built to be easy to trust:

- **Only talks to `api.anthropic.com`.** HTTPS only, ephemeral session, redirects refused. There's no analytics, telemetry or update checker.
- **The token stays in memory.** It's never logged, shown or written to disk, and TokenTide never refreshes or modifies it.
- **The Keychain grant is scoped to TokenTide's signature,** not to a shared CLI tool.
- **Stores almost nothing:** the widget position and the last limit percentages and reset times. It never stores the raw API response.
- **One file to audit.** The entire app is `TokenTide.swift`.
- **Verifiable builds.** Releases are built, signed and notarized by GitHub Actions from the tagged source, with a [build provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations):

  ```bash
  gh attestation verify TokenTide-vX.Y.Z.zip --repo ychu824/TokenTide
  ```

Details and threat model: [SECURITY.md](SECURITY.md).

## What it shows

- **Plan**: Pro / Max 5x / Max 20x / Team / Enterprise
- **Limits**: 5-hour and 7-day windows, plus per-model weekly windows when your plan has them. Each shows % left and a reset countdown, and turns red at 20% or less.
- **Model mix**: share of Claude Code tokens by Opus / Sonnet / Fable / Haiku, for the current 5-hour window and for today
- **Tokens**: Claude Code tokens in the current 5-hour window and today

The widget floats above every window, on every Space and over full-screen apps. It has no Dock icon and no menu bar item. Drag it anywhere and it remembers the spot. It always expands toward the middle of the screen. Right-click it for **Refresh**, **Launch at Login** and **Quit**.

## How it works

| What | Source | Refresh |
|---|---|---|
| Limit % and reset times | `GET api.anthropic.com/api/oauth/usage` with Claude Code's OAuth token | every 90 s |
| Plan name | `subscriptionType` / `rateLimitTier` in the Keychain entry, with `/api/oauth/profile` as a fallback | once |
| Tokens and model mix | Claude Code's session logs, `~/.claude/projects/**/*.jsonl` | every 5 s, and when you hover |

- **Limits are account-wide.** claude.ai, the desktop app and Claude Code all draw on the same limits.
- **Tokens and model mix cover Claude Code only.** claude.ai chats aren't logged locally.
- **Token counting.** Tokens are input + output + cache writes. Cache reads are excluded.
- **Token share is not limit share.** Opus and Fable tokens weigh more against your limits than Sonnet tokens.
- **Log reading is incremental.** TokenTide keeps a byte offset per file and parses only new lines, so a scan takes milliseconds.
- **Rate limits.** If the endpoint returns 429, TokenTide backs off per `Retry-After` (at least 2 min) and keeps showing the cached numbers.

## Caveats

- `/api/oauth/usage` and `/api/oauth/profile` are **undocumented** endpoints and may change without notice.
- If Claude Code re-creates its Keychain item, macOS may ask once more for permission.

## Contributing

Issues and PRs are welcome. To cut a release, see [docs/RELEASING.md](docs/RELEASING.md).

## License

[MIT](LICENSE)

---

TokenTide is an unofficial community tool. It is not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic, PBC.
