"use strict";
// Plugin host. Plugins are first-party: each is a folder in ./plugins with an index.js, added by the site's developer only.
//   GET  /api/plugins                  { ok, items: [{ id, name, description, icon, version, accepts, options }] }
//   POST /api/plugins/:id/run          { src: { url }, options: {} }  -> { ok, id }          (login)
//   GET  /api/plugins/jobs/:jid        { ok, status: queued|run|done|err|cancel, msg, pct, result?, error? }  (login, your own jobs)
//   POST /api/plugins/jobs/:jid/cancel
// A plugin file looks like (see plugins/README.md):
//   module.exports = { id, name, description, icon, version, accepts: ["ipa"], options: [{ key, label, type: "text"|"number"|"bool", def }],
//     async run(ctx) { ... return { title, sections: [{ title, kind: "kv"|"list"|"table"|"text", ... }] }; } };
// ctx: { blob (the IPA as a Blob), path, INJ, options, say(msg, pct), cancelled() }.
const fs = require("fs"), path = require("path"), os = require("os"), crypto = require("crypto");
const INJ = require("./inject-client.js");

module.exports = function mount({ app, express, limited, fail, okOrigin, env }) {
  const num = (v, d) => (Number.isFinite(Number(v)) && Number(v) > 0 ? Number(v) : d);
  const PAR = num(env && env.PLUGIN_JOBS, 2), IPA_MAX = num(env && env.PLUGIN_IPA_MAX_MB, 1500) * 1048576, KEEP_MS = 3600000;
  const dir = path.join(__dirname, "plugins"), reg = new Map(), tmp = path.join(os.tmpdir(), "dt-plugins");
  try { fs.mkdirSync(tmp, { recursive: true }); } catch { /* made on first use */ }

  for (const d of fs.existsSync(dir) ? fs.readdirSync(dir) : []) {
    const f = path.join(dir, d, "index.js"); if (!fs.existsSync(f)) continue;
    try {
      const p = require(f);
      if (!p || !/^[a-z0-9-]{2,40}$/.test(p.id || "") || typeof p.run !== "function" || typeof p.name !== "string") throw new Error("needs id, name and run()");
      if (reg.has(p.id)) throw new Error("duplicate id");
      reg.set(p.id, p);
    } catch (e) { console.warn("Plugin " + d + " not loaded:", e.message); }
  }
  const pub = (p) => ({ id: p.id, name: String(p.name).slice(0, 60), description: String(p.description || "").slice(0, 300), icon: String(p.icon || "code").slice(0, 20), version: String(p.version || "1.0"), accepts: p.accepts || ["ipa"],
    options: (p.options || []).filter((o) => o && /^[a-zA-Z]{1,24}$/.test(o.key)).map((o) => ({ key: o.key, label: String(o.label || o.key).slice(0, 60), type: ["number", "bool"].includes(o.type) ? o.type : "text", def: o.def === undefined ? "" : o.def })) });

  // what a plugin may hand back is trimmed to a fixed shape and size, and shown as plain text only
  const S = (x, n) => String(x == null ? "" : x).slice(0, n || 2000);
  function clean(r) {
    if (!r || typeof r !== "object") throw new Error("The plugin returned nothing.");
    const secs = (Array.isArray(r.sections) ? r.sections : []).slice(0, 30).map((s) => {
      const kind = ["kv", "list", "table", "text"].includes(s.kind) ? s.kind : "text", o = { title: S(s.title, 120), kind };
      if (kind === "kv") o.rows = (s.rows || []).slice(0, 500).map((x) => [S(x[0], 200), S(x[1], 1000)]);
      else if (kind === "list") o.items = (s.items || []).slice(0, 5000).map((x) => S(x, 500));
      else if (kind === "table") { o.cols = (s.cols || []).slice(0, 10).map((x) => S(x, 60)); o.rows = (s.rows || []).slice(0, 5000).map((row) => (Array.isArray(row) ? row : []).slice(0, 10).map((x) => S(x, 500))); }
      else o.text = S(s.text, 200000);
      if (s.note) o.note = S(s.note, 300);
      return o;
    });
    return { title: S(r.title, 120), sections: secs };
  }

  const jobs = new Map(), queue = []; let active = 0;
  setInterval(() => { const now = Date.now(); for (const [id, j] of jobs) if (j.end && now - j.end > KEEP_MS) jobs.delete(id); }, 300000).unref();

  async function exec(j) {
    const file = path.join(tmp, j.id + ".ipa");
    try {
      j.status = "run"; j.msg = "Downloading the package…";
      const repo = require("./repo");
      if (!repo.fetchToFile) throw new Error("Downloading from a repo isn't set up on this server.");
      await repo.fetchToFile(j.url, file, IPA_MAX, { cancelled: () => j.cancel, onBytes: (n) => { j.msg = "Downloading the package… " + Math.round(n / 1048576) + " MB"; } });
      if (j.cancel) throw new Error("Cancelled.");
      const blob = await fs.openAsBlob(file, { type: "application/octet-stream" });
      const out = await j.plugin.run({ blob, path: file, INJ, options: j.options, cancelled: () => j.cancel, say: (m, pct) => { j.msg = S(m, 200); if (pct >= 0 && pct <= 100) j.pct = pct; } });
      if (j.cancel) throw new Error("Cancelled.");
      j.result = clean(out); j.status = "done"; j.msg = "Done"; j.pct = 100;
    } catch (e) { j.status = j.cancel ? "cancel" : "err"; j.error = S(e && e.message ? e.message : "The plugin failed.", 300); }
    finally { j.end = Date.now(); try { fs.unlinkSync(file); } catch { /* already gone */ } active--; next(); }
  }
  function next() { while (active < PAR && queue.length) { const j = queue.shift(); if (j.cancel) { j.status = "cancel"; j.end = Date.now(); continue; } active++; exec(j); } }

  const noStore = (res) => res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
  app.get("/api/plugins", (req, res) => { noStore(res); res.json({ ok: true, items: [...reg.values()].map(pub) }); });
  app.post("/api/plugins/:id/run", express.json({ limit: "8kb" }), (req, res) => {
    noStore(res); if (!req.me) return fail(res, 401, "Log in to use tools.");
    if (req.get("x-dt") !== "1" || !okOrigin(req)) return fail(res, 400, "Bad request.");
    const p = reg.get(String(req.params.id)); if (!p) return fail(res, 404, "That tool doesn't exist.");
    if (limited("pl|" + req.me.id, 40, 3600000)) return fail(res, 429, "Too many runs. Try again later.");
    const b = req.body || {}, url = b.src && typeof b.src.url === "string" ? b.src.url : "";
    if (!/^https:\/\/[^\s\x00-\x1f]{3,990}$/.test(url)) return fail(res, 400, "Say which package to open.");
    let running = 0; for (const j of jobs.values()) if (j.uid === req.me.id && !j.end) running++;
    if (running >= 2) return fail(res, 429, "You already have two tools running.");
    const options = {}; for (const o of pub(p).options) { const v = b.options && b.options[o.key]; options[o.key] = o.type === "bool" ? (v === undefined ? !!o.def : !!v) : o.type === "number" ? (Number.isFinite(Number(v)) && v !== "" && v != null ? Number(v) : Number(o.def) || 0) : S(v === undefined ? o.def : v, 200); }
    const j = { id: crypto.randomBytes(9).toString("hex"), uid: req.me.id, plugin: p, url, options, status: "queued", msg: "Waiting…", pct: 0, at: Date.now() };
    jobs.set(j.id, j); queue.push(j); next(); res.json({ ok: true, id: j.id });
  });
  const mine = (req) => { const j = jobs.get(String(req.params.jid)); return j && req.me && j.uid === req.me.id ? j : null; };
  app.get("/api/plugins/jobs/:jid", (req, res) => {
    noStore(res); if (!req.me) return fail(res, 401, "Log in to use tools."); const j = mine(req); if (!j) return fail(res, 404, "That run has expired.");
    res.json({ ok: true, status: j.status, msg: j.msg, pct: j.pct | 0, result: j.status === "done" ? j.result : undefined, error: j.status === "err" ? j.error : undefined });
  });
  app.post("/api/plugins/jobs/:jid/cancel", (req, res) => {
    noStore(res); if (!req.me) return fail(res, 401, "Log in to use tools."); if (req.get("x-dt") !== "1" || !okOrigin(req)) return fail(res, 400, "Bad request.");
    const j = mine(req); if (!j) return fail(res, 404, "That run has expired."); j.cancel = true; res.json({ ok: true });
  });
};
