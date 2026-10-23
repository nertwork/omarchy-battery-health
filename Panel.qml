import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "nertwork.power"
  ipcTarget: "nertwork.power"
  // manageIpc: false so this panel can own its custom ShellIpc handlers below.
  manageIpc: false
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: ["power-saver", "balanced", "performance"]
  property string activeProfile: "balanced"
  property string pendingProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false

  // Display mode for the top bar widget:
  //   "both"       -> Percentage + Live Wattage (e.g. "79% · 32W")
  //   "percentage" -> Percentage only (e.g. "79%")
  //   "usage"      -> Live Wattage only (e.g. "32W")
  //   "icon"       -> Battery icon only
  property string displayMode: "both"
  property bool configLoaded: false
  readonly property string configPath: (Quickshell.env("HOME") || "/home/jfarr") + "/.local/state/omarchy/settings/nertwork.power.json"

  readonly property bool showPercentage: root.displayMode === "both" || root.displayMode === "percentage"
  readonly property bool showWatts: root.displayMode === "both" || root.displayMode === "usage"

  property int currentChargeLimit: 80
  property bool hasChargeLimit: false

  readonly property string telemetryScriptPath: {
    var url = String(Qt.resolvedUrl("bin/power-telemetry.sh"))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url)
  }

  property string chargeLimitPath: "/sys/class/power_supply/macsmc-battery/charge_control_end_threshold"

  function normalizeMode(m) {
    var s = String(m || "").trim().toLowerCase()
    if (s === "both" || s === "all" || s === "full" || s === "pct+watts" || s === "usage+percentage" || s === "percentage+usage") return "both"
    if (s === "percentage" || s === "percent" || s === "pct" || s === "%") return "percentage"
    if (s === "usage" || s === "watts" || s === "power" || s === "w" || s === "wattage") return "usage"
    if (s === "icon" || s === "none" || s === "off") return "icon"
    return "both"
  }

  function modeFromLegacyFlags(showPct, showW) {
    var p = showPct !== false
    var w = showW !== false
    if (p && w) return "both"
    if (p && !w) return "percentage"
    if (!p && w) return "usage"
    return "icon"
  }

  function applySettingsFromShell() {
    if (!root.settings || typeof root.settings !== "object") return
    if (root.settings.displayMode !== undefined && String(root.settings.displayMode) !== "") {
      root.displayMode = root.normalizeMode(root.settings.displayMode)
    } else if (!root.configLoaded && (root.settings.showPercentage !== undefined || root.settings.showWatts !== undefined)) {
      root.displayMode = root.modeFromLegacyFlags(root.settings.showPercentage, root.settings.showWatts)
    }
  }

  onSettingsChanged: applySettingsFromShell()

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var raw = configFile.text().trim()
        if (raw) {
          var data = JSON.parse(raw)
          if (data.displayMode !== undefined && String(data.displayMode) !== "") {
            root.displayMode = root.normalizeMode(data.displayMode)
          } else if (data.showPercentage !== undefined || data.showWatts !== undefined) {
            root.displayMode = root.modeFromLegacyFlags(data.showPercentage, data.showWatts)
          }
          root.configLoaded = true
          if (root.showWatts && !batteryProc.running) batteryProc.running = true
          return
        }
      } catch (e) {}
      root.configLoaded = true
      root.applySettingsFromShell()
    }
    onLoadFailed: {
      root.configLoaded = true
      root.applySettingsFromShell()
    }
  }

  Process {
    id: saveConfigProc
  }

  function setDisplayMode(mode) {
    var next = root.normalizeMode(mode)
    var showPct = (next === "both" || next === "percentage")
    var showW = (next === "both" || next === "usage")
    root.displayMode = next

    var payload = JSON.stringify({
      displayMode: next,
      showPercentage: showPct,
      showWatts: showW
    })
    saveConfigProc.command = [
      "bash", "-c",
      "mkdir -p ~/.local/state/omarchy/settings && printf '%s\\n' \"$1\" > ~/.local/state/omarchy/settings/nertwork.power.json",
      "_", payload
    ]
    saveConfigProc.running = true

    var nextSettings = Object.assign({}, root.settings || {}, {
      displayMode: next,
      showPercentage: showPct,
      showWatts: showW
    })
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, nextSettings)
    }
    if (showW && !batteryProc.running) batteryProc.running = true
  }

  function cycleDisplayMode() {
    if (root.displayMode === "both") {
      setDisplayMode("percentage")
    } else if (root.displayMode === "percentage") {
      setDisplayMode("usage")
    } else {
      setDisplayMode("both")
    }
  }

  function togglePercentage() {
    cycleDisplayMode()
  }

  FileView {
    id: chargeLimitFile
    path: root.chargeLimitPath
    watchChanges: true
    printErrors: false
    blockAllReads: true
    onFileChanged: reload()
    onLoaded: root.updateLimit()
    onLoadFailed: {
      if (root.batteryInfo && root.batteryInfo.charge_limit_end) {
        var parsed = parseInt(root.batteryInfo.charge_limit_end)
        if (!isNaN(parsed)) {
          root.currentChargeLimit = parsed
          root.hasChargeLimit = true
          return
        }
      }
      root.hasChargeLimit = false
    }
  }

  function updateLimit() {
    var raw = chargeLimitFile.text().trim()
    if (raw) {
      var parsed = parseInt(raw)
      if (!isNaN(parsed)) {
        root.currentChargeLimit = parsed
        root.hasChargeLimit = true
        return
      }
    }
    if (root.batteryInfo && root.batteryInfo.charge_limit_end) {
      var fallback = parseInt(root.batteryInfo.charge_limit_end)
      if (!isNaN(fallback)) {
        root.currentChargeLimit = fallback
        root.hasChargeLimit = true
        return
      }
    }
    root.hasChargeLimit = false
  }

  Component.onCompleted: {
    applySettingsFromShell()
    updateLimit()
    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
  }

  readonly property string barLabelText: {
    if (button.vertical) return ""
    var d = UPower.displayDevice
    var pct = (d && d.isPresent)
      ? (Math.round(root.batteryFraction * 100) + "%")
      : (root.batteryInfo.percentage || "")
    var watts = root.batteryInfo.system_power_short || root.batteryInfo.system_power || ""
    var parts = []
    if (root.showPercentage && pct) parts.push(pct)
    if (root.showWatts && watts) parts.push(watts)
    return parts.join(" · ")
  }
  readonly property bool hasBarText: root.barLabelText !== "" && !button.vertical

  TextMetrics {
    id: barLabelMetrics
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
    text: root.barLabelText
  }

  // With percentage/wattage shown the button paints a label to the left of the
  // icon, so the open-panel mark spans both label and glyph.
  readonly property real openPanelIndicatorWidth: hasBarText
    ? Math.ceil(barLabelMetrics.advanceWidth + Style.space(4) + button.glyphPaintedWidth)
    : 0
  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Commons.Color.foreground
  }

  // Cute agent-flavored phrases shown in the hero status line, rotated on a
  // timer so the panel feels alive when current is flowing (either direction).
  readonly property var chargingPhrases: [
    "Pumping power",
    "Injecting electrons",
    "Pouring juice",
    "Amassing watts",
    "Hoarding joules",
    "Sucking volts",
    "Topping reserves",
    "Soaking amps",
    "Inhaling kilowatts"
  ]
  readonly property var onBatteryPhrases: [
    "Slurping power",
    "Spending joules",
    "Draining watts",
    "Burning electrons",
    "Sipping juice",
    "Spending coulombs",
    "Bleeding amps",
    "Guzzling volts",
    "Munching reserves"
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current power state.
  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  readonly property string heroStatusText: {
    var loadSuffix = root.batteryInfo.system_power ? " · " + root.batteryInfo.system_power + " load" : ""
    if (fullyCharged) return "Fully charged" + loadSuffix
    if (chargeThresholdActive) return "Holding at " + (root.currentChargeLimit ? root.currentChargeLimit + "%" : "limit") + loadSuffix
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length] + (root.batteryInfo.system_power ? " · " + root.batteryInfo.system_power : "")
    return modeLabel() + loadSuffix
  }

  function refresh() {
    if (!batteryPresent) return

    chargeLimitFile.reload()
    updateLimit()
    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (!systemProc.running) systemProc.running = true
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    if (Object.keys(next).length === 0) return
    if (targetName === "battery") {
      batteryInfo = next
      if (next.charge_limit_path && next.charge_limit_path !== root.chargeLimitPath) {
        root.chargeLimitPath = next.charge_limit_path
      }
      if (next.charge_limit_end) {
        var lim = parseInt(next.charge_limit_end)
        if (!isNaN(lim)) {
          root.currentChargeLimit = lim
          root.hasChargeLimit = true
        }
      }
    } else {
      systemInfo = next
    }
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    if (!actionProc.running && !root.pendingProfile) {
      activeProfile = parsed.activeProfile
      profileIndex = parsed.profileIndex
      if (opened && !cursorActive) {
        var idx = profiles.indexOf(activeProfile)
        if (idx >= 0) profileIndex = idx
      }
    }
  }

  function setProfile(profile) {
    if (!profile) return
    root.activeProfile = profile
    var idx = root.profiles.indexOf(profile)
    if (idx >= 0) root.profileIndex = idx
    if (actionProc.running) {
      root.pendingProfile = profile
      return
    }
    root.pendingProfile = ""
    actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    actionProc.running = true
  }

  function cycleProfile() {
    var next = Model.nextProfile(root.activeProfile, root.profiles)
    setProfile(next)
  }

  ShellIpc {
    target: "omarchy.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.cycleDisplayMode(); return root.displayMode }
    function cycleDisplayMode() { root.cycleDisplayMode(); return root.displayMode }
    function cycle() { root.cycleDisplayMode(); return root.displayMode }
    function setDisplayMode(mode: string) { root.setDisplayMode(mode); return root.displayMode }
    function setMode(mode: string) { root.setDisplayMode(mode); return root.displayMode }
    function getDisplayMode() { return root.displayMode }
    function getMode() { return root.displayMode }
    function toggleChargeLimit() { root.toggleChargeLimit() }
    function setChargeLimit(limit: string) { root.setChargeLimit(parseInt(limit)) }
    function cycleProfile() { root.cycleProfile() }
    function setProfile(profile: string) { root.setProfile(profile) }
  }

  ShellIpc {
    target: "nertwork.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.cycleDisplayMode(); return root.displayMode }
    function cycleDisplayMode() { root.cycleDisplayMode(); return root.displayMode }
    function cycle() { root.cycleDisplayMode(); return root.displayMode }
    function setDisplayMode(mode: string) { root.setDisplayMode(mode); return root.displayMode }
    function setMode(mode: string) { root.setDisplayMode(mode); return root.displayMode }
    function getDisplayMode() { return root.displayMode }
    function getMode() { return root.displayMode }
    function toggleChargeLimit() { root.toggleChargeLimit() }
    function setChargeLimit(limit: string) { root.setChargeLimit(parseInt(limit)) }
    function cycleProfile() { root.cycleProfile() }
    function setProfile(profile: string) { root.setProfile(profile) }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        Qt.callLater(function() { root.close() })
        return
      }

      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    command: [root.telemetryScriptPath]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }
  }

  Process {
    id: actionProc
    onExited: {
      if (root.pendingProfile) {
        var next = root.pendingProfile
        root.pendingProfile = ""
        actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", next]
        actionProc.running = true
        return
      }
      if (!profilesProc.running) profilesProc.running = true
      root.refresh()
    }
  }

  Process {
    id: chargeLimitProc
    onExited: function(exitCode) {
      chargeLimitFile.reload()
      root.updateLimit()
      root.refresh()
      if (exitCode === 0) {
        notifyProc.command = [
          "omarchy-notification-send",
          "-g", "󱐋",
          "Battery Charge Limit",
          "Charge limit set to " + root.currentChargeLimit + "%"
        ]
        notifyProc.running = true
      }
    }
  }

  Process {
    id: notifyProc
  }

  function setChargeLimit(limit: string) {
    if (!limit || chargeLimitProc.running) return
    chargeLimitProc.command = ["omarchy-battery-charge-limit", String(limit)]
    chargeLimitProc.running = true
  }

  function toggleChargeLimit() {
    setChargeLimit(root.currentChargeLimit === 80 ? 100 : 80)
  }

  Timer { interval: 2000; running: root.opened; repeat: true; onTriggered: root.refresh() }
  Timer {
    interval: 5000
    running: !root.opened && root.batteryPresent
    repeat: true
    onTriggered: {
      if (!batteryProc.running) batteryProc.running = true
      if (!profilesProc.running) profilesProc.running = true
    }
  }

  // Rotate the status phrase while the panel is open and we're in a
  // rotating state (charging or on battery). The text swap is wrapped in a
  // fade so the changeover reads as one organism rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  // If we leave a rotating state mid-swap, halt the animation and snap back
  // to full opacity so "FULLY CHARGED" is legible immediately rather than
  // appearing dimmed.
  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.batteryIcon()
    labelText: root.barLabelText
    slotSize: !vertical && root.hasBarText ? Math.max(Style.bar.iconSlot, Math.ceil(barLabelMetrics.advanceWidth + Style.space(4) + Style.bar.iconSlot)) : Style.bar.iconSlot
    tooltipText: {
      var load = root.batteryInfo.system_power ? "Load: " + root.batteryInfo.system_power + " · " : ""
      var prof = root.activeProfile ? "Profile: " + root.activeProfile + " · " : ""
      return load + prof + (root.hasChargeLimit ? "Left: Open · Middle: Limit (" + root.currentChargeLimit + "%) · Right: Bar Mode (" + root.displayMode + ")" : "Left: Open · Right: Bar Mode (" + root.displayMode + ")")
    }
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.cycleDisplayMode()
      else if (b === Qt.MiddleButton && root.hasChargeLimit) root.toggleChargeLimit()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Battery"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.weight: Font.Medium
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              text: root.heroStatusText.toUpperCase()
              color: Commons.Color.blend(root.bar.foreground, root.bar.background, 0.55)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 0.6
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            text: root.batteryInfo.percentage || (Math.round(root.batteryFraction * 100) + "%")
            color: root.batteryFillColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            font.weight: Font.DemiBold
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 250 } }
          }
        }

        // ---------- Visual level bar ----------
        Rectangle {
          width: parent.width
          height: Style.space(10)
          radius: height / 2
          color: Commons.Color.blend(root.bar.foreground, root.bar.background, 0.12)
          clip: true

          Rectangle {
            id: fillBar
            height: parent.height
            width: Math.max(parent.height, parent.width * root.batteryFraction)
            radius: parent.radius
            color: root.batteryFillColor

            Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 250 } }
          }

          // Subtle charging shimmer — slides across the filled region while
          // actively charging so the bar reads as "filling" at a glance.
          Rectangle {
            id: shimmer
            visible: root.charging
            width: Math.max(Style.space(40), fillBar.width * 0.35)
            height: parent.height
            radius: parent.radius
            opacity: 0.35
            color: root.bar.background
            x: -width

            NumberAnimation on x {
              running: root.opened && root.charging
              loops: Animation.Infinite
              from: -shimmer.width
              to: fillBar.width
              duration: 1600
              easing.type: Easing.InOutSine
            }
          }
        }

        // ---------- Power & Battery telemetry grid ----------
        PanelSeparator {
          foreground: root.bar.foreground
          visible: metricsGrid.hasAny
        }

        Grid {
          id: metricsGrid
          width: parent.width
          columns: 2
          columnSpacing: Style.space(22)
          rowSpacing: Style.space(6)
          visible: hasAny

          readonly property bool hasAny: !!(
            root.batteryInfo.system_power ||
            root.batteryInfo.ac_power ||
            root.batteryInfo.battery_flow ||
            root.batteryInfo.ac_vi ||
            root.batteryInfo.rails ||
            root.batteryInfo.cpu_gpu ||
            root.batteryInfo.fans ||
            root.batteryInfo.time ||
            root.batteryInfo.health ||
            root.batteryInfo.cycles ||
            root.batteryInfo.temp_volt ||
            root.batteryInfo.threshold
          )
          readonly property real colWidth: (width - columnSpacing) / 2

          InfoPair {
            width: metricsGrid.colWidth
            visible: !!root.batteryInfo.system_power
            label: "System Load"
            value: root.batteryInfo.system_power || ""
          }
          InfoPair {
            width: metricsGrid.colWidth
            visible: !!root.batteryInfo.ac_power
            label: "AC Input"
            value: root.batteryInfo.ac_power || ""
          }
          InfoPair {
            width: metricsGrid.colWidth
            visible: !!root.batteryInfo.battery_flow
            label: "Battery Flow"
            value: root.batteryInfo.battery_flow || ""
          }
          InfoPair {
            width: metricsGrid.colWidth
            visible: !!root.batteryInfo.ac_vi
            label: "Charger V / I"
            value: root.batteryInfo.ac_vi || ""
          }
          InfoPair {
            width: metricsGrid.colWidth
            visible: !!root.batteryInfo.rails
            label: "3.8V / Heatpipe"
            value: root.batteryInfo.rails || ""
          }
          InfoPair {
            width: metricsGrid.colWidth
            visible: !!root.batteryInfo.cpu_gpu
            label: "CPU / dGPU"
            value: root.batteryInfo.cpu_gpu || ""
          }
          InfoPair {
            width: metricsGrid.colWidth
            visible: !!root.batteryInfo.fans
            label: "Cooling Fans"
            value: root.batteryInfo.fans || ""
          }
          InfoPair {
            width: metricsGrid.colWidth
            visible: !!root.batteryInfo.health
            label: "Battery Health"
            value: root.batteryInfo.health || ""
          }
          InfoPair {
            width: metricsGrid.colWidth
            visible: !!root.batteryInfo.cycles
            label: "Cycle Count"
            value: root.batteryInfo.cycles || ""
          }
          InfoPair {
            width: metricsGrid.colWidth
            visible: !!root.batteryInfo.temp_volt
            label: "Temp / Voltage"
            value: root.batteryInfo.temp_volt || ""
          }
          InfoPair {
            width: metricsGrid.colWidth
            visible: !!root.batteryInfo.time
            label: root.discharging ? "Remaining" : "To Full"
            value: root.batteryInfo.time || ""
          }
          InfoPair {
            width: metricsGrid.colWidth
            visible: !!root.batteryInfo.threshold
            label: "Charge Limit"
            value: root.batteryInfo.threshold || ""
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
          visible: root.profiles.length > 0
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.profiles.length > 0

          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }
        }

        // ---------- Battery charge limit picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
          visible: root.hasChargeLimit
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.hasChargeLimit

          PanelSectionHeader {
            text: "CHARGE LIMIT"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: limitRow
            width: parent.width
            spacing: Style.space(6)

            readonly property bool isCustom: root.currentChargeLimit !== 80 && root.currentChargeLimit !== 100
            readonly property real cellWidth: isCustom
              ? (width - spacing * 2) / 3
              : (width - spacing) / 2

            Button {
              width: limitRow.cellWidth
              iconText: "󱐋"
              iconSize: Style.font.title
              text: "80% (Protect)"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: root.currentChargeLimit === 80
              onClicked: root.setChargeLimit(80)
            }

            Button {
              width: limitRow.cellWidth
              iconText: "󰂄"
              iconSize: Style.font.title
              text: "100% (Full)"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: root.currentChargeLimit === 100
              onClicked: root.setChargeLimit(100)
            }

            Button {
              visible: limitRow.isCustom
              width: limitRow.cellWidth
              iconText: "󰢝"
              iconSize: Style.font.title
              text: root.currentChargeLimit + "% (Custom)"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: true
            }
          }
        }

        // ---------- Bar display mode picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "BAR DISPLAY"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: displayModeRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: (width - spacing * 2) / 3

            Button {
              width: displayModeRow.cellWidth
              iconText: "󰁹"
              iconSize: Style.font.title
              text: "Both (% · W)"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: root.displayMode === "both"
              onClicked: root.setDisplayMode("both")
            }

            Button {
              width: displayModeRow.cellWidth
              iconText: "󰏰"
              iconSize: Style.font.title
              text: "Percent (%)"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: root.displayMode === "percentage"
              onClicked: root.setDisplayMode("percentage")
            }

            Button {
              width: displayModeRow.cellWidth
              iconText: "󱐋"
              iconSize: Style.font.title
              text: "Usage (W)"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: root.displayMode === "usage"
              onClicked: root.setDisplayMode("usage")
            }
          }
        }
      }
    }
  }

  component InfoPair: Item {
    property string label: ""
    property string value: ""

    width: parent.width
    implicitHeight: Math.max(pairLabel.implicitHeight, pairValue.implicitHeight)
    height: implicitHeight

    InfoLabel {
      id: pairLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: parent.label
    }

    InfoValue {
      id: pairValue
      anchors.right: parent.right
      anchors.left: pairLabel.right
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      text: parent.value
    }
  }

  component InfoLabel: Text {
    color: Commons.Color.blend(root.bar.foreground, root.bar.background, 0.5)
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.weight: Font.Medium
    elide: Text.ElideRight
  }
}
