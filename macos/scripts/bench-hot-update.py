#!/usr/bin/env python3 -I
"""Hot-update bench for Mihomo: how fast, how reliably and how disruptively a routing change takes
effect, by four methods, against a throwaway core on its own ports with local servers only.

Exits are told apart by what answers: exit A's relay always reaches the server that answers "A",
exit B's the one that answers "B", and DIRECT reaches the requested host (answering "DIRECT")."""
import http.client, json, os, random, socket, statistics, struct, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import ThreadingTCPServer, StreamRequestHandler

# Usage: python3 -I scripts/bench-hot-update.py vendor/mihomo [work folder]
# Uses ports 17890, 19090, 18000-18002 and 18081-18082 on 127.0.0.1 only; nothing leaves the Mac.
ROOT = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".build", "bench-hot-update")
HOME = os.path.join(ROOT, "home")
os.makedirs(HOME, exist_ok=True)
MIHOMO = sys.argv[1]
MIXED, CTRL, SECRET = 17890, 19090, "bench"
API = f"http://127.0.0.1:{CTRL}"

# Test sockets close with a reset: thousands of short connections would otherwise hold every
# local port in TIME_WAIT and the bench, not Mihomo, would start failing.
LINGER = struct.pack("ii", 1, 0)

def quick(s):
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, LINGER)
    return s

# ---------- local servers ----------

def target_server(port, name):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def do_GET(self):
            body = name.encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *a): pass
    class Server(ThreadingHTTPServer):
        request_queue_size = 1024
    s = Server(("127.0.0.1", port), H)
    s.daemon_threads = True
    threading.Thread(target=s.serve_forever, daemon=True).start()

def relay(port, upstream):
    """An HTTP CONNECT proxy that ignores the requested target and always reaches `upstream`."""
    class H(StreamRequestHandler):
        def handle(self):
            try: self.relay()
            except OSError: pass
        def relay(self):
            quick(self.request)
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = self.request.recv(4096)
                if not chunk: return
                head += chunk
            out = quick(socket.create_connection(("127.0.0.1", upstream)))
            self.request.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            rest = head.split(b"\r\n\r\n", 1)[1]
            if rest: out.sendall(rest)
            def pipe(a, b):
                try:
                    while (d := a.recv(65536)): b.sendall(d)
                except OSError: pass
                finally:
                    for x in (a, b):
                        try: x.shutdown(socket.SHUT_RDWR)
                        except OSError: pass
            t = threading.Thread(target=pipe, args=(out, self.request), daemon=True); t.start()
            pipe(self.request, out); t.join()
    class Server(ThreadingTCPServer):
        allow_reuse_address = True
        request_queue_size = 1024
    s = Server(("127.0.0.1", port), H)
    s.daemon_threads = True
    threading.Thread(target=s.serve_forever, daemon=True).start()

# ---------- client ----------

class Tunnel:
    """One connection through Mihomo's mixed port (CONNECT), able to carry several requests."""
    def __init__(self, host, timeout=5):
        self.host = host
        self.s = quick(socket.create_connection(("127.0.0.1", MIXED), timeout=timeout))
        self.s.sendall(f"CONNECT {host}:18000 HTTP/1.1\r\nHost: {host}:18000\r\n\r\n".encode())
        head = self._until(b"\r\n\r\n")
        if b" 200" not in head.split(b"\r\n", 1)[0]: raise OSError("connect refused: " + head[:40].decode(errors="replace"))
        self.buf = b""
    def _until(self, mark):
        data = b""
        while mark not in data:
            chunk = self.s.recv(4096)
            if not chunk: raise OSError("closed")
            data += chunk
        return data
    def get(self):
        self.s.sendall(f"GET / HTTP/1.1\r\nHost: {self.host}\r\nConnection: keep-alive\r\n\r\n".encode())
        data = self.buf
        while b"\r\n\r\n" not in data:
            chunk = self.s.recv(4096)
            if not chunk: raise OSError("closed")
            data += chunk
        head, rest = data.split(b"\r\n\r\n", 1)
        length = int([l.split(b":")[1] for l in head.split(b"\r\n") if l.lower().startswith(b"content-length")][0])
        while len(rest) < length:
            chunk = self.s.recv(4096)
            if not chunk: raise OSError("closed")
            rest += chunk
        self.buf = rest[length:]
        return rest[:length].decode()
    def close(self):
        try: self.s.close()
        except OSError: pass

LAST_ERROR = threading.local()

def fetch(host):
    """A fresh connection, one request: (exit, ms) or (None, ms) on failure (why: LAST_ERROR.why)."""
    t = time.perf_counter()
    tn = None
    try:
        tn = Tunnel(host)
    except OSError as e:
        LAST_ERROR.why = "connect to mixed port: " + type(e).__name__ + (": " + str(e)[:40] if "refused" in str(e) else "")
        return None, (time.perf_counter() - t) * 1000
    try:
        body = tn.get(); tn.close()
        return body, (time.perf_counter() - t) * 1000
    except OSError as e:
        LAST_ERROR.why = "request inside tunnel: " + type(e).__name__
        tn.close()
        return None, (time.perf_counter() - t) * 1000

_api = threading.local()

def api(method, path, body=None):
    """One kept-alive connection per thread to the controller; reopened when the core restarts."""
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    for attempt in range(2):
        conn = getattr(_api, "conn", None) or http.client.HTTPConnection("127.0.0.1", CTRL, timeout=120)
        _api.conn = conn
        try:
            t = time.perf_counter()
            conn.request(method, path, body=data, headers={"Authorization": f"Bearer {SECRET}", "Content-Type": "application/json"})
            r = conn.getresponse(); payload = r.read()
            if r.status >= 400: raise RuntimeError(f"{method} {path} -> {r.status} {payload[:200]!r}")
            return r.status, (time.perf_counter() - t) * 1000, payload
        except (OSError, http.client.HTTPException):
            conn.close(); _api.conn = None
            if attempt: raise

def wait_for(host, want, limit=3.0):
    """(ms, attempts) until a fresh connection to `host` leaves by `want`; attempts 1 = the very
    first new connection after the change already did. (None, n) when it never did."""
    t, attempts = time.perf_counter(), 0
    while time.perf_counter() - t < limit:
        attempts += 1
        got, _ = fetch(host)
        if got == want: return (time.perf_counter() - t) * 1000, attempts
        time.sleep(0.005)
    return None, attempts

def track(results, w):
    ms, attempts = w
    if ms is not None: results["effect"].append(ms)
    if attempts == 1 and ms is not None: results["first"] += 1

def window(host, change=None, seconds=3.0, every=0.3):
    """Load for `seconds`, calling `change(i)` every `every` s when given: failures per window."""
    with Load(host) as load:
        t, i = time.perf_counter(), 0
        while time.perf_counter() - t < seconds:
            if change: change(i); i += 1
            time.sleep(every)
    return {"changes": i, "requests_ok": load.ok, "requests_failed": load.fail,
            "failure_rate": f"{100 * load.fail / max(1, load.ok + load.fail):.2f}%", "latency_ms": summary(load.lat), "why": load.why}

# ---------- load ----------

class Load:
    """Workers opening fresh connections to `host` back to back; failures and slow ones counted."""
    def __init__(self, host, workers=6):
        self.host, self.workers, self.stop = host, workers, threading.Event()
        self.ok = self.fail = 0
        self.lat, self.why = [], {}
        self.lock = threading.Lock()
    def run(self):
        while not self.stop.is_set():
            got, ms = fetch(self.host)
            time.sleep(0.005)
            with self.lock:
                if got is None:
                    self.fail += 1
                    reason = getattr(LAST_ERROR, "why", "?"); self.why[reason] = self.why.get(reason, 0) + 1
                else: self.ok += 1; self.lat.append(ms)
    def __enter__(self):
        self.threads = [threading.Thread(target=self.run, daemon=True) for _ in range(self.workers)]
        for t in self.threads: t.start()
        return self
    def __exit__(self, *a):
        self.stop.set()
        for t in self.threads: t.join()

# ---------- Mihomo ----------

def write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f: f.write(text)
    os.replace(tmp, path)

def provider_file(domains):
    return "payload:\n" + "".join(f"  - '{d}'\n" for d in domains) if domains else "payload: []\n"

def config(fillers, move_target="exitA", toggle=True):
    rules = ["RULE-SET,hot-a,exitA", "RULE-SET,hot-b,exitB", "DOMAIN-SUFFIX,sel.test,Sel",
             f"DOMAIN-SUFFIX,move.test,{move_target}"]
    if toggle: rules.append("DOMAIN-SUFFIX,tog.test,exitB")
    rules += [f"DOMAIN-SUFFIX,f{i}.filler,DIRECT" for i in range(fillers)]
    rules.append("MATCH,exitA")
    return f"""mixed-port: {MIXED}
external-controller: 127.0.0.1:{CTRL}
secret: {SECRET}
log-level: warning
ipv6: false
hosts:
  '+.test': 127.0.0.1
proxies:
  - {{name: exitA, type: http, server: 127.0.0.1, port: 18081}}
  - {{name: exitB, type: http, server: 127.0.0.1, port: 18082}}
proxy-groups:
  - {{name: Sel, type: select, proxies: [exitA, exitB]}}
rule-providers:
  hot-a: {{type: file, behavior: domain, path: ./hot-a.yaml, format: yaml}}
  hot-b: {{type: file, behavior: domain, path: ./hot-b.yaml, format: yaml}}
rules:
""" + "".join(f"  - {r}\n" for r in rules)

class Core:
    def __init__(self, fillers, store_selected=True):
        write(os.path.join(HOME, "hot-a.yaml"), provider_file([]))
        write(os.path.join(HOME, "hot-b.yaml"), provider_file([]))
        self.path = os.path.join(HOME, "bench.yaml")
        text = config(fillers)
        if not store_selected: text = text.replace("log-level: warning\n", "log-level: warning\nprofile:\n  store-selected: false\n")
        write(self.path, text)
        for port in (MIXED, CTRL):
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    raise SystemExit(f"port {port} is already taken: another core is running; stop it first")
        self.log = os.path.join(ROOT, "core.log")
        self.p = subprocess.Popen([MIHOMO, "-d", HOME, "-f", self.path], stdout=open(self.log, "w"), stderr=subprocess.STDOUT, cwd=HOME)
        _api.conn = None
        for _ in range(200):
            try:
                api("GET", "/version"); break
            except (OSError, RuntimeError): time.sleep(0.05)
        if self.p.poll() is not None or "address already in use" in open(self.log).read():
            raise SystemExit("the core did not start cleanly: " + open(self.log).read()[-400:])
    def usage(self):
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(self.p.pid)], capture_output=True, text=True).stdout.split()
        return {"rss_mb": round(int(out[0]) / 1024, 1)}
    def stop(self):
        self.p.terminate()
        try: self.p.wait(5)
        except subprocess.TimeoutExpired: self.p.kill(); self.p.wait()
        _api.conn = None
        for _ in range(100):
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", CTRL)) != 0: break
            time.sleep(0.05)

def pct(xs, p):
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(p / 100 * len(xs)))], 2) if xs else None

def summary(xs):
    return {"n": len(xs), "p50": pct(xs, 50), "p95": pct(xs, 95), "max": round(max(xs), 2) if xs else None}

# ---------- experiments ----------

def exp_select(n=200):
    """A select group's node: PUT /proxies/Sel. New connections, an open connection, load."""
    out = {}
    api_ms, r = [], {"first": 0, "effect": []}
    for i in range(n):
        want = "exitB" if i % 2 == 0 else "exitA"
        _, ms, _ = api("PUT", "/proxies/Sel", {"name": want})
        api_ms.append(ms)
        track(r, wait_for("sel.test", want[-1]))
    out["api_ms"] = summary(api_ms)
    out["first_new_connection_on_new_exit"] = f"{r['first']}/{n}"
    out["ms_until_effect"] = summary(r["effect"])
    # An open connection keeps its exit until it is closed.
    api("PUT", "/proxies/Sel", {"name": "exitA"}); time.sleep(0.05)
    tn = Tunnel("sel.test"); before = tn.get()
    api("PUT", "/proxies/Sel", {"name": "exitB"})
    after = tn.get()
    conns = json.loads(api("GET", "/connections")[2])["connections"] or []
    ids = [c["id"] for c in conns if c["metadata"].get("host") == "sel.test"]
    _, close_ms, _ = api("DELETE", f"/connections/{ids[0]}") if ids else (0, None, 0)
    try: tn.get(); survived = True
    except OSError: survived = False
    tn.close()
    out["open_connection"] = {"before": before, "after_switch_same_connection": after, "close_api_ms": close_ms and round(close_ms, 2),
                              "usable_after_close": survived, "new_connection_after_close": fetch("sel.test")[0]}
    out["baseline_load"] = window("sel.test")
    out["under_load"] = window("sel.test", lambda i: api("PUT", "/proxies/Sel", {"name": "exitB" if i % 2 == 0 else "exitA"}))
    return out

def exp_select_no_cache(n=100):
    """The same switch with Mihomo's selection cache off, to see where its time goes."""
    api_ms = []
    for i in range(n):
        _, ms, _ = api("PUT", "/proxies/Sel", {"name": "exitB" if i % 2 == 0 else "exitA"}); api_ms.append(ms)
    return {"api_ms": summary(api_ms)}

def exp_reload(core, fillers, n=20, force=False):
    """A rule change by reloading the whole config: PUT /configs with the new YAML. Veer sends it
    without `force`; `force=true` also rebuilds the listeners."""
    path = "/configs?force=true" if force else "/configs"
    out = {"rules": fillers + 6, "force": force}
    api_ms, r = [], {"first": 0, "effect": []}
    yaml_a, yaml_b = config(fillers, "exitA"), config(fillers, "exitB")
    out["yaml_kb"] = round(len(yaml_b.encode()) / 1024, 1)
    for i in range(n):
        want = "B" if i % 2 == 0 else "A"
        _, ms, _ = api("PUT", path, {"payload": yaml_b if want == "B" else yaml_a})
        api_ms.append(ms)
        track(r, wait_for("move.test", want))
    out["api_ms"] = summary(api_ms)
    out["first_new_connection_on_new_exit"] = f"{r['first']}/{n}"
    out["ms_until_effect"] = summary(r["effect"])
    tn = Tunnel("keep.test"); tn.get()
    api("PUT", path, {"payload": yaml_b})
    try: tn.get(); out["open_connection_survives"] = True
    except OSError: out["open_connection_survives"] = False
    tn.close()
    out["baseline_load"] = window("other.test")
    out["under_load"] = window("other.test", lambda i: api("PUT", path, {"payload": yaml_b if i % 2 == 0 else yaml_a}))
    return out

def exp_provider(fillers, provider_size, n=40):
    """A rule change by rewriting a file rule set and reloading only it: PUT /providers/rules/hot-b."""
    out = {"rules": fillers + 6, "rule_set_domains": provider_size}
    base = [f"p{i}.bulk" for i in range(provider_size)]
    path = os.path.join(HOME, "hot-b.yaml")
    api_ms, r = [], {"first": 0, "effect": []}
    for i in range(n):
        add = i % 2 == 0
        write(path, provider_file(base + (["+.move2.test"] if add else [])))
        _, ms, _ = api("PUT", "/providers/rules/hot-b")
        api_ms.append(ms)
        track(r, wait_for("move2.test", "B" if add else "A"))
    out["rule_count_reported"] = json.loads(api("GET", "/providers/rules")[2])["providers"]["hot-b"]["ruleCount"]
    out["api_ms"] = summary(api_ms)
    out["first_new_connection_on_new_exit"] = f"{r['first']}/{n}"
    out["ms_until_effect"] = summary(r["effect"])
    tn = Tunnel("keep.test"); tn.get()
    write(path, provider_file(base + ["+.move2.test"])); api("PUT", "/providers/rules/hot-b")
    try: tn.get(); out["open_connection_survives"] = True
    except OSError: out["open_connection_survives"] = False
    tn.close()
    def refresh(i):
        write(path, provider_file(base + (["+.move2.test"] if i % 2 == 0 else []))); api("PUT", "/providers/rules/hot-b")
    out["baseline_load"] = window("other.test")
    out["under_load"] = window("other.test", refresh)
    write(path, provider_file([])); api("PUT", "/providers/rules/hot-b")
    return out

def exp_disable(n=40):
    """A rule turned off and on in place: PATCH /rules/disable {index: bool}."""
    rules = json.loads(api("GET", "/rules")[2])["rules"]
    index = next(i for i, r in enumerate(rules) if r.get("payload") == "tog.test")
    out = {"rule_index": index}
    api_ms, codes, r = [], set(), {"first": 0, "effect": []}
    for i in range(n):
        off = i % 2 == 0
        code, ms, _ = api("PATCH", "/rules/disable", {str(index): off})
        codes.add(code); api_ms.append(ms)
        track(r, wait_for("tog.test", "A" if off else "B"))
    out["http_codes"] = sorted(codes)
    out["api_ms"] = summary(api_ms)
    out["first_new_connection_on_new_exit"] = f"{r['first']}/{n}"
    out["ms_until_effect"] = summary(r["effect"])
    out["baseline_load"] = window("other.test")
    out["under_load"] = window("other.test", lambda i: api("PATCH", "/rules/disable", {str(index): i % 2 == 0}))
    # Does a disabled rule stay disabled after a full reload?
    api("PATCH", "/rules/disable", {str(index): True})
    api("PUT", "/configs", {"payload": open(os.path.join(HOME, "bench.yaml")).read()})
    out["disabled_after_reload_route"] = fetch("tog.test")[0]
    api("PATCH", "/rules/disable", {str(index): False})
    return out

def exp_soak(core, n=1000):
    """Random changes by the three hot methods, each checked right after: does the core ever disagree?"""
    rules = json.loads(api("GET", "/rules")[2])["rules"]
    index = next(i for i, r in enumerate(rules) if r.get("payload") == "tog.test")
    path = os.path.join(HOME, "hot-b.yaml")
    state = {"sel": "A", "hot": False, "tog_off": False}
    wrong, failed, kinds = 0, 0, {"select": 0, "provider": 0, "disable": 0}
    before = core.usage()
    for _ in range(n):
        kind = random.choice(list(kinds)); kinds[kind] += 1
        if kind == "select":
            state["sel"] = "B" if state["sel"] == "A" else "A"
            api("PUT", "/proxies/Sel", {"name": "exit" + state["sel"]}); host, want = "sel.test", state["sel"]
        elif kind == "provider":
            state["hot"] = not state["hot"]
            write(path, provider_file(["+.soak.test"] if state["hot"] else [])); api("PUT", "/providers/rules/hot-b")
            host, want = "soak.test", "B" if state["hot"] else "A"
        else:
            state["tog_off"] = not state["tog_off"]
            api("PATCH", "/rules/disable", {str(index): state["tog_off"]}); host, want = "tog.test", "A" if state["tog_off"] else "B"
        got, _ = fetch(host)
        if got is None: failed += 1
        elif got != want: wrong += 1
    return {"changes": n, "by_method": kinds, "wrong_exit_right_after": wrong, "failed_requests": failed,
            "core_before": before, "core_after": core.usage()}

def child_cpu():
    import resource
    r = resource.getrusage(resource.RUSAGE_CHILDREN); return r.ru_utime + r.ru_stime

def exp_reload_cost(fillers, n=50):
    """CPU and memory of full reloads, each a config the core has not seen (one new rule each).
    CPU comes from the parent's accounting once the core exits; an idle core of the same life
    is subtracted. Every reload is checked to have taken effect."""
    def run(reloads):
        c0 = child_cpu(); core = Core(fillers); t = time.perf_counter(); before = core.usage(); took = 0; walls = []
        base = config(fillers)
        for i in range(reloads):
            y = base.replace("  - MATCH,exitA\n", f"  - DOMAIN-SUFFIX,u{i}.test,exitB\n  - MATCH,exitA\n")
            _, ms, _ = api("PUT", "/configs", {"payload": y}); walls.append(ms)
            took += fetch(f"u{i}.test")[0] == "B"
        while time.perf_counter() - t < 8: time.sleep(0.1)
        after = core.usage(); core.stop()
        return child_cpu() - c0, before, after, took, walls
    idle, *_ = run(0)
    busy, before, after, took, walls = run(n)
    return {"rules": fillers + 6, "reloads": n, "took_effect": f"{took}/{n}", "api_ms": summary(walls),
            "cpu_ms_per_reload": round(1000 * (busy - idle) / n, 1), "rss_before_mb": before["rss_mb"], "rss_after_mb": after["rss_mb"]}

def main():
    random.seed(7)
    target_server(18000, "DIRECT"); target_server(18001, "A"); target_server(18002, "B")
    relay(18081, 18001); relay(18082, 18002)
    results = {"mihomo": None, "machine": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()}
    core = Core(0)
    results["mihomo"] = json.loads(api("GET", "/version")[2])["version"]
    assert fetch("sel.test")[0] == "A" and fetch("unknown.test")[0] == "A", "sanity"
    print("select…", flush=True); results["select"] = exp_select()
    print("disable…", flush=True); results["disable"] = exp_disable()
    print("soak…", flush=True); results["soak"] = exp_soak(core)
    core.stop()
    results["reload"], results["provider"] = [], []
    core = Core(0, store_selected=False)
    print("select without cache…", flush=True); results["select_no_cache"] = exp_select_no_cache()
    core.stop()
    for fillers in (0, 1000, 10000, 50000):
        core = Core(fillers)
        print(f"reload {fillers}…", flush=True); results["reload"].append(exp_reload(core, fillers))
        if fillers in (0, 10000): results.setdefault("reload_force", []).append(exp_reload(core, fillers, force=True))
        print(f"provider {fillers}…", flush=True); results["provider"].append(exp_provider(fillers, 0))
        if fillers == 10000:
            results["provider_big_set"] = exp_provider(fillers, 20000, n=20)
        core.stop()
        print(f"reload cost {fillers}…", flush=True); results.setdefault("reload_cost", []).append(exp_reload_cost(fillers))
    with open(os.path.join(ROOT, "results.json"), "w") as f: json.dump(results, f, indent=2, ensure_ascii=False)
    print(json.dumps(results, indent=2, ensure_ascii=False))

if __name__ == "__main__":
    main()
