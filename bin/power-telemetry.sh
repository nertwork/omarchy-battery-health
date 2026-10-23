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
for d in /sys/class/power_supply/macsmc-battery /sys/class/power_supply/BAT0 /sys/class/power_supply/BAT*; do
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

# Locate USB-C PD active source (if present on ThinkPad / x86_64)
ucsi_v_uv=""
ucsi_i_ua=""
ucsi_imax_ua=""
for d in /sys/class/power_supply/ucsi-source-psy-*; do
  if [[ -r "$d/online" && "$(<"$d/online")" == "1" ]]; then
    [[ -r "$d/voltage_now" ]] && ucsi_v_uv="$(<"$d/voltage_now")"
    [[ -r "$d/current_now" ]] && ucsi_i_ua="$(<"$d/current_now")"
    [[ -r "$d/current_max" ]] && ucsi_imax_ua="$(<"$d/current_max")"
    break
  fi
done

# Locate macsmc_hwmon and thinkpad hwmon
smc_dir=""
tp_dir=""
for d in /sys/class/hwmon/hwmon*; do
  if [[ -f "$d/name" ]]; then
    hname="$(<"$d/name")"
    [[ "$hname" == "macsmc_hwmon" ]] && smc_dir="$d"
    [[ "$hname" == "thinkpad" ]] && tp_dir="$d"
  fi
done

# Intel RAPL energy delta (package-0 = CPU package W, psys = platform/system W)
rapl_pkg_w=""
rapl_psys_w=""
if [[ -r /sys/class/powercap/intel-rapl:0/energy_uj ]]; then
  now_ns="$(date +%s%N)"
  pkg1="$(</sys/class/powercap/intel-rapl:0/energy_uj)"
  psys1=0
  [[ -r /sys/class/powercap/intel-rapl:1/energy_uj ]] && psys1="$(</sys/class/powercap/intel-rapl:1/energy_uj)"
  max_uj="$(cat /sys/class/powercap/intel-rapl:0/max_energy_range_uj 2>/dev/null || echo 262143328850)"
  state_file="/tmp/omarchy-rapl-${UID:-1000}.state"
  prev_ns=0; prev_pkg=0; prev_psys=0
  if [[ -r "$state_file" ]]; then
    read -r prev_ns prev_pkg prev_psys < "$state_file" 2>/dev/null || true
  fi
  dt_ns=$(( now_ns - prev_ns ))
  if (( prev_ns <= 0 || dt_ns < 80000000 || dt_ns > 15000000000 )); then
    prev_ns=$now_ns; prev_pkg=$pkg1; prev_psys=$psys1
    sleep 0.15
    now_ns="$(date +%s%N)"
    pkg1="$(</sys/class/powercap/intel-rapl:0/energy_uj)"
    [[ -r /sys/class/powercap/intel-rapl:1/energy_uj ]] && psys1="$(</sys/class/powercap/intel-rapl:1/energy_uj)"
    dt_ns=$(( now_ns - prev_ns ))
  fi
  printf '%s %s %s\n' "$now_ns" "$pkg1" "$psys1" > "$state_file" 2>/dev/null || true
  if (( dt_ns > 0 )); then
    dpkg=$(( pkg1 - prev_pkg ))
    (( dpkg < 0 )) && dpkg=$(( dpkg + max_uj ))
    rapl_pkg_w="$(awk -v e="$dpkg" -v dt="$dt_ns" 'BEGIN { printf "%.1f", (e * 1000.0) / dt }')"
    if (( psys1 > 0 && prev_psys > 0 )); then
      dpsys=$(( psys1 - prev_psys ))
      (( dpsys < 0 )) && dpsys=$(( dpsys + max_uj ))
      rapl_psys_w="$(awk -v e="$dpsys" -v dt="$dt_ns" 'BEGIN { printf "%.1f", (e * 1000.0) / dt }')"
    fi
  fi
fi

# NVIDIA dGPU runtime PM & power draw (never wake from D3cold!)
dgpu_label=""
dgpu_num_w="0"
if [[ -r /sys/bus/pci/devices/0000:01:00.0/power/runtime_status ]]; then
  dgpu_state="$(</sys/bus/pci/devices/0000:01:00.0/power/runtime_status)"
  if [[ "$dgpu_state" == "suspended" ]]; then
    dgpu_label="0.0W (D3cold)"
    dgpu_num_w="0"
  elif [[ "$dgpu_state" == "active" ]] && command -v nvidia-smi >/dev/null 2>&1; then
    nv_raw="$(timeout 1.5s nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits </dev/null 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
    if [[ -n "$nv_raw" && "$nv_raw" != "[N/A]" ]]; then
      dgpu_num_w="$nv_raw"
      dgpu_label="$(awk -v w="$nv_raw" 'BEGIN { printf "%.1fW", w + 0 }')"
    else
      dgpu_label="Active"
    fi
  fi
fi

awk -v bat_dir="$bat_dir" -v ac_dir="$ac_dir" -v smc_dir="$smc_dir" -v tp_dir="$tp_dir" \
    -v rapl_pkg_w="$rapl_pkg_w" -v rapl_psys_w="$rapl_psys_w" \
    -v dgpu_label="$dgpu_label" -v dgpu_num_w="$dgpu_num_w" \
    -v ucsi_v_uv="$ucsi_v_uv" -v ucsi_i_ua="$ucsi_i_ua" -v ucsi_imax_ua="$ucsi_imax_ua" \
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
  # SMC telemetry (Apple Silicon)
  sys_uw  = read_file(smc_dir "/power1_input")
  ac_uw   = read_file(smc_dir "/power2_input")
  rail_uw = read_file(smc_dir "/power3_input")
  heat_uw = read_file(smc_dir "/power4_input")
  in_mv   = read_file(smc_dir "/in0_input")
  in_ma   = read_file(smc_dir "/curr1_input")
  fan1    = read_file(smc_dir "/fan1_input")
  fan2    = read_file(smc_dir "/fan2_input")

  # ThinkPad hwmon fallback for fans & CPU temp
  if (fan1 == "" && tp_dir != "") {
    fan1 = read_file(tp_dir "/fan1_input")
    fan2 = read_file(tp_dir "/fan2_input")
  }
  tp_temp_mc = (tp_dir != "") ? read_file(tp_dir "/temp1_input") : ""

  # USB-C PD fallback for charger V/I on ThinkPad
  if (in_mv == "" && ucsi_v_uv != "" && ucsi_v_uv + 0 > 0) {
    in_mv = (ucsi_v_uv + 0) / 1000.0
    if (ucsi_i_ua != "" && ucsi_i_ua + 0 > 0) {
      in_ma = (ucsi_i_ua + 0) / 1000.0
    } else if (ucsi_imax_ua != "" && ucsi_imax_ua + 0 > 0) {
      in_ma = (ucsi_imax_ua + 0) / 1000.0
    }
  }

  # AC telemetry
  ac_online   = read_file(ac_dir "/online")
  ac_limit_uw = read_file(ac_dir "/input_power_limit")
  if (ac_limit_uw == "" && ucsi_v_uv != "" && ucsi_imax_ua != "" && ucsi_v_uv + 0 > 0 && ucsi_imax_ua + 0 > 0) {
    ac_limit_uw = ((ucsi_v_uv + 0) / 1000000.0) * ((ucsi_imax_ua + 0) / 1000000.0) * 1000000.0
  }

  # Battery telemetry
  bat_status        = tolower(read_file(bat_dir "/status"))
  bat_cap           = read_file(bat_dir "/capacity")
  bat_power_now     = read_file(bat_dir "/power_now")
  bat_energy_now    = read_file(bat_dir "/energy_now")
  bat_energy_full   = read_file(bat_dir "/energy_full")
  bat_energy_design = read_file(bat_dir "/energy_full_design")
  bat_cycles        = read_file(bat_dir "/cycle_count")
  bat_temp          = read_file(bat_dir "/temp")
  bat_volt          = read_file(bat_dir "/voltage_now")
  bat_end_thresh    = read_file(bat_dir "/charge_control_end_threshold")
  bat_start_thresh  = read_file(bat_dir "/charge_control_start_threshold")

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
  } else if (state == "discharging" && bat_w > 0) {
    sys_w = bat_w
    system_power = sprintf("%.1fW", sys_w)
    system_power_short = sprintf("%.0fW", sys_w)
  } else if (rapl_psys_w != "" && rapl_psys_w + 0 > 0) {
    sys_w = rapl_psys_w + 0
    system_power = sprintf("%.1fW", sys_w)
    system_power_short = sprintf("%.0fW", sys_w)
  } else if (rapl_pkg_w != "" && rapl_pkg_w + 0 > 0) {
    sys_w = (rapl_pkg_w + 0) + (dgpu_num_w + 0)
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
    } else if (state == "charging" && bat_w > 0 && sys_w > 0) {
      ac_power = sprintf("Online (~%.1fW)", sys_w + bat_w)
    } else if (sys_w > 0) {
      ac_power = sprintf("Online (~%.1fW)", sys_w)
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
    battery_flow = sprintf("+%.1fW (Chg)", bat_w)
  } else if (state == "discharging") {
    battery_flow = sprintf("-%.1fW (Drain)", bat_w)
  } else {
    battery_flow = (rate != "" ? rate : "0W")
  }

  # Rails (Apple Silicon 3.8V Rail & Heatpipe) vs CPU / dGPU (ThinkPad RAPL + NVIDIA)
  rails = ""
  cpu_gpu = ""
  if (rail_uw != "" && heat_uw != "") {
    rw = (rail_uw + 0) / 1000000.0
    hw = (heat_uw + 0) / 1000000.0
    rails = sprintf("%.1fW · %.1fW", rw, hw)
  } else if (rapl_pkg_w != "") {
    if (dgpu_label != "") {
      cpu_gpu = sprintf("%sW · %s", rapl_pkg_w, dgpu_label)
    } else {
      cpu_gpu = sprintf("%sW", rapl_pkg_w)
    }
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
    health = sprintf("%.0f%% (%.0f/%.0fWh)", hpct, ef_wh, ed_wh)
    if (size == "") size = sprintf("%.0fWh", ef_wh)
    if (design_size == "") design_size = sprintf("%.0fWh", ed_wh)
  } else if (size != "" && design_size != "") {
    health = size " / " design_size
  } else {
    health = size
  }

  # Temp & Voltage
  temp_volt = ""
  tc_val = ""
  if (bat_temp != "") {
    tc_val = sprintf("%.1f°C", (bat_temp + 0) / 10.0)
  } else if (tp_temp_mc != "" && tp_temp_mc + 0 > 0) {
    tc_val = sprintf("%.1f°C", (tp_temp_mc + 0) / 1000.0)
  }
  if (tc_val != "" && bat_volt != "") {
    vv = (bat_volt + 0) / 1000000.0
    temp_volt = sprintf("%s · %.1fV", tc_val, vv)
  } else if (tc_val != "") {
    temp_volt = tc_val
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

  # Threshold (prefer instantaneous sysfs over cached upower)
  thresh = ""
  if (bat_end_thresh != "") {
    if (bat_end_thresh + 0 < 100) {
      if (bat_start_thresh != "" && bat_start_thresh != bat_end_thresh && bat_start_thresh != "0") {
        thresh = bat_start_thresh "-" bat_end_thresh "%"
      } else {
        thresh = bat_end_thresh "%"
      }
    }
  } else {
    thresh = orig_thresh
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
  if (cpu_gpu != "") print "cpu_gpu\t" cpu_gpu
  if (fans != "") print "fans\t" fans
  if (size != "") print "size\t" size
  if (design_size != "") print "design_size\t" design_size
  if (health != "") print "health\t" health
  if (bat_cycles != "") print "cycles\t" bat_cycles
  if (temp_volt != "") print "temp_volt\t" temp_volt
  if (time_str != "") print "time\t" time_str
  if (thresh != "") print "threshold\t" thresh
  if (bat_end_thresh != "") {
    print "charge_limit_end\t" bat_end_thresh
    print "charge_limit_path\t" bat_dir "/charge_control_end_threshold"
  }
}
'
