import QtQuick
import Quickshell.Io

// One instance for the whole shell, holding every printer.
//
// The bar is built once per monitor, so the panel exists once per monitor too,
// and when each copy held its own printer, each opened its own MQTT
// connection. A Bambu printer hands out three: on a desk with three screens
// the widget took every one of them, and a fourth client -- Bambu Studio in
// LAN mode, or `bambu watch` from a terminal -- got silence and called the
// printer unreachable. The printers live here instead, one connection each,
// and every panel draws from them.
Item {
  id: root

  property var shell: null

  readonly property string script:
    Qt.resolvedUrl("bin/bambu").toString().replace(/^file:\/\//, "")

  // Which printers are set up, as `bin/bambu profiles` reports them: "" is the
  // first printer, anything else was pinned with `bambu trust --profile`.
  // Starts with the first printer alone, so a single-printer install draws
  // exactly what it always did while the list is still being read.
  property var profiles: [""]

  // Pushed in by the panels. Every monitor's copy reads the same shell.json
  // entry, so it does not matter which one gets here first.
  property string host: ""
  property bool showCamera: true
  property int finishHoldMin: 10
  property bool notifyOnFinish: true
  property bool notifyOnError: true

  // Shared, so the printer you were looking at on one screen is the one you
  // find on the next.
  property int selected: 0
  // How many panels are open. The camera runs only while one is.
  property int openPanels: 0

  readonly property var printers: {
    var out = []
    for (var i = 0; i < printerRepeater.count; i++) {
      var item = printerRepeater.itemAt(i)
      if (item) out.push(item)
    }
    return out
  }

  Repeater {
    id: printerRepeater
    model: root.profiles
    delegate: Printer {
      profile: modelData
      script: root.script
      // The address override predates more than one printer, and it means the
      // first one.
      host: modelData === "" ? root.host : ""
      cameraWanted: root.openPanels > 0 && root.showCamera && index === root.selected
      finishHoldMin: root.finishHoldMin
      notifyOnFinish: root.notifyOnFinish
      notifyOnError: root.notifyOnError
    }
  }

  // Read at start-up, and again whenever a panel opens: a printer added with
  // `bambu trust --profile` shows up the next time you look, without a shell
  // restart. Only a changed list is applied, because a new model array
  // rebuilds every printer and drops its connection.
  Process {
    id: profilesProc
    command: [root.script, "profiles"]
    stdout: StdioCollector {
      onStreamFinished: {
        var list
        try {
          list = JSON.parse(text)
        } catch (e) {
          return
        }
        if (!Array.isArray(list) || list.length === 0) return
        list = list.filter(function(p) { return typeof p === "string" && /^([a-z0-9][a-z0-9-]{0,31})?$/.test(p) })
        if (JSON.stringify(list) === JSON.stringify(root.profiles)) return
        root.profiles = list
        if (root.selected >= list.length) root.selected = 0
      }
    }
  }

  function rescan() {
    if (!profilesProc.running) profilesProc.running = true
  }

  Component.onCompleted: rescan()
  onOpenPanelsChanged: if (openPanels > 0) rescan()
}
