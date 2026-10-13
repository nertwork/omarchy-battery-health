# Battery Health & Power for Omarchy

A polished, native Omarchy status bar panel and widget providing advanced battery health management, 80% charge threshold limiting, power profile switching, and live system analytics.

<p align="center">
  <b>80% Charge Limiting (Protect Mode)</b> • <b>Power Profiles</b> • <b>Cycle Counts & Health</b> • <b>Live Wattage & Rates</b>
</p>

<p align="center">
  <img src="preview.png" alt="Battery Health & Power Panel Preview" width="520">
</p>

---

## Features

- **Battery Health & Charge Threshold Limiting**:
  - One-click toggling between **80% (Protect)** and **100% (Full)** charge thresholds.
  - Extends lithium-ion battery longevity by preventing long stays at maximum voltage while docked or connected to AC power.
  - Automatic detection of hardware sysfs threshold nodes (`macsmc-battery`, `BAT0`, `BAT1`).
  - Native desktop notifications confirming threshold transitions.
- **Power Profile Management**:
  - Seamless switching between `Power-saver`, `Balanced`, and `Performance` system profiles.
  - Full keyboard navigation and hotkey support inside the panel.
- **Live Energy Analytics & Telemetry**:
  - Battery capacity and full design specifications.
  - Cycle count tracking and health status.
  - Real-time discharge/charge rate (watts/milliamps) and dynamic time-to-empty / time-to-full estimations.
  - Visual charge progress bar with subtle charging pulse animation.
- **Fast Bar Controls**:
  - **Left-Click**: Toggle detailed popup panel.
  - **Middle-Click**: Instantly toggle charge limit between 80% and 100% without opening the panel.
  - **Right-Click**: Toggle numerical battery percentage display on the bar.
- **Seamless Omarchy Integration**:
  - Matches active system themes dynamically with responsive palette blending.
  - Drop-in replacement for the stock `omarchy.power` widget with identical bar ergonomics.

---

## Installation and Removal

Install directly into Omarchy using the `omarchy plugin` CLI:

```bash
omarchy plugin add https://github.com/nertwork/omarchy-battery-health.git --enable
```

To update to the latest version:

```bash
omarchy plugin update nertwork.power
```

To remove the plugin:

```bash
omarchy plugin remove nertwork.power
```

---

## Hardware Compatibility & Setup

### Apple Silicon (Asahi / Arch ARM Linux)
Charge limiting is supported natively through `macsmc-battery` sysfs controls:
```
/sys/class/power_supply/macsmc-battery/charge_control_end_threshold
/sys/class/power_supply/macsmc-battery/charge_control_start_threshold
```

### Standard Laptops (ThinkPad, Dell, Framework, ASUS)
Standard Linux laptops expose charge thresholds via ACPI / kernel modules:
```
/sys/class/power_supply/BAT0/charge_control_end_threshold
/sys/class/power_supply/BAT1/charge_control_end_threshold
```

---

## Shortcuts & Controls

| Input | Action |
|---|---|
| **Bar Left-Click** | Toggle the Power & Battery Health panel |
| **Bar Middle-Click** | Quick-toggle charge limit between 80% and 100% |
| **Bar Right-Click** | Toggle battery percentage on the top bar |
| **`h` / `l` or `Left` / `Right`** | Select power profiles (inside panel) |
| **`Enter`** | Activate selected power profile |
| **`Esc`** | Close panel |

---

## License

MIT License. See [LICENSE](LICENSE) for details.
