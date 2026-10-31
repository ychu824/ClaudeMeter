#!/usr/bin/env bash
# One-command local release: build (universal, Developer ID) -> notarize -> staple -> publish.
#
#   scripts/release.sh v0.1.1
#
# One-time setup: store notarization credentials in your login keychain, so no
# password ever appears on the command line or in shell history:
#
#   xcrun notarytool store-credentials TokenTide \
#     --apple-id <developer Apple ID> --team-id <TEAM_ID>
#   (enter an app-specific password at the prompt)
#
# Needs: Xcode Command Line Tools, a "Developer ID Application" identity in your
# keychain, and gh (authenticated).
set -euo pipefail
# Everything runs inside main(), which bash parses in full before executing.
# That matters because we `git checkout` the tag below, which can change or
# remove this very file while it's running.
main() {
cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/release.sh vX.Y.Z}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Tag must look like v1.2.3"; exit 1; }
PROFILE="${NOTARY_PROFILE:-TokenTide}"
REPO="${REPO:-ychu824/TokenTide}"
ZIP="TokenTide-$TAG.zip"

[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Working tree has uncommitted changes."; exit 1; }

# Tag: reuse it if it exists, otherwise create and push it.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Using existing tag $TAG"
else
  git tag "$TAG" && git push origin "$TAG"
fi
START_REF="$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)"
git checkout -q "$TAG"
trap 'git checkout -q "$START_REF"' EXIT

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning \
          | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/')}"
[[ -n "$SIGN_ID" ]] || { echo "No Developer ID Application identity in your keychain."; exit 1; }

echo "==> Build"
VERSION="${TAG#v}" UNIVERSAL=1 SIGN_ID="$SIGN_ID" ./build.sh

echo "==> Notarize (profile: $PROFILE)"
ditto -c -k --keepParent TokenTide.app "/tmp/tokentide-submit.zip"
xcrun notarytool submit "/tmp/tokentide-submit.zip" --keychain-profile "$PROFILE" --wait
rm -f "/tmp/tokentide-submit.zip"

echo "==> Staple + verify"
xcrun stapler staple TokenTide.app
spctl --assess --type execute --verbose=2 TokenTide.app 2>&1 | tee /dev/stderr | grep -q "Notarized Developer ID" \
  || { echo "Gatekeeper check failed"; exit 1; }

echo "==> Package"
rm -f "$ZIP" SHA256SUMS.txt
ditto -c -k --keepParent TokenTide.app "$ZIP"
shasum -a 256 "$ZIP" > SHA256SUMS.txt

echo "==> Publish"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" SHA256SUMS.txt --repo "$REPO" --clobber
else
  gh release create "$TAG" "$ZIP" SHA256SUMS.txt --repo "$REPO" --title "TokenTide $TAG" --generate-notes
fi
echo "Done: https://github.com/$REPO/releases/tag/$TAG"
}
main "$@"
