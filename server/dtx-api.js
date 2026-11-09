"use strict";
// dtx-api.js — DTX wallet, per-use charging, app view/download counters and the Hub endpoint for the Uncrypt app.
// Written for this site: node:sqlite (DatabaseSync), req.me sessions, the quota object that decrypt-core calls.
// Put it next to site.js. Mounting is shown in DTX-SETUP.md.
//
//   GET  /api/dtx/hub             everything the Hub screen shows
//   GET  /api/dtx/history         ledger
//   POST /api/dtx/track           {app, kind: "view"|"download"}  (counted once per person per app per day)
//   GET  /api/dtx/stats?ids=a,b   views/downloads per app (bundle ID)
//   POST /api/dtx/scratch         daily scratch card
//   POST /api/dtx/certificate     buy a Certificate (300 DTX); staff activates it afterwards
//   POST /api/dtx/ai/<v1|v1vision|v1worker>/chat/completions   AI gateway, billed by tokens
const crypto = require("crypto");

const DEFAULT_PRICES = { decrypt: 5, inject: 3, dylib_studio: 4, certificate: 300, image: 10, sign: 3, photo: 2, webpage: 2, gif: 1, colour: 1, think: 3 };   // DTX per use
const DEFAULT_AI = { perKTokens: 1, visionX: 2, min: 1, maxTokens: 8192 };             // AI: ceil(tokens/1000 * perKTokens) DTX (x visionX for images), at least min
const LABELS = { ai_message: "AI message", ai_vision: "AI image chat", image: "Image generation", decrypt: "Decrypt", inject: "Inject", dylib_studio: "Dylib Studio",
  scratch: "Scratch card", refund: "Refund", bonus: "Bonus", topup: "Top up", premium: "Premium", certificate: "Certificate", sign: "Sign", photo: "AI photo", webpage: "Webpage", gif: "GIF search", colour: "Colour wheel", think: "Think harder" };
const SCRATCH = [{ w: 700, dtx: 1 }, { w: 200, dtx: 5 }, { w: 80, dtx: 10 }, { w: 16, dtx: 25 }, { w: 3, dtx: 100 }, { w: 1, dtx: 0, cert: true }];

module.exports = function createDtx(o) {
  const { db } = o;
  const secret = String(o.secret || "dtx");
  const prices = Object.assign({}, DEFAULT_PRICES, o.prices || {});
  const ai = Object.assign({}, DEFAULT_AI, o.ai || {});
  const welcomeBonus = Number(o.welcomeBonus) || 0;
  const upstreams = Object.assign({ v1: "http://127.0.0.1:8081", v1vision: "http://127.0.0.1:8082", v1worker: "http://127.0.0.1:8083", sdgen: "http://127.0.0.1:8084" }, o.upstreams || {});
  const isStaff = o.isStaff || (() => false);   // staff use everything free
  const okOrigin = o.okOrigin || (() => true);

  db.exec(`
    CREATE TABLE IF NOT EXISTS dtx_ledger(id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, delta INTEGER NOT NULL, kind TEXT NOT NULL, ref TEXT, at INTEGER NOT NULL);
    CREATE UNIQUE INDEX IF NOT EXISTS dtx_ledger_ref ON dtx_ledger(user_id, kind, ref) WHERE ref IS NOT NULL;
    CREATE INDEX IF NOT EXISTS dtx_ledger_user ON dtx_ledger(user_id, at);
    CREATE TABLE IF NOT EXISTS dtx_app_stats(app_id TEXT PRIMARY KEY, views INTEGER NOT NULL DEFAULT 0, downloads INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS dtx_seen(app_id TEXT NOT NULL, who TEXT NOT NULL, kind TEXT NOT NULL, day TEXT NOT NULL, PRIMARY KEY(app_id, who, kind, day));
    CREATE TABLE IF NOT EXISTS dtx_scratch(user_id TEXT NOT NULL, day TEXT NOT NULL, prize TEXT, PRIMARY KEY(user_id, day));
    CREATE TABLE IF NOT EXISTS dtx_welcome(user_id TEXT PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS dtx_certs(user_id TEXT PRIMARY KEY, status TEXT NOT NULL, expires TEXT, at INTEGER NOT NULL);`);

  const day = () => new Date().toISOString().slice(0, 10);
  const dayStart = () => { const d = new Date(); d.setUTCHours(0, 0, 0, 0); return d.getTime(); };
  const uidOf = (x) => String(x == null ? "" : x).replace(/^u/, "");   // "u12" (quota) and 12 (session) are the same person

  // node:sqlite has no .transaction(): BEGIN IMMEDIATE takes the write lock first, so a balance check and its debit can't interleave.
  function tx(fn) {
    db.exec("BEGIN IMMEDIATE");
    try { const r = fn(); db.exec("COMMIT"); return r; } catch (e) { try { db.exec("ROLLBACK"); } catch { /* already rolled back */ } throw e; }
  }
  const q = {
    bal: db.prepare("SELECT COALESCE(SUM(delta),0) AS b FROM dtx_ledger WHERE user_id=?"),
    add: db.prepare("INSERT INTO dtx_ledger(user_id,delta,kind,ref,at) VALUES(?,?,?,?,?)"),
    hist: db.prepare("SELECT id,delta,kind,at FROM dtx_ledger WHERE user_id=? ORDER BY id DESC LIMIT ?"),
    usage: db.prepare("SELECT kind, SUM(CASE WHEN ref LIKE 'tok:%' THEN 0 ELSE 1 END) AS n, -SUM(delta) AS dtx FROM dtx_ledger WHERE user_id=? AND delta<0 AND at>=? GROUP BY kind"),
    netSpent: db.prepare("SELECT -COALESCE(SUM(delta),0) AS s FROM dtx_ledger WHERE user_id=? AND at>=? AND (delta<0 OR kind='refund')"),
    byId: db.prepare("SELECT * FROM dtx_ledger WHERE id=? AND user_id=?"),
    refunded: db.prepare("SELECT 1 FROM dtx_ledger WHERE user_id=? AND kind='refund' AND ref=?"),
  };
  const balance = (uid) => Number(q.bal.get(uidOf(uid)).b) || 0;
  const spend = (uid, cost, kind, ref) => tx(() => {
    uid = uidOf(uid);
    if (balance(uid) < cost) return { ok: false };
    return { ok: true, id: Number(q.add.run(uid, -cost, kind, ref || null, Date.now()).lastInsertRowid) };
  });
  const credit = (uid, amount, kind, ref) => { try { q.add.run(uidOf(uid), amount, kind, ref || null, Date.now()); return true; } catch { return false; } };   // false: this ref was already applied
  const refund = (uid, ledgerId) => tx(() => {
    uid = uidOf(uid);
    const row = q.byId.get(ledgerId, uid);
    if (!row || row.delta >= 0 || q.refunded.get(uid, String(ledgerId))) return false;
    q.add.run(uid, -row.delta, "refund", String(ledgerId), Date.now()); return true;
  });
  function maybeWelcome(uid) {
    if (!welcomeBonus) return;
    if (db.prepare("INSERT OR IGNORE INTO dtx_welcome(user_id) VALUES(?)").run(uidOf(uid)).changes) credit(uid, welcomeBonus, "bonus", "welcome");
  }

  // ---- limits ----
  const over = (key, max, ms) => (o.limited ? o.limited(key, max, ms) : false);   // site.js's limited(): true when over
  const inflight = new Map(), MAX_INFLIGHT = Math.max(2, Math.min(8, Number(process.env.AI_MAX_INFLIGHT) || 4));   // a reply plus background helper calls (titles, style, tools) can overlap
  const deny = (res, status, error, extra) => res.status(status).json(Object.assign({ ok: false, error }, extra || {}));
  const addressOf = (id) => "dtx1" + crypto.createHmac("sha256", secret).update("dtx-addr|" + id).digest("hex").slice(0, 36);
  const aiCost = (tokens, vision) => Math.max(ai.min, Math.ceil(tokens / 1000 * ai.perKTokens * (vision ? ai.visionX : 1)));

  // ---- decrypt quota, paid in DTX ----
  // Same shape as quota.js, so decrypt-core uses it unchanged: acct: { decrypt: dtx.wrapQuota(quota, staffUid) }.
  // Staff decrypt free. Guests can't decrypt. Everyone else pays prices.decrypt per decrypt (refunded when the decrypt fails).
  // quota.js still enforces cooldowns, the failed-decrypt throttle and the download limits; raise DEC_LIMIT_* in the env (see DTX-SETUP.md).
  function wrapQuota(base, isStaff) {
    const charges = new Map();   // "uid|appId" -> ledger id of the last charge
    const key = (uid, appId) => uid + "|" + (appId || "");
    const cost = prices.decrypt, partner = (uid) => /^up\d+\./.test(String(uid || ""));   // partner keys act as "up<keyId>.<visitor>" (see apply-keyauth-patch.js)
    return Object.assign({}, base, {
      status(uid, ip, appId) {
        const st = base.status(uid, ip, appId);
        if (st.tier === "staff") return st;
        if (partner(uid)) return Object.assign({}, st, { unlimited: true, free: true });
        if (st.tier === "guest") return Object.assign({}, st, { limit: 0, left: 0, unlimited: false });
        const left = Math.floor(balance(uid) / cost);
        return Object.assign({}, st, { cost, balance: balance(uid), left, limit: left + st.used, unlimited: false, dtx: true });
      },
      consume(uid, ip, appId) {
        if (isStaff(uid) || partner(uid)) return base.consume(uid, ip, appId);   // staff and partner keys: free (cooldowns and the failed-decrypt throttle still apply)
        if (!/^u\d+$/.test(String(uid || ""))) return Object.assign({}, base.status(uid, ip, appId), { ok: false, limit: 0, left: 0, error: "Log in with Telegram to decrypt. Each decrypt costs " + cost + " DTX." });
        if (over("dtx|dec|" + uid, 30, 60000)) return Object.assign({}, base.status(uid, ip, appId), { ok: false, error: "Slow down a little and try again." });
        const s = spend(uid, cost, "decrypt", null);
        if (!s.ok) return Object.assign({}, base.status(uid, ip, appId), { ok: false, left: 0, error: "Not enough DTX. A decrypt costs " + cost + " DTX. You have " + balance(uid) + ".", need: cost, balance: balance(uid) });
        const r = base.consume(uid, ip, appId);
        if (!r.ok) { refund(uid, s.id); return r; }   // cooldown or fail throttle: nothing is charged
        charges.set(key(uid, appId), s.id); if (charges.size > 5000) charges.delete(charges.keys().next().value);
        return Object.assign({}, r, { cost, balance: balance(uid) });
      },
      refund(uid, ip, appId) {
        base.refund(uid, ip, appId);
        const id = charges.get(key(uid, appId));
        if (id) { charges.delete(key(uid, appId)); refund(uid, id); }
      },
    });
  }

  // Charge-per-use middleware for any other route: app.post("/api/x", dtx.guard("inject"), handler). Refunds on a 4xx/5xx or a dropped connection.
  function guard(kind) {
    return (req, res, next) => {
      const u = req.me; if (!u) return deny(res, 401, "Log in with Telegram to use this. It costs DTX.");
      if (isStaff("u" + u.id)) return next();
      const cost = prices[kind]; if (cost == null) return deny(res, 500, "Unknown price for " + kind);
      if (over("dtx|" + kind + "|" + u.id, 30, 60000)) return deny(res, 429, "Slow down a little and try again.");
      const s = spend(u.id, cost, kind, null);
      if (!s.ok) return deny(res, 402, "Not enough DTX. This costs " + cost + " DTX.", { need: cost, balance: balance(u.id) });
      let done = false;
      const settle = () => { if (done) return; done = true; if (res.statusCode >= 400 || !res.writableEnded) refund(u.id, s.id); };
      res.on("finish", settle); res.on("close", settle);
      res.setHeader("x-dtx-charged", String(cost));
      next();
    };
  }

  function userView(req) {
    const u = req.me; if (!u) return null;
    const m = o.meView ? o.meView(u) : {};
    const c = db.prepare("SELECT status,expires FROM dtx_certs WHERE user_id=?").get(String(u.id));
    return { id: u.id, username: u.username, photoUrl: m.photoUrl || null, role: m.role || "member", premium: !!m.premium, address: addressOf(u.id),
      certificate: c ? { active: c.status === "active" && (!c.expires || Date.parse(c.expires) > Date.now()), status: c.status, expires: c.expires || null } : { active: false, status: "none" } };
  }

  function router(express) {
    const r = express.Router();
    const small = express.json({ limit: "4kb", type: "application/json" });
    const big = express.json({ limit: "25mb", type: "application/json" });   // AI chats can carry screenshots
    const post = (req, res, next) => (okOrigin(req) ? next() : deny(res, 400, "Bad request."));
    r.use((req, res, next) => { res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" }); next(); });

    r.get("/hub", (req, res) => {
      const v = userView(req);
      const top = db.prepare("SELECT app_id,views,downloads FROM dtx_app_stats ORDER BY downloads DESC, views DESC LIMIT 10").all();
      const base = { ok: true, prices, rates: { aiPerKTokens: ai.perKTokens, aiVisionX: ai.visionX, aiMin: ai.min }, topApps: top.map((t) => ({ id: t.app_id, views: Number(t.views), downloads: Number(t.downloads) })) };
      if (!v) return res.json(Object.assign(base, { signedIn: false }));
      const uid = String(v.id); maybeWelcome(uid);
      const used = {}; for (const row of q.usage.all(uid, dayStart())) used[row.kind] = { count: Number(row.n) || 0, dtx: Number(row.dtx) || 0 };
      const today = (tbl) => { try { const r = db.prepare("SELECT n FROM " + tbl + " WHERE k=? AND day=?").get("u" + uid, day()); return r ? Number(r.n) : 0; } catch { return 0; } };   // quota.js counters
      const sc = db.prepare("SELECT prize FROM dtx_scratch WHERE user_id=? AND day=?").get(uid, day());
      res.json(Object.assign(base, {
        signedIn: true, decryptsToday: today("dec_quota"), downloadsToday: today("dl_quota"), unmetered: isStaff("u" + uid), user: { username: v.username, photoUrl: v.photoUrl, role: v.role, premium: v.premium, address: v.address }, certificate: v.certificate,
        balance: balance(uid), usageToday: used, spentToday: Math.max(0, Number(q.netSpent.get(uid, dayStart()).s) || 0),
        scratch: { available: !sc, prize: sc ? sc.prize : null },
        history: q.hist.all(uid, 20).map((h) => ({ id: Number(h.id), delta: Number(h.delta), label: LABELS[h.kind] || h.kind, at: Number(h.at) })),
      }));
    });

    r.get("/history", (req, res) => {
      if (!req.me) return deny(res, 401, "Log in first.");
      const n = Math.min(100, Math.max(1, parseInt(req.query.limit, 10) || 50));
      res.json({ ok: true, history: q.hist.all(String(req.me.id), n).map((h) => ({ id: Number(h.id), delta: Number(h.delta), label: LABELS[h.kind] || h.kind, at: Number(h.at) })) });
    });

    // One count per person (or per network for guests) per app per day, so a script can't inflate the numbers.
    r.post("/track", post, small, (req, res) => {
      const { app, kind } = req.body || {};
      if (typeof app !== "string" || !app || app.length > 200 || !["view", "download"].includes(kind)) return deny(res, 400, "Bad request.");
      const who = req.me ? "u" + req.me.id : "ip" + crypto.createHash("sha1").update(String(req.ip)).digest("hex").slice(0, 16);
      if (over("dtx|trk|" + who, 120, 60000)) return deny(res, 429, "Too many requests.");
      if (db.prepare("INSERT OR IGNORE INTO dtx_seen(app_id,who,kind,day) VALUES(?,?,?,?)").run(app, who, kind, day()).changes) {
        db.prepare("INSERT OR IGNORE INTO dtx_app_stats(app_id) VALUES(?)").run(app);
        db.prepare(kind === "view" ? "UPDATE dtx_app_stats SET views=views+1 WHERE app_id=?" : "UPDATE dtx_app_stats SET downloads=downloads+1 WHERE app_id=?").run(app);
      }
      res.json({ ok: true });
    });

    r.get("/stats", (req, res) => {
      if (over("dtx|stats|" + req.ip, 300, 60000)) return deny(res, 429, "Too many requests.");
      const ids = String(req.query.ids || "").split(",").map((s) => s.trim()).filter(Boolean).slice(0, 200), out = {};
      const st = db.prepare("SELECT views,downloads FROM dtx_app_stats WHERE app_id=?");
      for (const id of ids) { const row = st.get(id); out[id] = row ? { views: Number(row.views), downloads: Number(row.downloads) } : { views: 0, downloads: 0 }; }
      res.json({ ok: true, stats: out });
    });

    r.post("/scratch", post, small, (req, res) => {
      if (!req.me) return deny(res, 401, "Log in first.");
      const uid = String(req.me.id);
      if (over("dtx|scr|" + uid, 10, 60000)) return deny(res, 429, "Slow down.");
      const pick = tx(() => {
        if (db.prepare("SELECT 1 FROM dtx_scratch WHERE user_id=? AND day=?").get(uid, day())) return null;
        const total = SCRATCH.reduce((a, p) => a + p.w, 0); let roll = crypto.randomInt(total), hit = SCRATCH[0];
        for (const p of SCRATCH) { if (roll < p.w) { hit = p; break; } roll -= p.w; }
        db.prepare("INSERT INTO dtx_scratch(user_id,day,prize) VALUES(?,?,?)").run(uid, day(), hit.cert ? "Certificate" : hit.dtx + " DTX");
        if (hit.dtx) credit(uid, hit.dtx, "scratch", day());
        return hit;
      });
      if (!pick) return deny(res, 409, "You already scratched today. Come back tomorrow.");
      if (pick.cert) db.prepare("INSERT INTO dtx_certs(user_id,status,expires,at) VALUES(?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET status='pending'").run(uid, "pending", null, Date.now());
      res.json({ ok: true, prize: pick.cert ? "Certificate" : pick.dtx + " DTX", dtx: pick.dtx, certificate: !!pick.cert, balance: balance(uid) });
    });

    // Buying a Certificate takes DTX and files an order; staff turn it active:  UPDATE dtx_certs SET status='active', expires='2027-01-01T00:00:00Z' WHERE user_id='<id>';
    r.post("/certificate", post, small, (req, res) => {
      if (!req.me) return deny(res, 401, "Log in first.");
      const uid = String(req.me.id), cur = db.prepare("SELECT status FROM dtx_certs WHERE user_id=?").get(uid);
      if (cur && (cur.status === "pending" || cur.status === "active")) return deny(res, 409, cur.status === "active" ? "You already have a Certificate." : "Your Certificate order is already in.");
      const s = spend(uid, prices.certificate, "certificate", null);
      if (!s.ok) return deny(res, 402, "Not enough DTX. A Certificate costs " + prices.certificate + " DTX.", { need: prices.certificate, balance: balance(uid) });
      db.prepare("INSERT INTO dtx_certs(user_id,status,expires,at) VALUES(?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET status='pending', at=excluded.at").run(uid, "pending", null, Date.now());
      res.json({ ok: true, status: "pending", balance: balance(uid) });
    });


    // ---- Composer extras: webpage text, GIF search, colour wheel. Each costs DTX (staff free); a failed fetch is refunded. ----
    const dns = require("dns").promises, net = require("net");
    const GIPHY = String(o.giphyKey || process.env.GIPHY_KEY || "");
    const privIp = (ip) => {
      if (net.isIPv4(ip)) { const [a, b] = ip.split(".").map(Number); return a === 0 || a === 10 || a === 127 || a >= 224 || (a === 100 && b >= 64 && b < 128) || (a === 169 && b === 254) || (a === 172 && b >= 16 && b < 32) || (a === 192 && b === 168) || (a === 192 && b === 0); }
      const l = ip.toLowerCase(); if (l.startsWith("::ffff:")) return privIp(l.slice(7));
      return l === "::" || l === "::1" || l.startsWith("fc") || l.startsWith("fd") || l.startsWith("fe8") || l.startsWith("fe9") || l.startsWith("fea") || l.startsWith("feb");
    };
    async function safeFetch(raw, hops) {
      let u; try { u = new URL(raw); } catch { throw new Error("That isn't a web address."); }
      if (u.protocol !== "http:" && u.protocol !== "https:") throw new Error("Only http and https links work.");
      if (u.username || u.password || (u.port && u.port !== "80" && u.port !== "443")) throw new Error("That address isn't allowed.");
      const host = u.hostname.replace(/^\[|\]$/g, "");
      const ips = net.isIP(host) ? [host] : (await dns.lookup(host, { all: true })).map((x) => x.address);
      if (!ips.length || ips.some(privIp)) throw new Error("That address isn't allowed.");
      const c = new AbortController(), t = setTimeout(() => c.abort(), 8000);
      try {
        const rs = await fetch(u.href, { redirect: "manual", signal: c.signal, headers: { "user-agent": "Mozilla/5.0 (compatible; UncryptBot/1.0)", accept: "text/html,text/plain,application/json;q=0.9,*/*;q=0.5" } });
        if (rs.status >= 300 && rs.status < 400 && rs.headers.get("location")) { if (hops >= 3) throw new Error("Too many redirects."); return safeFetch(new URL(rs.headers.get("location"), u).href, hops + 1); }
        if (!rs.ok) throw new Error("The site answered " + rs.status + ".");
        const ct = String(rs.headers.get("content-type") || "");
        if (!/text\/|json|xml/i.test(ct)) throw new Error("That page isn't text.");
        let buf = ""; const dec = new TextDecoder("utf-8", { fatal: false });
        for await (const ch of rs.body) { buf += dec.decode(ch, { stream: true }); if (buf.length > 1500000) { c.abort(); break; } }
        return { url: u, ct, text: buf };
      } finally { clearTimeout(t); }
    }
    const htmlText = (h) => h.replace(/<(script|style|noscript|svg|head|template)[\s\S]*?<\/\1>/gi, " ").replace(/<!--[\s\S]*?-->/g, " ").replace(/<\/(p|div|li|h[1-6]|tr|br|section|article)>|<br\s*\/?>/gi, "\n").replace(/<[^>]+>/g, " ")
      .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&#(\d+);/g, (m, n) => { try { return String.fromCodePoint(+n); } catch { return " "; } })
      .replace(/[ \t\f\v]+/g, " ").replace(/\s*\n\s*/g, "\n").trim();
    function charge(req, res, kind) {   // -> { uid, id } or null (response already sent)
      const u = req.me; if (!u) { deny(res, 401, "Log in with Telegram first. This costs DTX."); return null; }
      const uid = String(u.id); if (over("dtx|x|" + uid, 20, 60000)) { deny(res, 429, "Slow down a little and try again."); return null; }
      if (isStaff("u" + uid)) return { uid, id: null };
      const s = spend(uid, prices[kind], kind, null);
      if (!s.ok) { deny(res, 402, "Not enough DTX. This costs " + prices[kind] + " DTX.", { need: prices[kind], balance: balance(uid) }); return null; }
      return { uid, id: s.id };
    }
    r.post("/extra/webpage", post, small, async (req, res) => {
      const c = charge(req, res, "webpage"); if (!c) return;
      try {
        const g = await safeFetch(String((req.body && req.body.url) || "").trim().slice(0, 600), 0);
        let t = /html/i.test(g.ct) ? htmlText(g.text) : g.text.trim(); if (!t) throw new Error("The page had no readable text.");
        const cut = t.length > 6000; if (cut) t = t.slice(0, 6000) + "\n…(truncated)";
        res.json({ ok: true, host: g.url.hostname, text: t, balance: balance(c.uid) });
      } catch (e) { if (c.id) refund(c.uid, c.id); deny(res, 400, String((e && e.name === "AbortError") ? "The site took too long." : (e && e.message) || "Couldn't load that page.").slice(0, 160)); }
    });
    r.post("/extra/gif", post, small, async (req, res) => {
      if (!GIPHY) return deny(res, 503, "GIFs aren't set up on this site yet.");
      const qs = String((req.body && req.body.q) || "").trim().slice(0, 60); if (!qs) return deny(res, 400, "Type what to search for.");
      const c = charge(req, res, "gif"); if (!c) return;
      try {
        const rs = await fetch("https://api.giphy.com/v1/gifs/search?" + new URLSearchParams({ api_key: GIPHY, q: qs, limit: "12", rating: "pg-13" }), { signal: AbortSignal.timeout(8000) });
        if (!rs.ok) throw new Error("GIPHY answered " + rs.status);
        const j = await rs.json();
        const items = (j.data || []).map((d) => ({ id: String(d.id), title: String(d.title || "").slice(0, 80), thumb: d.images && d.images.fixed_height_small && d.images.fixed_height_small.url, url: d.images && (d.images.downsized_medium || d.images.fixed_height || {}).url })).filter((x) => /^https:\/\/media/.test(x.url || "") && /^https:\/\//.test(x.thumb || ""));
        if (!items.length && c.id) refund(c.uid, c.id);
        res.json({ ok: true, items, balance: balance(c.uid) });
      } catch { if (c.id) refund(c.uid, c.id); deny(res, 502, "GIF search isn't answering. You weren't charged."); }
    });
    r.post("/extra/colour", post, small, (req, res) => {
      const c = charge(req, res, "colour"); if (!c) return;
      res.json({ ok: true, balance: balance(c.uid) });
    });

    // AI gateway. Signed-in people only. One DTX is held when the reply starts; when it ends the real cost (tokens used) is settled, never below the balance.
    r.post("/ai/:model/chat/completions", post, big, async (req, res) => {
      const base = upstreams[req.params.model];
      if (!base) return deny(res, 404, "Unknown model.");
      const u = req.me; if (!u) return deny(res, 401, "Log in with Telegram to chat. AI messages cost DTX.");
      const uid = String(u.id);
      if (over("dtx|ai|" + uid, 40, 60000)) return deny(res, 429, "Slow down a little and try again.");
      if ((inflight.get(uid) || 0) >= MAX_INFLIGHT) return deny(res, 429, "Two replies are already running. Wait for one to finish.");
      const body = req.body && typeof req.body === "object" ? req.body : null; if (!body) return deny(res, 400, "Bad request.");
      const free = isStaff("u" + uid);
      const kind = free ? null : req.params.model === "v1vision" ? "ai_vision" : req.params.model === "v1" ? "ai_message" : null, vision = kind === "ai_vision";
      if (typeof body.max_tokens !== "number" || body.max_tokens > ai.maxTokens) body.max_tokens = ai.maxTokens;
      if (body.stream) body.stream_options = Object.assign({}, body.stream_options, { include_usage: true });
      // Extras: thinking mode and photos cost a flat amount on top of the tokens. Refunded with the reply when nothing came back.
      const thinking = !!(body.chat_template_kwargs && body.chat_template_kwargs.enable_thinking);
      if (thinking) { body.chat_template_kwargs = { enable_thinking: true }; body.temperature = 0.6; body.top_p = 0.95; }
      else delete body.chat_template_kwargs;
      const photo = vision && JSON.stringify(body.messages || []).indexOf('"image_url"') >= 0;
      const extras = free ? [] : [thinking && ["think", prices.think], photo && ["photo", prices.photo]].filter(Boolean);
      const need = ai.min + extras.reduce((a, x) => a + x[1], 0);
      let ledgerId = null, held = 0; const extraIds = [];
      if (kind) {
        if (balance(uid) < need) return deny(res, 402, "Not enough DTX. This reply needs " + need + " DTX.", { need, balance: balance(uid) });
        const s = spend(uid, ai.min, kind, null);
        if (!s.ok) return deny(res, 402, "Not enough DTX. AI costs " + ai.perKTokens + " DTX per 1K tokens.", { need: ai.min, balance: balance(uid) });
        ledgerId = s.id; held = ai.min;
        for (const x of extras) { const e = spend(uid, x[1], x[0], null); if (e.ok) extraIds.push(e.id); }
      }
      inflight.set(uid, (inflight.get(uid) || 0) + 1);
      const ctl = new AbortController(); res.on("close", () => ctl.abort());
      let ok = false, sent = false, tail = "";
      try {
        const up = await fetch(base + "/v1/chat/completions", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: ctl.signal });
        res.status(up.status); res.setHeader("content-type", up.headers.get("content-type") || "application/json"); res.flushHeaders();
        if (up.body) for await (const chunk of up.body) { sent = true; res.write(chunk); tail = (tail + Buffer.from(chunk).toString("utf8")).slice(-4096); }   // the usage record arrives last
        ok = up.ok; res.end();
      } catch { if (!res.headersSent) deny(res, 502, "The model server is not answering."); else res.end(); }
      finally {
        inflight.set(uid, Math.max(0, (inflight.get(uid) || 1) - 1));
        if (ledgerId && !ok && !sent) { refund(uid, ledgerId); extraIds.forEach((id) => refund(uid, id)); }
        else if (ledgerId) {
          const m = tail.match(/"total_tokens"\s*:\s*(\d+)/), total = m ? parseInt(m[1], 10) : 0;
          const extra = Math.min(Math.max(0, aiCost(total, vision) - held), balance(uid));
          if (extra > 0) { try { q.add.run(uid, -extra, kind, "tok:" + ledgerId, Date.now()); } catch { /* already settled */ } }
        }
      }
    });
    // Image generation (stable-diffusion.cpp sd-server): /api/dtx/ai/sdgen/v1/images/generations (JSON) and /edits (multipart). Flat price, refunded when it fails.
    const rawImg = express.raw({ type: ["multipart/form-data", "application/json"], limit: "12mb" });
    r.post("/ai/sdgen/v1/images/:op", post, rawImg, async (req, res) => {
      if (req.params.op !== "generations" && req.params.op !== "edits") return deny(res, 404, "Unknown route.");
      const u = req.me; if (!u) return deny(res, 401, "Log in with Telegram to make images. They cost DTX.");
      const uid = String(u.id), cost = prices.image;
      if (over("dtx|img|" + uid, 12, 60000)) return deny(res, 429, "Slow down a little and try again.");
      if ((inflight.get(uid) || 0) >= MAX_INFLIGHT) return deny(res, 429, "Two replies are already running. Wait for one to finish.");
      if (!Buffer.isBuffer(req.body) || !req.body.length) return deny(res, 400, "Bad request.");
      let ledgerId = null;
      if (!isStaff("u" + uid)) {
        const s = spend(uid, cost, "image", null);
        if (!s.ok) return deny(res, 402, "Not enough DTX. An image costs " + cost + " DTX.", { need: cost, balance: balance(uid) });
        ledgerId = s.id;
      }
      inflight.set(uid, (inflight.get(uid) || 0) + 1);
      const ctl = new AbortController(); res.on("close", () => ctl.abort());
      let ok = false;
      try {
        const up = await fetch(upstreams.sdgen + "/v1/images/" + req.params.op, { method: "POST", headers: { "content-type": req.get("content-type") }, body: req.body, signal: ctl.signal });
        const buf = Buffer.from(await up.arrayBuffer());
        ok = up.ok; res.status(up.status).type(up.headers.get("content-type") || "application/json").send(buf);
      } catch { if (!res.headersSent) deny(res, 502, "The image server is not answering."); }
      finally {
        inflight.set(uid, Math.max(0, (inflight.get(uid) || 1) - 1));
        if (ledgerId && !ok) refund(uid, ledgerId);
      }
    });
    return r;
  }

  return { router, guard, wrapQuota, spend, credit, refund, balance, prices };
};
