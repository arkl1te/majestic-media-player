# Progress display shared by the build scripts (sourced, not run).
# On a terminal it keeps two live lines at the bottom: the current task's bar
# and the overall bar. Other output goes above them via pb_log. When stdout
# isn't a terminal (CI, logs), only pb_log lines and a final summary are printed.

PB_TTY=0
[[ -t 1 && ${TERM:-dumb} != dumb ]] && PB_TTY=1
PB_DRAWN=0
PB_COLS=$(tput cols 2>/dev/null || echo 80)
trap 'PB_COLS=$(tput cols 2>/dev/null || echo 80)' WINCH
PB_LAST=""
PB_TASK="" PB_TASK_PCT=0
PB_TOTAL="" PB_TOTAL_PCT=0

# pb_line LABEL PCT -> one formatted bar line, sized to the terminal width.
pb_line() {
  local label=$1 pct=$2 width fill bar pad
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  (( width = PB_COLS - 32 ))
  (( width > 50 )) && width=50
  (( width < 10 )) && width=10
  (( fill = pct * width / 100 ))
  printf -v bar '%*s' "$fill" ''
  bar=${bar// /█}
  printf -v pad '%*s' "$(( width - fill ))" ''
  pad=${pad// /░}
  printf '%-24.24s %s%s %3d%%' "$label" "$bar" "$pad" "$pct"
}

pb_draw() {
  (( PB_TTY )) || return 0
  local key="$PB_TASK|$PB_TASK_PCT|$PB_TOTAL|$PB_TOTAL_PCT"
  [[ $key == "$PB_LAST" ]] && return 0
  PB_LAST=$key
  (( PB_DRAWN )) && printf '\r\e[1A'
  printf '\e[K%s\n\e[K%s' "$(pb_line "$PB_TASK" "$PB_TASK_PCT")" "$(pb_line "$PB_TOTAL" "$PB_TOTAL_PCT")"
  PB_DRAWN=1
}

# pb_task LABEL PCT / pb_total LABEL PCT update a bar and redraw.
pb_task()  { PB_TASK=$1;  PB_TASK_PCT=$2;  pb_draw; }
pb_total() { PB_TOTAL=$1; PB_TOTAL_PCT=$2; pb_draw; }

# pb_log MSG... prints a line above the bars.
pb_log() {
  if (( PB_TTY && PB_DRAWN )); then
    printf '\r\e[1A\e[K%s\n' "$*"
    PB_DRAWN=0 PB_LAST=""
    pb_draw
  else
    printf '%s\n' "$*"
  fi
}

# pb_finish MSG: leave the bars on screen and print a final line.
pb_finish() {
  if (( PB_TTY )); then
    (( PB_DRAWN )) && printf '\n'
    PB_DRAWN=0 PB_LAST=""
  fi
  printf '%s\n' "$*"
}

if (( PB_TTY )); then
  printf '\e[?25l'
  trap 'printf "\e[?25h"; (( PB_DRAWN )) && printf "\n"' EXIT
  trap 'exit 130' INT TERM
fi
