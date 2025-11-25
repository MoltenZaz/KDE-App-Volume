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

dir=${1:?Usage: $0 up|down [step%]}
step_arg=${2:-5}
step_num=${step_arg%\%}

# Wayland/X11 PID detection
pid=""
if [[ "${XDG_SESSION_TYPE-}" == "wayland" ]] && command -v qdbus &>/dev/null; then
  pid=$(qdbus org.kde.KWin /KWin activeWindowProcessId 2>/dev/null || echo "")
fi
if ! [[ $pid =~ ^[0-9]+$ ]]; then
  win=$(xdotool getwindowfocus 2>/dev/null || echo "")
  [[ -n $win ]] && pid=$(xdotool getwindowpid "$win" 2>/dev/null || echo "")
fi
if ! [[ $pid =~ ^[0-9]+$ ]]; then
  echo "WARNING: cannot detect PID, falling back to role/title matching" >&2
  pid=""
fi

# Collect sink-input IDs
ids=()
current=""
while IFS= read -r line; do
  if [[ $line =~ ^Sink[[:space:]]Input[[:space:]]\#([0-9]+) ]]; then
    current=${BASH_REMATCH[1]}
  elif [[ $line =~ application.process.id[[:space:]]*=[[:space:]]\"$pid\" ]]; then
    ids+=("$current")
  elif [[ $line =~ application.process.binary[[:space:]]*=[[:space:]]\"wine64-preloader\" ]]; then
    ids+=("$current")
  elif [[ $line =~ application.icon_name[[:space:]]*=[[:space:]]\"applications-games\" ]]; then
    ids+=("$current")
  fi
done < <(pactl list sink-inputs)

# Clamp helper
clamp() {
  local v=$1
  (( v<0 )) && v=0
  (( v>100 )) && v=100
  echo "$v"
}

# Apply
if [[ $dir == up ]]; then
  adj=$step_num
else
  adj=$((-step_num))
fi

for idx in "${ids[@]}"; do
  vol=$(pactl list sink-inputs \
    | awk '/^Sink Input #'"$idx"'/{f=1} f&&/Volume:/{print $5;exit}' \
    | tr -d '%')
  new=$(clamp $((vol + adj)))
  pactl set-sink-input-volume "$idx" "${new}%"
done
