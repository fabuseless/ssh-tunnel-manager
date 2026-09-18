import QtQuick
import Quickshell

// Owner of all SSH Tunnel Manager state: tunnel definitions, live status, and
// action dispatch. A `service` is mounted once per session; the bar widget
// and the settings overlay both reach it through
// `bar.shell.serviceFor("fabuseless.ssh-tunnel-manager")`.
//
// tunnel-ctl (bin/tunnel-ctl) is the sole owner of tunnels.json and of every
// ssh process — this object only ever shells out to it and reflects the
// result. It never constructs an ssh command itself.
QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/fabuseless.ssh-tunnel-manager"
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

  // [{id, name, sshHost, localPort, remoteHost, remotePort, autoStart,
  //   foreign, active, forwardWarning}].
  // tunnel-ctl silently auto-adopts any foreign ssh -L process it finds
  // running (one not spawned by this plugin), permanently marking it
  // foreign:true (see auto_adopt_new_ports) — Panel.qml uses that to
  // segregate it into a display-and-kill-only section, distinct from a
  // tunnel created through the form.
  property var tunnels: []
  property var sshHosts: []
  property string lastError: ""

  // Whether tunnel-ctl adopts a never-before-seen foreign ssh -L process
  // into `tunnels` automatically. See Settings.qml's Preferences screen.
  property bool autoAdopt: true

  // Whether stopping a tunnel that's actually an autossh-supervised ssh
  // child kills the autossh parent too (so it stays stopped) or just the
  // child (autossh respawns it — a "temporary" stop). See Settings.qml's
  // Preferences screen.
  property bool killAutosshFully: true

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
  // Comfortably above do_start's own worst-case wait (a slow SSH agent
  // can legitimately take 20+ seconds to recover before a connection
  // completes) so a real, still-in-flight start/stop/autoStart call is
  // never reverted by this fallback sweep before the backend's own
  // answer has a chance to arrive.
  readonly property int pendingToggleTimeout: 33000

  function isPending(id) {
    // pendingToggles is mutated in place, so reading it alone never makes
    // a binding that calls this reactive — pendingToggleRevision is the
    // property that actually gets reassigned on every change, so it has
    // to be read here (matching displayActive below) for any binding
    // built on this function to notice pending state changing at all.
    root.pendingToggleRevision
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

  // Same optimistic-flip pattern, for the panel row's auto-restart-on-
  // reboot icon: updateTunnel's round trip (a CRUD call, then a status
  // refresh) was enough lag on its own that the icon looked unresponsive.
  property var pendingAutoStart: ({})
  property int pendingAutoStartRevision: 0

  function isAutoStartPending(id) {
    return root.pendingAutoStart[id] !== undefined
  }

  function displayAutoStart(tunnel) {
    root.pendingAutoStartRevision
    var pending = root.pendingAutoStart[tunnel.id]
    if (pending !== undefined) return pending.desired
    return !!tunnel.autoStart
  }

  function setPendingAutoStart(id, desired) {
    root.pendingAutoStart[id] = {
      desired: desired,
      deadline: Date.now() + root.pendingToggleTimeout
    }
    root.pendingAutoStartRevision++
    pendingSweep.running = true
  }

  function clearPendingAutoStart(id) {
    if (root.pendingAutoStart[id] === undefined) return
    delete root.pendingAutoStart[id]
    root.pendingAutoStartRevision++
  }

  // Same pattern again, for the panel row's favourite star. Kept as its
  // own independent pending map (not folded into pendingAutoStart) since
  // the two fields, while linked by a cascade (see setAutoStart/
  // setFavourite below), are still logically separate and can each be
  // toggled on their own.
  property var pendingFavourite: ({})
  property int pendingFavouriteRevision: 0

  function isFavouritePending(id) {
    return root.pendingFavourite[id] !== undefined
  }

  function displayFavourite(tunnel) {
    root.pendingFavouriteRevision
    var pending = root.pendingFavourite[tunnel.id]
    if (pending !== undefined) return pending.desired
    return !!tunnel.favourite
  }

  function setPendingFavourite(id, desired) {
    root.pendingFavourite[id] = {
      desired: desired,
      deadline: Date.now() + root.pendingToggleTimeout
    }
    root.pendingFavouriteRevision++
    pendingSweep.running = true
  }

  function clearPendingFavourite(id) {
    if (root.pendingFavourite[id] === undefined) return
    delete root.pendingFavourite[id]
    root.pendingFavouriteRevision++
  }

  // Sets autoStart on one tunnel, optimistically, then patches it through
  // the normal update path (which also handles the actual persistence and
  // any restart-if-connection-changed logic — irrelevant here since
  // autoStart alone never changes where a tunnel connects to).
  //
  // Cascade: turning autoStart ON always favourites the tunnel too (the
  // backend enforces this invariant regardless of what gets sent — see
  // do_add/do_update's own cascade — but it's mirrored here as well so
  // the star flips immediately instead of waiting a full round trip).
  // Turning autoStart off alone never touches favourite.
  function setAutoStart(id, desired, onDone) {
    var tunnel = root.tunnelById(id)
    if (!tunnel) return
    root.setPendingAutoStart(id, desired)
    var favouriteCascaded = false
    if (desired) {
      root.setPendingFavourite(id, true)
      favouriteCascaded = true
    }
    var payload = {
      name: tunnel.name,
      sshHost: tunnel.sshHost,
      localPort: tunnel.localPort,
      type: tunnel.type || "local",
      remoteHost: tunnel.remoteHost,
      remotePort: tunnel.remotePort,
      autoStart: desired,
      favourite: desired ? true : !!tunnel.favourite
    }
    root.updateTunnel(id, payload, function(ok, message) {
      // Success: updateTunnel already triggers its own refreshStatus;
      // leave the pending flag(s) for that call's reconcilePending to
      // clear once it confirms the new values, rather than racing it here.
      if (!ok) {
        root.lastError = message
        root.clearPendingAutoStart(id)
        if (favouriteCascaded) root.clearPendingFavourite(id)
      }
      if (onDone) onDone(ok, message)
    })
  }

  // Sets favourite on one tunnel, optimistically, then patches it through
  // the normal update path.
  //
  // Cascade: unfavouriting a tunnel always turns its autoStart off too
  // (mirrored here for the same instant-feedback reason as above — the
  // backend enforces this invariant regardless). Favouriting alone never
  // turns autoStart on.
  function setFavourite(id, desired, onDone) {
    var tunnel = root.tunnelById(id)
    if (!tunnel) return
    root.setPendingFavourite(id, desired)
    var autoStartCascaded = false
    if (!desired) {
      root.setPendingAutoStart(id, false)
      autoStartCascaded = true
    }
    var payload = {
      name: tunnel.name,
      sshHost: tunnel.sshHost,
      localPort: tunnel.localPort,
      type: tunnel.type || "local",
      remoteHost: tunnel.remoteHost,
      remotePort: tunnel.remotePort,
      autoStart: desired ? !!tunnel.autoStart : false,
      favourite: desired
    }
    root.updateTunnel(id, payload, function(ok, message) {
      if (!ok) {
        root.lastError = message
        root.clearPendingFavourite(id)
        if (autoStartCascaded) root.clearPendingAutoStart(id)
      }
      if (onDone) onDone(ok, message)
    })
  }

  property Timer pendingSweep: Timer {
    interval: 300
    repeat: true
    onTriggered: root.sweepPendingState()
  }

  function sweepPendingState() {
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

    changed = false
    for (var id2 in root.pendingAutoStart) {
      if (root.pendingAutoStart[id2].deadline <= now) {
        delete root.pendingAutoStart[id2]
        changed = true
      } else {
        stillPending = true
      }
    }
    if (changed) root.pendingAutoStartRevision++

    changed = false
    for (var id3 in root.pendingFavourite) {
      if (root.pendingFavourite[id3].deadline <= now) {
        delete root.pendingFavourite[id3]
        changed = true
      } else {
        stillPending = true
      }
    }
    if (changed) root.pendingFavouriteRevision++

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
        if (parsed && Array.isArray(parsed.tunnels)) {
          root.tunnels = parsed.tunnels
          root.lastError = ""
          root.reconcilePending()
        }
      } catch (e) {
        // Leave the previous snapshot in place rather than blanking the UI
        // over one malformed poll.
      }
    })
    if (started) pollWatchdog.restart()
  }

  // A pending flag is cleared here — once a fresh status confirms the
  // real value actually matches what was optimistically set — rather
  // than the instant an action's own process exits. That process firing
  // refreshStatus() itself races this exact callback: clearing on exit
  // alone leaves a real gap where pending is gone but root.tunnels is
  // still the pre-action snapshot, so the display falls back to the OLD
  // value for one tick before the fresh data arrives and flips it back —
  // a visible flicker (confirmed live: blue -> grey -> blue on
  // autoStart), not just a theoretical race. A pending entry the fresh
  // data doesn't yet confirm is left alone, so a slow action (a real ssh
  // connect) keeps showing its optimistic state through an unrelated
  // poll tick that lands before it's done, rather than flickering back
  // to stale-old on every such tick.
  function reconcilePending() {
    var changed = false
    for (var id in root.pendingToggles) {
      var t = root.tunnelById(id)
      if (t && !!t.active === root.pendingToggles[id].desired) {
        delete root.pendingToggles[id]
        changed = true
      }
    }
    if (changed) root.pendingToggleRevision++

    changed = false
    for (var id2 in root.pendingAutoStart) {
      var t2 = root.tunnelById(id2)
      if (t2 && !!t2.autoStart === root.pendingAutoStart[id2].desired) {
        delete root.pendingAutoStart[id2]
        changed = true
      }
    }
    if (changed) root.pendingAutoStartRevision++

    changed = false
    for (var id3 in root.pendingFavourite) {
      var t3 = root.tunnelById(id3)
      if (t3 && !!t3.favourite === root.pendingFavourite[id3].desired) {
        delete root.pendingFavourite[id3]
        changed = true
      }
    }
    if (changed) root.pendingFavouriteRevision++
  }

  // Starts every tunnel flagged autoStart on the service's own CRUD lane
  // (idle at this point in startup) instead of the regular status poll —
  // meant to run exactly once, right after the service comes up, never on
  // every poll, which would fight a tunnel the user just stopped by hand.
  function resumeAutoStart() {
    root.controller.runCrud(["resume-auto-start"], function(exitCode, stdout, stderr) {
      if (exitCode !== 0) {
        root.lastError = root.extractError(stdout, stderr, "Status check failed.")
        return
      }
      try {
        var parsed = JSON.parse(stdout)
        if (parsed && Array.isArray(parsed.tunnels)) {
          root.tunnels = parsed.tunnels
          root.lastError = ""
        }
      } catch (e) {
        // Fall back to a normal status poll rather than starting up blank.
        root.refreshStatus()
      }
    })
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

  function refreshPrefs() {
    root.controller.runCrud(["get-prefs"], function(exitCode, stdout, stderr) {
      if (exitCode !== 0) return
      try {
        var parsed = JSON.parse(stdout)
        if (!parsed) return
        if (typeof parsed.autoAdopt === "boolean") root.autoAdopt = parsed.autoAdopt
        if (typeof parsed.killAutosshFully === "boolean") root.killAutosshFully = parsed.killAutosshFully
      } catch (e) {
        // Keep whatever we had.
      }
    })
  }

  function setAutoAdopt(value, onDone) {
    root.controller.runCrud(["set-prefs", JSON.stringify({ autoAdopt: value })],
      function(exitCode, stdout, stderr) {
        if (exitCode === 0) {
          root.autoAdopt = value
          if (onDone) onDone(true, "")
        } else if (onDone) {
          onDone(false, root.extractError(stdout, stderr, "Could not save preference."))
        }
      })
  }

  function setKillAutosshFully(value, onDone) {
    root.controller.runCrud(["set-prefs", JSON.stringify({ killAutosshFully: value })],
      function(exitCode, stdout, stderr) {
        if (exitCode === 0) {
          root.killAutosshFully = value
          if (onDone) onDone(true, "")
        } else if (onDone) {
          onDone(false, root.extractError(stdout, stderr, "Could not save preference."))
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
    // Each tunnel id gets its own action process, but runAction still
    // refuses to overlap a SECOND call for this same id (e.g. a double
    // click) and returns false rather than queuing. Without this check
    // that would silently drop the click entirely — the optimistic flag
    // set above would just sit there until the sweep timeout, looking
    // stuck, while nothing ever actually ran. Clear it immediately
    // instead so another click can retry at once.
    var started = root.controller.runAction(id, ["start", id], function(exitCode, stdout, stderr) {
      // Success: leave the pending flag for refreshStatus's own
      // reconcilePending to clear once it confirms active:true, rather
      // than clearing here and racing that same refreshStatus call below.
      if (exitCode !== 0) {
        root.lastError = root.extractError(stdout, stderr, "Failed to start tunnel.")
        root.clearPendingToggle(id)
      }
      root.refreshStatus()
    })
    if (!started) {
      root.clearPendingToggle(id)
      root.lastError = "This tunnel is already busy — try again in a moment."
    }
  }

  function stopTunnel(id) {
    if (root.isPending(id)) return
    root.setPendingToggle(id, false)
    var started = root.controller.runAction(id, ["stop", id], function(exitCode, stdout, stderr) {
      if (exitCode !== 0) {
        root.lastError = root.extractError(stdout, stderr, "Failed to stop tunnel.")
        root.clearPendingToggle(id)
      }
      root.refreshStatus()
    })
    if (!started) {
      root.clearPendingToggle(id)
      root.lastError = "This tunnel is already busy — try again in a moment."
    }
  }

  function toggleTunnel(id) {
    var tunnel = root.tunnelById(id)
    if (!tunnel) return
    if (root.displayActive(tunnel)) root.stopTunnel(id)
    else root.startTunnel(id)
  }

  // The crud lane also refuses to overlap itself (runCrud returns false
  // rather than queuing) — without checking that, a call made while
  // another is still in flight would never invoke onDone at all, leaving
  // a caller like the tunnel form's submit button waiting forever.
  function createTunnel(draft, onDone) {
    var started = root.controller.runCrud(["add", JSON.stringify(draft)], function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        root.refreshStatus()
        if (onDone) onDone(true, "")
      } else if (onDone) {
        onDone(false, root.extractError(stdout, stderr, "Could not create tunnel."))
      }
    })
    if (!started && onDone) onDone(false, "Another action is still in progress — try again in a moment.")
  }

  function updateTunnel(id, draft, onDone) {
    var started = root.controller.runCrud(["update", id, JSON.stringify(draft)], function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        root.refreshStatus()
        if (onDone) onDone(true, "")
      } else if (onDone) {
        onDone(false, root.extractError(stdout, stderr, "Could not update tunnel."))
      }
    })
    if (!started && onDone) onDone(false, "Another action is still in progress — try again in a moment.")
  }

  function deleteTunnel(id, onDone) {
    var started = root.controller.runCrud(["remove", id], function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        root.refreshStatus()
        if (onDone) onDone(true, "")
      } else if (onDone) {
        onDone(false, root.extractError(stdout, stderr, "Could not delete tunnel."))
      }
    })
    if (!started && onDone) onDone(false, "Another action is still in progress — try again in a moment.")
  }

  Component.onCompleted: {
    root.resumeAutoStart()
    root.refreshSshHosts()
    root.refreshPrefs()
  }
}
