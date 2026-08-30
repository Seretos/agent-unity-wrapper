#!/usr/bin/env bash
# prev-release-tag.sh <plugin-name> <version-being-created>
#
# Reads the full tag list on stdin (one tag per line, e.g. `git tag --list`)
# and prints the previous release tag for <plugin-name> - the highest tag
# matching `<plugin-name>--vMAJOR.MINOR.PATCH[-PRERELEASE]` (strict SemVer
# 2.0.0 grammar, no build metadata) that is strictly lower than
# <version-being-created>. Prints nothing (and exits 0) when no such tag
# exists - that means this is the first release.
#
# Never runs git itself, so it is driveable from a fixture list in tests.
set -euo pipefail

PLUGIN_NAME="${1:?usage: prev-release-tag.sh <plugin-name> <version-being-created>}"
VERSION="${2:?usage: prev-release-tag.sh <plugin-name> <version-being-created>}"

NUMID='(0|[1-9][0-9]*)'
PREID='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
SEMVER_RE="^${NUMID}\\.${NUMID}\\.${NUMID}(-${PREID}(\\.${PREID})*)?\$"

MAJOR=""
MINOR=""
PATCH=""
PRERELEASE=""

# parse_semver <version-string>
# Sets MAJOR/MINOR/PATCH/PRERELEASE on success. Rejects build metadata (+)
# and anything not matching strict SemVer 2.0.0 core+prerelease grammar.
parse_semver() {
  local v="$1"
  case "$v" in
    *+*) return 1 ;;
  esac
  if [[ "$v" =~ $SEMVER_RE ]]; then
    MAJOR="${BASH_REMATCH[1]}"
    MINOR="${BASH_REMATCH[2]}"
    PATCH="${BASH_REMATCH[3]}"
    PRERELEASE="${BASH_REMATCH[4]#-}"
    return 0
  fi
  return 1
}

# num_id_gt <a> <b>
# Compares two numeric SemVer identifiers (digits only, no leading zeros -
# guaranteed by the NUMID grammar in SEMVER_RE) by digit-length first, then
# lexicographically. This avoids `10#...` arithmetic expansion, whose range
# is bounded (64-bit signed on modern bash) - SemVer 2.0.0 places no upper
# bound on numeric identifier magnitude, so an extremely large but
# spec-legal identifier could overflow or error under arithmetic expansion.
# Because leading zeros are already rejected by the grammar, length alone
# settles magnitude, and equal-length digit strings sort identically
# whether compared as strings or as numbers - so this is exact, not an
# approximation, for arbitrarily long identifiers.
num_id_gt() {
  local a="$1" b="$2"
  if (( ${#a} != ${#b} )); then
    (( ${#a} > ${#b} )) && return 0 || return 1
  fi
  [[ "$a" > "$b" ]] && return 0 || return 1
}

# compare_prerelease <a-prerelease> <b-prerelease>
# Returns 0 (true) if a > b per SemVer prerelease precedence, else 1.
# Both are non-empty dot-separated identifier strings.
compare_prerelease() {
  local a="$1" b="$2"
  local -a A B
  IFS='.' read -ra A <<< "$a"
  IFS='.' read -ra B <<< "$b"
  local max=${#A[@]}
  (( ${#B[@]} > max )) && max=${#B[@]}
  local i
  for (( i = 0; i < max; i++ )); do
    local ai="${A[$i]-}"
    local bi="${B[$i]-}"
    if [[ -z "$ai" && -z "$bi" ]]; then
      continue
    fi
    if [[ -z "$ai" ]]; then
      return 1 # a ran out of identifiers first -> a < b
    fi
    if [[ -z "$bi" ]]; then
      return 0 # b ran out first -> a > b
    fi
    local ai_num=0 bi_num=0
    [[ "$ai" =~ ^[0-9]+$ ]] && ai_num=1
    [[ "$bi" =~ ^[0-9]+$ ]] && bi_num=1
    if (( ai_num && bi_num )); then
      if [[ "$ai" != "$bi" ]]; then
        num_id_gt "$ai" "$bi" && return 0 || return 1
      fi
      continue
    elif (( ai_num && !bi_num )); then
      return 1 # numeric identifiers always have lower precedence
    elif (( !ai_num && bi_num )); then
      return 0
    else
      if [[ "$ai" != "$bi" ]]; then
        [[ "$ai" > "$bi" ]] && return 0 || return 1
      fi
      continue
    fi
  done
  return 1 # equal
}

# version_gt <a> <b>
# Returns 0 (true) if semver <a> has higher precedence than semver <b>.
# Both must already be valid per parse_semver.
version_gt() {
  local a="$1" b="$2"
  parse_semver "$a" || return 1
  local a_major=$MAJOR a_minor=$MINOR a_patch=$PATCH a_pre=$PRERELEASE
  parse_semver "$b" || return 1
  local b_major=$MAJOR b_minor=$MINOR b_patch=$PATCH b_pre=$PRERELEASE

  if [[ "$a_major" != "$b_major" ]]; then
    num_id_gt "$a_major" "$b_major" && return 0 || return 1
  fi
  if [[ "$a_minor" != "$b_minor" ]]; then
    num_id_gt "$a_minor" "$b_minor" && return 0 || return 1
  fi
  if [[ "$a_patch" != "$b_patch" ]]; then
    num_id_gt "$a_patch" "$b_patch" && return 0 || return 1
  fi

  if [[ -z "$a_pre" && -z "$b_pre" ]]; then
    return 1 # equal
  elif [[ -z "$a_pre" && -n "$b_pre" ]]; then
    return 0 # release > prerelease
  elif [[ -n "$a_pre" && -z "$b_pre" ]]; then
    return 1
  else
    compare_prerelease "$a_pre" "$b_pre"
  fi
}

if ! parse_semver "$VERSION"; then
  echo "::error::version '$VERSION' being created is not valid semver" >&2
  exit 1
fi

PREFIX="${PLUGIN_NAME}--v"
best_tag=""
best_version=""

while IFS= read -r tag || [[ -n "$tag" ]]; do
  # Tolerate CRLF line endings - stdin may be produced by a text-mode pipe
  # (e.g. Python's subprocess on Windows translates "\n" to "\r\n" on write).
  tag="${tag%$'\r'}"
  [[ -z "$tag" ]] && continue
  case "$tag" in
    "$PREFIX"*) ;;
    *) continue ;;
  esac
  candidate_version="${tag#"$PREFIX"}"

  parse_semver "$candidate_version" || continue

  [[ "$candidate_version" == "$VERSION" ]] && continue

  version_gt "$VERSION" "$candidate_version" || continue

  if [[ -z "$best_tag" ]] || version_gt "$candidate_version" "$best_version"; then
    best_tag="$tag"
    best_version="$candidate_version"
  fi
done

echo "$best_tag"
