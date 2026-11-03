#!/bin/zsh
# scripts/associated-domains.sh
# Adds `webcredentials:<domain>` to Config/Ladle.entitlements for each domain in
# APRON_ASSOCIATED_DOMAINS (space- or comma-separated) in the gitignored Config/Domains.xcconfig,
# the servers this build may use native passkeys on. xcodegen writes the entitlements file from
# project.yml on every `generate`, so run this right after it. Running it twice changes nothing.
# The same list reaches the app as the Info.plist key LadlePasskeyDomains.
# LADLE_PUSH (`development` or `production`) also sets aps-environment, push while closed
# (docs/PUSH.md); empty or absent, the build has no push entitlement.
set -euo pipefail
cd "$(dirname "$0")/.."
file=Config/Ladle.entitlements
key=:com.apple.developer.associated-domains
[[ -f Config/Domains.xcconfig ]] || exit 0
domains=$(sed -n 's/^[[:space:]]*APRON_ASSOCIATED_DOMAINS[[:space:]]*=//p' Config/Domains.xcconfig | tail -1)
present=("${(@f)$(/usr/libexec/PlistBuddy -c "Print $key" $file 2>/dev/null | sed 's/^[[:space:]]*//')}")
for domain in ${=domains//,/ }; do
  # The app reads the same list, so a bad entry stops the build rather than reaching it.
  [[ $domain == [A-Za-z0-9*]*.* ]] || { echo "APRON_ASSOCIATED_DOMAINS: $domain is not a domain" >&2; exit 1; }
  (( ${present[(Ie)webcredentials:$domain]} )) && continue
  /usr/libexec/PlistBuddy -c "Add $key: string webcredentials:$domain" $file
  present+=(webcredentials:$domain)
done

push=$(sed -n 's/^[[:space:]]*LADLE_PUSH[[:space:]]*=[[:space:]]*//p' Config/Domains.xcconfig | tail -1 | tr -d '[:space:]')
case $push in
  "") ;;
  development|production)
    /usr/libexec/PlistBuddy -c "Delete :aps-environment" $file 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :aps-environment string $push" $file ;;
  *) echo "LADLE_PUSH: $push is not development or production" >&2; exit 1 ;;
esac
