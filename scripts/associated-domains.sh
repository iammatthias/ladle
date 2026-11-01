#!/bin/zsh
# scripts/associated-domains.sh
# Adds `webcredentials:<domain>` to Config/Ladle.entitlements for each domain in
# APRON_ASSOCIATED_DOMAINS (space- or comma-separated) in the gitignored Config/Domains.xcconfig,
# the servers this build may use native passkeys on. xcodegen writes the entitlements file from
# project.yml on every `generate`, so run this right after it. Running it twice changes nothing.
# The same list reaches the app as the Info.plist key LadlePasskeyDomains.
set -euo pipefail
cd "$(dirname "$0")/.."
file=Config/Ladle.entitlements
key=:com.apple.developer.associated-domains
[[ -f Config/Domains.xcconfig ]] || exit 0
domains=$(sed -n 's/^[[:space:]]*APRON_ASSOCIATED_DOMAINS[[:space:]]*=//p' Config/Domains.xcconfig | tail -1)
present=$(/usr/libexec/PlistBuddy -c "Print $key" $file 2>/dev/null || true)
for domain in ${=domains//,/ }; do
  [[ $domain == [A-Za-z0-9*]*.* ]] || { echo "skipping $domain: not a domain" >&2; continue; }
  [[ $present == *"webcredentials:$domain"* ]] && continue
  /usr/libexec/PlistBuddy -c "Add $key: string webcredentials:$domain" $file
done
