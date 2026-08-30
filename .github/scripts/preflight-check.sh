#!/usr/bin/env bash
# preflight-check.sh <TAG> [<PREV_TAG>]
#
# Reads the full tag list on stdin (one tag per line, e.g. `git tag --list`)
# and decides, with no git/gh/network access of its own, whether it is safe
# to proceed with creating release <TAG>:
#
#   1. If marker tag src/<TAG> already exists, this release has already been
#      published - fail loudly (checked first, so the failure reported when
#      both conditions would fire is always this one).
#   2. Else if <PREV_TAG> is given and marker tag src/<PREV_TAG> is missing,
#      the previous release has no `main`-history marker to diff notes
#      against - fail with the one-time manual bootstrap commands.
#   3. Otherwise succeed silently (exit 0, no output) - this also covers the
#      first-release case where <PREV_TAG> is omitted entirely.
#
# Never deletes or moves a marker tag itself.
set -euo pipefail

TAG="${1:?usage: preflight-check.sh <TAG> [<PREV_TAG>]}"
PREV_TAG="${2:-}"

mapfile -t TAGS
# Tolerate CRLF line endings - stdin may be produced by a text-mode pipe
# (e.g. Python's subprocess on Windows translates "\n" to "\r\n" on write).
for _i in "${!TAGS[@]}"; do
  TAGS[$_i]="${TAGS[$_i]%$'\r'}"
done
unset _i

contains() {
  local needle="$1" t
  for t in "${TAGS[@]-}"; do
    [[ "$t" == "$needle" ]] && return 0
  done
  return 1
}

if contains "src/${TAG}"; then
  echo "::error::Marker tag src/${TAG} already exists - release ${TAG} has already been published. Delete the marker first or pick a new version." >&2
  exit 1
fi

if [[ -n "$PREV_TAG" ]] && ! contains "src/${PREV_TAG}"; then
  {
    echo "::error::Marker tag src/${PREV_TAG} is missing for the previous release ${PREV_TAG}. Bootstrap it manually from that release's Actions run head SHA, then re-run this workflow:"
    echo "  git tag src/${PREV_TAG} <head_sha>"
    echo "  git push origin src/${PREV_TAG}"
  } >&2
  exit 1
fi

exit 0
