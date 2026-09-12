import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar button plus popup panel. The service owns tunnel state and process
// dispatch; this file only renders it and forwards clicks.
Panel {
  id: root
  moduleName: "bhh27.ssh-local-tunnels"
  ipcTarget: "ssh-local-tunnels"
  manageIpc: false

  readonly property var svc: bar && bar.shell
    ? bar.shell.serviceFor("bhh27.ssh-local-tunnels") : null
  readonly property bool serviceReady: svc !== null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.4)

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
    bar.shell.summon("bhh27.ssh-local-tunnels",
      JSON.stringify({ editId: tunnelId || "" }))
  }

  // Opens the create form pre-filled from a discovered foreign tunnel. The
  // already-running foreign process is left untouched — adopting only
  // saves a definition; it starts using the normal ControlMaster path the
  // next time it's actually (re)started through the plugin.
  function openAdopt(discovered) {
    if (!bar || !bar.shell || typeof bar.shell.summon !== "function") return
    close()
    bar.shell.summon("bhh27.ssh-local-tunnels", JSON.stringify({
      editId: "",
      prefill: {
        name: discovered.sshHost,
        sshHost: discovered.sshHost,
        localPort: discovered.localPort,
        remoteHost: discovered.remoteHost || "127.0.0.1",
        remotePort: discovered.remotePort
      }
    }))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "ssh-local-tunnels"

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
      if (!root.serviceReady) return "SSH Local Tunnels — click to manage"
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
      onCloseRequested: root.close()

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.spacing.panelGap

        PanelHero {
          width: parent.width
          title: "SSH Local Tunnels"
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
              ? "The SSH Local Tunnels service did not start."
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
          visible: root.serviceReady && root.svc.tunnels.length > 0
          width: parent.width
          implicitHeight: Math.min(rowsColumn.implicitHeight, Style.space(360))
          clip: true
          ScrollBar.vertical.policy: ScrollBar.AsNeeded

          Column {
            id: rowsColumn
            width: listScroller.availableWidth
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

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - toggleSwitch.width
                    - editBtn.width - (Style.spacing.md * 2)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    width: parent.width
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.sshHost + ":" + modelData.localPort
                      + " → " + modelData.remoteHost + ":" + modelData.remotePort
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
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

                ToggleSwitch {
                  id: toggleSwitch
                  anchors.verticalCenter: parent.verticalCenter
                  checked: parent.tunnelActive
                  busy: parent.tunnelBusy
                  foreground: root.foreground
                  accent: Color.accent
                  onToggled: if (root.serviceReady) root.svc.toggleTunnel(modelData.id)
                }
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foreground
          visible: root.serviceReady && root.svc.discoveredTunnels.length > 0
        }

        Text {
          textFormat: Text.PlainText
          visible: root.serviceReady && root.svc.discoveredTunnels.length > 0
          text: "OTHER ACTIVE TUNNELS"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Foreign ssh -L processes found running on the system, not
        // created through this plugin — see Service.qml's
        // discoveredTunnels. Stop uses a narrowly-scoped, pid+start-time
        // verified kill (see bin/tunnel-ctl's security invariants); Adopt
        // just saves a matching definition without touching the running
        // process.
        ScrollView {
          id: discoveredScroller
          visible: root.serviceReady && root.svc.discoveredTunnels.length > 0
          width: parent.width
          implicitHeight: Math.min(discoveredColumn.implicitHeight, Style.space(240))
          clip: true
          ScrollBar.vertical.policy: ScrollBar.AsNeeded

          Column {
            id: discoveredColumn
            width: discoveredScroller.availableWidth
            spacing: Style.spacing.md

            Repeater {
              model: root.serviceReady ? root.svc.discoveredTunnels : null

              delegate: Row {
                required property var modelData
                width: discoveredColumn.width
                spacing: Style.spacing.md

                readonly property bool stopBusy: root.serviceReady
                  && root.svc.isForeignStopPending(modelData.pid)

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - stopBtn.width - adoptBtn.width - (Style.spacing.md * 2)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.sshHost + ":" + modelData.localPort
                      + " → " + (modelData.remoteHost || "unknown") + ":" + modelData.remotePort
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    width: parent.width
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "not managed by this plugin"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                PanelActionButton {
                  id: adoptBtn
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "✎"   // pencil, matching the managed-list edit affordance
                  tooltipText: "Adopt into managed list"
                  foreground: Qt.darker(root.foreground, 1.4)
                  fontFamily: root.fontFamily
                  fontSize: Style.font.icon + 4
                  onClicked: root.openAdopt(modelData)
                }

                PanelActionButton {
                  id: stopBtn
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "⏻"
                  tooltipText: "Stop"
                  foreground: Color.urgent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.icon + 4
                  enabled: !stopBusy
                  onClicked: if (root.serviceReady) {
                    root.svc.stopForeignTunnel(modelData.pid, modelData.startTicks)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
