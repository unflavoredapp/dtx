"use strict";
// decrypt.team: website + API. Same stack and conventions as AirShare's site.js (Express, SQLite, signed-cookie sessions,
// scrypt passwords, Basic-auth admin) and the SAME decrypt pipeline (decrypt-core.js is cut from AirShare's site.js, and
// ./decrypt.js is AirShare's Telegram bridge, copied unchanged).
//
// Env (put secrets in /etc/decrypt-team.env, see deploy/):
//   SESSION_SECRET (required, 32+ chars)  ADMIN_USER / ADMIN_PASS (admin pages are off without ADMIN_PASS)
//   PORT (3100)  HOST (127.0.0.1)  SITE_URL (https://decrypt.team)  DATA_DIR (./data)
//   STAFF_USERS (comma list of usernames with unlimited decrypts)  DEC_LIMIT_GUEST / DEC_LIMIT_MEMBER / DEC_APP_COOLDOWN_MIN
//   LIBRARY_GB (default 900) / DECRYPT_CACHE_DIR   DECRYPT_MODULE (defaults to ./decrypt)
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const express = require("express");
const { DatabaseSync } = require("node:sqlite");

const env = process.env;
const PORT = Number(env.PORT) || 3100, HOST = env.HOST || "127.0.0.1";
const SITE_URL = String(env.SITE_URL || "https://decrypt.team").replace(/\/+$/, "");
const SITE_HOST = new URL(SITE_URL).host;
const DATA_DIR = path.resolve(env.DATA_DIR || path.join(__dirname, "..", "data"));
if (!env.SESSION_SECRET || env.SESSION_SECRET.length < 32) { console.error("Set SESSION_SECRET to a random string of at least 32 characters."); process.exit(1); }
fs.mkdirSync(DATA_DIR, { recursive: true });
if (!env.DECRYPT_CACHE_DIR) env.DECRYPT_CACHE_DIR = path.join(DATA_DIR, "decrypt-cache");

const db = new DatabaseSync(path.join(DATA_DIR, "decrypt-team.db"));
db.exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;");
db.exec("CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE COLLATE NOCASE, email TEXT NOT NULL UNIQUE COLLATE NOCASE, pass_hash TEXT NOT NULL, created_at TEXT NOT NULL, last_login TEXT, banned INTEGER NOT NULL DEFAULT 0, tg_id TEXT, dc_id TEXT)");
for (const c of ["tg_id", "dc_id", "premium_until"]) { try { db.exec(`ALTER TABLE users ADD COLUMN ${c} TEXT`); } catch { /* already there */ } }   // databases made before social login
db.exec("CREATE UNIQUE INDEX IF NOT EXISTS users_tg ON users(tg_id) WHERE tg_id IS NOT NULL; CREATE UNIQUE INDEX IF NOT EXISTS users_dc ON users(dc_id) WHERE dc_id IS NOT NULL;");

const sessKey = crypto.createHash("sha256").update("decrypt-team-session|" + env.SESSION_SECRET).digest();
const viewSalt = crypto.createHash("sha256").update("decrypt-team-bridge|" + env.SESSION_SECRET).digest("hex");
const sign = (s) => crypto.createHmac("sha256", sessKey).update(s).digest("base64url");
const safeEq = (a, b) => { const x = Buffer.from(String(a)), y = Buffer.from(String(b)); return x.length === y.length && crypto.timingSafeEqual(x, y); };
const safeHttps = (u) => { try { const x = new URL(String(u || "")); return x.protocol === "https:" ? x.toString().slice(0, 500) : ""; } catch { return ""; } };

// ---------- passwords ----------
const scryptP = (pw, salt) => new Promise((resolve, reject) => crypto.scrypt(pw, salt, 64, { N: 16384, r: 8, p: 1 }, (e, k) => (e ? reject(e) : resolve(k))));
const DUMMY_SALT = crypto.randomBytes(16);
const hashPw = async (pw) => { const salt = crypto.randomBytes(16); return `scrypt$${salt.toString("base64")}$${(await scryptP(pw, salt)).toString("base64")}`; };
const checkPw = async (pw, stored) => { // unknown users still pay the hashing cost, so timing doesn't reveal accounts
  const [tag, s64, h64] = String(stored || "").split("$");
  if (tag !== "scrypt" || !s64 || !h64) { await scryptP(pw, DUMMY_SALT); return false; }
  const want = Buffer.from(h64, "base64"), got = await scryptP(pw, Buffer.from(s64, "base64"));
  return want.length === got.length && crypto.timingSafeEqual(want, got);
};

// ---------- rate limiting ----------
const hits = new Map();
const limited = (key, max, ms) => { const now = Date.now(); let h = hits.get(key); if (!h || h.reset < now) { h = { n: 0, reset: now + ms }; hits.set(key, h); } return ++h.n > max; };
const hitsOf = (key) => { const h = hits.get(key); return h && h.reset >= Date.now() ? h.n : 0; };   // reads a counter without counting
setInterval(() => { const now = Date.now(); for (const [k, v] of hits) if (v.reset < now) hits.delete(k); }, 600000).unref();

// ---------- app + sessions ----------
const app = express();
app.disable("x-powered-by");
app.set("trust proxy", "loopback"); // Apache runs on this machine and sets X-Forwarded-For
// One person can hold a whole IPv6 /64 and pick any address in it, so every limit counts the /64, not the single address.
// (IPv4-mapped addresses count as the IPv4 address.)
function ipKey(ip) {
  ip = String(ip || "").split("%")[0];
  const m4 = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip); if (m4) return m4[1];
  if (!ip.includes(":")) return ip;
  const halves = ip.split("::"), head = halves[0] ? halves[0].split(":") : [], tail = halves.length > 1 && halves[1] ? halves[1].split(":") : [];
  const g = halves.length > 1 ? head.concat(Array(Math.max(0, 8 - head.length - tail.length)).fill("0"), tail) : head;
  return g.slice(0, 4).map((x) => (parseInt(x || "0", 16) || 0).toString(16)).join(":") + "::/64";
}
app.use((req, _res, next) => { Object.defineProperty(req, "ip", { value: ipKey(req.ip), configurable: true, enumerable: true, writable: true }); next(); });
const secureCookie = SITE_URL.startsWith("https://");
const cookieFlags = `Path=/; HttpOnly; SameSite=Lax${secureCookie ? "; Secure" : ""}`;
const SESS_MS = 30 * 86400000;
const userById = db.prepare("SELECT id,username,email,banned,premium_until FROM users WHERE id=?");
const cookieOf = (req, name) => { const m = new RegExp("(?:^|;\\s*)" + name + "=([^;]+)").exec(req.headers.cookie || ""); return m ? m[1] : ""; };
function readSession(req) {
  const [id, exp, sig] = cookieOf(req, "dt_sess").split(".");
  if (!/^\d+$/.test(id || "") || !/^\d+$/.test(exp || "") || !sig || Number(exp) < Date.now() || !safeEq(sig, sign(`${id}.${exp}`))) return null;
  const u = userById.get(Number(id));
  return u && !u.banned ? u : null;
}
const setSession = (res, id) => { const exp = Date.now() + SESS_MS; res.append("Set-Cookie", `dt_sess=${id}.${exp}.${sign(`${id}.${exp}`)}; Max-Age=${SESS_MS / 1000}; ${cookieFlags}`); };
const clearSession = (res) => res.append("Set-Cookie", `dt_sess=; Max-Age=0; ${cookieFlags}`);
function guestId(req) { const [g, sig] = cookieOf(req, "dt_guest").split("."); return g && /^[0-9a-f]{24}$/.test(g) && sig && safeEq(sig, sign("g|" + g)) ? g : ""; }
function actorId(req, res, create) { // "u<id>" for accounts, "g<random>" for visitors without one
  if (req.me) return "u" + req.me.id;
  let g = guestId(req);
  if (!g && create && res) { g = crypto.randomBytes(12).toString("hex"); res.append("Set-Cookie", `dt_guest=${g}.${sign("g|" + g)}; Max-Age=${30 * 86400}; ${cookieFlags}`); }
  return g ? "g" + g : null;
}

app.use((_req, res, next) => {
  res.set({
    "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY", "Referrer-Policy": "strict-origin-when-cross-origin",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
    "Content-Security-Policy": "default-src 'self'; img-src 'self' https: data:; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
  });
  next();
});
app.use((req, _res, next) => { try { req.me = readSession(req); } catch { req.me = null; } next(); });

const fail = (res, status, error) => res.status(status).json({ ok: false, error });
const okOrigin = (req) => { const o = req.get("origin"); if (!o) return true; try { const h = new URL(o).host; return h === req.get("host") || h === SITE_HOST; } catch { return false; } };
const guard = (req, res, next) => {
  res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
  if (!okOrigin(req) || !req.is("application/json")) return fail(res, 400, "Bad request.");
  next();
};
const jsonBody = express.json({ limit: "4kb", type: "application/json" });
const jsonErr = (err, _req, res, next) => (err ? fail(res, 400, "Bad request.") : next());
const needUser = (req, res, next) => { req.uid = actorId(req, res, true); next(); };

// ---------- honeypot (see honeypot.js): decoy paths for scanners, a ban gate, fake admin credentials ----------
let honeypot;
try { honeypot = require("./honeypot")({ app, db, env, express, fail }); }
catch (e) { console.warn("Honeypot not loaded (upload honeypot.js next to site.js):", e.message); honeypot = { robots: "", isToken: () => false, trip() {}, admin() {}, art: () => "" }; }

// ---------- accounts ----------
const NAME_RE = /^[A-Za-z0-9_]{3,20}$/, EMAIL_RE = /^[^\s@]{1,64}@[^\s@.]+(?:\.[^\s@.]+)+$/;
const RESERVED = new Set(["admin", "administrator", "root", "system", "support", "staff", "moderator", "decrypt", "decryptteam", "owner"]);
const STAFF = require("./lib/decomp/roles").init({}).staffView;
const staffUid = (uid) => { const m = /^u(\d+)$/.exec(String(uid || "")); const u = m ? userById.get(Number(m[1])) : null; return !!(u && STAFF.has(u.username.toLowerCase())); };
const premiumOn = (u) => !!(u && u.premium_until && Date.parse(u.premium_until) > Date.now());
const isPremiumUid = (uid) => { const m = /^u(\d+)$/.exec(String(uid || "")); return premiumOn(m ? userById.get(Number(m[1])) : null); };
const me = (u) => (u ? { username: u.username, staff: STAFF.has(u.username.toLowerCase()), premium: premiumOn(u), premium_until: premiumOn(u) ? u.premium_until : null } : null);
// adds days to an account's Premium (stacking on what's left); returns false when the account doesn't exist. days may be negative.
function setPremium(uid, mode, days) {
  const u = userById.get(Number(uid)); if (!u) return false;
  const cur = u.premium_until ? Date.parse(u.premium_until) : 0, base = Math.max(Date.now(), cur || 0);
  const next = mode === "clear" ? null : (mode === "add" && days < 0 ? (cur - Math.abs(days) * 86400000) : base + days * 86400000);
  const val = next && next > Date.now() ? new Date(next).toISOString() : null;
  db.prepare("UPDATE users SET premium_until=? WHERE id=?").run(val, u.id); return true;
}

app.post("/api/auth/register", guard, jsonBody, async (req, res) => {
  try {
    if (limited("r|" + req.ip, Number(env.SIGNUPS_PER_HOUR) || 3, 3600000) || limited("rd|" + req.ip, Number(env.SIGNUPS_PER_DAY) || 6, 86400000)) return fail(res, 429, "Too many sign-ups from this network. Try again later.");
    const b = req.body || {};
    const username = String(b.username || "").trim(), email = String(b.email || "").trim().toLowerCase(), password = typeof b.password === "string" ? b.password : "";
    if (!NAME_RE.test(username)) return fail(res, 400, "Username must be 3-20 letters, numbers or underscores.");
    if (RESERVED.has(username.toLowerCase())) return fail(res, 400, "That username isn't available.");
    if (email.length > 120 || !EMAIL_RE.test(email)) return fail(res, 400, "Enter a valid email address.");
    if (password.length < 8 || password.length > 128) return fail(res, 400, "Password must be 8-128 characters.");
    const hash = await hashPw(password), now = new Date().toISOString();
    let id;
    try { id = Number(db.prepare("INSERT INTO users(username,email,pass_hash,created_at,last_login) VALUES(?,?,?,?,?)").run(username, email, hash, now, now).lastInsertRowid); }
    catch (e) { if (/UNIQUE/i.test(String(e.message))) return fail(res, 409, "That username or email is already in use."); throw e; }
    setSession(res, id);
    return res.json({ ok: true, user: me(userById.get(id)) });
  } catch (e) { console.warn("Register failed:", e.message); return fail(res, 500, "Something went wrong. Please try again."); }
}, jsonErr);

const findUser = db.prepare("SELECT id,username,email,pass_hash,banned,premium_until FROM users WHERE username=? OR email=?");
app.post("/api/auth/login", guard, jsonBody, async (req, res) => {
  try {
    const b = req.body || {};
    const ident = String(b.username || "").trim().slice(0, 120), password = typeof b.password === "string" ? b.password.slice(0, 128) : "";
    if (!ident || !password) return fail(res, 400, "Enter your username and password.");
    if (limited("l|" + req.ip, 20, 900000) || limited("lu|" + ident.toLowerCase(), 8, 900000)) return fail(res, 429, "Too many attempts. Try again in a few minutes.");
    if (honeypot.isToken(ident, password)) { honeypot.trip(req, "honeytoken login", true); await new Promise((r) => setTimeout(r, 1500)); return fail(res, 401, "Incorrect username or password."); }   // the fake admin login from the decoys
    const row = findUser.get(ident, ident.toLowerCase());
    const ok = await checkPw(password, row ? row.pass_hash : null);
    if (!row || !ok) return fail(res, 401, "Incorrect username or password.");
    if (row.banned) return fail(res, 403, "This account is disabled.");
    db.prepare("UPDATE users SET last_login=? WHERE id=?").run(new Date().toISOString(), row.id);
    setSession(res, row.id);
    return res.json({ ok: true, user: me(row) });
  } catch (e) { console.warn("Login failed:", e.message); return fail(res, 500, "Something went wrong. Please try again."); }
}, jsonErr);

app.post("/api/auth/logout", guard, jsonBody, (_req, res) => { clearSession(res); res.json({ ok: true }); }, jsonErr);
app.get("/api/auth/me", (req, res) => { res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" }); res.json({ ok: true, user: me(req.me) }); });

// ---------- Telegram / Discord login (see social.js) ----------
// First sign-in creates the account. The username always gets a random tail, so nobody can claim a staff or reserved name this way.
function socialUser(col, extId, hint) {
  if (col !== "tg_id" && col !== "dc_id") return null;
  const row = db.prepare(`SELECT id,banned FROM users WHERE ${col}=?`).get(String(extId));
  if (row) { if (row.banned) return null; db.prepare("UPDATE users SET last_login=? WHERE id=?").run(new Date().toISOString(), row.id); return row.id; }
  const base = String(hint || "").replace(/[^A-Za-z0-9]/g, "").slice(0, 12) || "user", now = new Date().toISOString();
  for (let i = 0; i < 8; i++) {
    const name = base + "_" + crypto.randomBytes(3).toString("hex").slice(0, 4);
    try { return Number(db.prepare(`INSERT INTO users(username,email,pass_hash,created_at,last_login,${col}) VALUES(?,?,?,?,?,?)`).run(name, `${col}${extId}@social.invalid`, "", now, now, String(extId)).lastInsertRowid); }
    catch (e) { if (!/UNIQUE/i.test(String(e.message))) throw e; if (db.prepare(`SELECT 1 FROM users WHERE ${col}=?`).get(String(extId))) return socialUser(col, extId, hint); }
  }
  return null;
}
require("./social")({ app, env, SITE_URL, limited, fail, guard, jsonBody, jsonErr, cookieOf, cookieFlags, sign, safeEq, setSession, socialUser, me, userById });

// ---------- decrypt (same pipeline as AirShare) ----------
const quota = require("./quota")({ db, isStaff: staffUid, isPremium: isPremiumUid });
let decMod = null;
try { decMod = require(env.DECRYPT_MODULE || "./decrypt").create({ db, secret: viewSalt }); }
catch (e) { console.warn("Decrypt bridge not loaded (copy AirShare's decrypt.js next to site.js):", e.message); }
let remoteMod = { enabled: false };
try { remoteMod = require(env.STORE_MODULE || "./remote").create(env); } catch (e) { console.warn("Remote storage not loaded:", e.message); }
const core = require("./decrypt-core")({ web: app, db, limited, fail, guard, needUser, jsonBody, jsonErr, actorId, acct: { decrypt: quota }, decMod, safeHttps, remoteMod });
require("./repo")({ app, db, limited, fail, safeHttps });
let hostedMod = null;
try { hostedMod = require("./hosted")({ app, db, limited, fail, env, remoteMod, dataDir: DATA_DIR, site: SITE_URL, okOrigin, express }); } catch (e) { console.warn("Hosting not loaded (upload hosted.js next to site.js):", e.message); }   // Repo Studio: host a built IPA at a normal download link   // Repo Studio: repo fetch helper and upstream versions
if (hostedMod) { try { require("./dta")({ app, db, limited, fail, env, okOrigin, express, hosted: hostedMod, isStaff: (u) => staffUid("u" + u) }); } catch (e) { console.warn("DTA feed not loaded (upload dta.js next to site.js):", e.message); } }   // community source /DTA.json
if (hostedMod) { try { require("./builder")({ app, limited, fail, env, okOrigin, express, core, hosted: hostedMod }); } catch (e) { console.warn("Server builds not loaded (upload builder.js next to site.js):", e.message); } }   // Repo Studio: big apps are rebuilt on the server instead of in the phone's browser
try { require("./ipabuild")({ app, express, limited, fail, okOrigin, isStaff: staffUid, isPremium: isPremiumUid, dataDir: DATA_DIR, env }); } catch (e) { console.warn("IPA Builder not loaded:", e.message); }
try { require("./dylibs")({ app, db, limited, fail, env, remoteMod, isStaff: (u) => staffUid("u" + u), isPremium: (u) => isPremiumUid("u" + u), dataDir: DATA_DIR, okOrigin, express }); } catch (e) { console.warn("Saved libraries not loaded (upload dylibs.js next to site.js):", e.message); }   // Repo Studio: libraries saved per app and version

// ---------- admin (Basic auth) ----------
const ADMIN_USER = String(env.ADMIN_USER || "admin"), ADMIN_PASS = String(env.ADMIN_PASS || "");
const adminAuth = (req, res, next) => {
  if (!ADMIN_PASS) return res.status(404).send("Admin is disabled. Set ADMIN_PASS.");
  if (hitsOf("adm|" + req.ip) >= 10) return res.status(429).send("Too many attempts. Try again later.");   // wrong guesses lock the network out for 15 minutes
  const h = String(req.get("authorization") || "");
  if (h.startsWith("Basic ")) {
    const raw = Buffer.from(h.slice(6), "base64").toString("utf8"), i = raw.indexOf(":");
    if (i >= 0 && safeEq(raw.slice(0, i), ADMIN_USER) && safeEq(raw.slice(i + 1), ADMIN_PASS)) return next();
    limited("adm|" + req.ip, 10, 900000);   // counts a failed try
  }
  res.set("WWW-Authenticate", 'Basic realm="Decrypt.team admin"');
  return res.status(401).send("Authentication required.");
};
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const likeEsc = (x) => String(x).replace(/[\\%_]/g, "\\$&");   // a search for "%" or "_" matches those characters, not everything
const ADMIN_CSRF = crypto.randomBytes(24).toString("hex");
const okCsrf = (t) => safeEq(String(t || ""), ADMIN_CSRF);
const adminCsp = "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'";
const adminPage = (res, title, body, script) => {
  res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow", "Content-Security-Policy": adminCsp });
  res.type("html").send(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>${esc(title)} · Admin</title><link rel="stylesheet" href="/admin.css"></head><body><main class="adm"><nav><a href="/admin">Overview</a><a href="/admin/users">Users</a><a href="/admin/library">Library</a><a href="/admin/payments">Payments</a><a href="/admin/telegram">Telegram</a><a href="/">Site</a></nav>${body}</main>${script ? `<script src="${script}"></script>` : ""}</body></html>`);
};
honeypot.admin({ adminAuth, adminPage, esc, okCsrf, csrf: ADMIN_CSRF });
app.get("/admin", adminAuth, async (_req, res) => {
  const users = db.prepare("SELECT COUNT(*) n FROM users").get().n;
  const today = new Date().toISOString().slice(0, 10);
  const decToday = db.prepare("SELECT COALESCE(SUM(n),0) n FROM dec_quota WHERE day=? AND k NOT LIKE 'ip|%' AND k NOT LIKE 'mip|%' AND k NOT LIKE 'fail|%'").get(today).n;
  const lib = core.libStats();
  let tg = "not loaded";
  if (decMod && decMod.status) { try { const s = await decMod.status(); tg = !s.lib ? "telegram package missing" : s.authed ? "connected" : "not logged in"; } catch { tg = "error"; } }
  const jobs = core.decBusy().length;
  adminPage(res, "Overview", `<h1>Decrypt.team</h1><div class="grid"><div class="box"><b>${users}</b><span>accounts</span></div><div class="box"><b>${decToday}</b><span>decrypts today</span></div><div class="box"><b>${jobs}</b><span>running now</span></div><div class="box"><b>${(lib.stored / 1e9).toFixed(2)} GB</b><span>library: ${lib.versions} versions of ${lib.apps} apps${lib.remote ? ` · on the storage server: ${lib.remote.uploaded}, uploading: ${lib.remote.pending}` : ""}</span></div><div class="box"><b>${(lib.bytes / 1e9).toFixed(2)} / ${(lib.max / 1e9).toFixed(0)} GB</b><span>${lib.remote ? "hot copies on this disk" : "disk used"}</span></div><div class="box"><b>${esc(tg)}</b><span>Telegram bridge</span></div></div>
<h2>Most wanted in the library</h2><table><tr><th>App</th><th>Version</th><th>Size</th><th>Requests</th><th>Downloads</th></tr>${lib.top.map((r) => `<tr><td>${esc(r.name)}</td><td>${esc(r.ver)}</td><td>${(r.size / 1e6).toFixed(0)} MB</td><td>${r.requests}</td><td>${r.downloads}</td></tr>`).join("") || `<tr><td colspan="5" class="m">Nothing yet.</td></tr>`}</table>
<h2>Recent accounts</h2><table><tr><th>User</th><th>Email</th><th>Joined</th><th>Last login</th></tr>${db.prepare("SELECT username,email,created_at,last_login FROM users ORDER BY id DESC LIMIT 30").all().map((u) => `<tr><td>${esc(u.username)}</td><td>${esc(u.email)}</td><td>${esc((u.created_at || "").slice(0, 10))}</td><td>${esc((u.last_login || "").slice(0, 16).replace("T", " "))}</td></tr>`).join("")}</table>`);
});

// Telegram login for the bridge. It works exactly like AirShare's /admin/telegram, but this site has its own database,
// so it also has its OWN Telegram session (never share one session between two servers: Telegram revokes it).
const tg = decMod && decMod.status ? decMod : null;
const tgJson = express.json({ limit: "20kb", type: "application/json" });
const tgGuard = (req, res, next) => {
  res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
  if (!req.is("application/json")) return fail(res, 400, "Bad request.");
  if (!okCsrf((req.body || {}).csrf)) return fail(res, 403, "Bad token. Reload the page and try again.");
  next();
};
app.get("/admin/telegram", adminAuth, async (_req, res) => {
  if (!tg) return adminPage(res, "Telegram", `<h1>Telegram</h1><p class="warn">The decrypt bridge isn't loaded. Copy AirShare's <code>decrypt.js</code> into <code>server/</code> and restart.</p>`);
  const s = await tg.status();
  const state = !s.lib ? "The <code>telegram</code> package isn't installed. Run <code>npm i telegram</code> in the server folder and restart."
    : s.authed ? `Connected as <b>${esc((s.who && s.who.name) || "account")}</b>${s.who && s.who.username ? " (@" + esc(s.who.username) + ")" : ""}. Requests go to <b>@${esc(s.bot)}</b>.`
    : s.hasKeys ? "Not logged in. Add your phone below." + (s.error ? " (" + esc(s.error) + ")" : "") : "Add your API id and hash first.";
  adminPage(res, "Telegram", `<h1>Telegram</h1><div class="flash" id="fl" hidden></div><div class="box wide"><span class="dot${s.authed ? " ok" : ""}"></span>${state}</div>
<input type="hidden" id="csrf" value="${esc(ADMIN_CSRF)}">
<h2>1 · API keys</h2><div class="box wide"><p class="m">From my.telegram.org → API development tools. Use a Telegram account that is NOT the one AirShare uses.</p>
<label for="ai">api_id</label><input id="ai" inputmode="numeric" autocomplete="off" value="${esc(s.apiId)}"><label for="ah">api_hash</label><input id="ah" type="password" autocomplete="off" placeholder="${s.hasKeys ? "saved (enter to replace)" : "32 hex characters"}"><button id="k">Save keys</button></div>
<h2>2 · Log in</h2><div class="box wide"><label for="ph">Phone (with country code)</label><input id="ph" type="tel" autocomplete="off" placeholder="+15551234567"><button id="sc">Send code</button>
<div id="cb" hidden><label for="cd">Code from Telegram</label><input id="cd" inputmode="numeric" autocomplete="off"><button id="si">Sign in</button></div>
<div id="pb" hidden><label for="pw">2-step verification password</label><input id="pw" type="password" autocomplete="off"><button id="sp">Sign in</button></div></div>
<details class="box wide"><summary>Or paste a session string</summary><label for="ss">gramjs StringSession</label><input id="ss" type="password" autocomplete="off"><button id="us">Use session</button></details>
${s.authed ? '<button class="danger" id="lo">Log out of Telegram</button>' : ""}`, "/admin-telegram.js");
});
app.post("/admin/telegram/keys", adminAuth, tgJson, tgGuard, async (req, res) => { if (!tg) return fail(res, 503, "Bridge not loaded."); const b = req.body || {}; const err = await tg.setKeys(b.api_id, b.api_hash); return err ? fail(res, 400, err) : res.json({ ok: true }); });
app.post("/admin/telegram/code", adminAuth, tgJson, tgGuard, async (req, res) => { if (!tg) return fail(res, 503, "Bridge not loaded."); const r = await tg.sendCode((req.body || {}).phone); return r.error ? fail(res, 400, r.error) : res.json(r); });
app.post("/admin/telegram/signin", adminAuth, tgJson, tgGuard, async (req, res) => { if (!tg) return fail(res, 503, "Bridge not loaded."); const b = req.body || {}; const r = await tg.signIn(b.code, b.password); return r.error ? fail(res, 400, r.error) : res.json(r.need2fa ? { ok: false, need2fa: true } : { ok: true }); });
app.post("/admin/telegram/session", adminAuth, tgJson, tgGuard, async (req, res) => { if (!tg) return fail(res, 503, "Bridge not loaded."); const err = await tg.useSession((req.body || {}).session); return err ? fail(res, 400, err) : res.json({ ok: true }); });
app.post("/admin/telegram/logout", adminAuth, tgJson, tgGuard, async (_req, res) => { if (!tg) return fail(res, 503, "Bridge not loaded."); await tg.logout(); return res.json({ ok: true }); });

// ---------- admin: accounts + Premium ----------
const adminJson = (req, res, next) => {
  res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
  if (!req.is("application/json")) return fail(res, 400, "Bad request.");
  if (!okCsrf((req.body || {}).csrf)) return fail(res, 403, "Bad token. Reload the page and try again.");
  next();
};
const admJson = express.json({ limit: "8kb", type: "application/json" });
app.get("/admin/users", adminAuth, (req, res) => {
  const find = String(req.query.q || "").trim().slice(0, 40);
  const rows = (find ? db.prepare("SELECT id,username,email,created_at,last_login,banned,premium_until,tg_id,dc_id FROM users WHERE username LIKE ? ESCAPE '\\' OR email LIKE ? ESCAPE '\\' ORDER BY id DESC LIMIT 100").all(`%${likeEsc(find)}%`, `%${likeEsc(find)}%`)
    : db.prepare("SELECT id,username,email,created_at,last_login,banned,premium_until,tg_id,dc_id FROM users ORDER BY id DESC LIMIT 100").all());
  const tr = rows.map((u) => { const p = premiumOn(u), via = u.tg_id ? "Telegram" : u.dc_id ? "Discord" : "password";
    return `<tr data-id="${u.id}"><td>${esc(u.username)}${STAFF.has(u.username.toLowerCase()) ? " <span class=\"m\">staff</span>" : ""}</td><td>${esc(/\.invalid$/.test(u.email) ? "" : u.email)}</td><td>${via}</td><td>${p ? esc(u.premium_until.slice(0, 10)) : "<span class=\"m\">free</span>"}</td><td>${u.banned ? "<span class=\"warn\">disabled</span>" : "active"}</td>
<td><button class="s" data-a="prem">Premium</button><button class="s" data-a="pw">Password</button><button class="s danger" data-a="ban">${u.banned ? "Enable" : "Disable"}</button></td></tr>`; }).join("");
  adminPage(res, "Users", `<h1>Users</h1><div class="flash" id="fl" hidden></div><input type="hidden" id="csrf" value="${esc(ADMIN_CSRF)}">
<h2>Create account</h2><div class="box wide"><label for="nu">Username</label><input id="nu" autocomplete="off" maxlength="20" placeholder="3-20 letters, numbers, _"><label for="ne">Email (optional)</label><input id="ne" type="email" autocomplete="off" maxlength="120">
<label for="np">Password (8+ characters)</label><input id="np" type="text" autocomplete="off" maxlength="128"><label for="nd">Premium days to start with (0 for none)</label><input id="nd" inputmode="numeric" value="0"><button id="cr">Create account</button></div>
<h2>Accounts</h2><form method="get" action="/admin/users"><input name="q" value="${esc(find)}" placeholder="Search username or email"></form>
<div class="scroll"><table><thead><tr><th>User</th><th>Email</th><th>Login</th><th>Premium until</th><th>State</th><th></th></tr></thead><tbody id="ub">${tr || '<tr><td colspan="6" class="m">No accounts.</td></tr>'}</tbody></table></div>`, "/admin-users.js");
});
const userOps = [
  ["/admin/users/create", async (b) => {
    const username = String(b.username || "").trim(), password = typeof b.password === "string" ? b.password : "", days = Math.floor(Number(b.days) || 0);
    let email = String(b.email || "").trim().toLowerCase();
    if (!NAME_RE.test(username)) return "Username must be 3-20 letters, numbers or underscores.";
    if (email && (email.length > 120 || !EMAIL_RE.test(email))) return "Enter a valid email address, or leave it empty.";
    if (!email) email = username.toLowerCase() + "@admin.invalid";
    if (password.length < 8 || password.length > 128) return "Password must be 8-128 characters.";
    if (days < 0 || days > 3650) return "Premium days must be 0 to 3650.";
    const hash = await hashPw(password), now = new Date().toISOString();
    let id; try { id = Number(db.prepare("INSERT INTO users(username,email,pass_hash,created_at) VALUES(?,?,?,?)").run(username, email, hash, now).lastInsertRowid); }
    catch (e) { if (/UNIQUE/i.test(String(e.message))) return "That username or email is already in use."; throw e; }
    if (days) setPremium(id, "add", days);
    return "";
  }],
  ["/admin/users/premium", async (b) => {   // days > 0 adds, days < 0 removes, clear:true ends Premium now
    const id = Number(b.id), days = Math.floor(Number(b.days) || 0);
    if (!userById.get(id)) return "No such account.";
    if (b.clear) { setPremium(id, "clear", 0); return ""; }
    if (!days || Math.abs(days) > 3650) return "Enter a number of days (1 to 3650, or negative to take days away).";
    setPremium(id, "add", days); return "";
  }],
  ["/admin/users/password", async (b) => {
    const id = Number(b.id), password = typeof b.password === "string" ? b.password : "";
    if (!userById.get(id)) return "No such account.";
    if (password.length < 8 || password.length > 128) return "Password must be 8-128 characters.";
    db.prepare("UPDATE users SET pass_hash=? WHERE id=?").run(await hashPw(password), id); return "";
  }],
  ["/admin/users/ban", async (b) => {
    const id = Number(b.id); if (!userById.get(id)) return "No such account.";
    db.prepare("UPDATE users SET banned=? WHERE id=?").run(b.banned ? 1 : 0, id); return "";
  }],
];
for (const [route, fn] of userOps) app.post(route, adminAuth, admJson, adminJson, async (req, res) => {
  try { const err = await fn(req.body || {}); return err ? fail(res, 400, err) : res.json({ ok: true }); }
  catch (e) { console.warn("Admin users:", e.message); return fail(res, 500, "Something went wrong."); }
});
app.get("/admin/library", adminAuth, (req, res) => {
  const find = String(req.query.q || "").trim().slice(0, 60), rows = core.libAdminList(find);
  const same = (x, y) => String(x || "").replace(/(\.0+)+$/, "") === String(y || "").replace(/(\.0+)+$/, "");
  const tr = rows.map((r) => `<tr data-a="${esc(r.app_id)}" data-v="${esc(r.ver)}"><td>${esc(r.name || r.bid || r.app_id)}<br><span class="m">${esc(r.bid || "")} · ${esc(r.app_id)}</span></td><td>v${esc(r.ver)}${r.ipa_ver && !same(r.ipa_ver, r.ver) ? `<br><span class="warn">file says v${esc(r.ipa_ver)}</span>` : ""}</td><td>${(r.size / 1048576).toFixed(0)} MB</td><td>${esc(new Date(r.created_at).toISOString().slice(0, 10))}</td><td>${r.downloads | 0}</td><td><button class="s danger" data-x="1">Delete</button></td></tr>`).join("");
  adminPage(res, "Library", `<h1>Library</h1><div class="flash" id="fl" hidden></div><input type="hidden" id="csrf" value="${esc(ADMIN_CSRF)}">
<form method="get" action="/admin/library"><input name="q" value="${esc(find)}" placeholder="Search app name, bundle ID or App Store ID"></form>
<div class="scroll"><table><thead><tr><th>App</th><th>Version</th><th>Size</th><th>Saved</th><th>Downloads</th><th></th></tr></thead><tbody id="lb">${tr || '<tr><td colspan="6" class="m">Nothing saved.</td></tr>'}</tbody></table></div>`, "/admin-library.js");
});
app.post("/admin/library/delete", adminAuth, admJson, adminJson, (req, res) => {
  try { const b = req.body || {}; return core.libAdminDrop(b.app, b.ver) ? res.json({ ok: true }) : fail(res, 404, "That version isn't in the library any more."); }
  catch (e) { console.warn("Admin library:", e.message); return fail(res, 500, "Something went wrong."); }
});
const payments = { on: false };   // set by the payments module once it knows whether the wallets work
require("./payments").mount(app, { onEnabled: (v) => { payments.on = !!v; }, limits: { guest: quota.limits.guest, member: quota.limits.member, premium: quota.limits.premium, downloads: quota.limits.downloads }, describePerks: () => [], db, guard, jsonBody, jsonErr, needAuth: (req, res, next) => (req.me ? next() : fail(res, 401, "Log in first.")), fail, limited, setPremium, auth: adminAuth, express, okCsrf, adminPage, esc, csrf: ADMIN_CSRF });

// community links for the footer cards (only shown when set)
const httpsOnly = (u) => /^https:\/\/[^\s"'<>]+$/.test(String(u || "")) ? String(u) : "";
app.get("/api/config", (_req, res) => res.json({ ok: true, telegram: httpsOnly(env.COMMUNITY_TELEGRAM), discord: httpsOnly(env.COMMUNITY_DISCORD) }));
app.get("/healthz", (_req, res) => res.json({ ok: true, time: new Date().toISOString(), bridge: !!decMod }));

// ---------- static site ----------
try { require("./stats")({ app, db, secret: viewSalt, limited }); } catch (e) { console.warn("Stats not loaded (upload stats.js next to site.js):", e.message); }   // home page numbers: real counts only
try { require("./members")({ app, db, express, limited, fail, okOrigin }); } catch (e) { console.warn("Member wall not loaded (upload members.js next to site.js):", e.message); }   // home page names of members who chose to be listed
try { require("./plugins")({ app, express, limited, fail, okOrigin, env }); } catch (e) { console.warn("Plugins not loaded (upload plugins.js and the plugins folder next to site.js):", e.message); }   // tools the developer adds: run on the server, results shown in the app
const community = require("./community")({ app, db, limited, fail, guard, needUser, jsonBody, jsonErr, actorId, core, decMod, remoteMod, isStaffUid: staffUid, limits: quota.limits, SITE: SITE_URL, payments, robotsBait: honeypot.robots });
const UI = require("./ui");   // page, styles, logo and browser script, all JavaScript
app.use((req, res, next) => {
  if (req.method !== "GET" && req.method !== "HEAD") return next();
  const pagePath = req.path === "/" || req.path === "/search" || /^\/(?:upgrade|about|requests|changelog|tools|tools\/cfg|tools\/inject|repo|vault|dylib|certificates|ipabuild|studio|studio\/import|studio\/search)\/?$/.test(req.path) || /^\/studio\/(?:app|inject)\/[A-Za-z0-9][A-Za-z0-9._-]{0,154}\/?$/.test(req.path) || /^\/vault\/[A-Za-z0-9][A-Za-z0-9._-]{1,150}\/?$/.test(req.path) || /^\/app\/\d{5,12}(?:\/[^/]*)?\/?$/.test(req.path);   // results, app and info pages are the same single-page shell
  const a = pagePath ? UI["/"] : Object.prototype.hasOwnProperty.call(UI, req.path) ? UI[req.path] : null;
  if (!a) return next();
  let body = a.body, etag = a.etag;
  if (pagePath) { const h = community.headFor(req.path); if (h) { body = community.inject(a.body, h); etag = '"' + crypto.createHash("sha1").update(body).digest("hex").slice(0, 16) + '"'; } }   // title, description and link previews per page
  else if (!etag) etag = a.etag = '"' + crypto.createHash("sha1").update(a.body).digest("hex").slice(0, 16) + '"';
  res.set({ "Content-Type": a.type, "Cache-Control": "no-cache", ETag: etag });   // browsers re-check on every load, so updates show at once
  if (req.get("if-none-match") === etag) return res.status(304).end();
  return req.method === "HEAD" ? res.end() : res.send(body);
});
// Dylib Source (staff only): the parser is only sent to signed-in staff; everyone else gets the same 404 as any unknown page.
const DYLIBSRC_JS = (() => { try { return fs.readFileSync(path.join(__dirname, "dylibsrc-client.js"), "utf8") + "\n" + fs.readFileSync(path.join(__dirname, "dylibsrc-lift.js"), "utf8"); } catch { try { return fs.readFileSync(path.join(__dirname, "dylibsrc-client.js"), "utf8"); } catch { return ""; } } })();
app.get("/staff/dylibsrc.js", (req, res) => {
  res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow", "X-Content-Type-Options": "nosniff" });
  if (!DYLIBSRC_JS || !req.me || !staffUid("u" + req.me.id)) return res.status(404).type("text").send("Not found.");
  res.type("application/javascript; charset=utf-8").send(DYLIBSRC_JS);
});
// Dylib Source (Ghidra): upload a dylib/framework/zip, get headers, class implementations, C functions, Swift types and a build back. Staff only; everyone else gets the same 404 as any unknown page.
try {
  const dsMod = require("./lib/decomp"), dsPage = require("./lib/decomp/page");
  const dsStaff = (req) => !!(req.me && staffUid("u" + req.me.id));
  const dsGuard = (req, res, next) => {
    if (!dsStaff(req)) return res.status(404).type("text").send("Not found.");
    if (req.method !== "GET" && (!okOrigin(req) || req.get("x-dt") !== "1")) return res.status(403).json({ error: "Forbidden." });
    next();
  };
  dsMod.mount(app, { dataDir: DATA_DIR, express, requireStaff: dsGuard, resolveLibrary: () => null, listSet: () => [] });
  const dsServe = (route, type, body) => app.get(route, (req, res) => {
    res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow", "X-Content-Type-Options": "nosniff" });
    if (!dsStaff(req)) return res.status(404).type("text").send("Not found.");
    res.type(type).send(body);
  });
  dsServe("/staff/dylib-source", "text/html; charset=utf-8", dsPage.html);
  dsServe("/staff/dylib-source.css", "text/css; charset=utf-8", dsPage.css);
  dsServe("/staff/dylib-source.js", "application/javascript; charset=utf-8", dsPage.js);
} catch (e) { console.warn("Dylib Source (Ghidra) not loaded:", e.message); }
app.use("/dylib-shots", express.static(path.join(__dirname, "static", "dylib"), { maxAge: "1h", index: false, dotfiles: "ignore", fallthrough: true, setHeaders: (r) => r.set("X-Content-Type-Options", "nosniff") }));
app.use("/team-logos", express.static(path.join(__dirname, "static", "team"), { maxAge: "1d", index: false, dotfiles: "ignore", fallthrough: true, setHeaders: (r) => r.set("X-Content-Type-Options", "nosniff") }));   // the team logos shown in the footer: put aircore.png, decrypt-bot.png and delvek.png in server/static/team/
app.use((_req, res) => res.status(404).type("text").send("Not found."));
app.use((err, _req, res, _next) => { console.warn("Unhandled:", err && err.message); if (!res.headersSent) res.status(500).type("text").send("Something went wrong."); });

if (require.main === module) {
  const server = app.listen(PORT, HOST, () => console.log(`decrypt.team listening on http://${HOST}:${PORT} (data: ${DATA_DIR})`));   // one plain line: the big ANSI banner wrapped into blocks in narrow and phone terminals (it still goes out to scanners, where it belongs)
  server.requestTimeout = 0;      // IPA downloads can take a long time
  server.headersTimeout = 30000;
  const bye = () => { console.log("Shutting down"); server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 10000).unref(); };
  process.on("SIGINT", bye); process.on("SIGTERM", bye);
}
module.exports = { app, db, ipKey, core };
