#!/usr/bin/env bash
# Fetches pinned Nim dependencies into ./vendor so builds are reproducible.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p vendor

while read -r name url rev; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  dir="vendor/$name"
  if [[ ! -d "$dir/.git" ]]; then
    git clone --quiet "$url" "$dir"
  fi
  if [[ "$(git -C "$dir" rev-parse HEAD)" != "$rev" ]]; then
    git -C "$dir" fetch --quiet origin
    git -C "$dir" checkout --quiet "$rev"
  fi
  echo "ok  $name @ ${rev:0:10}"
done < deps.lock
