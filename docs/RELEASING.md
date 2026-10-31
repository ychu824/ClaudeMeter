# Releasing TokenTide

## Local release (recommended)

One command builds a universal app, signs it with your Developer ID, notarizes and staples it, and publishes the GitHub Release:

```bash
scripts/release.sh v0.1.1
```

One-time setup: save notarization credentials in your login keychain, so no password is ever typed on the command line:

```bash
xcrun notarytool store-credentials TokenTide --apple-id <developer Apple ID> --team-id <TEAM_ID>
# enter an app-specific password at the prompt
```

The script reuses the tag if it already exists (for example after a failed CI run) and creates it otherwise.

## CI release (optional)

Pushing a `v*` tag runs `.github/workflows/release.yml`. The workflow:

1. Builds a universal (arm64 + x86_64) app.
2. Signs it with your Developer ID and the hardened runtime.
3. Notarizes it with Apple and staples the ticket.
4. Attests build provenance.
5. Publishes a GitHub Release with the zip and `SHA256SUMS.txt`.

## One-time setup: repository secrets

Add these under **Settings → Secrets and variables → Actions**, or with `gh secret set`.

| Secret | What it is |
|---|---|
| `MACOS_CERT_P12` | Your **Developer ID Application** certificate and private key, exported as `.p12` and base64-encoded |
| `MACOS_CERT_PASSWORD` | The password you set when exporting the `.p12` |
| **Notarization, option A:** `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`, `NOTARY_TEAM_ID` | Your Apple ID email, an **app-specific password**, and your Team ID |
| **Notarization, option B:** `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | An App Store Connect API key (`.p8`, base64-encoded), its Key ID, and your Issuer ID |

Set **one** of the two notarization options. If both are set, the API key wins.

Apple's notary service has returned persistent HTTP 500s to GitHub-hosted runners authenticating with an Apple ID + app-specific password, while the same credentials worked locally. If you hit that, use option B (API key) or the local release above.

### 1. Developer ID certificate

If you don't have a *Developer ID Application* certificate yet, create one at
developer.apple.com → Certificates → **+** → *Developer ID Application*. Then install it into your login keychain.

1. In **Keychain Access**, find `Developer ID Application: <Your Name> (<TEAMID>)`.
2. Expand it so the private key is included, select both, then right-click → **Export 2 items…** → save as `cert.p12` with a password.
3. Upload the certificate and its password:

```bash
base64 -i cert.p12 | gh secret set MACOS_CERT_P12 --repo ychu824/TokenTide
gh secret set MACOS_CERT_PASSWORD --repo ychu824/TokenTide   # paste the password at the prompt
rm cert.p12
```

### 2a. Notarization with an app-specific password (simplest)

1. Go to account.apple.com → **Sign-In and Security → App-Specific Passwords → +**, name it `TokenTide notarization`, and copy the password.
2. Upload it with your Apple ID and Team ID:

```bash
gh secret set NOTARY_APPLE_ID --repo ychu824/TokenTide   # the Apple ID email of your developer account
gh secret set NOTARY_PASSWORD --repo ychu824/TokenTide   # paste the app-specific password
gh secret set NOTARY_TEAM_ID  --repo ychu824/TokenTide   # e.g. H63486AZ9Y
```

You can revoke the password at any time from the same page.

### 2b. Notarization with an API key (alternative)

1. Go to App Store Connect → **Users and Access → Integrations → App Store Connect API → Team Keys → +**.
2. Choose the **Developer** role and download the `.p8`. Apple only lets you download it once.
3. Upload the key and its IDs:

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8 --repo ychu824/TokenTide
gh secret set NOTARY_KEY_ID    --repo ychu824/TokenTide   # e.g. XXXXXXXXXX
gh secret set NOTARY_ISSUER_ID --repo ychu824/TokenTide   # a UUID
```

Keep the `.p8` somewhere safe offline, or delete it. It can be revoked at any time from the same page.

## Cut a release

```bash
git tag v0.1.0
git push origin v0.1.0
```

Watch it run under the repo's **Actions** tab. A run takes about 5–10 minutes, most of it spent waiting on Apple's notary service.

## Verify a published build

```bash
gh attestation verify TokenTide-v0.1.0.zip --repo ychu824/TokenTide   # built by this repo's workflow
shasum -a 256 -c SHA256SUMS.txt
codesign -dv --verbose=4 TokenTide.app                                # Developer ID + hardened runtime
spctl --assess --type execute --verbose=2 TokenTide.app               # "source=Notarized Developer ID"
```
