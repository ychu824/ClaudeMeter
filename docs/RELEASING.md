# Releasing TokenTide

Releases are built, signed, notarized and published from a local Mac with one command:

```bash
scripts/release.sh v0.1.1
```

The script:

1. Creates and pushes the tag, or reuses it if it already exists.
2. Builds a universal (arm64 + x86_64) app from the tag, signed with your Developer ID and the hardened runtime.
3. Notarizes it with Apple and staples the ticket.
4. Checks it with Gatekeeper (`source=Notarized Developer ID`).
5. Publishes a GitHub Release with `TokenTide-vX.Y.Z.zip` and `SHA256SUMS.txt`.

It stops at the first failure without publishing anything.

## One-time setup

You need these on the Mac you release from:

- **Xcode Command Line Tools:** `xcode-select --install`
- **GitHub CLI**, signed in: `gh auth login`
- **A Developer ID Application certificate in your login keychain.** Create one at developer.apple.com → Certificates → **+** → *Developer ID Application* (G2 Sub-CA), using a CSR from Keychain Access, then double-click the downloaded `.cer`. Check it with:

  ```bash
  security find-identity -v -p codesigning   # should list "Developer ID Application: …"
  ```

- **Notarization credentials** saved in the keychain, so no password is ever typed on the command line:

  ```bash
  xcrun notarytool store-credentials TokenTide --apple-id <developer Apple ID> --team-id <TEAM_ID>
  # enter an app-specific password (account.apple.com → Sign-In and Security → App-Specific Passwords)
  ```

## Verify a published build

```bash
shasum -a 256 -c SHA256SUMS.txt
codesign -dv --verbose=4 TokenTide.app                    # Developer ID + hardened runtime
spctl --assess --type execute --verbose=2 TokenTide.app   # "source=Notarized Developer ID"
```
