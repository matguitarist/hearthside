#!/usr/bin/env bash
# Set the GitHub Actions secrets .github/workflows/macos-release.yml signs, notarizes and signs
# updates with. Passwords are read from hidden prompts; the Sparkle key goes from the keychain
# to GitHub through a temporary file that is deleted at once.
#
# usage: tools/macos-ci-secrets.sh <certificate.p12> [owner/repo]
set -euo pipefail

P12="${1:?usage: $0 <certificate.p12> [owner/repo]}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${2:-$(git -C "$ROOT" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"
SPARKLE="$(ls -d "$ROOT"/target/macos/sparkle-*/bin 2>/dev/null | tail -1)"
[ -x "$SPARKLE/generate_keys" ] || { echo "run tools/macos-app.sh once first (it fetches Sparkle)"; exit 1; }

# The password is checked the way the runner will use it: an import into a throwaway keychain by
# Apple's own `security` (Homebrew's or Apple's openssl may not read a Keychain Access export).
read -rsp "Password of $(basename "$P12"): " cert_pass; echo
tmp="$(mktemp -d)"
trap 'security delete-keychain "$tmp/check.keychain-db" 2>/dev/null; rm -rf "$tmp"' EXIT
security create-keychain -p check "$tmp/check.keychain-db"
security import "$P12" -k "$tmp/check.keychain-db" -P "$cert_pass" >/dev/null 2>&1 \
    || { echo "that password doesn't open $P12"; exit 1; }
security find-identity "$tmp/check.keychain-db" | grep -q "Developer ID Application" \
    || { echo "$P12 opens, but holds no Developer ID Application identity (export the certificate with its private key)"; exit 1; }
security delete-keychain "$tmp/check.keychain-db"
read -rp "Apple ID used for notarization: " apple_id
read -rp "Team ID: " team_id
read -rsp "App-specific password for $apple_id (appleid.apple.com → Sign-In and Security): " notary_pass; echo

echo "setting secrets on ${REPO}…"
base64 -i "$P12" | gh secret set MACOS_CERT_P12 -R "$REPO"
printf '%s' "$cert_pass" | gh secret set MACOS_CERT_PASSWORD -R "$REPO"
printf '%s' "$apple_id" | gh secret set NOTARY_APPLE_ID -R "$REPO"
printf '%s' "$team_id" | gh secret set NOTARY_TEAM_ID -R "$REPO"
printf '%s' "$notary_pass" | gh secret set NOTARY_PASSWORD -R "$REPO"
key="$tmp/sparkle-key"
"$SPARKLE/generate_keys" --account azeroth-survivors -x "$key" >/dev/null
gh secret set SPARKLE_PRIVATE_KEY -R "$REPO" < "$key"
gh secret list -R "$REPO"
