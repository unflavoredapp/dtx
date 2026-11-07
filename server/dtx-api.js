'use strict';
/**
 * dtx-api.js — DTX wallet, per-use charging, app view/download counters and the Hub endpoint.
 * Drop into /opt/dct/server/ and mount it (see the bottom of this file).
 *
 * It needs better-sqlite3 (a shared handle is passed in) and an adapter that maps YOUR login
 * to a user. If you already keep a DTX balance, pass `wallet` to use it; otherwise the module
 * keeps its own ledger table (dtx_ledger) and the balance is the sum of it.
 *
 *   const dtx = require('./dtx-api')({
 *     db,                                   // better-sqlite3 handle
 *     getUser: req => req.user && {         // null for guests
 *       id, username, photoUrl, role, premium, certificate: { active, expires }, address },
 *     grantCertificate: (userId) => {},     // used by the scratch card's rare prize
 *     aiUpstream: 'http://127.0.0.1:8081',  // llama-server (vision/worker ports below)
 *     upstreams: { v1: 'http://127.0.0.1:8081', v1vision: 'http://127.0.0.1:8082', v1worker: 'http://127.0.0.1:8083' },
 *   });
 *   app.use('/api/dtx', dtx.router(express));
 *   app.post('/api/build', dtx.guard('decrypt'), yourBuildHandler);   // charge per use, refund on failure
 */
const crypto = require('crypto');

const DEFAULT_PRICES = {            // DTX per use — edit freely
  ai_message: 1,
  ai_vision: 2,
  decrypt: 5,
  inject: 3,
  dylib_studio: 4,
};
const LABELS = {
  ai_message: 'AI message', ai_vision: 'AI image message', decrypt: 'Decrypt',
  inject: 'Inject', dylib_studio: 'Dylib Studio', scratch: 'Scratch card', refund: 'Refund',
  bonus: 'Bonus', topup: 'Top up', premium: 'Premium', certificate: 'Certificate',
};
const SCRATCH = [                    // weight, DTX (0 + cert for the rare prize)
  { w: 700, dtx: 1 }, { w: 200, dtx: 5 }, { w: 80, dtx: 10 },
  { w: 16, dtx: 25 }, { w: 3, dtx: 100 }, { w: 1, dtx: 0, cert: true },
];

module.exports = function createDtx(opts) {
  const { db, getUser } = opts;
  if (!db || !getUser) throw new Error('dtx-api: db and getUser are required');
  const prices = Object.assign({}, DEFAULT_PRICES, opts.prices || {});
  const welcomeBonus = opts.welcomeBonus || 0;
  const upstreams = Object.assign({
    v1: 'http://127.0.0.1:8081', v1vision: 'http://127.0.0.1:8082', v1worker: 'http://127.0.0.1:8083',
  }, opts.upstreams || {});

  db.exec(`
    CREATE TABLE IF NOT EXISTS dtx_ledger (
      id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, delta INTEGER NOT NULL,
      kind TEXT NOT NULL, ref TEXT, at INTEGER NOT NULL);
    CREATE UNIQUE INDEX IF NOT EXISTS dtx_ledger_ref ON dtx_ledger(user_id, kind, ref) WHERE ref IS NOT NULL;
    CREATE INDEX IF NOT EXISTS dtx_ledger_user ON dtx_ledger(user_id, at);
    CREATE TABLE IF NOT EXISTS dtx_app_stats (
      app_id TEXT PRIMARY KEY, views INTEGER NOT NULL DEFAULT 0, downloads INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS dtx_seen (
      app_id TEXT NOT NULL, who TEXT NOT NULL, kind TEXT NOT NULL, day TEXT NOT NULL,
      PRIMARY KEY (app_id, who, kind, day));
    CREATE TABLE IF NOT EXISTS dtx_scratch (user_id TEXT NOT NULL, day TEXT NOT NULL, prize TEXT, PRIMARY KEY (user_id, day));
    CREATE TABLE IF NOT EXISTS dtx_welcome (user_id TEXT PRIMARY KEY);
  `);

  const day = () => new Date().toISOString().slice(0, 10);
  const dayStart = () => { const d = new Date(); d.setUTCHours(0, 0, 0, 0); return d.getTime(); };

  // ---- wallet (own ledger unless an adapter is supplied) -------------------------------------
  const q = {
    bal: db.prepare('SELECT COALESCE(SUM(delta),0) AS b FROM dtx_ledger WHERE user_id=?'),
    add: db.prepare('INSERT INTO dtx_ledger(user_id,delta,kind,ref,at) VALUES (?,?,?,?,?)'),
    hist: db.prepare('SELECT id,delta,kind,at FROM dtx_ledger WHERE user_id=? ORDER BY id DESC LIMIT ?'),
    spentToday: db.prepare("SELECT kind, COUNT(*) AS n, COALESCE(-SUM(delta),0) AS dtx FROM dtx_ledger WHERE user_id=? AND delta<0 AND at>=? GROUP BY kind"),
    byId: db.prepare('SELECT * FROM dtx_ledger WHERE id=? AND user_id=?'),
    refunded: db.prepare("SELECT 1 FROM dtx_ledger WHERE user_id=? AND kind='refund' AND ref=?"),
  };
  const wallet = opts.wallet || {
    balance: (uid) => q.bal.get(String(uid)).b,
  };
  const balance = (uid) => wallet.balance(String(uid));

  // Atomic: the balance check and the debit happen in one transaction, so two parallel
  // requests can never spend the same coins.
  const spend = db.transaction((uid, cost, kind, ref) => {
    uid = String(uid);
    if (balance(uid) < cost) return { ok: false };
    const r = q.add.run(uid, -cost, kind, ref || null, Date.now());
    return { ok: true, id: Number(r.lastInsertRowid) };
  });
  const credit = (uid, amount, kind, ref) => {
    try { q.add.run(String(uid), amount, kind, ref || null, Date.now()); return true; }
    catch (e) { return false; }                // unique(ref) → already applied
  };
  const refund = db.transaction((uid, ledgerId) => {
    uid = String(uid);
    const row = q.byId.get(ledgerId, uid);
    if (!row || row.delta >= 0 || q.refunded.get(uid, String(ledgerId))) return false;
    q.add.run(uid, -row.delta, 'refund', String(ledgerId), Date.now());
    return true;
  });

  function maybeWelcome(uid) {
    if (!welcomeBonus) return;
    const r = db.prepare('INSERT OR IGNORE INTO dtx_welcome(user_id) VALUES (?)').run(String(uid));
    if (r.changes) credit(uid, welcomeBonus, 'bonus', 'welcome');
  }

  // ---- abuse limits ---------------------------------------------------------------------------
  const buckets = new Map();                   // key -> {n, t}
  function rate(key, max, windowMs) {
    const now = Date.now(); let b = buckets.get(key);
    if (!b || now - b.t > windowMs) b = { n: 0, t: now };
    b.n++; buckets.set(key, b);
    return b.n <= max;
  }
  setInterval(() => { const cut = Date.now() - 3600e3; for (const [k, v] of buckets) if (v.t < cut) buckets.delete(k); }, 600e3).unref();
  const inflight = new Map();                  // user -> running AI streams
  const MAX_INFLIGHT = 2;

  const clientIp = (req) => (req.headers['cf-connecting-ip'] || req.ip || '').toString();
  const money = (n) => Math.round(n);

  function deny(res, status, error, extra) {
    res.status(status).json(Object.assign({ error }, extra || {}));
  }

  // Charge-per-use middleware. Debits before the handler runs; if the handler ends with a
  // 4xx/5xx or the connection drops early, the charge is refunded automatically.
  function guard(kind, costOverride) {
    return (req, res, next) => {
      const user = getUser(req);
      if (!user) return deny(res, 401, 'Sign in with Telegram to use DTX tools.');
      const cost = costOverride != null ? costOverride : prices[kind];
      if (cost == null) return deny(res, 500, 'Unknown price for ' + kind);
      if (!rate('u:' + user.id + ':' + kind, 30, 60e3)) return deny(res, 429, 'Slow down a little and try again.');
      const s = spend(user.id, cost, kind, null);
      if (!s.ok) return deny(res, 402, 'Not enough DTX — this costs ' + cost + ' DTX.', { need: cost, balance: balance(user.id) });
      let done = false;
      const settle = () => {
        if (done) return; done = true;
        if (res.statusCode >= 400 || !res.writableEnded) refund(user.id, s.id);
      };
      res.on('finish', settle); res.on('close', settle);
      res.setHeader('x-dtx-charged', String(cost));
      res.locals.dtxLedgerId = s.id;
      req.dtxUser = user;
      next();
    };
  }

  // ---- router ---------------------------------------------------------------------------------
  function router(express) {
    const r = express.Router();
    r.use(express.json({ limit: '64kb' }));

    // Everything the Hub screen shows, in one round trip.
    r.get('/hub', (req, res) => {
      const user = getUser(req);
      const top = db.prepare('SELECT app_id,views,downloads FROM dtx_app_stats ORDER BY downloads DESC, views DESC LIMIT 10').all();
      const base = { prices, topApps: top.map(t => ({ id: t.app_id, views: t.views, downloads: t.downloads })) };
      if (!user) return res.json(Object.assign(base, { signedIn: false }));
      maybeWelcome(user.id);
      const used = {};
      for (const row of q.spentToday.all(String(user.id), dayStart())) used[row.kind] = { count: row.n, dtx: row.dtx };
      const sc = db.prepare('SELECT prize FROM dtx_scratch WHERE user_id=? AND day=?').get(String(user.id), day());
      res.json(Object.assign(base, {
        signedIn: true,
        user: { username: user.username, photoUrl: user.photoUrl || null, role: user.role || 'member', premium: !!user.premium, address: user.address || null },
        certificate: user.certificate || { active: false },
        balance: balance(user.id),
        usageToday: used,
        spentToday: Object.values(used).reduce((a, b) => a + b.dtx, 0),
        scratch: { available: !sc, prize: sc ? sc.prize : null },
        history: q.hist.all(String(user.id), 20).map(h => ({ id: h.id, delta: h.delta, label: LABELS[h.kind] || h.kind, at: h.at })),
      }));
    });

    r.get('/history', (req, res) => {
      const user = getUser(req); if (!user) return deny(res, 401, 'Sign in first.');
      const n = Math.min(100, Math.max(1, parseInt(req.query.limit, 10) || 50));
      res.json({ history: q.hist.all(String(user.id), n).map(h => ({ id: h.id, delta: h.delta, label: LABELS[h.kind] || h.kind, at: h.at })) });
    });

    // View / download counters. One count per person (or IP for guests) per app per day,
    // so a script can't inflate the numbers.
    r.post('/track', (req, res) => {
      const { app, kind } = req.body || {};
      if (typeof app !== 'string' || !app || app.length > 200 || !['view', 'download'].includes(kind)) return deny(res, 400, 'Bad request.');
      const user = getUser(req);
      const who = user ? 'u' + user.id : 'ip' + crypto.createHash('sha1').update(clientIp(req)).digest('hex').slice(0, 16);
      if (!rate('t:' + who, 120, 60e3)) return deny(res, 429, 'Too many requests.');
      const ins = db.prepare('INSERT OR IGNORE INTO dtx_seen(app_id,who,kind,day) VALUES (?,?,?,?)').run(app, who, kind, day());
      if (ins.changes) {
        db.prepare('INSERT OR IGNORE INTO dtx_app_stats(app_id) VALUES (?)').run(app);
        db.prepare(`UPDATE dtx_app_stats SET ${kind === 'view' ? 'views' : 'downloads'} = ${kind === 'view' ? 'views' : 'downloads'} + 1 WHERE app_id=?`).run(app);
      }
      res.json({ ok: true });
    });

    r.get('/stats', (req, res) => {
      const ids = String(req.query.ids || '').split(',').map(s => s.trim()).filter(Boolean).slice(0, 200);
      const out = {};
      const st = db.prepare('SELECT views,downloads FROM dtx_app_stats WHERE app_id=?');
      for (const id of ids) { const row = st.get(id); out[id] = row || { views: 0, downloads: 0 }; }
      res.json({ stats: out });
    });

    // Daily scratch card — the prize is drawn on the server, once per user per UTC day.
    r.post('/scratch', (req, res) => {
      const user = getUser(req); if (!user) return deny(res, 401, 'Sign in first.');
      const uid = String(user.id);
      const take = db.transaction(() => {
        if (db.prepare('SELECT 1 FROM dtx_scratch WHERE user_id=? AND day=?').get(uid, day())) return null;
        const total = SCRATCH.reduce((a, p) => a + p.w, 0);
        let roll = crypto.randomInt(total), pick = SCRATCH[0];
        for (const p of SCRATCH) { if (roll < p.w) { pick = p; break; } roll -= p.w; }
        db.prepare('INSERT INTO dtx_scratch(user_id,day,prize) VALUES (?,?,?)').run(uid, day(), pick.cert ? 'Certificate' : pick.dtx + ' DTX');
        if (pick.dtx) credit(uid, pick.dtx, 'scratch', day());
        return pick;
      });
      const pick = take();
      if (!pick) return deny(res, 409, 'You already scratched today. Come back tomorrow.');
      if (pick.cert && opts.grantCertificate) { try { opts.grantCertificate(user.id); } catch (e) { /* logged by caller */ } }
      res.json({ prize: pick.cert ? 'Certificate' : pick.dtx + ' DTX', dtx: pick.dtx, certificate: !!pick.cert, balance: balance(user.id) });
    });

    // AI gateway: /api/dtx/ai/<v1|v1vision|v1worker>/chat/completions. Signed-in people only, one
    // charge per request, refunded only if the model server fails before sending anything (cancelling mid-reply still costs). The worker path (background chores) is free
    // but still rate limited.
    r.post('/ai/:model/chat/completions', async (req, res) => {
      const base = upstreams[req.params.model];
      if (!base) return deny(res, 404, 'Unknown model.');
      const user = getUser(req); if (!user) return deny(res, 401, 'Sign in with Telegram to chat — AI messages cost DTX.');
      if (!rate('ai:' + user.id, 40, 60e3)) return deny(res, 429, 'Slow down a little and try again.');
      if ((inflight.get(user.id) || 0) >= MAX_INFLIGHT) return deny(res, 429, 'Two replies are already running. Wait for one to finish.');
      const body = req.body || {};
      if (JSON.stringify(body).length > 24e6) return deny(res, 413, 'That message is too large.');
      const kind = req.params.model === 'v1vision' ? 'ai_vision' : req.params.model === 'v1' ? 'ai_message' : null;
      let ledgerId = null;
      if (kind) {
        const s = spend(user.id, prices[kind], kind, null);
        if (!s.ok) return deny(res, 402, 'Not enough DTX — this costs ' + prices[kind] + ' DTX.', { need: prices[kind], balance: balance(user.id) });
        ledgerId = s.id; res.setHeader('x-dtx-charged', String(prices[kind]));
      }
      inflight.set(user.id, (inflight.get(user.id) || 0) + 1);
      const ctl = new AbortController();
      res.on('close', () => ctl.abort());
      let ok = false, sent = false;
      try {
        const up = await fetch(base + '/v1/chat/completions', {
          method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body), signal: ctl.signal,
        });
        res.status(up.status);
        res.setHeader('content-type', up.headers.get('content-type') || 'application/json');
        res.setHeader('cache-control', 'no-store');
        res.flushHeaders();
        if (up.body) for await (const chunk of up.body) { sent = true; res.write(chunk); }
        ok = up.ok;
        res.end();
      } catch (e) {
        if (!res.headersSent) deny(res, 502, 'The model server is not answering.'); else res.end();
      } finally {
        inflight.set(user.id, Math.max(0, (inflight.get(user.id) || 1) - 1));
        if (ledgerId && !ok && !sent) refund(user.id, ledgerId);
      }
    });

    return r;
  }

  return { router, guard, spend, credit, refund, balance, prices };
};
