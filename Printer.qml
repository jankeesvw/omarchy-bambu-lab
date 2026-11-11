import QtQuick
import Quickshell.Io

// One printer: its connection, its camera, its commands and what it last said.
// Service.qml holds one of these per printer and the panels draw whichever is
// chosen. All of this used to live on the panel itself, and behaves as it did
// there.
Item {
  id: printer
  visible: false

  // Which directory `bin/bambu` reads: "" is the unsuffixed one.
  property string profile: ""
  property string script: ""
  // Empty unless the printer has moved: `bambu trust` remembers where it was.
  property string host: ""

  // Wired by the panel.
  property bool cameraWanted: false
  property int finishHoldMin: 10
  property bool notifyOnFinish: true
  property bool notifyOnError: true

  property var state: null
  property bool connected: false
  property string setupError: ""
  property string setupStage: ""
  property string commandError: ""
  property bool commandBusy: false
  property bool celebrating: false

  property string frame: ""
  property bool cameraOk: false
  property string cameraError: ""
  property bool cameraDemo: false

  readonly property string gcodeState: state ? state.gcode_state : ""
  readonly property bool printing: gcodeState === "RUNNING" || gcodeState === "PREPARE"
  readonly property bool paused: gcodeState === "PAUSE"
  readonly property bool failed: gcodeState === "FAILED"
  readonly property bool finished: gcodeState === "FINISH"
  readonly property bool busy: printing || paused

  readonly property var errors: state && state.errors ? state.errors : []
  readonly property bool hasError: failed || errors.length > 0
                                   || (state ? state.print_error !== 0 : false)
  readonly property bool alert: hasError || (celebrating && !busy)

  readonly property string model: state && state.model ? state.model : ""
  // What the tab and the notifications call it: the model without the make,
  // which is what tells two printers on one desk apart -- and the profile
  // name until the printer has said what it is, or when two are the same.
  readonly property string name: {
    var short = model.replace(/^Bambu Lab\s+/, "")
    if (profile === "") return short !== "" ? short : "Printer"
    return short !== "" && short.toLowerCase() !== profile.toLowerCase()
           ? short + " (" + profile + ")" : (short !== "" ? short : profile)
  }

  // Which printers this camera works on. The port-6000 still image is what the
  // P1, A1 and A2 families offer; an X1, H2 or P2 serves RTSP instead, which
  // is a different thing to build and is not built. Rather than pointing a
  // connection at a port that will not answer, those models are told plainly.
  readonly property bool cameraCapable: {
    if (model === "") return true
    var name = model.toUpperCase()
    if (/\b(X1|H2|P2|X2)/.test(name)) return false
    return true
  }

  function cmd(args) {
    var base = [printer.script]
    if (printer.profile !== "") base = base.concat(["--profile", printer.profile])
    if (printer.host !== "") base = base.concat(["--host", printer.host])
    return base.concat(args)
  }

  function plain(s) { return String(s || "").replace(/[<>]/g, "") }

  Process {
    id: watchProc
    running: printer.script !== ""
    command: printer.cmd(["watch"])
    stdout: SplitParser {
      onRead: function(line) {
        var message
        try {
          message = JSON.parse(line)
        } catch (e) {
          return
        }

        if (message.type === "status") {
          printer.connected = !!message.connected
          printer.setupStage = message.setup ? String(message.error || "") : ""
          printer.setupError = (message.fatal && !message.setup)
                               ? String(message.error || "") : ""
          if (!printer.connected) printer.state = null
          return
        }
        if (message.type !== "state") return

        var was = printer.gcodeState
        printer.connected = true
        printer.setupError = ""
        printer.state = message
        printer.announce(was, message)
      }
    }
  }

  Process {
    id: cameraProc
    running: printer.cameraWanted && printer.connected && printer.cameraCapable
    command: printer.cmd(["camera"])
    stdout: SplitParser {
      onRead: function(line) {
        var message
        try {
          message = JSON.parse(line)
        } catch (e) {
          return
        }
        if (message.type === "frame") {
          printer.cameraOk = true
          printer.cameraError = ""
          printer.frame = String(message.path || "")
          return
        }
        if (message.type === "camera") {
          printer.cameraOk = !!message.ok
          printer.cameraDemo = !!message.demo
          printer.cameraError = message.ok ? "" : String(message.error || "")
        }
      }
    }
  }

  // A stale picture is exactly the thing you would misread, so it goes the
  // moment nobody is looking at this printer's camera.
  onCameraWantedChanged: if (!cameraWanted) { frame = ""; cameraOk = false }

  function announce(was, now) {
    if (was === "" || was === now.gcode_state) return

    if (now.gcode_state === "FINISH") {
      if (printer.finishHoldMin > 0) {
        printer.celebrating = true
        celebrateTimer.restart()
      }
      if (printer.notifyOnFinish) notify(false, now.task)
    }
    if (now.gcode_state === "FAILED" && printer.notifyOnError) notify(true, now.task)
    if (now.gcode_state === "RUNNING") printer.celebrating = false
  }

  Timer {
    id: celebrateTimer
    interval: Math.max(1, printer.finishHoldMin) * 60000
    onTriggered: printer.celebrating = false
  }

  Process { id: notifyProc }

  function notify(failedPrint, task) {
    // The body always starts with a word of ours, so a task called "--help"
    // cannot be read as an option.
    var title = printer.name + (failedPrint ? ": print failed" : ": print finished")
    var body = failedPrint
      ? (task ? "Failed: " + printer.plain(task) : "The print failed")
      : (task ? "Finished: " + printer.plain(task) : "The printer is done")
    notifyProc.command = ["notify-send", "-a", "Bambu Lab", title, body]
    notifyProc.running = true
  }

  Process {
    id: cmdProc
    stdout: StdioCollector {
      onStreamFinished: {
        var answer
        try {
          answer = JSON.parse(text)
        } catch (e) {
          printer.commandError = "the printer did not answer"
          return
        }
        printer.commandError = answer.ok ? "" : String(answer.error || "the printer refused it")
      }
    }
  }

  Timer {
    id: cooldown
    interval: 3000
    onTriggered: printer.commandBusy = false
  }

  function send(args) {
    if (printer.commandBusy) return
    printer.commandBusy = true
    printer.commandError = ""
    cmdProc.command = printer.cmd(args)
    cmdProc.running = true
    cooldown.restart()
  }
}
