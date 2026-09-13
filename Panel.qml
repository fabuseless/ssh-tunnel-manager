import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar button plus popup panel. The service owns tunnel state and process
// dispatch; this file only renders it and forwards clicks.
Panel {
  id: root
  moduleName: "bhh27.ssh-tunnel-manager"
  ipcTarget: "ssh-tunnel-manager"
  manageIpc: false

  readonly property var svc: bar && bar.shell
    ? bar.shell.serviceFor("bhh27.ssh-tunnel-manager") : null
  readonly property bool serviceReady: svc !== null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.4)

  // "" means no delete confirmation is open.
  property string deleteConfirmId: ""

  // A literal glyph (fa-link), matching the "any Nerd Font character works"
  // convention used elsewhere in the shell.
  readonly property string icon: ""

  readonly property color barIconColor: {
    var base = bar ? bar.barForeground : Color.foreground
    return serviceReady && svc.activeCount > 0 ? base : Qt.darker(base, 1.55)
  }

  function openSettings(tunnelId) {
    if (!bar || !bar.shell || typeof bar.shell.summon !== "function") return
    close()
    bar.shell.summon("bhh27.ssh-tunnel-manager",
      JSON.stringify({ editId: tunnelId || "" }))
  }

  function openPreferences() {
    if (!bar || !bar.shell || typeof bar.shell.summon !== "function") return
    close()
    bar.shell.summon("bhh27.ssh-tunnel-manager",
      JSON.stringify({ mode: "preferences" }))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (!root.opened) root.deleteConfirmId = ""

  IpcHandler {
    target: "ssh-tunnel-manager"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function start(id: string): string {
      if (!root.serviceReady) return "service unavailable"
      if (!root.svc.tunnelById(id)) return "unknown tunnel " + id
      root.svc.startTunnel(id)
      return "ok"
    }

    function stop(id: string): string {
      if (!root.serviceReady) return "service unavailable"
      if (!root.svc.tunnelById(id)) return "unknown tunnel " + id
      root.svc.stopTunnel(id)
      return "ok"
    }

    function status(): string {
      if (!root.serviceReady) return "service: UNREACHABLE"
      return JSON.stringify(root.svc.tunnels)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    foreground: root.barIconColor
    active: root.serviceReady && root.svc.lastError !== ""
    tooltipText: {
      if (!root.serviceReady) return "SSH Tunnel Manager — click to manage"
      var count = root.svc.activeCount
      if (count === 0) return "No tunnels connected"
      return count + (count === 1 ? " tunnel connected" : " tunnels connected")
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) {
        if (root.serviceReady) root.svc.refreshStatus()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (root.deleteConfirmId !== "") root.deleteConfirmId = ""
        else root.close()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.spacing.panelGap

        PanelHero {
          width: parent.width
          title: "SSH Tunnel Manager"
          meta: root.serviceReady
            ? (root.svc.activeCount + " active of " + root.svc.tunnels.length)
            : "Service unavailable"
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Text {
            textFormat: Text.PlainText
            text: root.icon
            color: root.barIconColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }

          trailingControl: Component {
            Row {
              spacing: Style.spacing.sm

              PanelActionButton {
                iconText: ""   // fa-gear
                tooltipText: "Preferences"
                foreground: Qt.darker(root.foreground, 1.4)
                fontFamily: root.fontFamily
                fontSize: Style.font.icon + 4
                onClicked: root.openPreferences()
              }

              PanelActionButton {
                iconText: "+"
                tooltipText: "New tunnel"
                foreground: Qt.darker(root.foreground, 1.4)
                fontFamily: root.fontFamily
                fontSize: Style.font.icon + 4
                onClicked: root.openSettings("")
              }
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.foreground }

        Text {
          textFormat: Text.PlainText
          visible: root.serviceReady && root.svc.lastError !== ""
          width: parent.width
          text: root.serviceReady ? root.svc.lastError : ""
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Column {
          width: parent.width
          visible: !root.serviceReady || root.svc.tunnels.length === 0
          spacing: Style.spacing.xl

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: !root.serviceReady
              ? "The SSH Tunnel Manager service did not start."
              : "No tunnels yet. Add one to get started."
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            visible: root.serviceReady
            bordered: true
            text: "New tunnel"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openSettings("")
          }
        }

        ScrollView {
          id: listScroller
          readonly property int maxHeight: Style.space(360)
          visible: root.serviceReady && root.svc.tunnels.length > 0
          width: parent.width
          implicitHeight: Math.min(rowsColumn.implicitHeight, maxHeight)
          clip: true
          // AlwaysOn (not just AsNeeded) once the list actually overflows,
          // matching Settings.qml's host-suggestions scroller — otherwise
          // a long list cuts off after the last visible row with no cue
          // that more tunnels exist below.
          ScrollBar.vertical.policy: rowsColumn.implicitHeight > maxHeight
            ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded

          Column {
            id: rowsColumn
            // A small gap so the toggle switch doesn't sit flush against
            // the scrollbar when it's showing.
            width: listScroller.availableWidth - Style.spacing.md
            spacing: Style.spacing.md

            Repeater {
              model: root.serviceReady ? root.svc.tunnels : null

              delegate: Row {
                required property var modelData
                width: rowsColumn.width
                spacing: Style.spacing.md

                readonly property bool tunnelActive: {
                  // Referenced first so this binding re-evaluates whenever an
                  // optimistic toggle flips or clears (see Service.qml).
                  if (root.serviceReady) root.svc.pendingToggleRevision
                  return root.serviceReady ? root.svc.displayActive(modelData) : false
                }
                readonly property bool tunnelBusy: root.serviceReady
                  && root.svc.isPending(modelData.id)

                Item {
                  id: textArea
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - toggleSwitch.width - editBtn.width
                    - deleteBtn.width - autoStartBtn.width - (Style.spacing.md * 4)
                  height: textColumn.implicitHeight

                  // At rest, both lines elide as before. While this row's
                  // text area is hovered, a line too long to fit instead
                  // marquee-scrolls to reveal the rest — same technique as
                  // the media bar widget's now-playing title
                  // (plugins/services/media/BarWidget.qml), but gated on
                  // hover rather than always-on since several long tunnel
                  // entries scrolling at once in a list would look busy.
                  //
                  // The hover MouseArea lives on this plain Item, not on
                  // the Column below — a Column (like any positioner)
                  // breaks entirely if a direct child uses anchors.
                  property bool hovered: false

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                    onEntered: textArea.hovered = true
                    onExited: textArea.hovered = false
                  }

                  Column {
                    id: textColumn
                    width: parent.width

                    Item {
                      id: nameClip
                      width: textColumn.width
                      height: nameText.implicitHeight
                      clip: true

                      Text {
                        id: nameText
                        textFormat: Text.PlainText
                        text: modelData.name
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        elide: textArea.hovered ? Text.ElideNone : Text.ElideRight
                        width: textArea.hovered ? implicitWidth : nameClip.width

                        readonly property bool needsScroll: implicitWidth > nameClip.width

                        NumberAnimation on x {
                          running: nameText.needsScroll && textArea.hovered
                          loops: Animation.Infinite
                          duration: Math.max(3000, nameText.implicitWidth * 25)
                          from: 0
                          to: -(nameText.implicitWidth - nameClip.width)
                          easing.type: Easing.Linear
                          onRunningChanged: if (!running) nameText.x = 0
                        }
                      }
                    }

                    Item {
                      id: subtitleClip
                      width: textColumn.width
                      height: subtitleText.implicitHeight
                      clip: true

                      Text {
                        id: subtitleText
                        textFormat: Text.PlainText
                        text: modelData.sshHost + ":" + modelData.localPort
                          + " → " + modelData.remoteHost + ":" + modelData.remotePort
                          + (modelData.forwardWarning ? "  (" + modelData.forwardWarning + ")" : "")
                        color: modelData.forwardWarning ? Color.urgent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: textArea.hovered ? Text.ElideNone : Text.ElideRight
                        width: textArea.hovered ? implicitWidth : subtitleClip.width

                        readonly property bool needsScroll: implicitWidth > subtitleClip.width

                        NumberAnimation on x {
                          running: subtitleText.needsScroll && textArea.hovered
                          loops: Animation.Infinite
                          duration: Math.max(3000, subtitleText.implicitWidth * 25)
                          from: 0
                          to: -(subtitleText.implicitWidth - subtitleClip.width)
                          easing.type: Easing.Linear
                          onRunningChanged: if (!running) subtitleText.x = 0
                        }
                      }
                    }
                  }
                }

                PanelActionButton {
                  id: editBtn
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "✎"   // pencil
                  tooltipText: "Edit"
                  foreground: Qt.darker(root.foreground, 1.4)
                  fontFamily: root.fontFamily
                  fontSize: Style.font.icon + 4
                  onClicked: root.openSettings(modelData.id)
                }

                PanelActionButton {
                  id: deleteBtn
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""   // fa-trash
                  tooltipText: "Delete"
                  foreground: Qt.darker(root.foreground, 1.4)
                  hoverColor: Color.urgent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.icon + 4
                  onClicked: {
                    if (!root.serviceReady) return
                    root.deleteConfirmId = modelData.id
                  }
                }

                PanelActionButton {
                  id: autoStartBtn
                  readonly property bool autoStartOn: root.serviceReady && root.svc.displayAutoStart(modelData)
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "\uf021"   // fa-refresh
                  tooltipText: autoStartOn
                    ? "Auto-restart on reboot: on" : "Auto-restart on reboot: off"
                  foreground: autoStartOn ? Color.accent : Qt.darker(root.foreground, 1.4)
                  fontFamily: root.fontFamily
                  fontSize: Style.font.icon + 4
                  onClicked: {
                    if (!root.serviceReady) return
                    root.svc.setAutoStart(modelData.id, !autoStartOn, function(ok, message) {
                      if (!ok) root.svc.lastError = message
                    })
                  }
                }

                ToggleSwitch {
                  id: toggleSwitch
                  anchors.verticalCenter: parent.verticalCenter
                  checked: parent.tunnelActive
                  busy: parent.tunnelBusy
                  // ToggleSwitch's own "busy" flag only swallows clicks —
                  // it has no visual treatment of its own (shared across
                  // every plugin, not this one's to change). A busy click
                  // here can legitimately mean "still connecting" for up
                  // to ~30s (a slow SSH agent), so without some visible
                  // cue an ignored click just looks broken. Dim locally
                  // instead of touching the shared component.
                  opacity: busy ? 0.5 : 1.0
                  Behavior on opacity { NumberAnimation { duration: 120 } }
                  foreground: root.foreground
                  accent: Color.accent
                  onToggled: if (root.serviceReady) root.svc.toggleTunnel(modelData.id)
                }
              }
            }
          }
        }
      }

      // Declared after column so it paints on top and blocks clicks to the
      // row list underneath while open.
      ConfirmDialog {
        id: deleteConfirm
        anchors.fill: parent
        opened: root.deleteConfirmId !== ""
        message: {
          var tunnel = root.serviceReady ? root.svc.tunnelById(root.deleteConfirmId) : null
          var name = tunnel ? tunnel.name : ""
          return "Delete “" + name + "”? If it's currently enabled, it will be disabled before deletion."
        }
        confirmText: "Delete"
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        cornerRadius: Style.cornerRadius
        onCanceled: root.deleteConfirmId = ""
        onConfirmed: {
          var id = root.deleteConfirmId
          root.deleteConfirmId = ""
          if (!root.serviceReady) return
          root.svc.deleteTunnel(id, function(ok, message) {
            if (!ok) root.svc.lastError = message
          })
        }
      }
    }
  }
}
