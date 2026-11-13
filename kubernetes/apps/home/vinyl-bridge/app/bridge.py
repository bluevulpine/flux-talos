#!/usr/bin/env python3
"""Vinyl bridge: a UPnP speaker the Victrola Stream Onyx autoplays to, which hands the record to
Home Assistant (and from there Music Assistant) instead of playing it.

Why it exists
-------------
The Victrola's autoplay pushes a record to exactly one "default speaker" (a Sonos group or a UPnP
renderer) with SetAVTransportURI + Play. Nothing else on the network is told a record started,
and it never sends Stop (none in 3.7 h of testing, 2026-11-10). This pod is that UPnP renderer.
It plays nothing: on Play it calls an HA webhook with the stream URL, and HA has Music Assistant
play that URL to whatever speakers it picks. It finds the end of a record from the stream itself.

What the Victrola does (observed 2026-11-10, firmware 0.43.179)
---------------------------------------------------------------
* UPnP output offers FLAC: SetAVTransportURI http://<victrola>:<port>/stream.flac, DIDL
  audio/x-flac, served as audio/ogg (Ogg FLAC, 48 kHz, 24-bit, stereo, ~1.1 Mbps).
* The port changes between sessions, so the URL is always taken from the request, never pinned.
* ~100 s after the FLAC URI it re-sent SetAVTransportURI with :<port>/stream.mp3 (320 kbps MP3)
  and Play. The likeliest cause is that the test renderer never consumed the stream. This bridge
  reads the stream continuously for as long as it is up, and while its FLAC stream is still
  flowing it IGNORES a later MP3 URI (logged), so HA keeps the lossless one. If the FLAC stream
  has died, it switches to the new URI and tells HA again.
* With the needle parked the stream stays up but carries digital silence (-90 dBFS). FLAC
  compresses that to almost nothing, so a sustained drop in the byte rate is the end-of-record
  signal: below SILENCE_BPS for SILENCE_SECONDS -> "stop"; back above it -> "start" again (the
  next side). An MP3 stream is constant bitrate, so on MP3 there is no automatic stop (logged).

Interfaces: SSDP and the UPnP HTTP server bind the VLAN-30 macvlan address (BIND_IP), because the
Victrola only finds renderers on its own L2. The webhook goes to Home Assistant BY NAME over the
pod's cluster interface, so moving HA to another VLAN or address does not break the bridge.

Stdlib only. Env: BIND_IP, HA_URL (e.g. http://homeassistant.funb.us:8123), HA_WEBHOOK_ID,
NAME, UDN_SEED, HTTP_PORT, SILENCE_BPS, SILENCE_SECONDS, STALL_SECONDS, POWER_POLL_SECONDS,
VICTROLA_API_PORT.
"""
import http.server
import json
import os
import queue
import re
import socket
import socketserver
import struct
import threading
import time
import urllib.parse
import urllib.request
import uuid as uuidlib

BIND_IP = os.environ["BIND_IP"]
HA_URL = os.environ["HA_URL"].rstrip("/")
HA_WEBHOOK_ID = os.environ["HA_WEBHOOK_ID"]
NAME = os.environ.get("NAME", "Vinyl")
PORT = int(os.environ.get("HTTP_PORT", "49494"))
# The Victrola stores the renderer's UDN as its default speaker, so it must survive restarts and
# IP changes: derive it from a fixed seed, not from the address.
UDN = "uuid:" + str(uuidlib.uuid5(uuidlib.NAMESPACE_DNS, os.environ.get("UDN_SEED", "vinyl-bridge.home")))
SILENCE_BPS = int(os.environ.get("SILENCE_BPS", "64000"))         # bits/s; music FLAC is ~1 Mbps
SILENCE_SECONDS = int(os.environ.get("SILENCE_SECONDS", "45"))    # longer than a quiet passage
WINDOW_S = 5
STALL_S = int(os.environ.get("STALL_SECONDS", "60"))  # no byte at all for this long: reconnect
# A reconnect that yields less than this before failing counts as a failed one. In standby the
# Victrola still answers and sends a few header bytes (151 observed) before stalling, which
# used to reset the retry count, so the bridge reconnected every minute forever.
MIN_GOOD_BYTES = 64 * 1024
# How often to read the Victrola's power state while following a stream. It drops from
# "online" to "networkStandby" (reason idleTimer) about 9 min after the last record ends
# (2026-11-13); that ends the session cleanly.
POWER_POLL_S = int(os.environ.get("POWER_POLL_SECONDS", "15"))
# Only networkStandby has been observed; "standby" and "off" are guesses at the deeper states.
STANDBY_TARGETS = {"networkStandby", "standby", "off"}
VICTROLA_API_PORT = int(os.environ.get("VICTROLA_API_PORT", "80"))  # its local API (tests override)
SINK = ",".join([
    "http-get:*:audio/x-flac:*", "http-get:*:audio/flac:*", "http-get:*:audio/ogg:*",
    "http-get:*:audio/mpeg:*",
])
LOCATION = f"http://{BIND_IP}:{PORT}/desc.xml"
SSDP_ADDR, SSDP_PORT = "239.255.255.250", 1900
TYPES = [
    "upnp:rootdevice", UDN,
    "urn:schemas-upnp-org:device:MediaRenderer:1",
    "urn:schemas-upnp-org:service:AVTransport:1",
    "urn:schemas-upnp-org:service:ConnectionManager:1",
    "urn:schemas-upnp-org:service:RenderingControl:1",
]


def log(*a):
    print(time.strftime("%Y-%m-%dT%H:%M:%S"), *a, flush=True)


def fmt_of(uri):
    return "flac" if uri.endswith(".flac") else "mp3" if uri.endswith(".mp3") else "unknown"


def _post(event, uri):
    """Tell HA. Failures are logged, not raised: a missed call must not kill the renderer."""
    body = json.dumps({"event": event, "url": uri, "format": fmt_of(uri) if uri else ""}).encode()
    req = urllib.request.Request(f"{HA_URL}/api/webhook/{HA_WEBHOOK_ID}", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            log("webhook", event, fmt_of(uri) if uri else "", "->", r.status)
    except Exception as e:
        log("webhook", event, "FAILED:", repr(e))


# One worker sends the webhooks, in order, off the request path: a slow or absent HA must not
# delay the SOAP answer to Play/Stop (a control point may treat a slow renderer as failed), and
# start/stop must not overtake each other.
_HOOKS = queue.Queue()


def _hook_worker():
    while True:
        _post(*_HOOKS.get())


def webhook(event, uri=""):
    _HOOKS.put((event, uri))


class Session:
    """The one stream the bridge is following. Reads it continuously and tracks silence."""

    def __init__(self):
        self.lock = threading.Lock()
        self.uri = ""
        self.pending_uri = ""
        self.alive = False          # True while the consumer is receiving bytes
        self.following = False      # True from Play until the consumer gives up or Stop
        self.generation = 0         # bumps when a new stream replaces the old one
        self.stop_sent = False      # HA was told "stop" (silence) and not "start" since
        self.transport = "NO_MEDIA_PRESENT"

    def set_uri(self, uri):
        with self.lock:
            if self.alive and fmt_of(self.uri) == "flac" and fmt_of(uri) != "flac":
                log("ignoring", fmt_of(uri), "URI while FLAC is still flowing:", uri)
                return
            self.pending_uri = uri
            log("URI set:", uri)

    def play(self):
        with self.lock:
            uri = self.pending_uri or self.uri
            if not uri:
                log("Play with no URI; ignored")
                return
            self.transport = "PLAYING"
            if uri == self.uri and self.following:
                return              # already following it (the Victrola sends Play twice)
            self.uri, self.pending_uri = uri, ""
            self.generation += 1
            gen = self.generation
            self.following, self.stop_sent = True, False
            # Enqueue under the lock (put never blocks), so the webhook order always matches
            # the order the session changed in.
            webhook("start", uri)
        threading.Thread(target=self._consume, args=(gen, uri), daemon=True).start()

    def stop(self, reason, gen=None):
        with self.lock:
            if gen is not None and self.generation != gen:
                return              # a newer Play already replaced the stream that gave up
            self.generation += 1
            self.transport = "STOPPED"
            was, told = self.uri, self.stop_sent
            self.uri, self.alive, self.following, self.stop_sent = "", False, False, False
            # A dead stream reads as silence first, so _watch has usually sent stop minutes
            # before the retries run out; a second one could cut off whatever HA plays since.
            if was and not told:
                webhook("stop", was)
        if was:
            log("stop:", reason, "(HA already told)" if told else "")

    def _report(self, gen, event, uri):
        """Send a silence/sound transition for this generation, remembering an unanswered stop."""
        with self.lock:
            if self.generation != gen:
                return
            self.stop_sent = event == "stop"
            webhook(event, uri)

    def _set_alive(self, gen, value):
        with self.lock:
            if self.generation == gen:   # an old consumer must not speak for a newer stream
                self.alive = value

    def _consume(self, gen, uri):
        """Read the stream for as long as this generation lasts.

        Reading and judging are split: this thread only reads and counts bytes, and _watch samples
        the count every WINDOW_S. Silent Ogg FLAC may arrive as one small page every several
        seconds, so a blocking fixed-size read could stall for a minute per chunk, and a socket
        timeout cannot be survived (the response object is unusable after one). With the split,
        a quiet stream simply shows a low byte rate, and only a long STALL_S with no byte at all
        counts as a broken connection.
        """
        counter = [0]
        threading.Thread(target=self._watch, args=(gen, uri, counter), daemon=True).start()
        threading.Thread(target=self._power, args=(gen, uri), daemon=True).start()
        failures = 0
        while self.generation == gen:
            got, t0 = 0, time.monotonic()
            try:
                req = urllib.request.Request(uri, headers={"User-Agent": "vinyl-bridge"})
                with urllib.request.urlopen(req, timeout=STALL_S) as r:
                    log("consuming", fmt_of(uri), r.headers.get("Content-Type"))
                    while self.generation == gen:
                        chunk = r.read1(65536)   # returns whatever has arrived, however small
                        if not chunk:
                            raise EOFError("stream ended")
                        got += len(chunk)
                        counter[0] += len(chunk)
                        self._set_alive(gen, True)
            except Exception as e:
                self._set_alive(gen, False)
                # Only a connection that delivered real audio resets the count, so a stream that
                # keeps dropping and reconnecting with data is still followed, but one that only
                # hands out a header and stalls (the Victrola in standby) is given up on.
                # A long-lived connection also counts as good: a parked needle between sides
                # carries almost no bytes, and dropping that session would lose the next start.
                good = got >= MIN_GOOD_BYTES or time.monotonic() - t0 > 2 * STALL_S
                failures = 0 if good else failures + 1
                log("stream error", failures, f"after {got} bytes:", repr(e))
                if failures >= 5:
                    self.stop("stream gone after 5 retries", gen)
                    return
                time.sleep(2 * max(failures, 1))

    def _power(self, gen, uri):
        """End the session when the Victrola goes to standby (read-only GET on its local API).

        Errors are ignored: the API is a convenience, and the stream checks still end a session
        without it."""
        api = f"http://{urllib.parse.urlsplit(uri).hostname}:{VICTROLA_API_PORT}/api/getData?path=powermanager:target&roles=@all"
        while True:
            time.sleep(POWER_POLL_S)
            if self.generation != gen:
                return
            try:
                with urllib.request.urlopen(api, timeout=5) as r:
                    target = json.load(r)["value"]["powerTarget"]["target"]
            except Exception:
                continue
            if target in STANDBY_TARGETS:
                self.stop(f"Victrola went to {target}", gen)
                return

    def _watch(self, gen, uri, counter):
        """Every WINDOW_S, turn the byte count into a bit rate and track silence (FLAC only)."""
        silent, silent_for, last = False, 0.0, 0
        if fmt_of(uri) != "flac":
            log("following", fmt_of(uri), "stream: constant bitrate, so no automatic stop")
            return
        while True:
            time.sleep(WINDOW_S)
            if self.generation != gen:
                return
            n, last = counter[0] - last, counter[0]
            bps = n * 8 / WINDOW_S
            if bps < SILENCE_BPS:           # also covers a stalled or reconnecting stream
                silent_for += WINDOW_S
                if not silent and silent_for >= SILENCE_SECONDS:
                    silent = True
                    log(f"silence for {silent_for:.0f} s ({bps:.0f} bit/s): stop")
                    self._report(gen, "stop", uri)
            else:
                if silent:
                    log(f"sound again ({bps:.0f} bit/s): start")
                    self._report(gen, "start", uri)
                silent, silent_for = False, 0.0


SESSION = Session()

DESC = f"""<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>
<device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>{NAME}</friendlyName><manufacturer>homelab</manufacturer><modelName>vinyl-bridge</modelName>
<UDN>{UDN}</UDN><serviceList>
<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
<SCPDURL>/avt.xml</SCPDURL><controlURL>/ctl/avt</controlURL><eventSubURL>/evt/avt</eventSubURL></service>
<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
<SCPDURL>/cm.xml</SCPDURL><controlURL>/ctl/cm</controlURL><eventSubURL>/evt/cm</eventSubURL></service>
<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
<SCPDURL>/rc.xml</SCPDURL><controlURL>/ctl/rc</controlURL><eventSubURL>/evt/rc</eventSubURL></service>
</serviceList></device></root>"""


def scpd(actions):
    out = ['<?xml version="1.0"?><scpd xmlns="urn:schemas-upnp-org:service-1-0">'
           "<specVersion><major>1</major><minor>0</minor></specVersion><actionList>"]
    for name, ins, outs in actions:
        out.append(f"<action><name>{name}</name><argumentList>")
        out += [f"<argument><name>{a}</name><direction>in</direction></argument>" for a in ins]
        out += [f"<argument><name>{a}</name><direction>out</direction></argument>" for a in outs]
        out.append("</argumentList></action>")
    out.append("</actionList><serviceStateTable/></scpd>")
    return "".join(out)


SCPDS = {
    "/avt.xml": scpd([
        ("SetAVTransportURI", ["InstanceID", "CurrentURI", "CurrentURIMetaData"], []),
        ("Play", ["InstanceID", "Speed"], []), ("Stop", ["InstanceID"], []), ("Pause", ["InstanceID"], []),
        ("GetTransportInfo", ["InstanceID"], ["CurrentTransportState", "CurrentTransportStatus", "CurrentSpeed"]),
        ("GetPositionInfo", ["InstanceID"], ["Track", "TrackDuration", "TrackMetaData", "TrackURI", "RelTime", "AbsTime", "RelCount", "AbsCount"]),
        ("GetMediaInfo", ["InstanceID"], ["NrTracks", "MediaDuration", "CurrentURI", "CurrentURIMetaData", "NextURI", "NextURIMetaData", "PlayMedium", "RecordMedium", "WriteStatus"]),
    ]),
    "/cm.xml": scpd([("GetProtocolInfo", [], ["Source", "Sink"]), ("GetCurrentConnectionIDs", [], ["ConnectionIDs"])]),
    "/rc.xml": scpd([
        ("GetVolume", ["InstanceID", "Channel"], ["CurrentVolume"]),
        ("SetVolume", ["InstanceID", "Channel", "DesiredVolume"], []),
        ("GetMute", ["InstanceID", "Channel"], ["CurrentMute"]),
    ]),
}


def xml_arg(body, name):
    m = re.search(rf"<{name}[^>]*>(.*?)</{name}>", body, re.S)
    return m.group(1) if m else ""


def unescape(s):
    return (s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"')
            .replace("&apos;", "'").replace("&amp;", "&"))


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def respond(action, body):
    s = SESSION
    if action == "SetAVTransportURI":
        s.set_uri(unescape(xml_arg(body, "CurrentURI")))
        return {}
    if action == "Play":
        s.play()
        return {}
    if action == "Stop":
        s.stop("Stop from controller")
        return {}
    if action == "Pause":
        return {}
    if action == "GetTransportInfo":
        return {"CurrentTransportState": s.transport, "CurrentTransportStatus": "OK", "CurrentSpeed": "1"}
    if action == "GetPositionInfo":
        return {"Track": "1", "TrackDuration": "NOT_IMPLEMENTED", "TrackMetaData": "", "TrackURI": s.uri,
                "RelTime": "00:00:00", "AbsTime": "NOT_IMPLEMENTED", "RelCount": "2147483647", "AbsCount": "2147483647"}
    if action == "GetMediaInfo":
        return {"NrTracks": "1", "MediaDuration": "", "CurrentURI": s.uri, "CurrentURIMetaData": "", "NextURI": "",
                "NextURIMetaData": "", "PlayMedium": "NETWORK", "RecordMedium": "NOT_IMPLEMENTED", "WriteStatus": "NOT_IMPLEMENTED"}
    if action == "GetProtocolInfo":
        return {"Source": "", "Sink": SINK}
    if action == "GetCurrentConnectionIDs":
        return {"ConnectionIDs": "0"}
    if action == "GetVolume":
        return {"CurrentVolume": "50"}
    if action == "GetMute":
        return {"CurrentMute": "0"}
    return {}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002 (base-class signature)
        pass                                # polling is constant; SOAP actions are logged below

    def _send(self, code, body=b"", ctype='text/xml; charset="utf-8"', extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Server", "Linux/6 UPnP/1.0 vinyl-bridge/1.0")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/desc.xml":
            return self._send(200, DESC.encode())
        if self.path in SCPDS:
            return self._send(200, SCPDS[self.path].encode())
        if self.path == "/healthz":
            return self._send(200, json.dumps({"transport": SESSION.transport, "streaming": SESSION.alive,
                                               "format": fmt_of(SESSION.uri)}).encode(), "application/json")
        self._send(404)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        service, _, action = self.headers.get("SOAPACTION", "").strip('"').partition("#")
        if action not in ("GetTransportInfo", "GetPositionInfo", "GetMediaInfo", "GetVolume", "GetMute"):
            log("SOAP", self.client_address[0], action)
        out = respond(action, body)
        args = "".join(f"<{k}>{esc(v)}</{k}>" for k, v in out.items())
        resp = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
                's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
                f'<u:{action}Response xmlns:u="{service}">{args}</u:{action}Response></s:Body></s:Envelope>')
        self._send(200, resp.encode())

    def do_SUBSCRIBE(self):
        # Accept event subscriptions so the Victrola is satisfied; no events are ever sent.
        self._send(200, extra={"SID": "uuid:" + str(uuidlib.uuid4()), "TIMEOUT": "Second-1800"})

    def do_UNSUBSCRIBE(self):
        self._send(200)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def ssdp_msg(nt, nts=None, st=None):
    usn = UDN if nt == UDN else f"{UDN}::{nt}"
    lines = (["NOTIFY * HTTP/1.1", f"HOST: {SSDP_ADDR}:{SSDP_PORT}", f"NT: {nt}", f"NTS: {nts}"] if nts
             else ["HTTP/1.1 200 OK", "EXT:", f"ST: {st}"])
    lines += ["CACHE-CONTROL: max-age=1800", f"LOCATION: {LOCATION}",
              "SERVER: Linux/6 UPnP/1.0 vinyl-bridge/1.0", f"USN: {usn}", "", ""]
    return "\r\n".join(lines).encode()


def ssdp_loop():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", SSDP_PORT))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                 struct.pack("4s4s", socket.inet_aton(SSDP_ADDR), socket.inet_aton(BIND_IP)))
    out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    out.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(BIND_IP))
    out.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    out.bind((BIND_IP, 0))

    def notify():
        while True:
            for nt in TYPES:
                out.sendto(ssdp_msg(nt, nts="ssdp:alive"), (SSDP_ADDR, SSDP_PORT))
            time.sleep(30)
    threading.Thread(target=fatal_on_error(notify), daemon=True).start()

    while True:
        data, addr = s.recvfrom(4096)
        text = data.decode("utf-8", "replace")
        if not text.startswith("M-SEARCH"):
            continue
        m = re.search(r"^ST:\s*(.+?)\s*$", text, re.M | re.I)
        st = m.group(1) if m else ""
        for t in (TYPES if st == "ssdp:all" else [st] if st in TYPES else []):
            out.sendto(ssdp_msg(t, st=t), addr)


def fatal_on_error(fn):
    """SSDP is the whole point: if it dies (no net1, address clash, sendto error), the HTTP
    server would keep /healthz green while the Victrola can no longer see Vinyl. Exit instead,
    so the pod restarts and the failure shows."""
    def run():
        try:
            fn()
        except BaseException as e:
            log(f"FATAL in {fn.__name__}:", repr(e))
        finally:
            os._exit(1)
    return run


if __name__ == "__main__":
    log(f"vinyl bridge '{NAME}' {UDN} at {LOCATION}; webhook to {HA_URL}; "
        f"silence < {SILENCE_BPS} bit/s for {SILENCE_SECONDS} s")
    threading.Thread(target=_hook_worker, daemon=True).start()
    threading.Thread(target=fatal_on_error(ssdp_loop), daemon=True).start()
    # All interfaces: the Victrola uses the VLAN-30 address (LOCATION), the kubelet probes
    # /healthz on the cluster IP (a node cannot reach its own macvlan children).
    Server(("", PORT), Handler).serve_forever()
