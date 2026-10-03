# Per-file write bytes from an strace -f -ttt -y log, per window.
# Temp files are credited to the file they are renamed over.
import re, sys, collections
log, t0, bounds = sys.argv[1], float(sys.argv[2]), [int(x) for x in sys.argv[3].split(",")]
W = re.compile(r'^(\d+) +([\d.]+) (write|pwrite64|writev)\((\d+)<([^>]*)>.*\) = (\d+)')
R = re.compile(r'^(\d+) +([\d.]+) (rename|renameat2?)\(.*?"([^"]+)".*?"([^"]+)".*\) = 0')
def norm(p):
    p = re.sub(r'^/config/', '', p)
    p = re.sub(r'\.preview_decode\.[^/]+/', '.preview_decode.<id>.X/', p)
    p = re.sub(r'(\.preview_decode_last)/\w+$', r'\1/<id>', p)
    p = re.sub(r'(meter-preview)-\w+$', r'\1-<id>', p)
    return p
pending = collections.defaultdict(list)   # tmp path -> [(t, bytes)]
acc = {b: collections.Counter() for b in bounds}
ops = {b: collections.Counter() for b in bounds}
def win(t):
    el = t - t0
    if el < 0: return None
    for b in bounds:
        if el < b: return b
    return None
def credit(t, path, n, op):
    w = win(t)
    if w is None: return
    acc[w][path] += n
    if op: ops[w][path] += 1
unfinished = {}
def lines():
    for line in open(log, errors="replace"):
        pid = line.split(" ", 1)[0]
        if line.rstrip().endswith("<unfinished ...>"):
            unfinished[pid] = line.rstrip()[:-len("<unfinished ...>")].rstrip(); continue
        m = re.match(r'^(\d+) +[\d.]+ <\.\.\. \w+ resumed>(.*)$', line.rstrip())
        if m:
            head = unfinished.pop(pid, None)
            if head is None: continue
            yield head + m.group(2); continue
        yield line
for line in lines():
    m = W.match(line)
    if m:
        t, path, n = float(m.group(2)), m.group(5), int(m.group(6))
        if not path.startswith("/") or path.startswith(("/dev/", "/proc/")) or "pipe:" in path or "socket:" in path: continue
        if re.search(r'\.tmp(\.\w+)?$', path) or re.search(r'\.tmp\.\d+$', path):
            pending[path].append((t, n)); continue
        credit(t, norm(path), n, True)  # in-place write (append or truncate)
        continue
    m = R.match(line)
    if m:
        src, dst = m.group(4), m.group(5)
        if not src.startswith("/"): continue
        for t, n in pending.pop(src, []): credit(t, norm(dst), n, False)
        credit(float(m.group(2)), norm(dst), 0, True)
for src, l in pending.items():   # never renamed
    for t, n in l: credit(t, norm(src) + " (unrenamed tmp)", n, False)
prev = 0
for b in bounds:
    dt = (b - prev) / 60
    tot = sum(acc[b].values())
    print(f"== window {prev}-{b}s: {tot/1e6/((b-prev)):.3f} MB/s total ({tot/dt/1e6:.1f} MB/min)")
    print(f"   {'file':<52} {'KB/min':>9} {'writes/min':>10} {'avg B/op':>9} {'share':>6}")
    for p, n in acc[b].most_common(30):
        o = ops[b][p]
        print(f"   {p:<52} {n/dt/1e3:9.1f} {o/dt:10.1f} {n/max(o,1):9.0f} {100*n/tot:5.1f}%")
    prev = b
