#!/bin/bash
# set-charge-limit.sh - Set battery charge control threshold
set -euo pipefail

limit="${1:-status}"

# Locate battery sysfs node
battery_node=""
for cand in /sys/class/power_supply/macsmc-battery /sys/class/power_supply/BAT0 /sys/class/power_supply/BAT1; do
  if [[ -f "$cand/charge_control_end_threshold" ]]; then
    battery_node="$cand"
    break
  fi
done

if [[ -z "$battery_node" ]]; then
  # Fallback to system command if installed
  if command -v omarchy-battery-charge-limit >/dev/null 2>&1; then
    exec omarchy-battery-charge-limit "$@"
  fi
  echo "Error: No compatible charge control threshold found in sysfs." >&2
  exit 1
fi

end_file="$battery_node/charge_control_end_threshold"
start_file="$battery_node/charge_control_start_threshold"

if [[ "$limit" == "status" ]]; then
  if [[ -f "$start_file" ]]; then
    printf 'Charge limit: %s%% (restart charging at %s%%)\n' "$(<"$end_file")" "$(<"$start_file")"
  else
    printf 'Charge limit: %s%%\n' "$(<"$end_file")"
  fi
  exit 0
fi

case "$limit" in
  80|100) ;;
  [0-9]|[1-9][0-9]|100) ;;
  *)
    echo "Usage: set-charge-limit.sh [80|100|<percent>]" >&2
    exit 2
    ;;
esac

if command -v omarchy-battery-charge-limit >/dev/null 2>&1 && [[ "$battery_node" == *macsmc-battery* ]]; then
  exec omarchy-battery-charge-limit "$limit"
fi

if (( EUID == 0 )); then
  printf '%s\n' "$limit" | /usr/bin/tee "$end_file" >/dev/null
else
  printf '%s\n' "$limit" | sudo -n /usr/bin/tee "$end_file" >/dev/null 2>&1 || \
  pkexec sh -c "echo '$limit' > '$end_file'"
fi

actual_end=$(<"$end_file")
printf 'Charge limit set to %s%%.\n' "$actual_end"
