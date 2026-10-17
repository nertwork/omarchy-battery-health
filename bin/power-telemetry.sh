#!/usr/bin/env bash
set -uo pipefail

declare -A kv

if command -v omarchy-battery-status >/dev/null 2>&1; then
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] && kv["$k"]="$v"
  done < <(omarchy-battery-status --shell 2>/dev/null || true)
fi

# Locate battery sysfs
bat_dir=""
for d in /sys/class/power_supply/macsmc-battery /sys/class/power_supply/BAT*; do
  if [[ -d "$d" ]]; then
    bat_dir="$d"
    break
  fi
done

# Locate AC sysfs
ac_dir=""
for d in /sys/class/power_supply/macsmc-ac /sys/class/power_supply/AC* /sys/class/power_supply/ADP* /sys/class/power_supply/ucsi-source-psy-*; do
  if [[ -d "$d" ]]; then
    ac_dir="$d"
    break
  fi
done

# Locate macsmc_hwmon
smc_dir=""
for d in /sys/class/hwmon/hwmon*; do
  if [[ -f "$d/name" ]] && [[ "$(<"$d/name")" == "macsmc_hwmon" ]]; then
    smc_dir="$d"
    break
  fi
done

awk -v bat_dir="$bat_dir" -v ac_dir="$ac_dir" -v smc_dir="$smc_dir" \
    -v orig_pct="${kv[percentage]:-}" \
    -v orig_state="${kv[state]:-}" \
    -v orig_rate="${kv[rate]:-}" \
    -v orig_size="${kv[size]:-}" \
    -v orig_design="${kv[design_size]:-}" \
    -v orig_time="${kv[time]:-}" \
    -v orig_thresh="${kv[threshold]:-}" '
function read_file(path,    val) {
  val = ""
  if (path != "" && (getline val < path) > 0) {
    close(path)
    return val
  }
  close(path)
  return ""
}
BEGIN {
  # SMC telemetry
  sys_uw = read_file(smc_dir "/power1_input")
  ac_uw  = read_file(smc_dir "/power2_input")
  rail_uw = read_file(smc_dir "/power3_input")
  heat_uw = read_file(smc_dir "/power4_input")
  in_mv   = read_file(smc_dir "/in0_input")
  in_ma   = read_file(smc_dir "/curr1_input")
  fan1    = read_file(smc_dir "/fan1_input")
  fan2    = read_file(smc_dir "/fan2_input")

  # AC telemetry
  ac_online = read_file(ac_dir "/online")
  ac_limit_uw = read_file(ac_dir "/input_power_limit")

  # Battery telemetry
  bat_status = tolower(read_file(bat_dir "/status"))
  bat_cap    = read_file(bat_dir "/capacity")
  bat_power_now = read_file(bat_dir "/power_now")
  bat_energy_now = read_file(bat_dir "/energy_now")
  bat_energy_full = read_file(bat_dir "/energy_full")
  bat_energy_design = read_file(bat_dir "/energy_full_design")
  bat_cycles = read_file(bat_dir "/cycle_count")
  bat_temp   = read_file(bat_dir "/temp")
  bat_volt   = read_file(bat_dir "/voltage_now")
  bat_end_thresh = read_file(bat_dir "/charge_control_end_threshold")
  bat_start_thresh = read_file(bat_dir "/charge_control_start_threshold")

  pct = (orig_pct != "") ? orig_pct : (bat_cap != "" ? bat_cap "%" : "")
  state = (orig_state != "") ? orig_state : bat_status
  rate = orig_rate

  # Compute battery power in Watts
  bat_w = 0
  if (bat_power_now != "" && bat_power_now + 0 != 0) {
    bat_w = (bat_power_now + 0) / 1000000.0
    if (bat_w < 0) bat_w = -bat_w
  } else if (rate != "") {
    r_num = rate
    sub(/[^0-9.]/, "", r_num)
    bat_w = r_num + 0
  }
  if (rate == "" && bat_w > 0) {
    rate = sprintf("%.1fW", bat_w)
  }

  # System power (watts used by laptop)
  sys_w = 0
  if (sys_uw != "" && sys_uw + 0 > 0) {
    sys_w = (sys_uw + 0) / 1000000.0
    system_power = sprintf("%.1fW", sys_w)
    system_power_short = sprintf("%.0fW", sys_w)
  } else if (bat_w > 0) {
    sys_w = bat_w
    system_power = sprintf("%.1fW", sys_w)
    system_power_short = sprintf("%.0fW", sys_w)
  } else {
    system_power = rate != "" ? rate : "0.0W"
    system_power_short = "0W"
  }

  # AC input power
  ac_power = ""
  if (ac_online == "1") {
    if (ac_uw != "" && ac_uw + 0 > 0) {
      ac_w = (ac_uw + 0) / 1000000.0
      if (ac_limit_uw != "" && ac_limit_uw + 0 > 0) {
        ac_lim_w = (ac_limit_uw + 0) / 1000000.0
        ac_power = sprintf("%.1fW / %.0fW", ac_w, ac_lim_w)
      } else {
        ac_power = sprintf("%.1fW", ac_w)
      }
    } else if (ac_limit_uw != "" && ac_limit_uw + 0 > 0) {
      ac_power = sprintf("Online (%.0fW max)", (ac_limit_uw + 0) / 1000000.0)
    } else {
      ac_power = "Connected"
    }
  } else {
    ac_power = "Offline"
  }

  # Charger V / I
  ac_vi = ""
  if (ac_online == "1" && in_mv != "" && in_mv + 0 > 0) {
    v = (in_mv + 0) / 1000.0
    if (in_ma != "" && in_ma + 0 > 0) {
      a = (in_ma + 0) / 1000.0
      ac_vi = sprintf("%.1fV · %.2fA", v, a)
    } else {
      ac_vi = sprintf("%.1fV", v)
    }
  }

  # Battery flow
  battery_flow = ""
  if (state == "holding" || state == "not-charging" || state == "not charging") {
    if (bat_w < 0.2) {
      battery_flow = "Holding (0W)"
    } else {
      battery_flow = sprintf("Holding (%.1fW)", bat_w)
    }
  } else if (state == "fully-charged" || state == "full") {
    battery_flow = "Full (0W)"
  } else if (state == "charging") {
    battery_flow = sprintf("+%.1fW (Charging)", bat_w)
  } else if (state == "discharging") {
    battery_flow = sprintf("-%.1fW (Discharging)", bat_w)
  } else {
    battery_flow = (rate != "" ? rate : "0W")
  }

  # Rails (3.8V Rail & Heatpipe)
  rails = ""
  if (rail_uw != "" && heat_uw != "") {
    rw = (rail_uw + 0) / 1000000.0
    hw = (heat_uw + 0) / 1000000.0
    rails = sprintf("%.1fW · %.1fW", rw, hw)
  }

  # Fans
  fans = ""
  if (fan1 != "" && fan2 != "") {
    f1 = fan1 + 0
    f2 = fan2 + 0
    if (f1 == 0 && f2 == 0) {
      fans = "0 RPM (Idle)"
    } else {
      fans = sprintf("%d / %d RPM", f1, f2)
    }
  } else if (fan1 != "") {
    fans = sprintf("%d RPM", fan1 + 0)
  }

  # Health & capacity
  size = orig_size
  design_size = orig_design
  health = ""
  if (bat_energy_full != "" && bat_energy_design != "" && bat_energy_design + 0 > 0) {
    ef_wh = (bat_energy_full + 0) / 1000000.0
    ed_wh = (bat_energy_design + 0) / 1000000.0
    hpct = (ef_wh / ed_wh) * 100.0
    health = sprintf("%.0f%% (%.0f / %.0fWh)", hpct, ef_wh, ed_wh)
    if (size == "") size = sprintf("%.0fWh", ef_wh)
    if (design_size == "") design_size = sprintf("%.0fWh", ed_wh)
  } else if (size != "" && design_size != "") {
    health = size " / " design_size
  } else {
    health = size
  }

  # Temp & Voltage
  temp_volt = ""
  if (bat_temp != "" && bat_volt != "") {
    tc = (bat_temp + 0) / 10.0
    vv = (bat_volt + 0) / 1000000.0
    temp_volt = sprintf("%.1f°C · %.2fV", tc, vv)
  } else if (bat_temp != "") {
    temp_volt = sprintf("%.1f°C", (bat_temp + 0) / 10.0)
  } else if (bat_volt != "") {
    temp_volt = sprintf("%.2fV", (bat_volt + 0) / 1000000.0)
  }

  # Time estimate fallback when discharging if empty
  time_str = orig_time
  if (time_str == "" && state == "discharging" && bat_energy_now != "" && sys_w > 0.5) {
    en_wh = (bat_energy_now + 0) / 1000000.0
    hrs = en_wh / sys_w
    h = int(hrs)
    m = int((hrs - h) * 60 + 0.5)
    if (m == 60) { h++; m = 0 }
    if (h > 0) time_str = sprintf("%dh %dm", h, m)
    else time_str = sprintf("%dm", m)
  }

  # Threshold
  thresh = orig_thresh
  if (thresh == "" && bat_end_thresh != "" && bat_end_thresh + 0 < 100) {
    if (bat_start_thresh != "" && bat_start_thresh != bat_end_thresh) {
      thresh = bat_start_thresh "-" bat_end_thresh "%"
    } else {
      thresh = bat_end_thresh "%"
    }
  }

  if (pct != "") print "percentage\t" pct
  if (state != "") print "state\t" state
  if (rate != "") print "rate\t" rate
  if (system_power != "") print "system_power\t" system_power
  if (system_power_short != "") print "system_power_short\t" system_power_short
  if (ac_power != "") print "ac_power\t" ac_power
  if (ac_vi != "") print "ac_vi\t" ac_vi
  if (battery_flow != "") print "battery_flow\t" battery_flow
  if (rails != "") print "rails\t" rails
  if (fans != "") print "fans\t" fans
  if (size != "") print "size\t" size
  if (design_size != "") print "design_size\t" design_size
  if (health != "") print "health\t" health
  if (bat_cycles != "") print "cycles\t" bat_cycles
  if (temp_volt != "") print "temp_volt\t" temp_volt
  if (time_str != "") print "time\t" time_str
  if (thresh != "") print "threshold\t" thresh
}
'
