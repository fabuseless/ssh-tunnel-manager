import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "ConfigStore.js" as ConfigStore

// Create/edit tunnel form.
//
// Summoned by the shell, not by IPC — Panel.qml already owns the
// "ssh-local-tunnels" target and a target routes to one handler.
//   omarchy-shell shell summon bhh27.ssh-local-tunnels '{"editId":"<id>"}'
Item {
  id: root

  // Injected by the shell's overlay loader.
  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  property string editId: ""   // "" means create mode

  property string nameDraft: ""
  property string sshHostDraft: ""
  property string localPortDraft: ""
  property string remoteHostDraft: "127.0.0.1"
  property string remotePortDraft: ""
  property bool favoriteDraft: false

  property var fieldErrors: ({})
  property string formError: ""
  property bool saving: false

  readonly property bool editing: root.editId !== ""

  readonly property color foreground: Color.menu.text
  readonly property string family: Style.font.family
  readonly property color background: Color.menu.background
  readonly property var borderSpec: Border.surfaceSpec(
    "menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

  function open(payloadJson) {
    root.opened = true
    root.formError = ""
    root.fieldErrors = ({})
    root.saving = false
    try {
      var payload = payloadJson ? JSON.parse(payloadJson) : {}
      root.editId = String(payload.editId || "")
    } catch (e) {
      root.editId = ""
    }
    root.resetDrafts()
    if (root.service) root.service.refreshSshHosts()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") {
      root.shell.hide((root.manifest && root.manifest.id) || "bhh27.ssh-local-tunnels")
    }
  }

  function resetDrafts() {
    if (root.editing && root.service) {
      var tunnel = root.service.tunnelById(root.editId)
      if (tunnel) {
        root.nameDraft = tunnel.name
        root.sshHostDraft = tunnel.sshHost
        root.localPortDraft = String(tunnel.localPort)
        root.remoteHostDraft = tunnel.remoteHost
        root.remotePortDraft = String(tunnel.remotePort)
        root.favoriteDraft = !!tunnel.favorite
        return
      }
    }
    root.nameDraft = ""
    root.sshHostDraft = ""
    root.localPortDraft = ""
    root.remoteHostDraft = "127.0.0.1"
    root.remotePortDraft = ""
    root.favoriteDraft = false
  }

  function currentDraft() {
    return {
      name: root.nameDraft,
      sshHost: root.sshHostDraft,
      localPort: Number(root.localPortDraft),
      remoteHost: root.remoteHostDraft,
      remotePort: Number(root.remotePortDraft),
      favorite: root.favoriteDraft
    }
  }

  // Excludes the tunnel being edited, so its own port isn't flagged as a
  // collision with itself.
  function otherTunnels() {
    if (!root.service) return []
    var out = []
    var all = root.service.tunnels
    for (var i = 0; i < all.length; i++) {
      if (all[i].id !== root.editId) out.push(all[i])
    }
    return out
  }

  function save() {
    if (!root.service || root.saving) return
    var draft = root.currentDraft()
    var errors = ConfigStore.validate(draft, root.otherTunnels())
    root.fieldErrors = errors
    if (ConfigStore.hasErrors(errors)) return

    var payload = ConfigStore.toPayload(draft)
    root.saving = true
    root.formError = ""
    var onDone = function(ok, message) {
      root.saving = false
      if (ok) root.dismiss()
      else root.formError = message
    }
    if (root.editing) root.service.updateTunnel(root.editId, payload, onDone)
    else root.service.createTunnel(payload, onDone)
  }

  function remove() {
    if (!root.service || !root.editing || root.saving) return
    root.saving = true
    root.service.deleteTunnel(root.editId, function(ok, message) {
      root.saving = false
      if (ok) root.dismiss()
      else root.formError = message
    })
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "ssh-local-tunnels-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(460), window.width - Style.gapsOut * 2)
      height: Math.min(Style.space(560), window.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        onCloseRequested: root.dismiss()

        ColumnLayout {
          id: formColumn
          anchors.fill: parent
          spacing: Style.spacing.lg

          Text {
            textFormat: Text.PlainText
            text: root.editing ? "Edit tunnel" : "New tunnel"
            color: root.foreground
            font.family: root.family
            font.pixelSize: Style.font.title
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            ScrollBar.vertical.policy: ScrollBar.AsNeeded

            Column {
              id: fieldsColumn
              width: formColumn.width
              spacing: Style.spacing.md

              Text {
                textFormat: Text.PlainText
                text: "Name"
                color: Color.muted
                font.family: root.family
                font.pixelSize: Style.font.bodySmall
              }
              TextField {
                width: fieldsColumn.width
                text: root.nameDraft
                placeholderText: "Framework VNC"
                onTextChanged: root.nameDraft = text
              }
              Text {
                textFormat: Text.PlainText
                visible: !!root.fieldErrors.name
                text: root.fieldErrors.name || ""
                color: Color.urgent
                font.family: root.family
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                text: "Host"
                color: Color.muted
                font.family: root.family
                font.pixelSize: Style.font.bodySmall
              }
              ComboBox {
                id: hostCombo
                width: fieldsColumn.width
                editable: true
                model: root.service ? root.service.sshHosts : []
                editText: root.sshHostDraft
                onEditTextChanged: root.sshHostDraft = editText
                Component.onCompleted: editText = root.sshHostDraft
              }
              Text {
                textFormat: Text.PlainText
                width: fieldsColumn.width
                text: "Pick a Host from ~/.ssh/config, or type any user@host."
                wrapMode: Text.WordWrap
                color: Color.muted
                font.family: root.family
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                visible: !!root.fieldErrors.sshHost
                text: root.fieldErrors.sshHost || ""
                color: Color.urgent
                font.family: root.family
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                text: "Local port"
                color: Color.muted
                font.family: root.family
                font.pixelSize: Style.font.bodySmall
              }
              TextField {
                width: fieldsColumn.width
                text: root.localPortDraft
                placeholderText: "5900"
                validator: IntValidator { bottom: 1; top: 65535 }
                onTextChanged: root.localPortDraft = text
              }
              Text {
                textFormat: Text.PlainText
                visible: !!root.fieldErrors.localPort
                text: root.fieldErrors.localPort || ""
                color: Color.urgent
                font.family: root.family
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                text: "Remote host"
                color: Color.muted
                font.family: root.family
                font.pixelSize: Style.font.bodySmall
              }
              TextField {
                width: fieldsColumn.width
                text: root.remoteHostDraft
                placeholderText: "127.0.0.1"
                onTextChanged: root.remoteHostDraft = text
              }
              Text {
                textFormat: Text.PlainText
                visible: !!root.fieldErrors.remoteHost
                text: root.fieldErrors.remoteHost || ""
                color: Color.urgent
                font.family: root.family
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                text: "Remote port"
                color: Color.muted
                font.family: root.family
                font.pixelSize: Style.font.bodySmall
              }
              TextField {
                width: fieldsColumn.width
                text: root.remotePortDraft
                placeholderText: "5900"
                validator: IntValidator { bottom: 1; top: 65535 }
                onTextChanged: root.remotePortDraft = text
              }
              Text {
                textFormat: Text.PlainText
                visible: !!root.fieldErrors.remotePort
                text: root.fieldErrors.remotePort || ""
                color: Color.urgent
                font.family: root.family
                font.pixelSize: Style.font.caption
              }

              Toggle {
                width: fieldsColumn.width
                label: "Favorite"
                description: "Toggle this tunnel directly from the bar icon."
                checked: root.favoriteDraft
                foreground: root.foreground
                fontFamily: root.family
                onClicked: root.favoriteDraft = !root.favoriteDraft
              }

              Text {
                textFormat: Text.PlainText
                visible: root.formError !== ""
                width: fieldsColumn.width
                text: root.formError
                wrapMode: Text.WordWrap
                color: Color.urgent
                font.family: root.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          Row {
            id: actionRow
            spacing: Style.spacing.xl

            Button {
              bordered: true
              text: root.saving ? "Saving…" : (root.editing ? "Save" : "Create")
              opacity: root.saving ? 0.6 : 1.0
              foreground: root.foreground
              fontFamily: root.family
              onClicked: root.save()
            }

            Button {
              bordered: true
              text: "Cancel"
              foreground: root.foreground
              fontFamily: root.family
              onClicked: root.dismiss()
            }

            Button {
              visible: root.editing
              bordered: true
              text: "Delete"
              foreground: Color.urgent
              fontFamily: root.family
              onClicked: root.remove()
            }
          }
        }
      }
    }
  }
}
