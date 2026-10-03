# Host-side sampler: per-process CPU of the two bash loops, container CPU,
# preview one-shot starts (writes to .preview_decode_last) - per window.
import os, sys, time
cid, cfg, t0, windows = sys.argv[1], sys.argv[2], float(sys.argv[3]), [int(x) for x in sys.argv[4].split(",")]
acct = f"/sys/fs/cgroup/cpuacct/docker/{cid}/cpuacct.usage"
HZ = os.sysconf("SC_CLK_TCK")
def procs():
    out = {}
    for p in os.listdir("/proc"):
        if not p.isdigit(): continue
        try:
            cmd = open(f"/proc/{p}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace")
            st = open(f"/proc/{p}/stat").read().rsplit(")", 1)[1].split()
        except OSError: continue
        out[int(p)] = (cmd, int(st[1]), [int(x) for x in st[11:15]])  # ppid, utime stime cutime cstime
    return out
def find(ps):
    res = {}
    listen = [p for p, (c, _, _) in ps.items() if "wmbusmeters --useconfig=/config/listen" in c]
    raw = [p for p, (c, _, _) in ps.items() if "bridge_ledger.py raw" in c]
    if listen:
        par = ps[listen[0]][1]
        sib = [p for p, (c, pp, _) in ps.items() if pp == par and p != listen[0] and c.split(" ")[0].endswith("bash")]
        res["listen_parser"] = sib
    main = [p for p, (c, _, _) in ps.items() if c.startswith("/usr/bin/wmbusmeters --useconfig=/config ") or c.strip() == "/usr/bin/wmbusmeters --useconfig=/config"]
    if main:
        par = ps[main[0]][1]
        res["decode_loop"] = [p for p, (c, pp, _) in ps.items() if pp == par and p > main[0] and c.split(" ")[0].endswith("bash")][:1]
    if raw:
        u = ps[raw[0]][1]; par = ps[u][1]
        res["delegation_loop"] = [p for p, (c, pp, _) in ps.items() if pp == par and p != u and c.split(" ")[0].endswith("bash")]
    return res
def subtree(ps, roots):
    out, todo = set(), list(roots)
    while todo:
        p = todo.pop()
        if p in out or p not in ps: continue
        out.add(p)
        todo += [c for c, (_, pp, _) in ps.items() if pp == p]
    return out
def snap(ps, pids):
    # whole subtree: live descendants by their own time, reaped ones through cutime
    t = [0, 0, 0, 0]
    for p in subtree(ps, pids):
        t = [a + b for a, b in zip(t, ps[p][2])]
    return [t[0] + t[1], t[2] + t[3], 0, 0]
last = {}
def scan_last():
    n = 0
    d = f"{cfg}/.preview_decode_last"
    for f in os.listdir(d):
        try: v = open(f"{d}/{f}").read()
        except OSError: continue
        if f in last and last[f] != v: n += 1
        elif f not in last and starts_seen: n += 1
        last[f] = v
    return n
starts_seen = False
scan_last(); starts_seen = True
marks = {}
oneshots = {w: 0 for w in windows}
ps = procs(); target = find(ps)
print("pids", target, flush=True)
def mark(name):
    ps = procs()
    marks[name] = (time.time(), int(open(acct).read()), {k: snap(ps, v) for k, v in target.items()})
while time.time() < t0: time.sleep(0.05)
mark(0)
wi = 0; bounds = windows
while wi < len(bounds):
    time.sleep(1)
    el = time.time() - t0
    oneshots[bounds[wi]] += scan_last()
    if el >= bounds[wi]:
        mark(bounds[wi]); wi += 1
prev = 0
for b in bounds:
    (ta, ca, pa), (tb, cb, pb) = marks[prev], marks[b]
    dt = tb - ta
    line = f"window {prev:>3}-{b:<3}s: container {100 * (cb - ca) / 1e9 / dt:5.1f}% of a core"
    for k in target:
        d = [y - x for x, y in zip(pa[k], pb[k])]
        line += f" | {k}: live {100 * d[0] / HZ / dt:5.1f}% + reaped {100 * d[1] / HZ / dt:5.1f}% = {100 * (d[0] + d[1]) / HZ / dt:5.1f}%"
    line += f" | one-shots {oneshots[b]} ({60 * oneshots[b] / dt:.1f}/min)"
    print(line, flush=True)
    prev = b
