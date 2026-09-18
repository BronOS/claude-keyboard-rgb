#!/usr/bin/env python3
"""kbstrip — drive a WLED LED strip (DDP over UDP) as a Claude Code status indicator, Linux edition.

    kbstrip working|done|attention|idle|end   (hook client; session id read from the hook JSON on stdin)
    kbstrip status | stop | pause | resume | daemon | strip-test [secs per step]

A port of the strip path of kbstatus (macOS) with no keyboard: same config block, same colors,
same pulse math, same DDP frames, so any machine can drive the same strip (WLED shows the last
packet it received; one active sender at a time). Python 3.8+, standard library only.

Config: ~/.config/kbstatus/config.json (the "strip" block plus the status colors / timeouts);
KBSTRIP_CONFIG overrides the path. Log: ~/.cache/kbstrip (KBSTRIP_CACHE overrides); socket:
$XDG_RUNTIME_DIR/kbstrip.sock, else ~/.cache/kbstrip/sock (KBSTRIP_SOCK overrides).
"""
import json, math, os, select, socket, struct, subprocess, sys, time

HOME = os.path.expanduser("~")
CONFIG = os.environ.get("KBSTRIP_CONFIG", os.path.join(HOME, ".config/kbstatus/config.json"))
CACHE = os.environ.get("KBSTRIP_CACHE", os.path.join(HOME, ".cache/kbstrip"))
LOG, PAUSED = os.path.join(CACHE, "daemon.log"), os.path.join(CACHE, "paused")
# Unix socket paths are limited to ~104 bytes: prefer the short runtime dir; KBSTRIP_SOCK overrides.
SOCK = os.environ.get("KBSTRIP_SOCK") or (os.path.join(os.environ["XDG_RUNTIME_DIR"], "kbstrip.sock")
                                          if os.environ.get("XDG_RUNTIME_DIR") else os.path.join(CACHE, "sock"))
os.makedirs(CACHE, exist_ok=True)


def log(s):
    with open(LOG, "a") as f:
        f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + " " + s + "\n")


# ---- config -------------------------------------------------------------------------------------

DEFAULTS = dict(working=(0, 90, 255), done=(0, 255, 40), attention=(255, 0, 0), badgeColor=(255, 0, 0),
                doneHoldSeconds=90.0, workingTimeoutMinutes=20.0, pulseFloor=0.25,
                attentionStyle="pulse", workingStyle="pulse")
MAX_LEDS = 480


def parse_strip(j):
    """The "strip" block, validated like StripConfig.parse in core.swift. Returns (cfg, error)."""
    if not isinstance(j, dict):
        return None, "strip must be an object"
    host = j.get("host")
    if not isinstance(host, str) or not host:
        return None, "strip.host missing"
    leds = j.get("leds")
    if not isinstance(leds, int) or not 1 <= leds <= MAX_LEDS:
        return None, "strip.leds must be 1...%d" % MAX_LEDS

    def rng(key):
        v = j.get(key)
        if v is None:
            return None, None
        ok = isinstance(v, list) and len(v) == 2 and all(isinstance(x, int) for x in v) and 0 <= v[0] <= v[1] < leds
        return ((v[0], v[1]), None) if ok else (None, "strip.%s must be [first, last] within 0...%d" % (key, leds - 1))

    sr, e = rng("statusRange")
    if e:
        return None, e
    br, e = rng("badgeRange")
    if e:
        return None, e
    c = dict(host=host, port=4048, leds=leds, statusRange=sr or (0, leds - 1), badgeRange=br,
             brightness=0.6, badgeWidth=1, fps=5.0, keepAliveSeconds=1.0, transport="ddp")
    if "port" in j:
        if not isinstance(j["port"], int) or not 1 <= j["port"] <= 65535:
            return None, "strip.port out of range"
        c["port"] = j["port"]
    if isinstance(j.get("brightness"), (int, float)):
        c["brightness"] = max(0.0, min(1.0, float(j["brightness"])))
    if "badgeWidth" in j:
        if not isinstance(j["badgeWidth"], int) or j["badgeWidth"] < 1:
            return None, "strip.badgeWidth must be >= 1"
        c["badgeWidth"] = j["badgeWidth"]
    if isinstance(j.get("fps"), (int, float)):
        c["fps"] = max(1.0, min(10.0, float(j["fps"])))
    if isinstance(j.get("keepAliveSeconds"), (int, float)):
        c["keepAliveSeconds"] = max(0.2, float(j["keepAliveSeconds"]))
    if isinstance(j.get("transport"), str):
        c["transport"] = j["transport"]
    if c["transport"] != "ddp":
        return None, 'strip.transport "%s" not supported (only ddp)' % c["transport"]
    return c, None


def load_config():
    cfg = dict(DEFAULTS, strip=None, stripError=None)
    try:
        with open(CONFIG) as f:
            j = json.load(f)
    except FileNotFoundError:
        cfg["stripError"] = "no config at " + CONFIG
        return cfg
    except ValueError as e:
        cfg["stripError"] = "config is not valid JSON: %s" % e
        return cfg
    for k in ("working", "done", "attention", "badgeColor"):
        v = j.get(k)
        if isinstance(v, list) and len(v) == 3 and all(isinstance(x, int) for x in v):
            cfg[k] = tuple(max(0, min(255, x)) for x in v)
    for k in ("doneHoldSeconds", "workingTimeoutMinutes", "pulseFloor"):
        if isinstance(j.get(k), (int, float)):
            cfg[k] = float(j[k])
    for k in ("attentionStyle", "workingStyle"):
        if isinstance(j.get(k), str):
            cfg[k] = j[k]
    if "strip" in j:
        cfg["strip"], cfg["stripError"] = parse_strip(j["strip"])
    else:
        cfg["stripError"] = "no strip block in " + CONFIG
    return cfg


# ---- picture: same math as core.swift ------------------------------------------------------------

NOMINAL_HZ = {"attention": 2.0, "working": 0.8}


def pulse_level(t, hz, floor):
    return floor + (1 - floor) * (0.5 - 0.5 * math.cos(2 * math.pi * hz * t))


def scaled(c, level):
    return tuple(int(round(x * level)) for x in c)


def style_for(status, cfg):
    return cfg["workingStyle"] if status == "working" else cfg["attentionStyle"] if status == "attention" else "static"


def strip_colors(status, style, badge, t, sc, cfg):
    out = [(0, 0, 0)] * sc["leds"]
    color = cfg.get(status) if status in ("working", "done", "attention") else None
    if color:
        if style == "pulse":
            level = pulse_level(t, min(NOMINAL_HZ.get(status, 0.8), sc["fps"] / 4), cfg["pulseFloor"])
        elif style == "blink":
            level = 1 if t % 1.0 < 0.5 else 0
        else:
            level = 1
        lit = scaled(color, level)
        a, b = sc["statusRange"]
        for i in range(a, b + 1):
            out[i] = lit
    if sc["badgeRange"] and badge > 0:
        a, b = sc["badgeRange"]
        for i in range(a, a + min(badge * sc["badgeWidth"], b - a + 1)):
            out[i] = cfg["badgeColor"]
    return out if sc["brightness"] == 1 else [scaled(c, sc["brightness"]) for c in out]


# ---- DDP ------------------------------------------------------------------------------------------
# 10-byte header: flags (0x40 = v1, |0x01 = push), sequence 1..15, type 0x0B (RGB 8-bit),
# destination 1, channel offset (u32 BE), data length (u16 BE); then RGB bytes. 160 LEDs per packet.

LEDS_PER_PACKET = 160


def ddp_frame(colors, seq):
    if not colors:
        return [struct.pack(">BBBBIH", 0x41, seq & 0x0F, 0x0B, 1, 0, 0)]
    pkts = []
    for s in range(0, len(colors), LEDS_PER_PACKET):
        chunk = colors[s:s + LEDS_PER_PACKET]
        push = s + LEDS_PER_PACKET >= len(colors)
        data = bytes(x for c in chunk for x in c)
        pkts.append(struct.pack(">BBBBIH", 0x40 | (1 if push else 0), seq & 0x0F, 0x0B, 1, s * 3, len(data)) + data)
    return pkts


class StripSender:
    """Fire-and-forget UDP to the board: no acks, no retries. Re-resolves the host no sooner than 60 s after an error."""

    def __init__(self, sc):
        self.cfg, self.sock, self.addr, self.seq, self.packets = sc, None, None, 1, 0
        self.last_resolve, self.err_logged, self.target = 0.0, False, "unresolved"
        self.resolve()

    def resolve(self):
        self.last_resolve = time.monotonic()
        try:
            fam, _, _, _, addr = socket.getaddrinfo(self.cfg["host"], self.cfg["port"], type=socket.SOCK_DGRAM)[0]
        except socket.gaierror as e:
            log("strip: cannot resolve %s: %s" % (self.cfg["host"], e))
            self.addr = None
            return
        if self.sock:
            self.sock.close()
        self.sock, self.addr, self.target = socket.socket(fam, socket.SOCK_DGRAM), addr, addr[0]
        c = self.cfg
        log("strip: %s -> %s:%d, %d LEDs, status %s, badges %s, brightness %s"
            % (c["host"], self.target, c["port"], c["leds"], c["statusRange"], c["badgeRange"] or "none", c["brightness"]))

    def send(self, colors):
        if self.addr is None:
            if time.monotonic() - self.last_resolve > 60:
                self.resolve()
            if self.addr is None:
                return
        try:
            for p in ddp_frame(colors, self.seq):
                self.sock.sendto(p, self.addr)
                self.packets += 1
        except OSError as e:
            if not self.err_logged:
                log("strip: send to %s failed: %s" % (self.target, e))
                self.err_logged = True
            self.addr, self.last_resolve = None, time.monotonic()
            return
        self.err_logged = False
        self.seq = 1 if self.seq >= 15 else self.seq + 1


# ---- daemon ---------------------------------------------------------------------------------------

class Daemon:
    def __init__(self, cfg):
        self.cfg, self.sessions, self.stop = cfg, {}, False   # sessions: id -> (status, since)
        self.strip = StripSender(cfg["strip"])
        self.last_send, self.last_colors, self.shown = 0.0, None, None

    def composite(self):
        now = time.time()
        for sid, (st, since) in list(self.sessions.items()):
            if st == "done" and now - since > self.cfg["doneHoldSeconds"]:
                del self.sessions[sid]
            elif st == "working" and now - since > self.cfg["workingTimeoutMinutes"] * 60:
                del self.sessions[sid]
        states = {s for s, _ in self.sessions.values()}
        for s in ("attention", "working", "done"):
            if s in states:
                return s
        return "idle"

    def handle(self, line):
        parts = line.split()
        if line == "STATUS":
            return self.status_text()
        if line == "STOP":
            self.stop = True
            return ""
        if len(parts) >= 3 and parts[0] == "SET":
            sid, verb = parts[1], parts[2]
            if verb in ("end", "idle"):
                self.sessions.pop(sid, None)
                log("session %s %s" % (sid, "ended" if verb == "end" else "-> idle"))
            elif verb in ("working", "done", "attention"):
                self.sessions[sid] = (verb, time.time())
                log("session %s -> %s" % (sid, verb))
        return ""

    def status_text(self):
        s = self.strip
        t = "composite: %s\nshown: %s\nstrip: %s (%s) %d LEDs, %d packets, last %s\n" % (
            self.composite(), self.shown or "none", s.cfg["host"], s.target, s.cfg["leds"], s.packets,
            "%.1f s ago" % (time.monotonic() - self.last_send) if self.last_send else "never")
        for sid, (st, since) in self.sessions.items():
            t += "  %s %s since %ds\n" % (sid, st, int(time.time() - since))
        return t

    def render(self):
        status, sc, t = self.composite(), self.strip.cfg, time.monotonic()
        style = style_for(status, self.cfg)
        colors = strip_colors(status, style, 0, t, sc, self.cfg)
        dark = status == "idle"
        if style in ("pulse", "blink") and self.shown == status and t - self.last_send < 1.0 / sc["fps"]:
            return
        changed = colors != self.last_colors
        if not changed and (dark or t - self.last_send < sc["keepAliveSeconds"]):
            return
        self.strip.send(colors)
        self.last_send, self.last_colors = t, colors
        if self.shown != status:
            self.shown = status
            log("strip: %s" % status)

    def run(self):
        if client_send("STATUS") is not None:
            sys.stderr.write("kbstrip daemon already running\n")
            return
        try:
            os.unlink(SOCK)
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(SOCK)
        srv.listen(16)
        log("daemon starting (pid %d)" % os.getpid())
        while not self.stop:
            ready, _, _ = select.select([srv], [], [], 0.1)
            for s in ready:
                conn, _ = s.accept()
                try:
                    line = conn.recv(512).decode("utf-8", "replace").strip()
                    reply = self.handle(line)
                    if reply:
                        conn.sendall(reply.encode())
                except OSError:
                    pass
                finally:
                    conn.close()
            self.render()
        self.strip.send([(0, 0, 0)] * self.strip.cfg["leds"])   # strip dark
        srv.close()
        try:
            os.unlink(SOCK)
        except FileNotFoundError:
            pass
        log("daemon stopped")


# ---- client ---------------------------------------------------------------------------------------

def client_send(line, expect_reply=False):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(SOCK)
        s.sendall((line + "\n").encode())
        return s.recv(4096).decode() if expect_reply else ""
    except OSError:
        return None
    finally:
        s.close()


def spawn_daemon():
    with open(LOG, "a") as out:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "daemon"], stdin=subprocess.DEVNULL,
                         stdout=out, stderr=out, start_new_session=True, close_fds=True)


def session_id(args):
    if "--session" in args:
        i = args.index("--session")
        if i + 1 < len(args):
            return args[i + 1]
    if not sys.stdin.isatty():
        try:
            j = json.load(sys.stdin)
            if isinstance(j, dict) and isinstance(j.get("session_id"), str):
                return j["session_id"][:36]
        except ValueError:
            pass
    return "manual"


def main(argv):
    verb = argv[0] if argv else "help"
    if verb in ("working", "done", "attention", "idle", "end"):
        if os.path.exists(PAUSED):
            return 0
        line = "SET %s %s" % (session_id(argv), verb)
        if client_send(line) is None:
            cfg = load_config()
            if not cfg["strip"]:
                sys.stderr.write("kbstrip: %s\n" % cfg["stripError"])
                return 1
            spawn_daemon()
            for _ in range(40):
                time.sleep(0.05)
                if client_send(line) is not None:
                    return 0
            sys.stderr.write("kbstrip: daemon not reachable\n")
            return 1
        return 0
    if verb == "status":
        print(client_send("STATUS", expect_reply=True) or "daemon not running", end="")
    elif verb == "stop":
        print("daemon not running" if client_send("STOP") is None else "stop requested")
    elif verb == "pause":
        client_send("STOP")
        open(PAUSED, "a").close()
        print("paused: hooks are no-ops, daemon stopped")
    elif verb == "resume":
        try:
            os.unlink(PAUSED)
        except FileNotFoundError:
            pass
        print("resumed: next hook call starts the daemon")
    elif verb == "daemon":
        cfg = load_config()
        if not cfg["strip"]:
            log("strip: disabled: %s" % cfg["stripError"])
            return 1
        Daemon(cfg).run()
    elif verb == "strip-test":   # red, green, blue on every LED, then the badge pattern, then off
        cfg = load_config()
        if not cfg["strip"]:
            print("no strip block: %s" % cfg["stripError"])
            return 1
        sc, step = cfg["strip"], float(argv[1]) if len(argv) > 1 else 1.0
        sender = StripSender(sc)
        print("strip: %s -> %s:%d, %d LEDs" % (sc["host"], sender.target, sc["port"], sc["leds"]))

        def show(colors, label):
            print("  " + label)
            sender.send(colors)
            time.sleep(step)

        for name, c in (("red", (255, 0, 0)), ("green", (0, 255, 0)), ("blue", (0, 0, 255))):
            show([scaled(c, sc["brightness"])] * sc["leds"], "%s on all %d LEDs" % (name, sc["leds"]))
        if sc["badgeRange"]:
            a, b = sc["badgeRange"]
            for n in range(1, b - a + 2):
                show(strip_colors("idle", "static", n, 0, sc, cfg), "badge %d of %d" % (n, b - a + 1))
        show([(0, 0, 0)] * sc["leds"], "off")
        print("sent %d packets" % sender.packets)
    else:
        print(__doc__.strip())
        print("config: %s   log: %s" % (CONFIG, LOG))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]) or 0)
