# Releasing TokenTide

Pushing a `v*` tag runs `.github/workflows/release.yml`. The workflow:

1. Builds a universal (arm64 + x86_64) app.
2. Signs it with your Developer ID and the hardened runtime.
3. Notarizes it with Apple and staples the ticket.
4. Attests build provenance.
5. Publishes a GitHub Release with the zip and `SHA256SUMS.txt`.

## One-time setup: 5 repository secrets

Add these under **Settings → Secrets and variables → Actions**, or with `gh secret set`.

| Secret | What it is |
|---|---|
| `MACOS_CERT_P12` | Your **Developer ID Application** certificate and private key, exported as `.p12` and base64-encoded |
| `MACOS_CERT_PASSWORD` | The password you set when exporting the `.p12` |
| `NOTARY_KEY_P8` | App Store Connect API key (`.p8`), base64-encoded |
| `NOTARY_KEY_ID` | That key's Key ID |
| `NOTARY_ISSUER_ID` | Your Issuer ID, shown at the top of the Keys page |

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

### 2. Notarization API key

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
