#!/usr/bin/env python3
"""Talks MQTT to a Bambu Lab printer over the local network.

A Bambu printer runs an MQTT broker on port 8883 and will hand its entire
state to anybody on the network who knows the LAN access code. That is the
whole protocol: subscribe to `device/<serial>/report`, publish to
`device/<serial>/request`, and everything the printer knows arrives as JSON.

This is a complete MQTT 3.1.1 client in a few hundred lines of standard
library, rather than a dependency on paho-mqtt. The printer needs four packet
types out of the fourteen in the spec -- CONNECT, SUBSCRIBE, PUBLISH, PINGREQ
-- and asking every user of the plugin to install a package to send those is a
worse trade than writing them out.

Three modes:

    MODE=watch      hold the connection open, print NDJSON state to stdout
    MODE=camera     hold the chamber camera open, write JPEG frames to the
                    cache directory and print the path of each one
    MODE=stop|pause|resume|light-on|light-off
                    connect, send the one command, print {"ok":true}, exit

Everything comes in through the environment. Nothing arrives in argv, because
/proc/<pid>/cmdline is world readable on a stock kernel and the access code is
worth as much as physical access to the printer:

    BAMBU_HOST          address of the printer
    BAMBU_SERIAL        serial number, which is also the MQTT topic
    BAMBU_ACCESS_CODE   the LAN access code from the printer screen
    BAMBU_FINGERPRINT   sha256 of the pinned certificate, hex
    BAMBU_CACHE         where camera frames go (camera mode only)
"""

import hashlib
import json
import os
import socket
import ssl
import struct
import sys
import time

MQTT_PORT = 8883
# The chamber camera. A separate protocol on a separate port, but behind the
# same certificate, so the same pin covers both.
CAMERA_PORT = 6000

# Printers live on DHCP leases, so the address in the settings is a guess about
# who is listening and not a statement about who they are. The pin is what
# turns "something answered on this address" into "the printer I set this up
# against" -- and it is checked before the access code is put on the wire.
CONNECT_TIMEOUT = 10
KEEPALIVE = 60
PING_EVERY = 30
# The printer goes quiet when it is idle, but never for this long: it reports
# its wifi signal every few seconds no matter what. Silence past this means the
# connection died in a way TCP has not noticed yet.
SILENCE_LIMIT = 90
# OpenBambuAPI warns that a P1 stalls if it is asked to serialise its whole
# state too often. Progress arrives in the deltas anyway, so a full refresh is
# a safety net against a missed delta rather than the way state is kept.
#
# Generous rather than tight, because the bar runs one of these per monitor: a
# two-screen desk means two connections asking, and the interval that matters
# is the one arriving at the printer.
PUSHALL_EVERY = 900
BACKOFF_MAX = 60
# Frames are written round-robin over a handful of names rather than to one
# fixed path. Qt caches an image by its URL, so a file rewritten in place tends
# to keep showing the first frame it ever read; a new name each time sidesteps
# the whole question.
FRAME_SLOTS = 4


def emit(obj):
    """One JSON object per line on stdout, for the QML side to read."""
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def env(name):
    value = os.environ.get(name, "")
    if not value:
        sys.exit("bambu-mqtt: %s is not set" % name)
    return value


# --------------------------------------------------------------- MQTT packets


def encode_length(n):
    """MQTT's variable-length integer: seven bits a byte, high bit continues."""
    out = bytearray()
    while True:
        digit = n % 128
        n //= 128
        if n:
            digit |= 0x80
        out.append(digit)
        if not n:
            return bytes(out)


def encode_string(value):
    if isinstance(value, str):
        value = value.encode("utf-8")
    return len(value).to_bytes(2, "big") + value


def packet(header, body):
    return bytes([header]) + encode_length(len(body)) + body


def connect_tls(host, port, fingerprint):
    """Open a TLS socket to the printer, and prove it is the right printer.

    The certificate's common name is a serial number rather than a hostname, so
    there is nothing for hostname verification to compare against, and it is
    signed by Bambu's own CA which we have no copy of. Both checks are switched
    off and replaced by something stricter than either: exactly one certificate
    gets through, the one pinned during setup.

    Nothing secret has gone out when this returns -- the handshake proves who
    they are before anything of ours proves who we are.
    """
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    raw = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
    sock = ctx.wrap_socket(raw)
    seen = hashlib.sha256(sock.getpeercert(binary_form=True)).hexdigest()
    if seen != fingerprint:
        try:
            sock.close()
        except OSError:
            pass
        raise Untrusted(seen)
    return sock


class Connection:
    """One TCP+TLS session to the printer, speaking just enough MQTT."""

    def __init__(self, host, serial, code, fingerprint):
        self.host = host
        self.serial = serial
        self.code = code
        self.fingerprint = fingerprint.lower()
        self.sock = None
        self.buf = b""
        self.packet_id = 0
        self.report_topic = "device/%s/report" % serial
        self.request_topic = "device/%s/request" % serial

    # -- setting up ---------------------------------------------------------

    def open(self):
        self.sock = connect_tls(self.host, MQTT_PORT, self.fingerprint)
        self._connect()
        self._subscribe()

    def _connect(self):
        body = (
            encode_string("MQTT")
            + bytes([4])       # protocol level: 3.1.1
            + bytes([0xC2])    # username + password + clean session
            + KEEPALIVE.to_bytes(2, "big")
            + encode_string("omarchy-%d" % os.getpid())
            + encode_string("bblp")
            + encode_string(self.code)
        )
        self.sock.sendall(packet(0x10, body))

        self.sock.settimeout(CONNECT_TIMEOUT)
        reply = self.sock.recv(4)
        if len(reply) < 4 or reply[0] != 0x20:
            raise Refused("the printer did not answer the connection")
        if reply[3] != 0:
            raise Refused(CONNACK_ERRORS.get(reply[3], "connection refused (%d)" % reply[3]),
                          reply[3] in CONNACK_FATAL)

    def _subscribe(self):
        self.packet_id += 1
        body = (
            self.packet_id.to_bytes(2, "big")
            + encode_string(self.report_topic)
            + bytes([0])       # QoS 0: the printer repeats itself constantly
        )
        self.sock.sendall(packet(0x82, body))
        self.sock.settimeout(CONNECT_TIMEOUT)
        reply = self.sock.recv(5)
        if len(reply) < 5 or reply[0] != 0x90 or reply[4] == 0x80:
            raise Refused("the printer refused the subscription")

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    # -- talking ------------------------------------------------------------

    def publish(self, payload, qos=0):
        """Send one command. QoS 1 asks the printer to acknowledge it."""
        body = encode_string(self.request_topic)
        header = 0x30
        if qos == 1:
            self.packet_id += 1
            pid = self.packet_id
            header = 0x32
            body += pid.to_bytes(2, "big")
        body += json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.sock.sendall(packet(header, body))
        return self.packet_id if qos == 1 else None

    def ping(self):
        self.sock.sendall(b"\xc0\x00")

    def pushall(self):
        self.publish({"pushing": {"sequence_id": "1", "command": "pushall",
                                  "version": 1, "push_target": 1}})

    def get_version(self):
        """Ask for the module list, which is where the printer names itself."""
        self.publish({"info": {"sequence_id": "0", "command": "get_version"}})

    def resume_push(self):
        """Nudge a printer that has stopped reporting back into talking."""
        self.publish({"pushing": {"sequence_id": "1", "command": "start"}})

    def read(self):
        """Yield ("publish", payload) and ("puback", id) as they arrive.

        Returns without yielding when the socket is merely quiet; raises when
        the other end has gone away.
        """
        try:
            chunk = self.sock.recv(65536)
        except socket.timeout:
            return
        except ssl.SSLWantReadError:
            return
        if not chunk:
            raise Dropped("the printer closed the connection")
        self.buf += chunk

        while True:
            frame = self._take_packet()
            if frame is None:
                return
            header, body = frame
            kind = header >> 4
            if kind == 3:                                   # PUBLISH
                topic_len = int.from_bytes(body[:2], "big")
                rest = body[2 + topic_len:]
                if (header >> 1) & 0x03 == 1:               # QoS 1
                    pid, rest = rest[:2], rest[2:]
                    self.sock.sendall(packet(0x40, pid))    # PUBACK
                yield "publish", rest
            elif kind == 4:                                 # PUBACK
                yield "puback", int.from_bytes(body[:2], "big")

    def _take_packet(self):
        """Peel one whole MQTT packet off the buffer, or None if it is short."""
        if len(self.buf) < 2:
            return None
        multiplier, length, i = 1, 0, 1
        while True:
            if i >= len(self.buf):
                return None
            digit = self.buf[i]
            length += (digit & 0x7F) * multiplier
            multiplier *= 128
            i += 1
            if not digit & 0x80:
                break
            if multiplier > 128 ** 3:
                raise Dropped("malformed packet length")
        if len(self.buf) < i + length:
            return None
        header = self.buf[0]
        body = self.buf[i:i + length]
        self.buf = self.buf[i + length:]
        return header, body


# The two the printer actually uses for a bad credential. Measured: a P1S on
# firmware 01.10 answers a wrong access code with 5 rather than the 4 the spec
# would suggest, so both have to mean the same thing here -- and both have to
# stop the retry loop, because no amount of reconnecting fixes a typo.
CONNACK_ERRORS = {
    1: "the printer rejected the protocol version",
    2: "the printer rejected the client id",
    3: "the printer is not accepting connections",
    4: "Wrong access code. It is on the printer screen under Settings, Network, LAN Mode.",
    5: "Wrong access code. It is on the printer screen under Settings, Network, LAN Mode.",
}

# Refusals worth stopping for rather than retrying.
CONNACK_FATAL = (4, 5)


class Untrusted(Exception):
    """The certificate is not the one that was pinned."""

    def __init__(self, seen):
        super().__init__("certificate mismatch")
        self.seen = seen


class Refused(Exception):
    """The printer answered, and said no."""

    def __init__(self, message, fatal=False):
        super().__init__(message)
        # Whether trying again could ever help.
        self.fatal = fatal


class Dropped(Exception):
    """The connection went away."""


# ------------------------------------------------------------------- reading


def merge(into, delta):
    """Fold a delta report into the state we are keeping.

    The printer sends its whole state once and small changes afterwards, so
    the running state is the accumulation. Dicts merge key by key; anything
    else replaces, because the printer resends whole objects inside its lists
    rather than patching them.
    """
    for key, value in delta.items():
        if isinstance(value, dict) and isinstance(into.get(key), dict):
            merge(into[key], value)
        else:
            into[key] = value


def number(value, fallback=0):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return fallback


def decimal(value, fallback=0.0):
    try:
        return round(float(value), 1)
    except (TypeError, ValueError):
        return fallback


def bits(value):
    """The printer writes its bitmasks as hex strings."""
    try:
        return int(str(value), 16)
    except (TypeError, ValueError):
        return 0


def colour(raw):
    """RRGGBBAA off the printer to #RRGGBB for QML.

    Anything that is not eight hex digits is a value we do not understand, and
    a grey square says so more honestly than a colour invented to fill the gap.
    """
    text = str(raw or "")
    if len(text) != 8:
        return "#808080"
    for ch in text:
        if ch not in "0123456789abcdefABCDEF":
            return "#808080"
    if text[6:8].upper() == "00":      # fully transparent: an empty slot
        return ""
    return "#" + text[:6].upper()


# The fans report in gears rather than percent, fifteen of them.
def fan(value):
    return min(100, max(0, round(number(value) / 15 * 100)))


# What the printer is doing, when it is doing something other than printing.
# Nothing here is shown while the printer is idle, because this field does not
# reliably return to a resting value: this printer reports stage 0 when it has
# been sitting untouched for hours.
STAGES = {
    1: "levelling the bed", 2: "heating the bed", 3: "measuring vibration",
    4: "changing filament", 5: "paused", 6: "paused: filament ran out",
    7: "heating the nozzle", 8: "calibrating extrusion", 9: "scanning the bed",
    10: "inspecting the first layer", 11: "identifying the build plate",
    12: "calibrating", 13: "homing", 14: "cleaning the nozzle",
    16: "paused by you", 17: "paused: front cover open",
    18: "calibrating the camera", 19: "calibrating flow",
    20: "paused: nozzle temperature", 21: "paused: bed temperature",
    22: "unloading filament", 23: "skipping objects", 24: "loading filament",
    25: "calibrating motor noise", 26: "paused: AMS disconnected",
    27: "paused: heat-break fan", 28: "paused: chamber temperature",
    29: "cooling the chamber", 30: "paused: your gcode said to",
    31: "motor noise showoff", 32: "paused: filament is covered",
    33: "paused: cutter error", 34: "paused: first layer failed",
    35: "paused: the nozzle is clogged",
}

SPEEDS = {1: "silent", 2: "standard", 3: "sport", 4: "ludicrous"}


def hms_code(entry):
    """Build the code Bambu's own wiki is indexed by.

    Both halves are 32-bit numbers that the wiki writes as four groups of four
    hex digits. Formatting them as numbers rather than passing the printer's
    text through is also what makes this safe to put in a URL later.
    """
    attr = number(entry.get("attr"))
    code = number(entry.get("code"))
    return "%04X_%04X_%04X_%04X" % (
        (attr >> 16) & 0xFFFF, attr & 0xFFFF,
        (code >> 16) & 0xFFFF, code & 0xFFFF,
    )


HMS_SEVERITY = {1: "fatal", 2: "serious", 3: "common", 4: "info"}


def trays_of(unit, present_bits, unit_index):
    """The four slots of one AMS, in slot order.

    Which slots are loaded is not on the unit but on the group above it: one
    bitmask covering every AMS at once, four bits each. So the bit for a slot
    is found by counting past the units before it.
    """
    out = []
    for entry in unit.get("tray", []):
        slot = number(entry.get("id"), -1)
        if slot < 0:
            continue
        colours = [c for c in (colour(x) for x in (entry.get("cols") or [])) if c]
        single = colour(entry.get("tray_color"))
        if not colours and single:
            colours = [single]
        kind = str(entry.get("tray_type") or "").strip()
        brand = str(entry.get("tray_sub_brands") or "").strip()
        out.append({
            "slot": slot,
            # The bitmask is the printer's own answer to what is loaded; a
            # slot can carry a remembered colour long after the spool is out.
            "present": bool(present_bits >> (unit_index * 4 + slot) & 1) and bool(kind),
            "label": brand or kind or "empty",
            "colors": colours,
            "temp_min": number(entry.get("nozzle_temp_min")),
            "temp_max": number(entry.get("nozzle_temp_max")),
        })
    out.sort(key=lambda t: t["slot"])
    return out


def model_of(info):
    """The printer's own name for itself, out of the module list.

    The OTA module carries it as product_name on current firmware -- measured
    as "Bambu Lab P1S" on a P1S running 01.10. Older firmware leaves it empty
    and identifies the machine by hardware and project codes instead, which is
    a lookup table this does not carry: an unnamed printer is shown by the make
    alone rather than guessed at.
    """
    for module in (info or {}).get("module") or []:
        if not isinstance(module, dict):
            continue
        if module.get("name") != "ota":
            continue
        name = str(module.get("product_name") or "").strip()
        # It reaches a Text element, so it is held to the same rule as every
        # other string the printer sends.
        if 0 < len(name) <= 40 and all(c.isalnum() or c in " -" for c in name):
            return name
    return ""


def snapshot(state):
    """Everything QML is allowed to know, named the way QML wants it.

    All the parsing lives here rather than in the shell script or in QML: one
    place that turns the printer's strings into numbers is one place to check
    when the printer starts saying something new.
    """
    ams = state.get("ams") or {}
    units = ams.get("ams") or []

    present_bits = bits(ams.get("tray_exist_bits", "0"))
    trays = []
    for index, unit in enumerate(units):
        for tray in trays_of(unit, present_bits, index):
            tray["ams"] = number(unit.get("id"), index)
            trays.append(tray)

    # tray_now indexes across every AMS at once: the top bits pick the unit and
    # the bottom two the slot. 255 means nothing is loaded, 254 the external
    # spool on the back.
    now = number(ams.get("tray_now"), 255)
    active_ams, active_slot = -1, -1
    if now < 254:
        active_ams, active_slot = now >> 2, now & 3
    for tray in trays:
        tray["active"] = tray["ams"] == active_ams and tray["slot"] == active_slot

    external = state.get("vt_tray") or {}
    ext_colours = [c for c in [colour(external.get("tray_color"))] if c]
    ext_type = str(external.get("tray_type") or "").strip()

    gcode_state = str(state.get("gcode_state") or "").upper()
    stage = number(state.get("stg_cur"), -1)

    lights = state.get("lights_report") or []
    light_on = any(
        str(node.get("node")) == "chamber_light" and str(node.get("mode")) == "on"
        for node in lights if isinstance(node, dict)
    )

    errors = []
    for entry in state.get("hms") or []:
        if not isinstance(entry, dict):
            continue
        errors.append({
            "code": hms_code(entry),
            "severity": HMS_SEVERITY.get((number(entry.get("code")) >> 16) & 0xFFFF, "info"),
        })

    return {
        "type": "state",
        "model": "",
        "gcode_state": gcode_state,
        # Only meaningful mid-print. An idle printer reports a stage that means
        # nothing, so saying "printing" over an idle machine is the bug this
        # avoids.
        "stage": STAGES.get(stage, "") if gcode_state not in ("", "IDLE", "FINISH", "FAILED") else "",
        "percent": max(0, min(100, number(state.get("mc_percent")))),
        "remaining_min": max(0, number(state.get("mc_remaining_time"))),
        "layer": number(state.get("layer_num")),
        "total_layers": number(state.get("total_layer_num")),
        "task": str(state.get("subtask_name") or ""),
        "nozzle": decimal(state.get("nozzle_temper")),
        "nozzle_target": decimal(state.get("nozzle_target_temper")),
        "nozzle_type": str(state.get("nozzle_type") or "").replace("_", " "),
        "nozzle_diameter": str(state.get("nozzle_diameter") or ""),
        "bed": decimal(state.get("bed_temper")),
        "bed_target": decimal(state.get("bed_target_temper")),
        "fan_part": fan(state.get("cooling_fan_speed")),
        "fan_aux": fan(state.get("big_fan1_speed")),
        "fan_chamber": fan(state.get("big_fan2_speed")),
        "speed": SPEEDS.get(number(state.get("spd_lvl")), ""),
        "wifi": str(state.get("wifi_signal") or ""),
        "light_on": light_on,
        "ams": {
            "present": bool(units),
            "humidity": number(ams.get("humidity") if isinstance(ams.get("humidity"), (int, str)) else 0),
            "trays": trays,
        },
        "external": {
            "present": bool(ext_type),
            "label": ext_type,
            "colors": ext_colours,
        },
        "print_error": number(state.get("print_error")),
        "errors": errors,
    }


# The AMS keeps its humidity on the unit, not the group.
def humidity_of(state):
    units = (state.get("ams") or {}).get("ams") or []
    if not units:
        return 0
    return number(units[0].get("humidity"))


# --------------------------------------------------------------------- modes


def watch(host, serial, code, fingerprint):
    """Hold the connection open forever, printing state as it changes."""
    state = {}
    backoff = 1
    last = ""
    model = ""

    while True:
        conn = Connection(host, serial, code, fingerprint)
        try:
            conn.open()
        except Untrusted as e:
            # Not something to retry: a different certificate is a different
            # printer, and the answer is a person deciding to trust it.
            emit({"type": "status", "connected": False, "fatal": True,
                  "error": "This is not the printer you trusted. Run: bambu trust",
                  "fingerprint": e.seen})
            return 1
        except Refused as e:
            emit({"type": "status", "connected": False, "fatal": e.fatal, "error": str(e)})
            if e.fatal:
                return 1
            time.sleep(backoff)
            backoff = min(BACKOFF_MAX, backoff * 2)
            continue
        except (OSError, ssl.SSLError) as e:
            # A printer that is switched off is the normal case, not a fault.
            emit({"type": "status", "connected": False, "error": "printer unreachable"})
            time.sleep(backoff)
            backoff = min(BACKOFF_MAX, backoff * 2)
            continue

        backoff = 1
        state = {}
        last = ""
        emit({"type": "status", "connected": True})

        now = time.monotonic()
        pinged = now
        pushed = now
        heard = now
        nudged = False

        try:
            conn.sock.settimeout(2)
            conn.get_version()
            conn.pushall()
            while True:
                for kind, payload in conn.read():
                    if kind != "publish":
                        continue
                    heard = time.monotonic()
                    nudged = False
                    try:
                        report = json.loads(payload.decode("utf-8", "replace"))
                    except ValueError:
                        continue
                    if "info" in report:
                        found = model_of(report["info"])
                        if found:
                            model = found
                            last = ""      # redraw with the name in place
                    if "print" not in report:
                        continue
                    merge(state, report["print"])
                    current = snapshot(state)
                    current["model"] = model
                    current["ams"]["humidity"] = humidity_of(state)
                    line = json.dumps(current, separators=(",", ":"))
                    # The printer repeats its wifi signal every few seconds
                    # whether or not anything moved. Only changes are worth
                    # waking the panel for.
                    if line != last:
                        last = line
                        sys.stdout.write(line + "\n")
                        sys.stdout.flush()

                clock = time.monotonic()
                if clock - pinged >= PING_EVERY:
                    conn.ping()
                    pinged = clock
                if clock - pushed >= PUSHALL_EVERY:
                    conn.pushall()
                    pushed = clock
                if clock - heard >= SILENCE_LIMIT:
                    if nudged:
                        raise Dropped("the printer stopped reporting")
                    # One prod before giving up: a printer that has stopped
                    # pushing usually starts again when asked, and a reconnect
                    # costs a visible gap in the bar.
                    conn.resume_push()
                    nudged = True
                    heard = clock
        except (Dropped, OSError, ssl.SSLError) as e:
            emit({"type": "status", "connected": False, "error": str(e) or "connection lost"})
        finally:
            conn.close()
        time.sleep(backoff)
        backoff = min(BACKOFF_MAX, backoff * 2)




# --------------------------------------------------------------------- camera


def camera(host, code, fingerprint, cache):
    """Hold the chamber camera open, writing each frame out as a file.

    The camera is its own small protocol rather than anything standard: one
    fixed-size greeting, and then JPEG frames each behind a sixteen-byte header
    whose first four bytes are the length. There is no RTSP on a P1 and no way
    to ask for one, so this is the only way in.

    It runs only while the panel is open. A frame is around 65 kB and they
    arrive a couple of times a second, which is not something to be decoding in
    the background all day for a panel nobody is looking at.
    """
    slot = 0
    backoff = 1

    while True:
        try:
            sock = connect_tls(host, CAMERA_PORT, fingerprint)
        except Untrusted as e:
            emit({"type": "camera", "ok": False, "fatal": True,
                  "error": "This is not the printer you trusted. Run: bambu trust",
                  "fingerprint": e.seen})
            return 1
        except (OSError, ssl.SSLError):
            emit({"type": "camera", "ok": False, "error": "no camera"})
            time.sleep(backoff)
            backoff = min(BACKOFF_MAX, backoff * 2)
            continue

        # The greeting: two magic numbers, two zeroes, then the username and
        # the access code each padded out to a fixed 32 bytes.
        greeting = (
            struct.pack("<IIII", 0x40, 0x3000, 0, 0)
            + b"bblp".ljust(32, b"\x00")
            + code.encode("utf-8")[:32].ljust(32, b"\x00")
        )

        backoff = 1
        buf = b""
        seen_any = False
        try:
            sock.sendall(greeting)
            sock.settimeout(20)
            while True:
                chunk = sock.recv(262144)
                if not chunk:
                    raise Dropped("the camera closed the connection")
                buf += chunk

                while len(buf) >= 16:
                    size = int.from_bytes(buf[0:4], "little")
                    # A length this far out means the stream is not where we
                    # think it is, and reading on would only make it worse.
                    if size <= 0 or size > 8_000_000:
                        raise Dropped("the camera sent a frame we cannot read")
                    if len(buf) < 16 + size:
                        break
                    frame = buf[16:16 + size]
                    buf = buf[16 + size:]
                    # Only whole pictures reach the panel. A truncated JPEG
                    # renders as a grey block with a torn bottom edge, which
                    # looks like a broken widget rather than a dropped frame.
                    if frame[:3] != b"\xff\xd8\xff" or frame[-2:] != b"\xff\xd9":
                        continue
                    path = write_frame(cache, slot, frame)
                    slot = (slot + 1) % FRAME_SLOTS
                    if path:
                        if not seen_any:
                            seen_any = True
                            emit({"type": "camera", "ok": True})
                        emit({"type": "frame", "path": path})
        except (Dropped, OSError, ssl.SSLError):
            emit({"type": "camera", "ok": False, "error": "the camera stopped"})
        finally:
            try:
                sock.close()
            except OSError:
                pass
        time.sleep(backoff)
        backoff = min(BACKOFF_MAX, backoff * 2)


def write_frame(cache, slot, data):
    """Write one frame, through a rename so the panel never reads a half file.

    Written 0600 and into a directory the shell script has already checked is
    ours: these are pictures of the inside of a room in your house.
    """
    final = os.path.join(cache, "frame-%d.jpg" % slot)
    temp = final + ".part"
    try:
        handle = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(handle, data)
        finally:
            os.close(handle)
        os.replace(temp, final)
        return final
    except OSError:
        try:
            os.unlink(temp)
        except OSError:
            pass
        return None



# Exactly the shape pybambu sends, down to the absent "param": a printer that
# does not recognise a message drops it without a word, so an extra field is
# indistinguishable from a printer that is ignoring you.
COMMANDS = {
    "stop": {"print": {"sequence_id": "0", "command": "stop"}},
    "pause": {"print": {"sequence_id": "0", "command": "pause"}},
    "resume": {"print": {"sequence_id": "0", "command": "resume"}},
    "light-on": {"system": {"sequence_id": "0", "command": "ledctrl",
                            "led_node": "chamber_light", "led_mode": "on",
                            "led_on_time": 500, "led_off_time": 500,
                            "loop_times": 0, "interval_time": 0}},
    "light-off": {"system": {"sequence_id": "0", "command": "ledctrl",
                             "led_node": "chamber_light", "led_mode": "off",
                             "led_on_time": 500, "led_off_time": 500,
                             "loop_times": 0, "interval_time": 0}},
}


# What counts as the printer having done it. Checked against the reports that
# arrive after the command goes out.
def acted(mode, state):
    gcode = str(state.get("gcode_state") or "").upper()
    if mode == "stop":
        return gcode in ("IDLE", "FINISH", "FAILED", "PREPARE")
    if mode == "pause":
        return gcode == "PAUSE"
    if mode == "resume":
        return gcode == "RUNNING"
    if mode in ("light-on", "light-off"):
        want = "on" if mode == "light-on" else "off"
        return any(str(n.get("node")) == "chamber_light" and str(n.get("mode")) == want
                   for n in (state.get("lights_report") or []) if isinstance(n, dict))
    return True


COMMAND_WINDOW = 12

# What a P1 does when it has decided not to listen.
#
# From firmware 01.07 onwards, a P1 that is signed in to Bambu's cloud ignores
# control commands that arrive over the local network. It does not refuse them
# and it does not answer: it goes on reporting its state as if nothing was
# said. pybambu calls this hybrid mode, and no client can talk its way past it
# -- the printer has to be put in LAN Only mode, which unbinds it from the
# cloud, or driven through the cloud instead.
#
# So the distinction worth drawing is between a printer that never said
# anything (something is wrong with the connection) and one that kept talking
# while ignoring us (this).
HYBRID = ("The printer is ignoring commands sent over the network. A P1 on "
          "firmware 01.07 or newer does that whenever it is signed in to Bambu's "
          "cloud. Switch it to LAN Only mode on the printer to control it from here.")


def command(mode, host, serial, code, fingerprint):
    """Send one command, then watch until the printer visibly does it.

    Published at QoS 0, because that is all the printer offers: it does not
    acknowledge a QoS 1 publish, so waiting for one reports failure on a
    command that worked. What is worth waiting for is the printer's own report
    changing -- "it stopped" rather than "the packet left".
    """
    conn = Connection(host, serial, code, fingerprint)
    try:
        conn.open()
    except Untrusted:
        emit({"ok": False, "error": "This is not the printer you trusted. Run: bambu trust"})
        return 1
    except Refused as e:
        emit({"ok": False, "error": str(e)})
        return 1
    except (OSError, ssl.SSLError):
        emit({"ok": False, "error": "printer unreachable"})
        return 1

    try:
        conn.publish(COMMANDS[mode])
        # The reports are partial, so they accumulate the same way the watcher
        # accumulates them: the field that says it worked may arrive in a
        # different message from the one that says anything at all.
        state = {}
        heard = False
        conn.sock.settimeout(1)
        deadline = time.monotonic() + COMMAND_WINDOW
        while time.monotonic() < deadline:
            for kind, payload in conn.read():
                if kind != "publish":
                    continue
                heard = True
                try:
                    report = json.loads(payload.decode("utf-8", "replace"))
                except ValueError:
                    continue
                if "print" not in report:
                    continue
                merge(state, report["print"])
                if acted(mode, state):
                    emit({"ok": True})
                    return 0
        # It kept reporting the whole time and simply did not do it, which is
        # the signature of a printer that has been told not to listen.
        emit({"ok": False, "error": HYBRID if heard else "the printer did not answer",
              "hybrid": heard})
        return 1
    except (Dropped, OSError, ssl.SSLError):
        emit({"ok": False, "error": "the connection dropped before the printer answered"})
        return 1
    finally:
        conn.close()


def main():
    mode = env("BAMBU_MODE")
    host = env("BAMBU_HOST")
    serial = env("BAMBU_SERIAL")
    code = env("BAMBU_ACCESS_CODE")
    fingerprint = env("BAMBU_FINGERPRINT")

    if mode == "watch":
        return watch(host, serial, code, fingerprint)
    if mode == "camera":
        return camera(host, code, fingerprint, env("BAMBU_CACHE"))
    if mode in COMMANDS:
        return command(mode, host, serial, code, fingerprint)
    sys.exit("bambu-mqtt: unknown mode %r" % mode)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
    except BrokenPipeError:
        # The shell closed the panel and went away; that is a normal ending.
        sys.exit(0)
