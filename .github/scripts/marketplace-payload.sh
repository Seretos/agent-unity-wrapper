#!/usr/bin/env bash
# marketplace-payload.sh
#
# Reads NAME, DESC, REPO, CATEGORY, VERSION, TAG, CHANGELOG from the
# environment and prints the agent-marketplace repository_dispatch JSON
# payload on stdout via a single `jq -n` call (never a heredoc, so hostile
# characters in DESC/CHANGELOG - quotes, backslashes, `$(...)`, embedded
# newlines - round-trip exactly instead of being shell-interpolated).
#
# `icon` and `description_url` are computed inside the jq expression from
# $REPO/$TAG at expansion time, not hardcoded literals. The `changelog` key
# is omitted entirely when CHANGELOG is empty.
set -euo pipefail

NAME="${NAME:?NAME env var required}"
DESC="${DESC:?DESC env var required}"
REPO="${REPO:?REPO env var required}"
CATEGORY="${CATEGORY:?CATEGORY env var required}"
VERSION="${VERSION:?VERSION env var required}"
TAG="${TAG:?TAG env var required}"
CHANGELOG="${CHANGELOG:-}"

jq -n \
  --arg name "$NAME" \
  --arg description "$DESC" \
  --arg repo "$REPO" \
  --arg category "$CATEGORY" \
  --arg version "$VERSION" \
  --arg tag "$TAG" \
  --arg changelog "$CHANGELOG" \
  '{
    event_type: "plugin-release",
    client_payload: (
      {
        name: $name,
        description: $description,
        repo: $repo,
        category: $category,
        version: $version,
        ref: $tag,
        icon: ("https://raw.githubusercontent.com/" + $repo + "/" + $tag + "/assets/icon.png"),
        description_url: ("https://raw.githubusercontent.com/" + $repo + "/" + $tag + "/description.md")
      }
      + (if $changelog == "" then {} else { changelog: $changelog } end)
    )
  }'
