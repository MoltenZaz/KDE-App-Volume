#!/usr/bin/env bash
set -euo pipefail

#── Single-instance lock ──────────────────────────────────────────────────────
lockfile=/tmp/volctrl.lock

# Open the lockfile on FD 9
exec 9>"$lockfile"

# Try to acquire a non‐blocking lock; exit if already held
flock -n 9 || exit 0

# When the script exits, FD 9 (and the lock) is automatically released
#─────────────────────────────────────────────────────────────────────────────

# volctrl.sh — per-app volume, 0–100% clamp, KDE Wayland/X11 + game‐role catch

# Optional debug trace
if [[ ${1:-} == --debug ]]; then
  set -x
  shift
fi

# 1) parse args
dir=${1:?Usage: $0 [--debug] up|down [step%]}
step_arg=${2:-5}

# normalize step
if [[ $step_arg =~ %$ ]]; then
  step="$step_arg"; step_num=${step_arg%\%}
else
  step="${step_arg}%"; step_num="$step_arg"
fi

# 2) get focused window ID & PID
winid=""; pid=""

if [[ "${XDG_SESSION_TYPE-}" == "wayland" ]] && command -v qdbus &>/dev/null; then
  winid=$(qdbus org.kde.KWin /KWin activeWindow 2>/dev/null || echo)
  winid=$((winid||0))
  [[ $winid ]] && pid=$(xprop -id "$winid" _NET_WM_PID 2>/dev/null \
                         | awk -F= '{gsub(/ /,"",$2); print $2}')
fi

if ! [[ $pid =~ ^[0-9]+$ ]]; then
  winid=$(xdotool getwindowfocus 2>/dev/null || echo)
  [[ $winid ]] && pid=$(xdotool getwindowpid "$winid" 2>/dev/null || echo)
fi

if ! [[ $pid =~ ^[0-9]+$ ]]; then
  echo "ERROR: cannot detect focused-window PID" >&2
  exit 1
fi

# 3) window title for native-Wayland fallback
win_title=""
if [[ $winid ]]; then
  win_title=$(xprop -id "$winid" _NET_WM_NAME 2>/dev/null \
    | awk -F\" '/_NET_WM_NAME/{print $2}')
fi

# 4) scan sink-inputs and match by:
#    • process.id
#    • process.binary
#    • media.role = "game"
#    • window title in application.name or media.name
ids=(); current=""
bin=$(basename "$(readlink /proc/$pid/exe 2>/dev/null)" 2>/dev/null)

while IFS= read -r line; do
  if [[ $line =~ ^Sink[[:space:]]Input[[:space:]]\#([0-9]+) ]]; then
    current=${BASH_REMATCH[1]}
  else
    # 4a) by PID
    if [[ $line =~ application.process.id[[:space:]]*=[[:space:]]\"$pid\" ]]; then
      ids+=("$current"); continue
    fi
    # 4b) by binary (Proton/Wine games)
    if [[ -n $bin ]] && \
       [[ $line =~ application.process.binary[[:space:]]*=[[:space:]]\"$bin\" ]]; then
      ids+=("$current"); continue
    fi
    # 4c) by media.role = "game"
    if [[ $line =~ media.role[[:space:]]*=[[:space:]]\"game\" ]]; then
      ids+=("$current"); continue
    fi
    # 4d) by window title (native Wayland)
    if [[ -n $win_title ]]; then
      if [[ $line =~ application.name[[:space:]]*=[[:space:]]\".*$win_title.*\" ]] \
      || [[ $line =~ media.name[[:space:]]*=[[:space:]]\".*$win_title.*\" ]]; then
        ids+=("$current"); continue
      fi
    fi
  fi
done < <(pactl list sink-inputs)

# 5) dedupe & sort
if (( ${#ids[@]} > 1 )); then
  mapfile -t ids < <(printf "%s\n" "${ids[@]}" | sort -un)
fi

# 6) single-stream fallback
if (( ${#ids[@]} == 0 )); then
  mapfile -t all_ids < <(
    pactl list sink-inputs short |
    awk '$2 !~ /monitor$/ { print $1 }'
  )
  if (( ${#all_ids[@]} == 1 )); then
    ids=("${all_ids[0]}")
  fi
fi

# 7) compute signed adjustment
if [[ $dir == up ]]; then
  adj=$step_num
else
  adj=$(( -step_num ))
fi

# 8) clamp helper
clamp() {
  local v=$1
  (( v<0   )) && v=0
  (( v>100 )) && v=100
  echo "$v"
}

# 9) apply or skip
if (( ${#ids[@]} > 0 )); then
  for idx in "${ids[@]}"; do
    vol=$(pactl list sink-inputs \
      | awk '/^Sink Input #'"$idx"'/{f=1} f&&/Volume:/{print $5;exit}' \
      | tr -d '%')
    new=$(clamp $((vol + adj)))
    pactl set-sink-input-volume "$idx" "${new}%"
  done
else
  echo "No matching streams; leaving master unchanged." >&2
  exit 0
fi
