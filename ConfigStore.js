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

// Returns { errors: { field: message, ... } } — empty object means valid.
// `existingTunnels` excludes the tunnel being edited (caller's job to filter).
function validate(draft, existingTunnels) {
  var errors = {}

  var name = String(draft.name || "").trim()
  if (!name) errors.name = "Name is required."
  else if (name.length > 100) errors.name = "Name is too long."

  var sshHost = String(draft.sshHost || "").trim()
  if (!sshHost) errors.sshHost = "Host is required."
  else if (!isValidHostToken(sshHost)) errors.sshHost = "Host cannot contain spaces."

  if (!isValidPort(draft.localPort)) {
    errors.localPort = "Local port must be between 1 and 65535."
  } else {
    var localPort = Number(draft.localPort)
    var list = existingTunnels || []
    for (var i = 0; i < list.length; i++) {
      if (Number(list[i].localPort) === localPort) {
        errors.localPort = "Another tunnel already uses local port " + localPort + "."
        break
      }
    }
  }

  var remoteHost = String(draft.remoteHost || "127.0.0.1").trim()
  if (!isValidHostToken(remoteHost)) errors.remoteHost = "Remote host cannot contain spaces."

  if (!isValidPort(draft.remotePort)) {
    errors.remotePort = "Remote port must be between 1 and 65535."
  }

  return errors
}

function hasErrors(errors) {
  for (var key in errors) return true
  return false
}

// Shapes a draft into the payload tunnel-ctl's add/update actions expect.
function toPayload(draft) {
  return {
    name: String(draft.name || "").trim(),
    sshHost: String(draft.sshHost || "").trim(),
    localPort: Math.floor(Number(draft.localPort)),
    remoteHost: String(draft.remoteHost || "127.0.0.1").trim() || "127.0.0.1",
    remotePort: Math.floor(Number(draft.remotePort)),
    favorite: !!draft.favorite
  }
}
