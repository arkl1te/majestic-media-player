#!/usr/bin/env bash
# Fetches pinned Nim dependencies into ./vendor so builds are reproducible.
# Run directly, or sourced by tools/build.sh, which maps this stage onto part
# of its overall progress bar (STAGE_LO..STAGE_HI percent).

# stage_pct PCT -> overall percent for PCT through the current stage.
stage_pct() { echo $(( ${STAGE_LO:-0} + $1 * (${STAGE_HI:-100} - ${STAGE_LO:-0}) / 100 )); }

# git_progress DONE N NAME CMD... runs a git command with --progress and turns its
# "Receiving objects: 42%" / "Resolving deltas: 80%" output into the bars.
git_progress() {
  local done=$1 n=$2 name=$3 line pct task status
  shift 3
  while IFS= read -r line; do
    task=""
    if [[ $line =~ (Receiving\ objects|remote:\ Counting\ objects):\ +([0-9]+)% ]]; then
      pct=${BASH_REMATCH[2]}; [[ ${BASH_REMATCH[1]} == remote* ]] && task=$(( pct / 10 )) || task=$(( 10 + pct * 75 / 100 ))
    elif [[ $line =~ (Resolving\ deltas|Updating\ files):\ +([0-9]+)% ]]; then
      task=$(( 85 + ${BASH_REMATCH[2]} * 15 / 100 ))
    elif [[ $line == fatal:* || $line == error:* ]]; then
      pb_log "$name: $line"
    fi
    if [[ -n $task ]]; then
      pb_task "$name" "$task"
      pb_total "Overall (deps $((done + 1))/$n)" "$(stage_pct $(( (done * 100 + task) / n )))"
    fi
  done < <(set +e +o pipefail; "$@" 2>&1 | tr '\r' '\n'; echo "${PIPESTATUS[0]}" > "$PB_STATUS")
  read -r status < "$PB_STATUS"
  return "$status"
}

fetch_deps() {
  local entries=() name url rev dir i n
  mkdir -p vendor
  PB_STATUS=$(mktemp)
  while read -r name url rev; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    entries+=("$name $url $rev")
  done < deps.lock
  n=${#entries[@]}

  for (( i = 0; i < n; i++ )); do
    read -r name url rev <<< "${entries[i]}"
    dir="vendor/$name"
    pb_task "$name" 0
    pb_total "Overall (deps $((i + 1))/$n)" "$(stage_pct $(( i * 100 / n )))"
    if [[ ! -d "$dir/.git" ]]; then
      git_progress "$i" "$n" "$name" git clone --progress "$url" "$dir"
    fi
    if [[ "$(git -C "$dir" rev-parse HEAD)" != "$rev" ]]; then
      git_progress "$i" "$n" "$name" git -C "$dir" fetch --progress origin
      git -C "$dir" checkout --quiet "$rev"
    fi
    pb_task "$name" 100
    (( PB_TTY )) || pb_log "ok  $name @ ${rev:0:10}"
  done
  pb_total "Overall (deps $n/$n)" "$(stage_pct 100)"
  rm -f "$PB_STATUS"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -euo pipefail
  cd "$(dirname "$0")/.."
  source tools/progress.sh
  fetch_deps
  pb_finish "Dependencies ready."
fi
