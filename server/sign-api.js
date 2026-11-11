"use strict";
// sign-api.js — server signing for the Uncrypt app: zsign on this machine, run by a chain of core-pinned workers.
// Put it next to site.js. Mounting is shown in SIGN-SETUP.md.
//
//   POST /api/sign/jobs                         { ipaUrl, p12, provision, password, name, bundleId, version, ... }  -> { ok, id, position, workers }   (login, costs prices.sign)
//   GET  /api/sign/jobs/:id?since=N             { ok, state: queued|running|done|failed, lines: [{ w, us, t }], next, result?, error? }   (login, your own jobs)
//   GET  /api/sign/dl/:token/app.ipa            the signed IPA            (no login: iOS fetches these itself, the token is the key)
//   GET  /api/sign/dl/:token/manifest.plist     the OTA install manifest
//
// How a job runs
//   Each worker owns a fixed set of CPU cores (two physical cores with their hyperthreads by default). A job goes to
//   the first idle worker, which fetches the IPA and runs zsign under `taskset` on its own cores. The moment a worker
//   finishes, it takes the next job in the queue itself. Every log line carries the worker number and the
//   microseconds since the job was accepted, which is what the app's signer log shows.
//
// What is kept
//   The .p12, its password and the profile exist only for the length of the job: the files are removed and the password
//   dropped as soon as zsign exits, whether it worked or not. The signed IPA stays for SIGN_KEEP_MIN minutes (30) so
//   the phone can install it, then it is removed too.
const crypto = require("crypto"), fs = require("fs"), path = require("path"), os = require("os"), dns = require("dns"), https = require("https"), net = require("net");
const { spawn } = require("child_process");
const fsp = fs.promises;

// ---- which addresses the IPA may be fetched from (public ones only) ----
function privateAddress(ip) {
  if (net.isIPv4(ip)) {
    const p = ip.split(".").map(Number);
    return p[0] === 0 || p[0] === 10 || p[0] === 127 || p[0] >= 224 || (p[0] === 100 && p[1] >= 64 && p[1] <= 127) ||
      (p[0] === 169 && p[1] === 254) || (p[0] === 172 && p[1] >= 16 && p[1] <= 31) || (p[0] === 192 && p[1] === 168) || (p[0] === 192 && p[1] === 0 && p[2] === 0) || (p[0] === 198 && (p[1] === 18 || p[1] === 19));
  }
  if (net.isIPv6(ip)) {
    const a = ip.toLowerCase();
    const mapped = a.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
    if (mapped) return privateAddress(mapped[1]);
    return a === "::" || a === "::1" || a.startsWith("fc") || a.startsWith("fd") || /^fe[89ab]/.test(a) || a.startsWith("ff") || a.startsWith("::ffff:") || a.startsWith("64:ff9b:");
  }
  return true;   // not an address at all
}

// The check happens on the address the socket is about to connect to, so a hostname can't pass the check and then point somewhere else.
function publicLookup(hostname, options, cb) {
  dns.lookup(hostname, options, (err, address, family) => {
    if (err) return cb(err);
    const list = Array.isArray(address) ? address : [{ address, family }];
    if (!list.length || list.some((a) => privateAddress(a.address))) return cb(new Error("That link points at a private address."));
    cb(null, address, family);
  });
}

function download(link, dest, maxBytes, onProgress, hops) {
  return new Promise((resolve, reject) => {
    let url;
    try { url = new URL(link); } catch { return reject(new Error("The IPA link is not a valid URL.")); }
    if (url.protocol !== "https:") return reject(new Error("The IPA link must be https."));
    if (net.isIP(url.hostname.replace(/^\[|\]$/g, "")) && privateAddress(url.hostname.replace(/^\[|\]$/g, ""))) return reject(new Error("That link points at a private address."));
    const req = https.get(url, { lookup: publicLookup, headers: { "user-agent": "Uncrypt-sign/1", accept: "*/*" }, timeout: 30000 }, (res) => {
      const code = res.statusCode || 0;
      if (code >= 300 && code < 400 && res.headers.location) {
        res.resume();
        if ((hops || 0) >= 5) return reject(new Error("Too many redirects fetching the IPA."));
        let next; try { next = new URL(res.headers.location, url).toString(); } catch { return reject(new Error("Bad redirect fetching the IPA.")); }
        return resolve(download(next, dest, maxBytes, onProgress, (hops || 0) + 1));
      }
      if (code < 200 || code >= 300) { res.resume(); return reject(new Error("The IPA link answered with HTTP " + code + ".")); }
      const total = Number(res.headers["content-length"]) || 0;
      if (total > maxBytes) { res.destroy(); return reject(new Error("That IPA is too large to sign here.")); }
      const out = fs.createWriteStream(dest, { mode: 0o600 });
      let got = 0, failed = false;
      const stop = (e) => { if (failed) return; failed = true; res.destroy(); out.destroy(); reject(e); };
      res.on("data", (chunk) => { got += chunk.length; if (got > maxBytes) return stop(new Error("That IPA is too large to sign here.")); if (onProgress) onProgress(got, total); });
      res.on("error", stop); out.on("error", stop);
      res.pipe(out);
      out.on("finish", () => { if (!failed) resolve(got); });
    });
    req.on("timeout", () => req.destroy(new Error("The IPA link stopped answering.")));
    req.on("error", reject);
  });
}

// ---- the cores each worker is pinned to ----
// SIGN_CORES="0-1,16-17;2-3,18-19" sets them by hand (one worker per ;). Otherwise: read the CPU layout and give each
// worker two physical cores together with their hyperthreads, so no two workers ever share a physical core.
function coreGroups(spec) {
  if (spec && String(spec).trim()) return String(spec).split(";").map((s) => s.trim()).filter((s) => /^[0-9,\-]+$/.test(s));
  const physical = [], seen = new Set();
  const n = os.cpus().length;
  for (let c = 0; c < n; c++) {
    if (seen.has(c)) continue;
    let siblings = [c];
    try {
      const txt = fs.readFileSync("/sys/devices/system/cpu/cpu" + c + "/topology/thread_siblings_list", "utf8").trim();
      siblings = [];
      for (const part of txt.split(",")) { const [a, b] = part.split("-").map(Number); for (let i = a; i <= (b == null ? a : b); i++) siblings.push(i); }
    } catch { /* no layout to read: every logical CPU counts as its own core */ }
    siblings.forEach((s) => seen.add(s));
    physical.push(siblings);
  }
  const per = physical.length >= 4 ? 2 : 1, groups = [];
  for (let i = 0; i < physical.length; i += per) groups.push(physical.slice(i, i + per).flat().sort((a, b) => a - b).join(","));
  return groups.length ? groups : ["0"];
}

const xml = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const clean = (s) => String(s).replace(/\u001b?\[[0-9;]*m/g, "").replace(/^>>>\s*/, "").trim();

module.exports = function mountSign({ app, express, limited, fail, okOrigin, env, SITE_URL, dtx, isStaff, fetchIpa }) {
  env = env || {};
  const num = (v, d) => (Number.isFinite(Number(v)) && Number(v) > 0 ? Number(v) : d);
  const DIR = env.SIGN_DIR || "/var/lib/dct-sign";
  const ZSIGN = env.SIGN_ZSIGN || "/usr/local/bin/zsign";
  const TASKSET = env.SIGN_TASKSET === "0" ? null : (env.SIGN_TASKSET || "taskset");
  const KEEP_MS = num(env.SIGN_KEEP_MIN, 30) * 60000, MAX_IPA = num(env.SIGN_MAX_MB, 4096) * 1048576, MAX_QUEUE = num(env.SIGN_MAX_QUEUE, 40), JOB_MS = num(env.SIGN_JOB_MIN, 15) * 60000;
  const BASE = String(SITE_URL || env.SITE_URL || "https://decrypt.team").replace(/\/+$/, "");
  const staff = isStaff || (() => false), over = limited || (() => false), origin = okOrigin || (() => true);
  const deny = fail || ((res, status, error) => res.status(status).json({ ok: false, error }));
  const getIpa = fetchIpa || download;
  fs.mkdirSync(DIR, { recursive: true, mode: 0o700 });
  // anything left from before a restart is from a job that no longer exists
  for (const d of fs.readdirSync(DIR)) if (/^job-[0-9a-f]{32}$/.test(d)) fs.rmSync(path.join(DIR, d), { recursive: true, force: true });

  const workers = coreGroups(env.SIGN_CORES).map((cores, i) => ({ n: i + 1, cores, job: null }));
  const jobs = new Map(), byToken = new Map(), queue = [];
  console.log("Sign: " + workers.length + " workers, cores " + workers.map((w) => w.cores).join(" | "));

  const say = (job, w, text) => { const t = clean(text); if (t) job.lines.push({ w, us: Number((process.hrtime.bigint() - job.t0) / 1000n), t }); if (job.lines.length > 4000) { const cut = job.lines.length - 4000; job.lines.splice(0, cut); job.dropped += cut; } };
  const wipeSecrets = (job) => {
    job.password = null;
    for (const f of ["cert.p12", "profile.mobileprovision"]) fs.rmSync(path.join(job.dir, f), { force: true });
  };
  const forget = (job) => { jobs.delete(job.id); byToken.delete(job.token); fs.rmSync(job.dir, { recursive: true, force: true }); };

  // A worker that finishes takes the next job itself; a new job wakes the first idle worker.
  function pump() {
    for (const w of workers) {
      if (w.job || !queue.length) continue;
      const job = queue.shift();
      w.job = job;
      run(w, job).catch((e) => { job.error = job.error || String((e && e.message) || e); })
        .finally(() => {
          wipeSecrets(job);
          fs.rmSync(path.join(job.dir, "in.ipa"), { force: true });
          fs.rmSync(path.join(job.dir, "tmp"), { recursive: true, force: true });
          if (job.error) {
            job.state = "failed"; say(job, w.n, "✗ " + job.error);
            if (job.ledger && dtx) { try { dtx.refund(job.uid, job.ledger); say(job, 0, "Refunded " + job.cost + " DTX"); } catch { /* nothing to refund */ } }
          }
          job.timer = setTimeout(() => forget(job), job.error ? 10 * 60000 : KEEP_MS); job.timer.unref();
          w.job = null;
          pump();
        });
    }
  }

  async function run(w, job) {
    job.state = "running"; job.worker = w.n; job.cores = w.cores;
    say(job, w.n, "Worker W" + w.n + " took the job, pinned to cores " + w.cores);
    const input = path.join(job.dir, "in.ipa"), output = path.join(job.dir, "signed.ipa");

    let t = process.hrtime.bigint(), lastPct = -1;
    say(job, w.n, "Fetching IPA from " + job.host + "…");
    const bytes = await getIpa(job.ipaUrl, input, MAX_IPA, (got, total) => {
      const pct = total ? Math.floor(got / total * 4) * 25 : -1;
      if (pct > lastPct && pct > 0 && pct < 100) { lastPct = pct; say(job, w.n, "Fetching IPA " + pct + "%"); }
    });
    say(job, w.n, "✓ Fetched " + (bytes / 1048576).toFixed(1) + " MB · " + Number((process.hrtime.bigint() - t) / 1000n) + "µs");

    const args = ["-k", path.join(job.dir, "cert.p12"), "-p", job.password, "-m", path.join(job.dir, "profile.mobileprovision"), "-o", output, "-t", path.join(job.dir, "tmp"), "-z", "1"];
    if (job.setBundleId) args.push("-b", job.bundleId);
    if (job.setName) args.push("-n", job.name);
    if (job.setVersion) args.push("-r", job.version);
    if (job.icon) args.push("-I", path.join(job.dir, "icon.png"));
    if (job.rmExtensions) args.push("-E");
    if (job.rmWatch) args.push("-W");
    args.push(input);
    fs.mkdirSync(path.join(job.dir, "tmp"), { recursive: true, mode: 0o700 });

    t = process.hrtime.bigint();
    say(job, w.n, "▸ zsign…");
    const cmd = TASKSET ? TASKSET : ZSIGN, argv = TASKSET ? ["-c", w.cores, ZSIGN].concat(args) : args;
    const code = await new Promise((resolve, reject) => {
      const child = spawn(cmd, argv, { cwd: job.dir, stdio: ["ignore", "pipe", "pipe"], env: { PATH: process.env.PATH || "/usr/local/bin:/usr/bin:/bin", HOME: job.dir } });
      const kill = setTimeout(() => { job.error = "Signing took too long and was stopped."; child.kill("SIGKILL"); }, JOB_MS);
      let buf = "";
      const feed = (chunk) => {
        buf += chunk.toString("utf8");
        let nl; while ((nl = buf.indexOf("\n")) >= 0) { say(job, w.n, buf.slice(0, nl)); buf = buf.slice(nl + 1); }
      };
      child.stdout.on("data", feed); child.stderr.on("data", feed);
      child.on("error", (e) => { clearTimeout(kill); reject(new Error(e.code === "ENOENT" ? "zsign is not installed on the server." : "Could not start zsign.")); });
      child.on("close", (c) => { clearTimeout(kill); if (buf) say(job, w.n, buf); resolve(c); });
    });
    if (job.error) throw new Error(job.error);
    if (code !== 0 || !fs.existsSync(output)) throw new Error("zsign could not sign this app (exit " + code + "). The lines above say why.");
    say(job, w.n, "✓ zsign · " + Number((process.hrtime.bigint() - t) / 1000n) + "µs");

    job.size = (await fsp.stat(output)).size;
    job.totalUs = Number((process.hrtime.bigint() - job.t0) / 1000n);
    job.state = "done";
    say(job, w.n, "✓ Ready to install · " + (job.size / 1048576).toFixed(1) + " MB");
  }

  const b64 = (v, max) => { if (typeof v !== "string" || !v || v.length > max * 1.4) return null; try { const b = Buffer.from(v, "base64"); return b.length && b.length <= max ? b : null; } catch { return null; } };
  const text = (v, max) => (typeof v === "string" ? v.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, max) : "");
  const json = express.json({ limit: "6mb", type: "application/json" });
  const noStore = (res) => res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });

  app.post("/api/sign/jobs", json, (req, res) => {
    noStore(res);
    if (!req.me) return deny(res, 401, "Log in with Telegram to sign on the server.");
    if (req.get("x-dt") !== "1" || !origin(req)) return deny(res, 400, "Bad request.");
    const uid = String(req.me.id), b = req.body || {};
    if (over("sign|" + uid, 20, 3600000)) return deny(res, 429, "Too many sign jobs. Try again later.");
    if (queue.length >= MAX_QUEUE) return deny(res, 503, "The sign queue is full. Try again in a minute.");
    let mine = 0; for (const j of jobs.values()) if (j.uid === uid && (j.state === "queued" || j.state === "running")) mine += 1;
    if (mine >= 2) return deny(res, 429, "Two of your sign jobs are already running. Wait for one to finish.");

    const p12 = b64(b.p12, 200 * 1024), provision = b64(b.provision, 512 * 1024), icon = b.icon ? b64(b.icon, 4 * 1048576) : null;
    if (!p12 || !provision) return deny(res, 400, "The certificate or profile is missing.");
    if (b.icon && !icon) return deny(res, 400, "That icon is too large.");
    if (icon && !(icon[0] === 0x89 && icon[1] === 0x50 && icon[2] === 0x4e && icon[3] === 0x47)) return deny(res, 400, "The icon must be a PNG.");
    const password = typeof b.password === "string" ? b.password.slice(0, 256) : "";
    const bundleId = text(b.bundleId, 200), name = text(b.name, 120), version = text(b.version, 40);
    if (!/^[A-Za-z0-9.\-]{1,200}$/.test(bundleId)) return deny(res, 400, "That bundle ID is not valid.");
    if (!name || !version) return deny(res, 400, "The app name or version is missing.");
    let link; try { link = new URL(String(b.ipaUrl || "")); } catch { return deny(res, 400, "The IPA link is missing."); }
    if (link.protocol !== "https:") return deny(res, 400, "The IPA link must be https.");

    let ledger = null, cost = 0;
    if (dtx && !staff("u" + uid)) {
      cost = Number(dtx.prices && dtx.prices.sign) || 0;
      if (cost > 0) {
        const s = dtx.spend(uid, cost, "sign", null);
        if (!s.ok) return deny(res, 402, "Not enough DTX. Signing on the server costs " + cost + " DTX.");
        ledger = s.id;
      }
    }

    const id = crypto.randomBytes(16).toString("hex"), token = crypto.randomBytes(24).toString("hex");
    const dir = path.join(DIR, "job-" + id);
    try {
      fs.mkdirSync(dir, { mode: 0o700 });
      fs.writeFileSync(path.join(dir, "cert.p12"), p12, { mode: 0o600 });
      fs.writeFileSync(path.join(dir, "profile.mobileprovision"), provision, { mode: 0o600 });
      if (icon) fs.writeFileSync(path.join(dir, "icon.png"), icon, { mode: 0o600 });
    } catch {
      fs.rmSync(dir, { recursive: true, force: true });
      if (ledger) dtx.refund(uid, ledger);
      return deny(res, 500, "The server could not store the job.");
    }
    const job = { id, token, uid, dir, state: "queued", lines: [], dropped: 0, t0: process.hrtime.bigint(), ipaUrl: link.toString(), host: link.hostname, password,
      bundleId, name, version, setBundleId: !!b.setBundleId, setName: !!b.setName, setVersion: !!b.setVersion, icon: !!icon, rmExtensions: !!b.rmExtensions, rmWatch: !!b.rmWatch,
      ledger, cost, worker: null, cores: null, size: 0, totalUs: 0, error: null, timer: null };
    jobs.set(id, job); byToken.set(token, job); queue.push(job);
    say(job, 0, "Job accepted" + (cost ? " · " + cost + " DTX" : "") + " · " + workers.length + " workers, " + (queue.length - 1) + " ahead of you");
    pump();
    res.json({ ok: true, id, position: Math.max(0, queue.indexOf(job)), workers: workers.length });
  });

  app.get("/api/sign/jobs/:id", (req, res) => {
    noStore(res);
    if (!req.me) return deny(res, 401, "Log in first.");
    const job = jobs.get(String(req.params.id));
    if (!job || job.uid !== String(req.me.id)) return deny(res, 404, "No such sign job.");
    const since = Math.max(0, parseInt(req.query.since, 10) || 0), start = Math.max(0, since - job.dropped);
    const out = { ok: true, state: job.state, position: Math.max(0, queue.indexOf(job)), worker: job.worker, cores: job.cores, lines: job.lines.slice(start, start + 500), error: job.error };
    out.next = job.dropped + start + out.lines.length;
    if (job.state === "done") {
      const dl = BASE + "/api/sign/dl/" + job.token;
      out.result = { ipa: dl + "/app.ipa", manifest: dl + "/manifest.plist", install: "itms-services://?action=download-manifest&url=" + encodeURIComponent(dl + "/manifest.plist"),
        size: job.size, totalUs: job.totalUs, name: job.name, bundleId: job.bundleId, version: job.version, minutes: Math.round(KEEP_MS / 60000) };
    }
    res.json(out);
  });

  // iOS downloads these on its own, with no cookie and no app headers. The long random token is what lets it in.
  const forInstall = (req, res) => {
    const job = byToken.get(String(req.params.token));
    if (!job || job.state !== "done") { deny(res, 404, "This install link has expired. Sign the app again."); return null; }
    return job;
  };
  app.get("/api/sign/dl/:token/manifest.plist", (req, res) => {
    noStore(res);
    const job = forInstall(req, res); if (!job) return;
    const ipa = BASE + "/api/sign/dl/" + job.token + "/app.ipa";
    res.type("text/xml").send('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>items</key><array><dict>' +
      "<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>" + xml(ipa) + "</string></dict></array>" +
      "<key>metadata</key><dict><key>bundle-identifier</key><string>" + xml(job.bundleId) + "</string><key>bundle-version</key><string>" + xml(job.version) + "</string>" +
      "<key>kind</key><string>software</string><key>title</key><string>" + xml(job.name) + "</string></dict></dict></array></dict></plist>\n");
  });
  app.get("/api/sign/dl/:token/app.ipa", (req, res) => {
    noStore(res);
    const job = forInstall(req, res); if (!job) return;
    res.type("application/octet-stream").set("Content-Disposition", 'attachment; filename="' + job.bundleId + '.ipa"');
    res.sendFile(path.join(job.dir, "signed.ipa"), { dotfiles: "allow" }, (e) => { if (e && !res.headersSent) deny(res, 404, "This install link has expired. Sign the app again."); });
  });

  return { workers: workers.map((w) => ({ n: w.n, cores: w.cores })), jobs, queue };
};
module.exports.coreGroups = coreGroups;
module.exports.privateAddress = privateAddress;
