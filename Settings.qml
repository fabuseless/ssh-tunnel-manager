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
  // Set only for a create-mode open triggered by "Adopt" on a discovered
  // foreign tunnel — {name, sshHost, localPort, remoteHost, remotePort}.
  property var pendingPrefill: null

  property string nameDraft: ""
  property string sshHostDraft: ""
  property string localPortDraft: ""
  property string remoteHostDraft: "127.0.0.1"
  property string remotePortDraft: ""

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
      root.pendingPrefill = (!root.editId && payload.prefill) ? payload.prefill : null
    } catch (e) {
      root.editId = ""
      root.pendingPrefill = null
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
        return
      }
    }
    if (!root.editing && root.pendingPrefill) {
      var p = root.pendingPrefill
      root.nameDraft = String(p.name || "")
      root.sshHostDraft = String(p.sshHost || "")
      root.localPortDraft = String(p.localPort || "")
      root.remoteHostDraft = String(p.remoteHost || "127.0.0.1")
      root.remotePortDraft = String(p.remotePort || "")
      return
    }
    root.nameDraft = ""
    root.sshHostDraft = ""
    root.localPortDraft = ""
    root.remoteHostDraft = "127.0.0.1"
    root.remotePortDraft = ""
  }

  function currentDraft() {
    return {
      name: root.nameDraft,
      sshHost: root.sshHostDraft,
      localPort: Number(root.localPortDraft),
      remoteHost: root.remoteHostDraft,
      remotePort: Number(root.remotePortDraft)
    }
  }

  // Case-insensitive substring match against the known SSH config hosts,
  // for the host field's suggestion list. Empty query shows all of them.
  function filteredHosts() {
    if (!root.service) return []
    var query = root.sshHostDraft.trim().toLowerCase()
    var all = root.service.sshHosts
    if (!query) return all
    var out = []
    for (var i = 0; i < all.length; i++) {
      if (all[i].toLowerCase().indexOf(query) !== -1) out.push(all[i])
    }
    return out
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
      padding: Style.spacing.popupPadding

      MouseArea { anchors.fill: parent }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        // BorderSurface.padding only *computes* the insets; callers apply
        // them — see hass/Settings.qml for the same convention.
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
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

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: !root.editing && !!root.pendingPrefill
            text: "Adopted from a running tunnel — it keeps running until you stop it separately."
            wrapMode: Text.WordWrap
            color: Color.muted
            font.family: root.family
            font.pixelSize: Style.font.caption
          }

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
                placeholderText: "My Tunnel"
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
              TextField {
                id: hostField
                width: fieldsColumn.width
                text: root.sshHostDraft
                placeholderText: "user@host"
                onTextChanged: root.sshHostDraft = text
              }
              // A themed autocomplete list rather than a ComboBox: an
              // editable ComboBox's `editText` and `currentIndex` are
              // separate state, so setting editText programmatically (as a
              // draft-bound field needs to) never marks anything as
              // "selected" in the dropdown — it only looks picked until the
              // user reopens the list and clicks the same entry again. Here
              // the text field IS the value, always; the list below is just
              // a convenience that writes into the same property.
              //
              // Bounded and independently scrollable: a long ~/.ssh/config
              // must produce a short dropdown, not one that expands the
              // whole form and buries Local Port/Remote Host/Remote Port/
              // Create below every alias. The scrollbar is only forced
              // visible when the list actually overflows the cap, so a
              // short match list shows no persistent scrollbar clutter.
              ScrollView {
                id: hostSuggestionsScroller
                readonly property int maxHeight: Style.space(160)
                width: fieldsColumn.width
                visible: hostField.activeFocus && root.filteredHosts().length > 0
                implicitHeight: Math.min(hostSuggestionsColumn.implicitHeight, maxHeight)
                clip: true
                ScrollBar.vertical.policy: hostSuggestionsColumn.implicitHeight > maxHeight
                  ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded

                Column {
                  id: hostSuggestionsColumn
                  width: hostSuggestionsScroller.availableWidth
                  spacing: Style.spacing.xxs

                  Repeater {
                    model: hostSuggestionsScroller.visible ? root.filteredHosts() : []
                    delegate: Rectangle {
                      id: suggestionRow
                      required property string modelData
                      width: hostSuggestionsColumn.width
                      height: suggestionText.implicitHeight + Style.spacing.sm * 2
                      radius: Style.cornerRadius
                      color: suggestionMouse.containsMouse
                        ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                      Text {
                        id: suggestionText
                        anchors {
                          left: parent.left; right: parent.right
                          verticalCenter: parent.verticalCenter
                          leftMargin: Style.spacing.sm
                        }
                        textFormat: Text.PlainText
                        text: suggestionRow.modelData
                        color: root.foreground
                        font.family: root.family
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }

                      MouseArea {
                        id: suggestionMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                          root.sshHostDraft = suggestionRow.modelData
                          hostField.forceActiveFocus()
                        }
                      }
                    }
                  }
                }
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
                placeholderText: "8080"
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
                placeholderText: "80"
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
