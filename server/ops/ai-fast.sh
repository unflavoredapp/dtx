#!/usr/bin/env bash
# ai-fast.sh — pins llama-server to AVX cores, adds parallel slots, speculative decoding and a small worker.
#
#   bash ai-fast.sh plan     show the CPU layout and the exact launch commands (changes nothing)
#   bash ai-fast.sh apply    write launchers + systemd units to /opt/ai-fast (still doesn't stop anything)
#
# It reads your RUNNING llama-server command lines, so models/ports/context are reused as they are.
#   WORKER_GGUF=/path/small-instruct-q4.gguf   a small model (0.5B-3B, same family as the main one) used as
#                                              (1) the speculative-decoding draft for the main model, and
#                                              (2) the "worker" server on :8082 for background chores
#   NP=2   parallel slots on the main model      PORT_WORKER=8082   BIN=llama-server
set -euo pipefail
MODE="${1:-plan}"
BIN="${BIN:-$(command -v llama-server || true)}"
[ -n "$BIN" ] || { echo "llama-server not found; run: BIN=/path/to/llama-server bash $0 $MODE"; exit 1; }
export MODE BIN NP="${NP:-2}" WORKER_GGUF="${WORKER_GGUF:-}" PORT_WORKER="${PORT_WORKER:-8082}"

python3 - <<'PY'
import os, re, shlex, subprocess, sys

BIN, MODE, NP = os.environ["BIN"], os.environ["MODE"], int(os.environ["NP"])
WORKER = os.environ["WORKER_GGUF"]; PORT_W = os.environ["PORT_WORKER"]

def sh(c):
    return subprocess.run(c, shell=True, capture_output=True, text=True).stdout

help_txt = sh(f"{shlex.quote(BIN)} --help 2>&1")
def has(flag): return flag in help_txt

# ---- CPU layout: one thread per PHYSICAL core, AVX level -------------------------------------------------------
cpus = {}
for l in sh("lscpu -p=CPU,CORE,SOCKET,NODE").splitlines():
    if l.startswith("#") or not l.strip(): continue
    c, core, sock, node = (int(x) if x.strip() else 0 for x in l.split(","))
    cpus.setdefault((sock, core), []).append(c)
phys = sorted(min(v) for v in cpus.values())
flags = open("/proc/cpuinfo").read()
avx = "avx512f" if "avx512f" in flags else "avx2" if "avx2" in flags else "none"
print(f"physical cores: {len(phys)}   logical: {sum(len(v) for v in cpus.values())}   SIMD: {avx}")
if avx == "none": print("WARNING: no AVX2/AVX-512 — inference will be slow")
if avx == "avx512f" and not re.search(r"avx512", sh(f"strings {shlex.quote(BIN)} | grep -m1 -i avx512")):
    print("note: if this build was not compiled with AVX-512, rebuild: cmake -B build -DGGML_NATIVE=ON && cmake --build build -j")

# ---- running servers -------------------------------------------------------------------------------------------
procs = []
for l in sh("pgrep -a llama-server").splitlines():
    pid, _, cmd = l.partition(" ")
    a = shlex.split(cmd)
    procs.append(a[1:] if a and a[0].endswith("llama-server") else a)
if not procs:
    print("no running llama-server found — add your command lines by hand."); sys.exit(0)

def val(a, *names):
    for n in names:
        if n in a and a.index(n) + 1 < len(a): return a[a.index(n) + 1]
    return None
def drop(a, flags_with_val, flags_alone=()):
    out, i = [], 0
    while i < len(a):
        if a[i] in flags_with_val: i += 2; continue
        if a[i] in flags_alone: i += 1; continue
        out.append(a[i]); i += 1
    return out
STRIP = ("-t", "--threads", "-tb", "--threads-batch", "-np", "--parallel", "-C", "--cpu-mask", "-Cr", "--cpu-range",
         "--cpu-strict", "--prio", "--poll", "-td", "-tbd", "-md", "--model-draft", "--draft-max", "--draft-min", "--cache-reuse")

vision = [p for p in procs if "--mmproj" in p or "-mm" in p]
mains = [p for p in procs if p not in vision]

# split the physical cores: main 60% / vision 20% / worker 20% (at least 1 each)
n = len(phys); nw = max(1, n // 5) if WORKER else 0; nv = max(1, n // 5) if vision else 0
nm = max(1, n - nw - nv)
main_c, vis_c, wrk_c = phys[:nm], phys[nm:nm + nv], phys[nm + nv:nm + nv + nw]
def mask(cs): return hex(sum(1 << c for c in cs))
def perf(cs):
    f = ["-t", str(len(cs)), "-tb", str(len(cs))]
    if has("--cpu-mask"): f += ["--cpu-mask", mask(cs)]
    if has("--cpu-strict"): f += ["--cpu-strict", "1"]
    if has("--prio"): f += ["--prio", "2"]
    if has("--poll"): f += ["--poll", "50"]
    return f
def fa(): return [] if "flash-attn [" in help_txt or "[on|off|auto]" in help_txt else (["-fa"] if has("--flash-attn") else [])

units = {}
for i, p in enumerate(mains):
    base = drop(p, STRIP)
    ctx = int(val(base, "-c", "--ctx-size") or 32768)
    base = drop(base, ("-c", "--ctx-size"))
    cmd = base + ["-c", str(ctx * NP)] + perf(main_c) + fa()          # each slot keeps the full context
    if has("--parallel"): cmd += ["-np", str(NP)]
    if has("--cache-reuse"): cmd += ["--cache-reuse", "256"]
    if has("--mlock"): cmd += ["--mlock"]
    if WORKER and has("--model-draft"):
        cmd += ["-md", WORKER, "--draft-max", "8", "--draft-min", "2"]
        if has("--threads-draft"): cmd += ["-td", str(len(main_c))]
    units["ai-main" + (str(i) if i else "")] = cmd
for i, p in enumerate(vision):
    units["ai-vision" + (str(i) if i else "")] = drop(p, STRIP) + perf(vis_c) + fa()
if WORKER:
    units["ai-worker"] = ["-m", WORKER, "--host", "127.0.0.1", "--port", PORT_W, "-c", "8192", "-np", "2", "--alias", "AiDecryptWorker"] + perf(wrk_c) + fa()

print(f"\nmain   -> cores {main_c}\nvision -> cores {vis_c}\nworker -> cores {wrk_c}\n")
for name, cmd in units.items():
    print(f"[{name}]\n  {BIN} " + " ".join(shlex.quote(x) for x in cmd) + "\n")

if MODE == "apply":
    os.makedirs("/opt/ai-fast", exist_ok=True)
    for name, cmd in units.items():
        open(f"/opt/ai-fast/{name}.sh", "w").write("#!/usr/bin/env bash\nexec " + shlex.quote(BIN) + " " + " ".join(shlex.quote(x) for x in cmd) + "\n")
        os.chmod(f"/opt/ai-fast/{name}.sh", 0o755)
        open(f"/etc/systemd/system/{name}.service", "w").write(
            f"[Unit]\nDescription={name}\nAfter=network.target\n\n[Service]\nExecStart=/opt/ai-fast/{name}.sh\n"
            "Restart=always\nLimitMEMLOCK=infinity\nNice=-5\n\n[Install]\nWantedBy=multi-user.target\n")
    print("written to /opt/ai-fast and /etc/systemd/system.")
    print("next: stop your current llama-server (pm2 / systemctl / screen), then:")
    print("  systemctl daemon-reload && systemctl enable --now " + " ".join(units))
    if WORKER:
        print("\nnginx: next to your /v1vision/ block add the same for the worker, then reload nginx:")
        print(f"  location /v1worker/ {{ rewrite ^/v1worker/(.*)$ /v1/$1 break; proxy_pass http://127.0.0.1:{PORT_W}; proxy_buffering off; proxy_read_timeout 600s; }}")
PY
