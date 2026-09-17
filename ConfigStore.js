.pragma library

// Client-side-only validation for instant form feedback. tunnel-ctl
// re-validates everything from scratch and is the authoritative boundary —
// this module exists purely so the Settings overlay can show inline errors
// without a subprocess round trip for the common mistakes.

var RESERVED_IDS = ["__proto__", "constructor", "prototype"]

function isReservedId(value) {
  return RESERVED_IDS.indexOf(value) !== -1
}

function isValidPort(value) {
  var n = Number(value)
  return isFinite(n) && Math.floor(n) === n && n >= 1 && n <= 65535
}

function isValidHostToken(value) {
  var s = String(value || "")
  if (s.length === 0 || s.length > 255) return false
  return !/\s/.test(s)
}

// Same scope as tunnel-ctl's validate_whole port_key: a remote tunnel's
// port is opened on the far (sshHost) side, not a local bind at all, so
// it can only collide with ANOTHER remote tunnel to that exact host —
// never with a local/dynamic tunnel's real local port, and never with a
// remote tunnel to a different host reusing the same port number.
function portConflicts(draftType, draftSshHost, localPort, otherTunnel) {
  var otherType = otherTunnel.type || "local"
  if (draftType === "remote") {
    return otherType === "remote"
      && String(otherTunnel.sshHost) === String(draftSshHost)
      && Number(otherTunnel.localPort) === localPort
  }
  return otherType !== "remote" && Number(otherTunnel.localPort) === localPort
}

// Returns { errors: { field: message, ... } } — empty object means valid.
// `existingTunnels` excludes the tunnel being edited (caller's job to filter).
function validate(draft, existingTunnels) {
  var errors = {}
  var type = draft.type || "local"

  var name = String(draft.name || "").trim()
  if (!name) errors.name = "Name is required."
  else if (name.length > 100) errors.name = "Name is too long."

  var sshHost = String(draft.sshHost || "").trim()
  if (!sshHost) errors.sshHost = "Host is required."
  else if (!isValidHostToken(sshHost)) errors.sshHost = "Host cannot contain spaces."

  if (!isValidPort(draft.localPort)) {
    errors.localPort = "Port must be between 1 and 65535."
  } else {
    var localPort = Number(draft.localPort)
    var list = existingTunnels || []
    for (var i = 0; i < list.length; i++) {
      if (portConflicts(type, sshHost, localPort, list[i])) {
        errors.localPort = type === "remote"
          ? "Another remote tunnel to this host already uses port " + localPort + "."
          : "Another tunnel already uses local port " + localPort + "."
        break
      }
    }
  }

  // remoteHost/remotePort are meaningless for a dynamic (SOCKS) tunnel —
  // no fixed destination exists — so they are simply not validated at all
  // for that type.
  if (type !== "dynamic") {
    var remoteHost = String(draft.remoteHost || "127.0.0.1").trim()
    if (!isValidHostToken(remoteHost)) errors.remoteHost = "Host cannot contain spaces."

    if (!isValidPort(draft.remotePort)) {
      errors.remotePort = "Port must be between 1 and 65535."
    }
  }

  return errors
}

function hasErrors(errors) {
  for (var key in errors) return true
  return false
}

// Shapes a draft into the payload tunnel-ctl's add/update actions expect.
function toPayload(draft) {
  var type = draft.type || "local"
  var payload = {
    name: String(draft.name || "").trim(),
    sshHost: String(draft.sshHost || "").trim(),
    localPort: Math.floor(Number(draft.localPort)),
    type: type,
    autoStart: !!draft.autoStart,
    favourite: !!draft.favourite
  }
  // A dynamic (SOCKS) tunnel has no fixed destination — sending stale
  // remoteHost/remotePort values here would be meaningless. The draft's
  // own properties are left untouched so switching tabs never loses
  // what was typed; only the submitted payload is pruned.
  if (type !== "dynamic") {
    payload.remoteHost = String(draft.remoteHost || "127.0.0.1").trim() || "127.0.0.1"
    payload.remotePort = Math.floor(Number(draft.remotePort))
  }
  return payload
}
