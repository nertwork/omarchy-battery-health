#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C

is_uint() {
  [[ "${1:-}" =~ ^[0-9]{1,18}$ ]]
}

is_safe_regular_file() {
  local f="$1" max_bytes="${2:-4096}" f_mode f_size
  [[ -n "$f" && -f "$f" && ! -L "$f" && -O "$f" ]] || return 1
  f_mode="$(stat -c '%a' "$f" 2>/dev/null || true)"
  [[ "$f_mode" == "600" ]] || return 1
  f_size="$(stat -c '%s' "$f" 2>/dev/null || true)"
  is_uint "$f_size" && is_uint "$max_bytes" || return 1
  (( 10#$f_size > 0 && 10#$f_size <= 10#$max_bytes ))
}

# Checked, user-owned 0700 runtime directory for state, cache, and locks
runtime_base="${XDG_RUNTIME_DIR:-${HOME}/.local/state}"
state_dir=""
if [[ -n "$runtime_base" && ! -L "$runtime_base" ]]; then
  (umask 077 && mkdir -p "$runtime_base") 2>/dev/null || true
  if [[ -d "$runtime_base" && ! -L "$runtime_base" && -O "$runtime_base" ]]; then
    candidate_dir="${runtime_base}/omarchy-power"
    (umask 077 && mkdir -p "$candidate_dir") 2>/dev/null || true
    if [[ -d "$candidate_dir" && ! -L "$candidate_dir" && -O "$candidate_dir" ]]; then
      chmod 0700 "$candidate_dir" 2>/dev/null || true
      if [[ "$(stat -c '%a' "$candidate_dir" 2>/dev/null)" == "700" ]]; then
        state_dir="$candidate_dir"
      fi
    fi
  fi
fi

# Short 1.2s cache + flock so multiple monitor bar instances share a single sample
cache_file="${state_dir:+$state_dir/telemetry.cache}"
lock_file="${state_dir:+$state_dir/telemetry.lock}"

read_fresh_cache() {
  local now_ms mtime_s mtime_ms pf
  [[ -n "$cache_file" ]] && is_safe_regular_file "$cache_file" 4096 || return 1
  for pf in "${HOME}/.local/state/omarchy/powerprofiles/last-profile" "${HOME}/.local/state/omarchy/powerprofiles/gpu-mode" "/var/lib/omarchy-power-profile/last-profile" "/var/lib/omarchy-power-profile/gpu-mode"; do
    if [[ -e "$pf" && "$pf" -nt "$cache_file" ]]; then
      return 1
    fi
  done
  now_ms="$(date +%s%3N)"
  mtime_s="$(stat -c '%Y' "$cache_file" 2>/dev/null || echo 0)"
  is_uint "$now_ms" && is_uint "$mtime_s" || return 1
  mtime_ms=$(( 10#$mtime_s * 1000 ))
  if (( 10#$now_ms >= 10#$mtime_ms && 10#$now_ms - 10#$mtime_ms < 1200 )); then
    head -c 4096 "$cache_file" 2>/dev/null
    return 0
  fi
  return 1
}

if [[ "${1:-}" != "--no-cache" && -n "$state_dir" ]]; then
  if read_fresh_cache; then
    exit 0
  fi
  if [[ ! -L "$lock_file" && ( ! -e "$lock_file" || ( -f "$lock_file" && -O "$lock_file" ) ) ]]; then
    old_umask="$(umask)"
    umask 077
    exec 9>"$lock_file" 2>/dev/null || true
    umask "$old_umask"
    if [[ -f "$lock_file" && ! -L "$lock_file" && -O "$lock_file" ]]; then
      chmod 0600 "$lock_file" 2>/dev/null || true
      if flock -w 2 9; then
        if read_fresh_cache; then
          exit 0
        fi
        tmp_cache="$(umask 077 && mktemp "${state_dir}/.cache.XXXXXX" 2>/dev/null || true)"
        if [[ -n "$tmp_cache" && -f "$tmp_cache" && ! -L "$tmp_cache" && -O "$tmp_cache" ]]; then
          chmod 0600 "$tmp_cache" 2>/dev/null || true
          if "$0" --no-cache > "$tmp_cache" && mv -f "$tmp_cache" "$cache_file"; then
            if is_safe_regular_file "$cache_file" 4096; then
              head -c 4096 "$cache_file" 2>/dev/null
              exit 0
            fi
          fi
          rm -f "$tmp_cache" 2>/dev/null || true
        fi
      fi
    fi
  fi
fi

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
  now_us="$(date +%s%6N)"
  pkg1="$(head -c 32 /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null | tr -d '[:space:]' || true)"
  psys1="0"
  if [[ -r /sys/class/powercap/intel-rapl:1/energy_uj ]]; then
    psys1="$(head -c 32 /sys/class/powercap/intel-rapl:1/energy_uj 2>/dev/null | tr -d '[:space:]' || true)"
    is_uint "$psys1" || psys1="0"
  fi
  max_uj="$(head -c 32 /sys/class/powercap/intel-rapl:0/max_energy_range_uj 2>/dev/null | tr -d '[:space:]' || true)"
  is_uint "$max_uj" || max_uj="262143328850"

  rapl_state="${state_dir:+$state_dir/rapl.state}"
  prev_us="0"; prev_pkg="0"; prev_psys="0"
  if [[ -n "$rapl_state" ]]; then
    if is_safe_regular_file "$rapl_state" 64; then
      raw_us=""; raw_pkg=""; raw_psys=""
      IFS=' ' read -r raw_us raw_pkg raw_psys _ < <(head -c 64 "$rapl_state" 2>/dev/null) || true
      if is_uint "$raw_us" && is_uint "$raw_pkg" && is_uint "${raw_psys:-0}"; then
        prev_us="$raw_us"
        prev_pkg="$raw_pkg"
        prev_psys="${raw_psys:-0}"
      else
        rm -f "$rapl_state" 2>/dev/null || true
      fi
    elif [[ -e "$rapl_state" || -L "$rapl_state" ]]; then
      rm -f "$rapl_state" 2>/dev/null || true
    fi
  fi

  if is_uint "$now_us" && is_uint "$pkg1" && is_uint "$psys1" && is_uint "$max_uj" && is_uint "$prev_us" && is_uint "$prev_pkg" && is_uint "$prev_psys"; then
    dt_us="0"
    if (( 10#$prev_us > 0 && 10#$now_us > 10#$prev_us )); then
      dt_us=$(( 10#$now_us - 10#$prev_us ))
    fi
    if ! is_uint "$dt_us" || (( 10#$dt_us < 80000 || 10#$dt_us > 15000000 )); then
      prev_us="$now_us"; prev_pkg="$pkg1"; prev_psys="$psys1"
      sleep 0.15
      now_us="$(date +%s%6N)"
      pkg1="$(head -c 32 /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ -r /sys/class/powercap/intel-rapl:1/energy_uj ]]; then
        psys1="$(head -c 32 /sys/class/powercap/intel-rapl:1/energy_uj 2>/dev/null | tr -d '[:space:]' || true)"
        is_uint "$psys1" || psys1="0"
      fi
      dt_us="0"
      if is_uint "$now_us" && is_uint "$prev_us" && is_uint "$pkg1" && (( 10#$now_us > 10#$prev_us )); then
        dt_us=$(( 10#$now_us - 10#$prev_us ))
      fi
    fi

    if [[ -n "$rapl_state" && -n "$state_dir" ]] && is_uint "$now_us" && is_uint "$pkg1" && is_uint "$psys1"; then
      tmp_state="$(umask 077 && mktemp "${state_dir}/.rapl.XXXXXX" 2>/dev/null || true)"
      if [[ -n "$tmp_state" && -f "$tmp_state" && ! -L "$tmp_state" && -O "$tmp_state" ]]; then
        chmod 0600 "$tmp_state" 2>/dev/null || true
        if printf '%s %s %s\n' "$now_us" "$pkg1" "$psys1" > "$tmp_state" 2>/dev/null; then
          mv -f "$tmp_state" "$rapl_state" 2>/dev/null || rm -f "$tmp_state" 2>/dev/null || true
        else
          rm -f "$tmp_state" 2>/dev/null || true
        fi
      fi
    fi

    if is_uint "$dt_us" && (( 10#$dt_us > 0 )) && is_uint "$pkg1" && is_uint "$prev_pkg" && is_uint "$max_uj"; then
      if (( 10#$pkg1 >= 10#$prev_pkg )); then
        dpkg=$(( 10#$pkg1 - 10#$prev_pkg ))
      else
        dpkg=$(( 10#$pkg1 + 10#$max_uj - 10#$prev_pkg ))
      fi
      if is_uint "$dpkg"; then
        rapl_pkg_w="$(awk -v e="$dpkg" -v dt="$dt_us" 'BEGIN { printf "%.1f", (e + 0.0) / dt }')"
      fi
      if is_uint "$psys1" && is_uint "$prev_psys" && (( 10#$psys1 > 0 && 10#$prev_psys > 0 )); then
        if (( 10#$psys1 >= 10#$prev_psys )); then
          dpsys=$(( 10#$psys1 - 10#$prev_psys ))
        else
          dpsys=$(( 10#$psys1 + 10#$max_uj - 10#$prev_psys ))
        fi
        if is_uint "$dpsys"; then
          rapl_psys_w="$(awk -v e="$dpsys" -v dt="$dt_us" 'BEGIN { printf "%.1f", (e + 0.0) / dt }')"
        fi
      fi
    fi
  fi
fi

# NVIDIA dGPU runtime PM & power draw (never wake from D3cold!)
dgpu_label=""
dgpu_num_w="0"
nvidia_gpu=""
if [[ -r /sys/bus/pci/devices/0000:01:00.0/power/runtime_status ]]; then
  dgpu_state="$(</sys/bus/pci/devices/0000:01:00.0/power/runtime_status)"
  if [[ "$dgpu_state" == "suspended" ]]; then
    dgpu_label="0.0W (D3cold)"
    dgpu_num_w="0"
    nvidia_gpu="Sleeping (RTD3 D3cold · 0W)"
  elif [[ "$dgpu_state" == "active" ]] && command -v nvidia-smi >/dev/null 2>&1; then
    nv_line="$(timeout 1.5s nvidia-smi --query-gpu=power.draw,clocks.current.graphics,utilization.gpu,memory.used,temperature.gpu,pstate --format=csv,noheader,nounits </dev/null 2>/dev/null | head -n1 || true)"
    if [[ -n "$nv_line" ]]; then
      IFS="," read -r nv_w nv_clk nv_util nv_mem nv_temp nv_pstate <<< "$nv_line"
      nv_w="${nv_w//[[:space:]]/}"
      nv_clk="${nv_clk//[[:space:]]/}"
      nv_util="${nv_util//[[:space:]]/}"
      nv_mem="${nv_mem//[[:space:]]/}"
      nv_temp="${nv_temp//[[:space:]]/}"
      nv_pstate="${nv_pstate//[[:space:]]/}"
      if [[ -n "$nv_w" && "$nv_w" != "[N/A]" ]]; then
        dgpu_num_w="$nv_w"
        if [[ "$nv_util" =~ ^[0-9]+$ ]] && (( 10#$nv_util > 0 )); then
          dgpu_label="$(awk -v w="$nv_w" -v u="$nv_util" 'BEGIN { printf "%.1fW (%d%%)", w + 0, u + 0 }')"
        elif [[ -n "$nv_pstate" && "$nv_pstate" != "[N/A]" ]]; then
          dgpu_label="$(awk -v w="$nv_w" -v p="$nv_pstate" 'BEGIN { printf "%.1fW (%s)", w + 0, p }')"
        else
          dgpu_label="$(awk -v w="$nv_w" 'BEGIN { printf "%.1fW", w + 0 }')"
        fi
      else
        dgpu_label="Active"
      fi
      if [[ -n "$nv_clk" && "$nv_clk" != "[N/A]" ]]; then
        if [[ "$nv_util" =~ ^[0-9]+$ ]] && (( 10#$nv_util > 0 )); then
          nvidia_gpu="${nv_clk}MHz · ${nv_mem:-0}MiB · ${nv_temp:-0}°C (${nv_util}%)"
        else
          nvidia_gpu="${nv_clk}MHz · ${nv_mem:-0}MiB · ${nv_temp:-0}°C (${nv_pstate:-P0})"
        fi
      else
        nvidia_gpu="Active (${dgpu_label})"
      fi
    else
      dgpu_label="Active"
      nvidia_gpu="Active"
    fi
  fi
fi

gpu_mode=""
for gm_file in "${HOME}/.local/state/omarchy/powerprofiles/gpu-mode" "/var/lib/omarchy-power-profile/gpu-mode"; do
  if [[ -r "$gm_file" ]]; then
    gpu_mode="$(head -n1 "$gm_file" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
    [[ -n "$gpu_mode" ]] && break
  fi
done

awk -v bat_dir="$bat_dir" -v ac_dir="$ac_dir" -v smc_dir="$smc_dir" -v tp_dir="$tp_dir" \
    -v rapl_pkg_w="$rapl_pkg_w" -v rapl_psys_w="$rapl_psys_w" \
    -v dgpu_label="$dgpu_label" -v dgpu_num_w="$dgpu_num_w" \
    -v nvidia_gpu="$nvidia_gpu" -v gpu_mode="$gpu_mode" \
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
function fmt_short_w(w) {
  if (w <= 0) return "0W"
  if (w < 1.0) return sprintf("%.1fW", w)
  return sprintf("%.0fW", w)
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
    system_power_short = fmt_short_w(sys_w)
  } else if (ac_uw != "" && ac_uw + 0 > 0) {
    sys_w = (ac_uw + 0) / 1000000.0
    system_power = sprintf("%.1fW", sys_w)
    system_power_short = fmt_short_w(sys_w)
  } else if (state == "discharging" && bat_w > 0) {
    sys_w = bat_w
    system_power = sprintf("%.1fW", sys_w)
    system_power_short = fmt_short_w(sys_w)
  } else if (rapl_psys_w != "" && rapl_psys_w + 0 > 0) {
    sys_w = rapl_psys_w + 0
    system_power = sprintf("%.1fW", sys_w)
    system_power_short = fmt_short_w(sys_w)
  } else if (rapl_pkg_w != "" && rapl_pkg_w + 0 > 0) {
    sys_w = (rapl_pkg_w + 0) + (dgpu_num_w + 0)
    system_power = sprintf("%.1fW", sys_w)
    system_power_short = fmt_short_w(sys_w)
  } else if (bat_w > 0) {
    sys_w = bat_w
    system_power = sprintf("%.1fW", sys_w)
    system_power_short = fmt_short_w(sys_w)
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
  if (nvidia_gpu != "") print "nvidia_gpu\t" nvidia_gpu
  if (gpu_mode != "") print "gpu_mode\t" gpu_mode
}
'
