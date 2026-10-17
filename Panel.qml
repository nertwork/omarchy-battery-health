import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "nertwork.power"
  ipcTarget: "nertwork.power"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false
  readonly property bool showPercentage: setting("showPercentage", false) === true
  readonly property bool showWatts: setting("showWatts", true) !== false
  property int currentChargeLimit: 80
  property bool hasChargeLimit: false

  readonly property string telemetryScriptPath: {
    var url = String(Qt.resolvedUrl("bin/power-telemetry.sh"))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url)
  }

  FileView {
    id: chargeLimitFile
    path: "/sys/class/power_supply/macsmc-battery/charge_control_end_threshold"
    watchChanges: true
    printErrors: false
    blockAllReads: true
    onFileChanged: reload()
    onLoaded: root.updateLimit()
    onLoadFailed: root.hasChargeLimit = false
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
    root.hasChargeLimit = false
  }

  Component.onCompleted: {
    updateLimit()
    if (!batteryProc.running) batteryProc.running = true
  }
  readonly property bool hasBarText: (showPercentage || showWatts) && !button.vertical
  readonly property string barText: {
    if (button.vertical) return root.batteryIcon()
    var pct = Math.round(root.batteryFraction * 100) + "%"
    var watts = root.batteryInfo.system_power_short || root.batteryInfo.system_power || ""
    var parts = []
    if (root.showPercentage) parts.push(pct)
    if (root.showWatts && watts) parts.push(watts)
    if (parts.length === 0) return root.batteryIcon()
    return parts.join(" · ") + "  " + root.batteryIcon()
  }
  // With percentage/wattage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: hasBarText ? button.glyphPaintedWidth : 0
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
    return root.bar ? root.bar.foreground : Color.foreground
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
    if (targetName === "battery") batteryInfo = next
    else systemInfo = next
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    actionProc.running = true
  }

  function togglePercentage() {
    var nextPct = root.showPercentage
    var nextWatts = root.showWatts
    if (!root.showPercentage && root.showWatts) {
      nextPct = true; nextWatts = true
    } else if (root.showPercentage && root.showWatts) {
      nextPct = true; nextWatts = false
    } else if (root.showPercentage && !root.showWatts) {
      nextPct = false; nextWatts = false
    } else {
      nextPct = false; nextWatts = true
    }
    root.settings = Object.assign({}, root.settings, { showPercentage: nextPct, showWatts: nextWatts })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
    if (nextWatts && !batteryProc.running) batteryProc.running = true
  }

  IpcHandler {
    target: "omarchy.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
    function toggleChargeLimit() { root.toggleChargeLimit() }
    function setChargeLimit(limit: string) { root.setChargeLimit(parseInt(limit)) }
  }

  IpcHandler {
    target: "nertwork.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
    function toggleChargeLimit() { root.toggleChargeLimit() }
    function setChargeLimit(limit: string) { root.setChargeLimit(parseInt(limit)) }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
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
    onExited: root.refresh()
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
    chargeLimitProc.command = ["omarchy", "battery", "charge", "limit", String(limit)]
    chargeLimitProc.running = true
  }

  function toggleChargeLimit() {
    setChargeLimit(root.currentChargeLimit === 80 ? 100 : 80)
  }

  Timer { interval: 2000; running: root.opened; repeat: true; onTriggered: root.refresh() }
  Timer {
    interval: 5000
    running: !root.opened && root.batteryPresent && root.showWatts
    repeat: true
    onTriggered: if (!batteryProc.running) batteryProc.running = true
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
    text: root.barText
    slotSize: !vertical && root.hasBarText ? Math.max(Style.bar.iconSlot, Math.ceil(button.glyphPaintedWidth + Style.space(14))) : Style.bar.iconSlot
    tooltipText: {
      var load = root.batteryInfo.system_power ? "Load: " + root.batteryInfo.system_power + " · " : ""
      return load + (root.hasChargeLimit ? "Left: Open · Middle: Limit (" + root.currentChargeLimit + "%) · Right: Bar Mode" : "Left: Open · Right: Bar Mode")
    }
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
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
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.batteryInfo.percentage || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Battery progress bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Stats ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the section never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(24)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.space(8)
            InfoPair { label: "System load"; value: root.batteryInfo.system_power || "—" }
            InfoPair { label: "AC input"; value: root.batteryInfo.ac_power || (root.discharging ? "Offline" : "—") }
            InfoPair {
              visible: !!root.batteryInfo.rails
              label: "3.8V / Heatpipe"
              value: root.batteryInfo.rails || "—"
            }
            InfoPair { label: "Battery health"; value: root.batteryInfo.health || root.batteryInfo.size || "—" }
            InfoPair { label: "Charge cycles"; value: root.batteryInfo.cycles || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.space(8)
            InfoPair { label: "Battery flow"; value: root.batteryInfo.battery_flow || (root.chargeThresholdActive ? "Holding" : (root.batteryInfo.rate || "—")) }
            InfoPair {
              label: (!root.discharging && root.batteryInfo.ac_vi) ? "Charger V / I" : (root.discharging ? "Time left" : "Time to full")
              value: (!root.discharging && root.batteryInfo.ac_vi) ? root.batteryInfo.ac_vi : (root.batteryFlowIdle ? "—" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              visible: !!root.batteryInfo.fans
              label: "Fans"
              value: root.batteryInfo.fans || "—"
            }
            InfoPair {
              label: root.chargeThresholdActive ? "Charge limit" : (root.discharging ? "Time left" : "Time to full")
              value: root.chargeThresholdActive ? (root.batteryInfo.threshold || (root.currentChargeLimit ? root.currentChargeLimit + "%" : "—")) : (root.batteryFlowIdle ? "—" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              visible: !!root.batteryInfo.temp_volt
              label: "Temp / Voltage"
              value: root.batteryInfo.temp_volt || "—"
            }
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

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
      elide: Text.ElideRight
      text: parent.value
    }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
