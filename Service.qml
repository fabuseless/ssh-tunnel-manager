import QtQuick
import Quickshell

// Owner of all SSH Local Tunnels state: tunnel definitions, live status, and
// action dispatch. A `service` is mounted once per session; the bar widget
// and the settings overlay both reach it through
// `bar.shell.serviceFor("bhh27.ssh-local-tunnels")`.
//
// tunnel-ctl (bin/tunnel-ctl) is the sole owner of tunnels.json and of every
// ssh process — this object only ever shells out to it and reflects the
// result. It never constructs an ssh command itself.
QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/bhh27.ssh-local-tunnels"
  readonly property string ctlPath: pluginDir + "/bin/tunnel-ctl"

  // Injected from the bar-widget's settings (manifest.json's barWidget.schema).
  property var settings: ({})

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(root.setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  readonly property int pollIntervalSec: root.intSetting("pollIntervalSec", 7, 3, 120)

  // [{id, name, sshHost, localPort, remoteHost, remotePort, active}]
  property var tunnels: []
  property var sshHosts: []
  property string lastError: ""

  readonly property int activeCount: {
    root.pendingToggleRevision
    var n = 0
    for (var i = 0; i < root.tunnels.length; i++) {
      if (root.displayActive(root.tunnels[i])) n++
    }
    return n
  }

  property TunnelProcessController controller: TunnelProcessController {
    executable: root.ctlPath
  }

  // ------------------------------------------------------------ optimistic toggles

  // id -> { desired: bool, deadline: ms }. A toggle flips at once in the UI
  // and is corrected by the next status poll or by the action's own failure.
  property var pendingToggles: ({})
  // pendingToggles is mutated in place; bindings need this scalar to notice.
  property int pendingToggleRevision: 0
  readonly property int pendingToggleTimeout: 8000

  function isPending(id) {
    return root.pendingToggles[id] !== undefined
  }

  function displayActive(tunnel) {
    root.pendingToggleRevision
    var pending = root.pendingToggles[tunnel.id]
    if (pending !== undefined) return pending.desired
    return !!tunnel.active
  }

  function setPendingToggle(id, desired) {
    root.pendingToggles[id] = {
      desired: desired,
      deadline: Date.now() + root.pendingToggleTimeout
    }
    root.pendingToggleRevision++
    pendingSweep.running = true
  }

  function clearPendingToggle(id) {
    if (root.pendingToggles[id] === undefined) return
    delete root.pendingToggles[id]
    root.pendingToggleRevision++
  }

  property Timer pendingSweep: Timer {
    interval: 300
    repeat: true
    onTriggered: root.sweepPendingToggles()
  }

  function sweepPendingToggles() {
    var now = Date.now()
    var changed = false
    var stillPending = false
    for (var id in root.pendingToggles) {
      if (root.pendingToggles[id].deadline <= now) {
        delete root.pendingToggles[id]
        changed = true
      } else {
        stillPending = true
      }
    }
    if (changed) root.pendingToggleRevision++
    if (!stillPending) pendingSweep.running = false
  }

  // ------------------------------------------------------------ status polling

  property Timer pollTimer: Timer {
    interval: root.pollIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  // A hung status check (e.g. ssh stuck on a dead network) would otherwise
  // stop polling forever, since runStatus refuses to overlap itself.
  property Timer pollWatchdog: Timer {
    interval: 15000
    repeat: false
    onTriggered: {
      if (root.controller.statusProcess.running) {
        root.controller.statusProcess.running = false
      }
    }
  }

  function refreshStatus() {
    var started = root.controller.runStatus(function(exitCode, stdout, stderr) {
      pollWatchdog.stop()
      if (exitCode !== 0) {
        root.lastError = root.extractError(stdout, stderr, "Status check failed.")
        return
      }
      try {
        var parsed = JSON.parse(stdout)
        if (Array.isArray(parsed)) {
          root.tunnels = parsed
          root.lastError = ""
        }
      } catch (e) {
        // Leave the previous snapshot in place rather than blanking the UI
        // over one malformed poll.
      }
    })
    if (started) pollWatchdog.restart()
  }

  function refreshSshHosts() {
    root.controller.runCrud(["list-ssh-hosts"], function(exitCode, stdout, stderr) {
      if (exitCode !== 0) return
      try {
        var parsed = JSON.parse(stdout)
        if (Array.isArray(parsed)) root.sshHosts = parsed
      } catch (e) {
        // Keep whatever we had.
      }
    })
  }

  // ------------------------------------------------------------ actions

  function tunnelById(id) {
    for (var i = 0; i < root.tunnels.length; i++) {
      if (root.tunnels[i].id === id) return root.tunnels[i]
    }
    return null
  }

  // tunnel-ctl's own failures are single "tunnel-ctl: message" lines on
  // stderr; surface just the message, not the whole invocation noise.
  function extractError(stdout, stderr, fallback) {
    var text = String(stderr || stdout || "").trim()
    if (!text) return fallback
    var marker = "tunnel-ctl: "
    var idx = text.indexOf(marker)
    if (idx !== -1) text = text.slice(idx + marker.length)
    return text.split("\n")[0] || fallback
  }

  function startTunnel(id) {
    if (root.isPending(id)) return
    root.setPendingToggle(id, true)
    root.controller.runAction(["start", id], function(exitCode, stdout, stderr) {
      root.clearPendingToggle(id)
      if (exitCode !== 0) root.lastError = root.extractError(stdout, stderr, "Failed to start tunnel.")
      root.refreshStatus()
    })
  }

  function stopTunnel(id) {
    if (root.isPending(id)) return
    root.setPendingToggle(id, false)
    root.controller.runAction(["stop", id], function(exitCode, stdout, stderr) {
      root.clearPendingToggle(id)
      if (exitCode !== 0) root.lastError = root.extractError(stdout, stderr, "Failed to stop tunnel.")
      root.refreshStatus()
    })
  }

  function toggleTunnel(id) {
    var tunnel = root.tunnelById(id)
    if (!tunnel) return
    if (root.displayActive(tunnel)) root.stopTunnel(id)
    else root.startTunnel(id)
  }

  function createTunnel(draft, onDone) {
    root.controller.runCrud(["add", JSON.stringify(draft)], function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        root.refreshStatus()
        if (onDone) onDone(true, "")
      } else if (onDone) {
        onDone(false, root.extractError(stdout, stderr, "Could not create tunnel."))
      }
    })
  }

  function updateTunnel(id, draft, onDone) {
    root.controller.runCrud(["update", id, JSON.stringify(draft)], function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        root.refreshStatus()
        if (onDone) onDone(true, "")
      } else if (onDone) {
        onDone(false, root.extractError(stdout, stderr, "Could not update tunnel."))
      }
    })
  }

  function deleteTunnel(id, onDone) {
    root.controller.runCrud(["remove", id], function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        root.refreshStatus()
        if (onDone) onDone(true, "")
      } else if (onDone) {
        onDone(false, root.extractError(stdout, stderr, "Could not delete tunnel."))
      }
    })
  }

  Component.onCompleted: {
    root.refreshStatus()
    root.refreshSshHosts()
  }
}
