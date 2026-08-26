import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui

// A Bambu Lab printer in the bar: a spool that takes the colour of whatever is
// running, and a panel laid out the way the Home Assistant card lays it out --
// the spools, what the printer says about itself, the temperatures, and the
// numbers that answer "when is it done".
//
// A print is a thing you start and then walk away from for eleven hours, so
// the bar itself is deliberately quiet: a dim spool while nothing is
// happening, the filament colour and a percentage while something is, and the
// urgent colour when the printer wants you.
//
// None of the talking happens here. `bin/bambu watch` holds an MQTT connection
// open and prints a line of JSON whenever the printer's state changes, which
// is also what makes the panel cheap: there is nothing to poll and nothing to
// fetch when it opens. Nothing in this file knows the access code.
//
// Glyphs are \u escapes rather than literal characters, so the source survives
// editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "jankeesvw.bambu-lab"
  ipcTarget: "jankeesvw.bambu-lab"

  readonly property string iconPause: "\uf04c"
  readonly property string iconResume: "\uf04b"
  readonly property string iconStop: "\uf04d"
  readonly property string iconLight: "\uf0eb"
  readonly property string iconWarn: "\uf071"
  readonly property string iconPrinter: "\uf02f"
  readonly property string iconWifi: "\uf1eb"
  readonly property string iconOk: "\uf058"
  readonly property string iconClock: "\uf017"
  readonly property string iconRemaining: "\uf254"
  readonly property string iconNozzle: "\uf2c7"
  readonly property string iconBed: "\uf2cb"
  readonly property string iconFan: "\uf021"
  readonly property string iconPercent: "\uf0e4"
  readonly property string iconHumidity: "\uf043"
  readonly property string iconCamera: "\uf030"

  // The script that does the talking sits next to this file, so the plugin
  // runs from wherever it was installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/bambu").toString().replace(/^file:\/\//, "")

  // Empty unless the printer has moved: `bambu trust` remembers where it was.
  readonly property string host: setting("host", "")

  readonly property int panelWidth: setting("panelWidth", 420)
  readonly property int finishHoldMin: setting("finishHoldMin", 10)
  readonly property bool notifyOnFinish: setting("notifyOnFinish", true)
  readonly property bool notifyOnError: setting("notifyOnError", true)
  readonly property bool showExternalSpool: setting("showExternalSpool", true)
  readonly property bool showCamera: setting("showCamera", true)

  // The card's spacing rhythm, in one place.
  readonly property int gap: Style.space(14)
  readonly property int labelGap: Style.space(6)
  readonly property int pad: Style.space(12)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Everything the printer told us, as `bin/bambu` hands it over. Replaced
  // wholesale on every line rather than patched: the script has already done
  // the accumulating, so this is always a complete picture.
  property var state: null
  property bool connected: false
  // Set when the trouble is ours rather than the printer's -- no access code,
  // nothing pinned, the wrong certificate. Those want reading, not retrying.
  property string setupError: ""
  // Which part of the first run is still outstanding, if any. Kept apart from
  // setupError because an install that has not been pointed at a printer yet
  // is not a fault, and should not be shown in the colour of one.
  property string setupStage: ""
  // What went wrong with the last button press, shown until the next one.
  property string commandError: ""
  // Blocks a second press while a command is in flight and for a moment after,
  // because the printer answers a stop with silence for a second or two and a
  // second stop in that gap is a stop sent to a printer that already stopped.
  property bool commandBusy: false
  // A print that finished, kept lit for a while so one that ended while you
  // were downstairs is still announced when you get back.
  property bool celebrating: false

  // The newest camera frame on disk, and whether the camera is answering at
  // all. Frames arrive as whole files with a fresh name each time: Qt caches an
  // image by its URL, so a file rewritten in place would keep showing the
  // first frame it ever read.
  property string frame: ""
  property bool cameraOk: false
  property string cameraError: ""
  // The demo has no camera to pose with: a still of the author's own printer
  // is the author's own printer, and an invented one looks invented.
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

  readonly property var trays: state && state.ams ? state.ams.trays : []
  // What the printer calls itself, when it says. Older firmware does not, and
  // then the make alone is a truer label than a guess.
  readonly property string model: state && state.model ? state.model : ""
  readonly property string title: model !== "" ? model : "Bambu Lab"

  // Which printers this camera works on. The port-6000 still image is what the
  // P1 and A1 families offer; an X1, H2 or P2 serves RTSP instead, which is a
  // different thing to build and is not built. Rather than pointing a
  // connection at a port that will not answer, those models are told plainly.
  readonly property bool cameraCapable: {
    if (model === "") return true            // unknown: try, and find out
    var name = model.toUpperCase()
    if (/\b(X1|H2|P2|X2)/.test(name)) return false
    return true
  }

  // The mark wears the bar's own colour. Tinting it with the running filament
  // was tried and dropped: a bar is a row of theme-coloured glyphs, and one
  // item in an arbitrary colour reads as a rogue element rather than as
  // information. Which filament is running is a question the panel answers.
  readonly property color markColor:
    alert ? (bar ? bar.urgent : Color.urgent) : foreground

  readonly property bool needsSetup: setupStage !== ""
  // Set up, but the printer is not answering: a switched-off printer, which is
  // most evenings. Not a fault, so it gets the shape of the panel rather than
  // an apology on an empty card.
  readonly property bool waiting: !connected && !needsSetup && setupError === ""

  // The three things between a fresh install and a working widget. Done steps
  // stay on the list so you can see how far along you are.
  readonly property var setupSteps: [
    {
      number: "1",
      title: "Turn on LAN Mode on the printer",
      body: "Settings, then Network. The access code is on that same screen.",
      code: "",
      done: root.setupStage === "no-code",
    },
    {
      number: "2",
      title: "Trust the printer",
      body: "Use the address the printer shows under Settings, WLAN.",
      code: root.script + " trust --host 192.168.1.42",
      done: root.setupStage === "no-code",
    },
    {
      number: "3",
      title: "Save the access code",
      body: "In a file only you can read.",
      code: "printf %s YOURCODE > ~/.config/omarchy-bambu/access-code",
      done: false,
    },
  ]

  readonly property bool showExternal:
    showExternalSpool && state && state.external && state.external.present

  // External text goes through this before it reaches the shared bar tooltip,
  // whose textFormat belongs to the shell rather than to us.
  function plain(s) { return String(s || "").replace(/[<>]/g, "") }

  function minutes(total) {
    var n = Math.max(0, Math.floor(total))
    var h = Math.floor(n / 60)
    var m = n % 60
    if (h > 0) return h + ":" + (m < 10 ? "0" : "") + m
    return m + "m"
  }

  // When the printer expects to be done, as a clock time rather than a
  // countdown: "17:42" is something you can plan an evening around in a way
  // that "1:11 left" is not.
  function finishTime(remaining) {
    var when = new Date(Date.now() + Math.max(0, remaining) * 60000)
    var h = when.getHours()
    var m = when.getMinutes()
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
  }

  // ------------------------------------------------------------------ state

  // Runs for as long as the shell does. The script reconnects on its own, so a
  // printer switched off in the evening is picked up again in the morning
  // without anything here noticing it went.
  Process {
    id: watchProc
    running: true
    command: root.cmd(["watch"])
    stdout: SplitParser {
      onRead: function(line) {
        var message
        try {
          message = JSON.parse(line)
        } catch (e) {
          return
        }

        if (message.type === "status") {
          root.connected = !!message.connected
          root.setupStage = message.setup ? String(message.error || "") : ""
          root.setupError = (message.fatal && !message.setup)
                            ? String(message.error || "") : ""
          if (!root.connected) root.state = null
          return
        }
        if (message.type !== "state") return

        var was = root.gcodeState
        root.connected = true
        root.setupError = ""
        root.state = message
        root.announce(was, message)
      }
    }
  }

  // Only while you are looking at it. A frame is about 65 kB and they arrive a
  // couple of times a second, which is not something to be decoding all day for
  // a panel that is shut.
  Process {
    id: cameraProc
    running: root.opened && root.showCamera && root.connected && root.cameraCapable
    command: root.cmd(["camera"])
    stdout: SplitParser {
      onRead: function(line) {
        var message
        try {
          message = JSON.parse(line)
        } catch (e) {
          return
        }
        if (message.type === "frame") {
          root.cameraOk = true
          root.cameraError = ""
          root.frame = String(message.path || "")
          return
        }
        if (message.type === "camera") {
          root.cameraOk = !!message.ok
          root.cameraDemo = !!message.demo
          root.cameraError = message.ok ? "" : String(message.error || "")
        }
      }
    }
  }

  // A print that ends is the whole reason to have this in the bar, and it ends
  // while you are somewhere else.
  function announce(was, now) {
    if (was === "" || was === now.gcode_state) return

    if (now.gcode_state === "FINISH") {
      if (root.finishHoldMin > 0) {
        root.celebrating = true
        celebrateTimer.restart()
      }
      if (root.notifyOnFinish) notify("Print finished", now.task)
    }
    if (now.gcode_state === "FAILED" && root.notifyOnError) {
      notify("Print failed", now.task)
    }
    if (now.gcode_state === "RUNNING") root.celebrating = false
  }

  Timer {
    id: celebrateTimer
    interval: Math.max(1, root.finishHoldMin) * 60000
    onTriggered: root.celebrating = false
  }

  Process { id: notifyProc }

  function notify(title, task) {
    // The task name is whatever was typed into the slicer, so it is kept out
    // of anything that reads an argument as an option: the body always starts
    // with a word of ours, which is what stops a file called "--help" from
    // being read as one.
    var body = title === "Print failed"
      ? (task ? "Failed: " + root.plain(task) : "The print failed")
      : (task ? "Finished: " + root.plain(task) : "The printer is done")
    notifyProc.command = ["notify-send", "-a", "Bambu Lab", title, body]
    notifyProc.running = true
  }

  // --------------------------------------------------------------- commands

  // The address override rides on every call, so a setting changed in the
  // panel takes effect on the next command rather than at the next login.
  function cmd(args) {
    var base = [root.script]
    if (root.host !== "") base = base.concat(["--host", root.host])
    return base.concat(args)
  }

  Process {
    id: cmdProc
    stdout: StdioCollector {
      onStreamFinished: {
        var answer
        try {
          answer = JSON.parse(text)
        } catch (e) {
          root.commandError = "the printer did not answer"
          return
        }
        root.commandError = answer.ok ? "" : String(answer.error || "the printer refused it")
      }
    }
  }

  Timer {
    id: cooldown
    interval: 3000
    onTriggered: root.commandBusy = false
  }

  function send(args) {
    if (root.commandBusy) return
    root.commandBusy = true
    root.commandError = ""
    cmdProc.command = root.cmd(args)
    cmdProc.running = true
    cooldown.restart()
  }

  // ------------------------------------------------------------------- bar

  readonly property bool alert: hasError || (celebrating && !busy)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar
    active: root.alert
    // A printer sitting idle is not news. `dimmed` rather than opacity: the
    // button animates its own opacity and a second binding on it fights the
    // animation instead of replacing it.
    dimmed: !root.connected || (!root.busy && !root.alert)

    tooltipText: {
      if (root.setupError !== "") return root.plain(root.setupError)
      if (!root.connected) return "Printer unreachable"
      if (root.hasError) return "The printer needs you"
      if (root.busy && root.state)
        return root.plain((root.state.task || "Printing") + " · " + root.state.percent + "%"
                          + (root.state.remaining_min > 0
                             ? " · done " + root.finishTime(root.state.remaining_min) : ""))
      if (root.finished) return "Print finished"
      return "Printer idle"
    }

    onPressed: function(b) { root.toggle() }

    iconComponent: BambuMark {
      iconSize: Style.font.icon
      color: root.markColor
    }
  }

  // ----------------------------------------------------------------- panel

  // The keyboard panel rather than a popup card: stop needs a confirmation, a
  // confirmation needs arrow keys, and a PopupWindow never gets keyboard focus
  // on Wayland.
  KeyboardPanel {
    id: panel
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: keys

    // Plain property reads rather than fittedContentWidth(): the helper does
    // not re-evaluate when the desired width changes, which it does whenever
    // the setting is edited with the panel open.
    // One width, whatever the panel is showing. Narrowing it while the printer
    // is away was tried and dropped: on its own the narrow card looks right,
    // but opening the panel on an absent printer and again on a present one
    // makes the whole thing jump sideways, and a card that changes size is a
    // card you have to re-find every time.
    readonly property int desiredWidth: Style.space(root.panelWidth)
    contentWidth: Math.min(desiredWidth,
                           availableCardWidth > 0 ? availableCardWidth : desiredWidth)
    // The height helper, though, is the one to use: contentHeight is the whole
    // card, so the padding and the borders have to be added to what the column
    // measures or the last row hangs out of the bottom.
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent

      onCloseRequested: {
        if (stopConfirm.opened) { root.cancelStop(); return }
        root.close()
      }
      // Only this one. Enter arrives as both returnRequested and
      // activateRequested, and a control wired to both fires twice.
      onActivateRequested: root.activate()
      onMoveRequested: function(dx, dy) { root.moveCursor(dx !== 0 ? dx : dy) }
      onTabRequested: function(direction) { root.moveCursor(direction, true) }

      Keys.onPressed: function(event) {
        if (stopConfirm.handleKey(event)) event.accepted = true
      }

      // One rhythm for the whole card rather than a number per place: blocks
      // are separated by `gap`, a label sits `labelGap` above the thing it
      // names, and every boxed group has `pad` inside it.
      ColumnLayout {
        id: content
        width: parent.width
        spacing: root.gap

        // -- the printer, and the controls ---------------------------------

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(1)

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              elide: Text.ElideRight
              text: root.title
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              color: root.foreground
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              elide: Text.ElideRight
              visible: text !== ""
              text: root.headline
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: Util.alpha(root.foreground, 0.6)
            }
          }

          Repeater {
            model: root.connected ? root.headerActions : []
            delegate: RoundButton {
              icon: modelData.icon
              danger: modelData.danger
              enabled: !root.commandBusy && modelData.enabled
              hasCursor: root.cursor === index && modelData.enabled
              foreground: root.foreground
              fontFamily: root.fontFamily
              onActivated: root.run(modelData.id)
            }
          }
        }

        // -- the chamber ---------------------------------------------------
        //
        // A P1 has no RTSP and no way to ask for one, so this is a stream of
        // whole JPEGs at a frame or two a second rather than video. That is
        // enough to answer the question you open it for: is it still stuck to
        // the plate.

        // -- the first run -------------------------------------------------

        ColumnLayout {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(2)
          spacing: root.gap
          visible: root.needsSetup

          Repeater {
            model: root.setupSteps
            delegate: SetupStep {
              Layout.fillWidth: true
              number: modelData.number
              title: modelData.title
              body: modelData.body
              code: modelData.code
              done: modelData.done
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Click a command to copy it."
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: Util.alpha(root.foreground, 0.4)
          }
        }

        // -- waiting for the printer ---------------------------------------

        Skeleton {
          Layout.fillWidth: true
          visible: root.waiting
          foreground: root.foreground
          fontFamily: root.fontFamily
          pad: root.pad
          labelGap: root.labelGap
          message: "Looking for the printer"
        }

        // Always sixteen by nine, picture or no picture. The first frame takes
        // a second or two to arrive and the connection drops when the printer
        // sleeps; if the block came and went with it, the whole card would
        // grow and shrink by a third under the cursor. Reserving the space
        // costs an empty rectangle and buys a panel that holds still.
        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: Math.round(width * 9 / 16)
          visible: root.showCamera && root.connected
          radius: Style.cornerRadius
          color: Util.alpha(root.foreground, 0.05)
          clip: true

          Image {
            id: chamber
            anchors.fill: parent
            visible: root.frame !== ""
            source: root.frame !== "" ? "file://" + root.frame : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            // Each frame is its own file, so nothing is gained by keeping the
            // old ones decoded and a panel left open would grow without it.
            cache: false
          }

          // What stands in for the picture. Faint on purpose: it is a space
          // waiting to be filled, not a message demanding to be read.
          ColumnLayout {
            anchors.centerIn: parent
            width: parent.width - root.pad * 2
            spacing: Style.space(8)
            visible: root.frame === ""

            Text {
              textFormat: Text.PlainText
              Layout.alignment: Qt.AlignHCenter
              text: root.iconCamera
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              color: Util.alpha(root.foreground, 0.25)
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              text: !root.cameraCapable
                    ? "This printer sends video rather than stills, which this does not read yet."
                    : root.cameraDemo
                      ? "Camera"
                      : root.cameraError !== ""
                        ? "No camera. Turn on LAN Mode Liveview on the printer."
                        : "Looking for the camera…"
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: Util.alpha(root.foreground, 0.4)
            }
          }
        }

        // -- the spools ----------------------------------------------------

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          visible: root.trays.length > 0 || root.showExternal

          ColumnLayout {
            visible: root.showExternal
            spacing: root.labelGap

            Text {
              textFormat: Text.PlainText
              text: "EXT."
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: Util.alpha(root.foreground, 0.55)
            }

            Rectangle {
              Layout.preferredWidth: extTray.implicitWidth + root.pad * 2
              Layout.preferredHeight: extTray.implicitHeight + root.pad * 2
              radius: Style.cornerRadius
              color: Util.alpha(root.foreground, 0.05)

              AmsTray {
                id: extTray
                anchors.centerIn: parent
                present: true
                label: root.showExternal ? root.state.external.label : ""
                colors: root.showExternal ? root.state.external.colors : []
                active: false
                foreground: root.foreground
                background: Color.popups.background
                fontFamily: root.fontFamily
              }
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: root.labelGap

            RowLayout {
              Layout.fillWidth: true
              Text {
                textFormat: Text.PlainText
                text: "AMS"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: Util.alpha(root.foreground, 0.55)
              }
              Item { Layout.fillWidth: true }
              Chip {
                visible: root.state !== null && root.state.ams.humidity > 0
                icon: root.iconHumidity
                text: root.humidityText
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
            }

            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: amsRow.implicitHeight + root.pad * 2
              radius: Style.cornerRadius
              color: Util.alpha(root.foreground, 0.05)

              // Full width, for the same reason the readings row is: an inset
              // row hands its padding to the outer two cells and the spools
              // stop sitting on even quarters of the box.
              RowLayout {
                id: amsRow
                anchors.centerIn: parent
                width: parent.width
                spacing: 0

                Repeater {
                  model: root.trays
                  delegate: AmsTray {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 0
                    slot: modelData.slot
                    present: modelData.present
                    label: modelData.label
                    colors: modelData.colors
                    active: modelData.active
                    foreground: root.foreground
                    background: Color.popups.background
                    fontFamily: root.fontFamily
                  }
                }
              }
            }
          }
        }

        // -- what the printer says about itself ----------------------------

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: root.connected && root.state !== null

          Text {
            textFormat: Text.PlainText
            text: "Printer"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: Util.alpha(root.foreground, 0.55)
          }

          Item { Layout.fillWidth: true }

          Chip {
            icon: root.iconPrinter
            text: root.stateWord
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Chip {
            icon: root.iconLight
            text: root.state && root.state.light_on ? "On" : "Off"
            iconColor: root.state && root.state.light_on
                       ? Color.accent : Util.alpha(root.foreground, 0.5)
            foreground: root.foreground
            fontFamily: root.fontFamily
            interactive: !root.commandBusy
            hasCursor: root.cursor === root.actions.length - 1
            onClicked: root.run("light")
          }

          Chip {
            icon: root.hasError ? root.iconWarn : root.iconOk
            text: root.hasError
                  ? (root.errors.length > 0 ? root.errors[0].severity : "Error") : "OK"
            iconColor: root.hasError ? Color.urgent : Util.alpha(root.foreground, 0.6)
            foreground: root.foreground
            fontFamily: root.fontFamily
            interactive: root.errors.length > 0
            onClicked: if (root.errors.length > 0) root.openWiki(root.errors[0].code)
          }
        }

        // -- temperatures --------------------------------------------------
        //
        // No chamber temperature. Only the X1, H2, P2 and X2 families have a
        // sensor for it; a P1 or an A1 still sends the field, and what it
        // sends means nothing.

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: cells.implicitHeight + root.pad * 2
          radius: Style.cornerRadius
          color: Util.alpha(root.foreground, 0.05)
          visible: root.connected && root.state !== null

          // Exact quarters. `fillWidth` alone shares out only the leftover
          // space, and it shares it in proportion to what is already in each
          // cell -- so "220 / 220" ends up wider than "0 %" and the four
          // readings sit at four different places. Zeroing the preferred width
          // takes the content out of the sum and leaves plain quarters.
          // The full width of the box, not an inset row inside it. Insetting
          // hands the padding to the outer two cells, so those two end up
          // wider than the middle two and the whole row stops looking evenly
          // spaced -- most visibly on the right, where nothing follows to
          // disguise it. Full width puts the dividers on exact quarters.
          RowLayout {
            id: cells
            anchors.centerIn: parent
            width: parent.width
            spacing: 0

            Repeater {
              model: root.readings
              delegate: Item {
                Layout.fillWidth: true
                Layout.preferredWidth: 0
                Layout.preferredHeight: cell.implicitHeight

                ColumnLayout {
                  id: cell
                  anchors.centerIn: parent
                  spacing: Style.space(5)

                  Text {
                    textFormat: Text.PlainText
                    Layout.alignment: Qt.AlignHCenter
                    text: modelData.icon
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    color: Util.alpha(root.foreground, 0.5)
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.alignment: Qt.AlignHCenter
                    text: modelData.value
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    color: root.foreground
                  }
                }

                // A hairline between the quarters, so they read as four cells
                // rather than four things that happen to be spaced out.
                Rectangle {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: 1
                  height: Math.round(cell.implicitHeight * 0.8)
                  visible: index < root.readings.length - 1
                  color: Util.alpha(root.foreground, 0.12)
                }
              }
            }
          }
        }

        // -- how far along -------------------------------------------------

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(6)
          visible: root.busy
          radius: height / 2
          color: Util.alpha(root.foreground, 0.15)

          Rectangle {
            width: parent.width * (root.state ? root.state.percent / 100 : 0)
            height: parent.height
            radius: height / 2
            color: root.paused ? Util.alpha(Color.accent, 0.5) : Color.accent
            Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          visible: root.busy && root.state !== null

          Chip {
            icon: root.iconPercent
            text: root.state ? root.state.percent + " %" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          Item { Layout.fillWidth: true }
          Chip {
            visible: root.state !== null && root.state.remaining_min > 0
            icon: root.iconClock
            text: root.state ? root.finishTime(root.state.remaining_min) : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          Item { Layout.fillWidth: true }
          Chip {
            visible: root.state !== null && root.state.remaining_min > 0
            icon: root.iconRemaining
            text: root.state ? root.minutes(root.state.remaining_min) : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
        }

        // -- and when it is not working ------------------------------------

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
          visible: text !== ""
          text: root.setupError !== "" ? root.setupError
              : root.commandError !== "" ? root.commandError
              // Nothing here while the setup steps or the skeleton are up.
              // Both already say the printer is not talking -- the steps by
              // being unfinished, the skeleton by being empty and turning --
              // and a third sentence saying it again is just noise.
              : ""
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: root.setupError !== "" || root.commandError !== ""
                 ? Color.urgent : Util.alpha(root.foreground, 0.6)
        }
      }

      // Stop is the one control here that cannot be taken back: a stopped
      // print is scrap and the hours are gone. So it asks, and it asks with
      // Cancel selected -- the component defaults to the confirming side,
      // which is the wrong way round when the confirming side is destructive.
      ConfirmDialog {
        id: stopConfirm
        anchors.fill: parent
        z: 10
        opened: root.stopPending
        message: "Stop this print? It cannot be resumed."
        confirmText: "Stop"
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelStop()
        onConfirmed: {
          root.stopPending = false
          root.send(["stop"])
        }
      }
    }
  }

  // -------------------------------------------------------------- behaviour

  property bool stopPending: false
  property int cursor: 0

  function cancelStop() {
    stopPending = false
    stopConfirm.selectedIndex = 0
  }

  // The two round controls in the header. They stay in place while the printer
  // is idle rather than appearing and disappearing under the cursor; a control
  // with nothing to do is dimmed instead.
  readonly property var headerActions: [
    {id: "stop", icon: root.iconStop, danger: true, enabled: root.busy},
    {id: root.paused ? "resume" : "pause",
     icon: root.paused ? root.iconResume : root.iconPause,
     danger: false, enabled: root.busy},
  ]

  // Everything the keyboard can reach, in the order it is drawn: the two
  // header controls, then the light down in the printer row. One list so the
  // keyboard and the mouse walk exactly the same set.
  readonly property var actions:
    headerActions.concat([{id: "light", icon: root.iconLight,
                           danger: false, enabled: root.connected}])

  // Disabled controls are stepped over rather than landed on. Stop and pause
  // are both dead while the printer is idle, and a cursor parked on a control
  // that does nothing makes Enter look broken.
  function moveCursor(step, wrap) {
    if (stopConfirm.opened || actions.length === 0) return
    var direction = step >= 0 ? 1 : -1
    var next = cursor
    for (var tries = 0; tries < actions.length; tries++) {
      next += direction
      if (next < 0 || next >= actions.length) {
        if (!wrap) return
        next = (next + actions.length) % actions.length
      }
      if (actions[next].enabled) { cursor = next; return }
    }
  }

  // Where the cursor starts: the first control that can actually do something.
  function firstEnabled() {
    for (var i = 0; i < actions.length; i++) if (actions[i].enabled) return i
    return -1
  }

  function activate() {
    if (stopConfirm.opened) return
    if (cursor < 0 || cursor >= actions.length) return
    if (!actions[cursor].enabled) return
    run(actions[cursor].id)
  }

  function run(id) {
    if (root.commandBusy) return
    if (id === "stop") {
      // Cancel is where the cursor starts, every time it opens.
      stopConfirm.selectedIndex = 0
      root.stopPending = true
      return
    }
    if (id === "light") {
      root.send(["light", root.state && root.state.light_on ? "off" : "on"])
      return
    }
    root.send([id])
  }

  onOpenedChanged: {
    if (!opened) {
      stopPending = false
      // Dropped rather than kept: the next frame is seconds away, and a stale
      // picture of the chamber is exactly the thing you would misread.
      frame = ""
      cameraOk = false
      return
    }
    cursor = firstEnabled()
    commandError = ""
    // Opening the panel is you having seen it.
    celebrating = false
  }

  Process { id: wikiProc }

  // Bambu index their own troubleshooting by this code. It is built out of
  // formatted integers rather than any string the printer sent, which is what
  // makes it safe to hand to a browser.
  function openWiki(code) {
    if (!/^[0-9A-F]{4}(_[0-9A-F]{4}){3}$/.test(String(code))) return
    wikiProc.command = ["xdg-open",
                        "https://wiki.bambulab.com/en/x1/troubleshooting/hmscode/"
                        + String(code).toLowerCase()]
    wikiProc.running = true
    root.close()
  }

  // ---------------------------------------------------------------- wording

  readonly property string headline: {
    if (needsSetup) return setupStage === "no-code" ? "Almost there" : "Not set up yet"
    if (setupError !== "") return "Something is wrong"
    if (!connected) return "Unreachable"
    if (!state) return "Connecting…"
    if (busy && state.task !== "") return state.task
    if (!busy && state.nozzle_diameter !== "")
      return state.nozzle_diameter + " mm " + state.nozzle_type
    return ""
  }

  readonly property string stateWord: {
    if (!state) return "—"
    if (printing) return state.stage !== "" ? state.stage : "Printing"
    if (paused) return "Paused"
    if (failed) return "Failed"
    if (finished) return "Finished"
    return "Idle"
  }

  readonly property var readings: {
    if (!state) return []
    function temperature(icon, now, target) {
      return {icon: icon,
              value: target > 0 ? Math.round(now) + " / " + Math.round(target)
                                : Math.round(now) + " °C"}
    }
    return [
      temperature(root.iconNozzle, state.nozzle, state.nozzle_target),
      temperature(root.iconBed, state.bed, state.bed_target),
      {icon: root.iconFan, value: state.fan_part + " %"},
      {icon: root.iconWifi, value: state.wifi !== "" ? state.wifi : "—"},
    ]
  }

  readonly property string humidityText: {
    if (!state || state.ams.humidity <= 0) return ""
    // The AMS reports a level of one to five, where one is driest.
    var words = ["", "dry", "dry", "fair", "damp", "wet"]
    return words[Math.max(1, Math.min(5, state.ams.humidity))]
  }
}
