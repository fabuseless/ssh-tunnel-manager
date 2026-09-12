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

  property var _actionCallback: null
  readonly property bool actionBusy: actionProcess.running

  function runAction(args, onDone) {
    if (actionProcess.running) return false
    root._actionCallback = onDone
    actionProcess.command = [root.executable].concat(args)
    actionProcess.running = true
    return true
  }

  property Process actionProcess: Process {
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var cb = root._actionCallback
      root._actionCallback = null
      if (cb) cb(exitCode, actionStdout.text, actionStderr.text)
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
