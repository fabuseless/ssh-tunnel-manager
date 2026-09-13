import QtQuick
import Quickshell.Io

// Owns every invocation of bin/tunnel-ctl. Every call is an argv array
// appended to `executable` — never a shell string — and each of the three
// process lanes below is independent so a slow `ssh` connect attempt during
// a start/stop action never blocks the next status poll or a settings-form
// CRUD call from going out.
QtObject {
  id: root

  required property string executable

  // ---------------------------------------------------------- status lane

  property var _statusCallback: null

  function runStatus(onDone) {
    if (statusProcess.running) return false
    root._statusCallback = onDone
    statusProcess.command = [root.executable, "status"]
    statusProcess.running = true
    return true
  }

  property Process statusProcess: Process {
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var cb = root._statusCallback
      root._statusCallback = null
      if (cb) cb(exitCode, statusStdout.text, statusStderr.text)
    }
  }

  // ---------------------------------------------------------- action lane
  // start / stop
  //
  // One independent process per tunnel id rather than a single shared
  // lane: toggling tunnel A used to make tunnel B's switch refuse clicks
  // too (start/stop is a network-bound ssh connect that can genuinely
  // take up to ~30s), which felt broken with more than one tunnel around
  // — only ever one of them clickable at a time. Calls for the SAME id
  // still serialize (busy check keyed by id); different ids run fully
  // concurrently.

  property var _actionProcesses: ({})   // id -> Process

  function isActionBusy(id) {
    return root._actionProcesses[id] !== undefined
  }

  function runAction(id, args, onDone) {
    if (root._actionProcesses[id] !== undefined) return false
    var proc = actionProcessComponent.createObject(root, {
      command: [root.executable].concat(args)
    })
    proc._tunnelId = id
    proc._onDone = onDone
    root._actionProcesses[id] = proc
    proc.running = true
    return true
  }

  property Component actionProcessComponent: Component {
    Process {
      property string _tunnelId: ""
      property var _onDone: null
      stdout: StdioCollector { id: actionStdout; waitForEnd: true }
      stderr: StdioCollector { id: actionStderr; waitForEnd: true }
      onExited: function(exitCode) {
        delete root._actionProcesses[_tunnelId]
        var cb = _onDone
        var out = actionStdout.text
        var err = actionStderr.text
        destroy()
        if (cb) cb(exitCode, out, err)
      }
    }
  }

  // ---------------------------------------------------------- crud lane
  // add / update / remove / list-ssh-hosts

  property var _crudCallback: null
  readonly property bool crudBusy: crudProcess.running

  function runCrud(args, onDone) {
    if (crudProcess.running) return false
    root._crudCallback = onDone
    crudProcess.command = [root.executable].concat(args)
    crudProcess.running = true
    return true
  }

  property Process crudProcess: Process {
    running: false
    command: []
    stdout: StdioCollector { id: crudStdout; waitForEnd: true }
    stderr: StdioCollector { id: crudStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var cb = root._crudCallback
      root._crudCallback = null
      if (cb) cb(exitCode, crudStdout.text, crudStderr.text)
    }
  }
}
