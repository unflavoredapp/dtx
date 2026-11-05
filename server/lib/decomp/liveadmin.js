'use strict';
// Staff API for Live Sync releases: everything live-admin.js does on the command line, plus a DRAFT step so Ai-Decrypt can
// propose a release, the person reviews the exact diff in the app, and one tap publishes it.
//
//   GET  /api/staff/live/state                       signing-key fingerprint + recent releases with adoption counts
//   POST /api/staff/live/draft    { changes, channel?, percent?, note? }   -> { config, base, baseRev, diff[], warnings[] }   (writes NOTHING)
//   POST /api/staff/live/publish  { changes, channel?, percent?, note?, baseRev }  -> { rev }   (re-derives the config itself)
//   POST /api/staff/live/releases/:rev/:action  { percent? }   action = rollout | pause | resume | rollback
//
// The caller never supplies a finished config: it supplies CHANGES, which are merged onto the newest release those people
// would get, then cleaned with the same rules the app applies (sizes, characters, shapes). The server is the only author
// of what gets signed. Releases go out on the beta channel unless a different one is asked for.
const path = require('path');

const fs = require('fs'), crypto = require('crypto');
let A = null;
try { A = require(path.join(__dirname, '..', '..', 'live.js')).admin; } catch (e) { A = null; }

const ident = (s, n = 60) => typeof s === 'string' && s.length > 0 && s.length <= n && /^[A-Za-z0-9_.\-]+$/.test(s);
const hexOk = (s) => typeof s === 'string' && /^#?[0-9a-fA-F]{6}$/.test(s.trim());
const normHex = (s) => '#' + s.trim().replace(/^#/, '').toUpperCase();
const uniq = (a) => [...new Set(a)];
const cut = (s, n) => String(s == null ? '' : s).slice(0, n);

// ---- screens: a tree of whitelisted building blocks, drawn natively by the app (no code, no remote images) ----
const NODE_TYPES = new Set(['text', 'image', 'button', 'stack', 'card', 'divider', 'spacer', 'list', 'kv', 'badge', 'toggle']);
const STYLES = new Set(['title', 'headline', 'body', 'caption', 'mono', 'primary', 'plain', 'glass']);
const COLORS = new Set(['accent', 'secondary', 'white', 'red', 'green', 'orange', 'yellow', 'blue']);
const ACTIONS = new Set(['open_url', 'open_screen', 'ask_ai', 'copy', 'sync', 'close']);
const symOk = (s) => typeof s === 'string' && s.length > 0 && s.length <= 60 && /^[A-Za-z0-9._]+$/.test(s);

function cleanAction(a, warn) {
  if (!a || typeof a !== 'object') return undefined;
  if (!ACTIONS.has(a.type)) { warn.push(`Action "${cut(a.type, 20)}" is not allowed and was dropped`); return undefined; }
  if (a.type === 'open_url') { if (typeof a.url === 'string' && /^https:\/\/\S{3,390}$/.test(a.url)) return { type: a.type, url: a.url }; warn.push('A button link must be https and was dropped'); return undefined; }
  if (a.type === 'open_screen') return ident(a.screen, 40) ? { type: a.type, screen: a.screen } : undefined;
  if (a.type === 'ask_ai' || a.type === 'copy') return typeof a.text === 'string' && a.text.trim() ? { type: a.type, text: cut(a.text.trim(), 600) } : undefined;
  return { type: a.type };
}
function cleanNode(n, depth, budget, warn) {
  if (!n || typeof n !== 'object' || depth > 6 || budget.n >= 150) return null;
  if (!NODE_TYPES.has(n.t)) { warn.push(`Element type "${cut(n.t, 20)}" is not available and was dropped`); return null; }
  budget.n++;
  const o = { t: n.t };
  if (typeof n.text === 'string') o.text = cut(n.text, 600);
  if (STYLES.has(n.style)) o.style = n.style;
  if (COLORS.has(n.color)) o.color = n.color;
  if (['left', 'center', 'right'].includes(n.align)) o.align = n.align;
  if (symOk(n.symbol)) o.symbol = n.symbol;
  if (typeof n.title === 'string') o.title = cut(n.title, 120);
  if (typeof n.subtitle === 'string') o.subtitle = cut(n.subtitle, 240);
  if (symOk(n.icon)) o.icon = n.icon;
  const act = cleanAction(n.action, warn); if (act) o.action = act;
  if (n.axis === 'h' || n.axis === 'v') o.axis = n.axis;
  if (Number.isFinite(Number(n.size))) o.size = Math.max(0, Math.min(120, Number(n.size)));
  if (ident(n.key, 40)) o.key = n.key;
  if (typeof n.on === 'boolean') o.on = n.on;
  if (Array.isArray(n.children)) o.children = n.children.slice(0, 40).map((c) => cleanNode(c, depth + 1, budget, warn)).filter(Boolean);
  if (Array.isArray(n.items)) o.items = n.items.slice(0, 30).filter((i) => i && typeof i.title === 'string' && i.title.trim()).map((i) => {
    const r = { title: cut(i.title, 120) }; if (typeof i.subtitle === 'string') r.subtitle = cut(i.subtitle, 240); if (symOk(i.icon)) r.icon = i.icon;
    const a = cleanAction(i.action, warn); if (a) r.action = a; return r; });
  if (Array.isArray(n.rows)) o.rows = n.rows.slice(0, 30).filter((r) => r && typeof r.k === 'string').map((r) => ({ k: cut(r.k, 80), v: cut(r.v, 240) }));
  return o;
}
function cleanScreen(s, warn) {
  if (!s || typeof s !== 'object' || !ident(s.id, 40) || typeof s.title !== 'string' || !s.title.trim()) { warn.push('A screen needs an id (letters, digits, - _) and a title and was dropped'); return null; }
  const budget = { n: 0 }, local = [];
  const body = (Array.isArray(s.body) ? s.body : []).slice(0, 40).map((n) => cleanNode(n, 0, budget, local)).filter(Boolean);
  for (const w of uniq(local).slice(0, 4)) warn.push(`Screen "${s.id}": ${w}`);
  if (!body.length) { warn.push(`Screen "${s.id}" had nothing to show and was dropped`); return null; }
  const show = (Array.isArray(s.show) ? s.show : ['sidebar']).filter((x) => x === 'sidebar' || x === 'home');
  return { id: s.id, title: cut(s.title.trim(), 60), icon: symOk(s.icon) ? s.icon : undefined, show: show.length ? uniq(show) : ['sidebar'], body };
}
// ---- recipes: on-device tools written as data (see Tools/Recipes.swift in the app) ----
const REC_OPS = new Set(['plist', 'text', 'glob', 'dirs']), REC_KINDS = new Set(['kv', 'list', 'table', 'text']);
const globOk = (g) => typeof g === 'string' && g.length > 0 && g.length <= 200 && !g.includes('..') && !g.startsWith('/') && /^[\w .\-*\/+@()]+$/.test(g);
const refsOf = (str) => { const r = []; String(str || '').replace(/\{([A-Za-z0-9_.\-]+)\}/g, (m, k) => { r.push(k); return m; }); return r; };

function cleanRecipe(r, warn) {
  if (!r || typeof r !== 'object') { warn.push('The recipe was empty'); return null; }
  if (typeof r.id !== 'string' || !/^[a-z0-9-]{2,40}$/.test(r.id)) { warn.push('A recipe id must be 2-40 lowercase letters, digits or dashes'); return null; }
  if (typeof r.name !== 'string' || !r.name.trim()) { warn.push('A recipe needs a name'); return null; }
  const o = { id: r.id, name: cut(r.name.trim(), 60), summary: cut(r.summary, 200), icon: symOk(r.icon) ? r.icon : 'doc.text.magnifyingglass', version: cut(r.version || '1.0', 16) };
  if (r.mode) warn.push('Recipes written by the AI never run automatically; "mode" was dropped');
  // Short tags (e.g. "dylib", "objc", "binary-analysis") so the app can pick tools by what they're FOR
  // instead of guessing from the name/summary. Free-form but capped: 1-6 tags, each 1-24 lowercase letters/digits/dashes.
  const capabilities = uniq((Array.isArray(r.capabilities) ? r.capabilities : [])
    .filter((c) => typeof c === 'string' && /^[a-z0-9-]{1,24}$/.test(c)).slice(0, 6));
  if (r.capabilities && !capabilities.length) warn.push('"capabilities" must be short lowercase tags (letters, digits, dashes) and was dropped');
  if (capabilities.length) o.capabilities = capabilities;
  const options = [];
  for (const x of (Array.isArray(r.options) ? r.options : []).slice(0, 8)) {
    if (!x || !/^[a-zA-Z]{1,24}$/.test(x.key || '')) { warn.push('An option key must be 1-24 letters and was dropped'); continue; }
    options.push({ key: x.key, label: cut(x.label || x.key, 60), type: ['bool', 'number'].includes(x.type) ? x.type : 'text', def: cut(x.def == null ? '' : x.def, 100) });
  }
  if (options.length) o.options = options;
  const names = new Set(), steps = [];
  for (const st of (Array.isArray(r.steps) ? r.steps : []).slice(0, 20)) {
    if (!st || !REC_OPS.has(st.op)) { warn.push(`Step type "${cut(st && st.op, 20)}" is not available and was dropped`); continue; }
    if (!ident(st.as, 20) || names.has(st.as)) { warn.push('A step needs a unique short name ("as") and was dropped'); continue; }
    const pat = st.op === 'plist' || st.op === 'text' ? st.file : st.match;
    if (!globOk(pat)) { warn.push(`Step "${st.as}": the file pattern is not allowed and the step was dropped`); continue; }
    const n = { op: st.op, as: st.as }; if (st.op === 'plist' || st.op === 'text') n.file = pat; else n.match = pat;
    if (st.optional === true) n.optional = true;
    names.add(st.as); steps.push(n);
  }
  const optKeys = new Set(options.map((x) => x.key));
  const known = (k) => { const h = k.split('.')[0]; return h === 'n' || (h === 'opt' && optKeys.has(k.split('.')[1])) || names.has(h); };
  const output = [];
  for (const ou of (Array.isArray(r.output) ? r.output : []).slice(0, 30)) {
    if (!ou || !REC_KINDS.has(ou.kind || 'text')) { warn.push('An output section had an unknown kind and was dropped'); continue; }
    const c = { kind: ou.kind || 'text' }; if (typeof ou.title === 'string') c.title = cut(ou.title, 120);
    if (Array.isArray(ou.rows)) c.rows = ou.rows.slice(0, 200).filter(Array.isArray).map((row) => row.slice(0, 4).map((v) => cut(v, 300)));
    for (const k of ['from', 'prefix', 'suffix', 'strip', 'filter']) if (typeof ou[k] === 'string') c[k] = cut(ou[k], k === 'from' ? 80 : 60);
    if (typeof ou.text === 'string') c.text = cut(ou.text, 4000);
    if (ou.basename === true) c.basename = true;
    if (Number.isFinite(Number(ou.limit))) c.limit = Math.max(1, Math.min(5000, Number(ou.limit)));
    const refs = [...refsOf(c.title), ...refsOf(c.text), ...refsOf(c.filter), ...(c.rows || []).flat().flatMap(refsOf)];
    if (c.from && !names.has(c.from.split('.')[0])) { warn.push(`Section "${c.title || c.kind}" reads "${c.from}", which no step produces; it was dropped`); continue; }
    const bad = refs.find((k) => !known(k));
    if (bad) { warn.push(`Section "${c.title || c.kind}" uses {${bad}}, which no step or option provides; it was dropped`); continue; }
    output.push(c);
  }
  if (!steps.length) { warn.push('The recipe has no valid steps'); return null; }
  if (!output.length) { warn.push('The recipe has no valid output sections'); return null; }
  o.steps = steps; o.output = output;
  return o;
}

const countNodes = (nodes) => (nodes || []).reduce((n, x) => n + 1 + countNodes(x.children), 0);

/** the app's own sanitizer, mirrored: anything odd is dropped (and reported), never repaired */
function clean(c, warn) {
  c = c && typeof c === 'object' ? c : {};
  const out = {};
  const bools = (o, max, keyLen, what) => {
    const r = {};
    for (const [k, v] of Object.entries(o && typeof o === 'object' ? o : {}).slice(0, max)) {
      if (ident(k, keyLen) && typeof v === 'boolean') r[k] = v; else warn.push(`${what} "${cut(k, 30)}" was dropped`);
    }
    return r;
  };
  const f = bools(c.flags, 50, 40, 'Flag'); if (Object.keys(f).length) out.flags = f;
  const a = bools(c.auto, 100, 60, 'Auto-run setting'); if (Object.keys(a).length) out.auto = a;
  if (c.theme && c.theme.accent !== undefined) { if (hexOk(c.theme.accent)) out.theme = { accent: normHex(c.theme.accent) }; else warn.push('The accent colour was not a 6-digit hex and was dropped'); }
  for (const k of ['hide', 'order']) {
    if (!Array.isArray(c[k])) continue;
    const ok = uniq(c[k].filter((x) => ident(x))).slice(0, 100);
    if (ok.length !== c[k].length) warn.push(`Some "${k}" entries were not valid tool ids and were dropped`);
    if (ok.length) out[k] = ok;
  }
  if (c.banner && typeof c.banner === 'object') {
    const b = c.banner;
    if (ident(b.id, 40) && typeof b.title === 'string' && b.title.trim()) {
      const url = typeof b.url === 'string' && /^https:\/\/\S{3,390}$/.test(b.url) ? b.url : '';
      if (b.url && !url) warn.push('The banner link must be https and was dropped');
      out.banner = { id: b.id, title: cut(b.title.trim(), 80), text: cut(b.text, 400), url };
    } else warn.push('The banner needs a title and was dropped');
  }
  if (Array.isArray(c.experimental)) {
    const e = c.experimental.filter((x) => x && ident(x.id, 40) && typeof x.title === 'string' && x.title.trim()).slice(0, 10)
      .map((x) => ({ id: x.id, title: cut(x.title.trim(), 80), detail: cut(x.detail, 200) }));
    if (e.length !== c.experimental.length) warn.push('Some experimental switches were invalid and were dropped');
    if (e.length) out.experimental = e;
  }
  if (Array.isArray(c.screens)) {
    const seen = new Set(), list = [];
    for (const sc of c.screens.slice(0, 12)) { const k = cleanScreen(sc, warn); if (k && !seen.has(k.id)) { seen.add(k.id); list.push(k); } }
    if (list.length) out.screens = list;
  }
  return out;
}

/** merge a set of changes onto the base config (the base is never edited in place) */
function merge(base, ch) {
  const c = JSON.parse(JSON.stringify(base || {}));
  ch = ch && typeof ch === 'object' ? ch : {};
  if (ch.accent !== undefined) { if (ch.accent === null || ch.accent === '' || ch.accent === 'default') delete c.theme; else c.theme = { accent: ch.accent }; }
  const mergeMap = (key, src) => {
    if (!src || typeof src !== 'object') return;
    const m = Object.assign({}, c[key]);
    for (const [k, v] of Object.entries(src)) { if (v === null) delete m[k]; else m[k] = v; }
    c[key] = m;
  };
  mergeMap('flags', ch.flags); mergeMap('auto', ch.auto);
  if (Array.isArray(ch.hide)) c.hide = uniq([...(c.hide || []), ...ch.hide]);
  if (Array.isArray(ch.show)) c.hide = (c.hide || []).filter((x) => !ch.show.includes(x));
  if (Array.isArray(ch.order)) c.order = ch.order;
  if (ch.clearBanner) delete c.banner;
  if (ch.banner && typeof ch.banner === 'object') c.banner = Object.assign({ id: 'b-' + Date.now().toString(36) }, ch.banner);
  if (Array.isArray(ch.experimental)) c.experimental = ch.experimental;
  if (Array.isArray(ch.removeScreens)) c.screens = (c.screens || []).filter((x) => !ch.removeScreens.includes(x.id));
  if (Array.isArray(ch.screens)) {
    const list = (c.screens || []).slice();
    for (const sc of ch.screens) { if (!sc || typeof sc !== 'object') continue; const i = list.findIndex((x) => x.id === sc.id); if (i >= 0) list[i] = sc; else list.push(sc); }
    c.screens = list;
  }
  return c;
}

const show = (v) => (v === undefined ? 'unset' : typeof v === 'string' ? v : JSON.stringify(v));
/** readable one-liners: what this release changes compared with what people have now */
function diff(a, b) {
  a = a || {}; b = b || {}; const out = [];
  const sa = (a.theme && a.theme.accent) || null, sb = (b.theme && b.theme.accent) || null;
  if (sa !== sb) out.push({ kind: 'accent', text: `Accent colour: ${sa || 'app default'} → ${sb || 'app default'}` });
  for (const key of ['flags', 'auto']) {
    const x = a[key] || {}, y = b[key] || {};
    for (const k of uniq([...Object.keys(x), ...Object.keys(y)])) if (x[k] !== y[k]) out.push({ kind: key, text: `${key === 'flags' ? 'Flag' : 'Auto-run'} ${k}: ${show(x[k])} → ${show(y[k])}` });
  }
  const ha = a.hide || [], hb = b.hide || [];
  for (const t of hb.filter((x) => !ha.includes(x))) out.push({ kind: 'hide', text: `Hide tool: ${t}` });
  for (const t of ha.filter((x) => !hb.includes(x))) out.push({ kind: 'hide', text: `Show tool again: ${t}` });
  if (JSON.stringify(a.order || []) !== JSON.stringify(b.order || [])) out.push({ kind: 'order', text: `Tool order: ${(b.order || []).join(', ') || 'default'}` });
  const ba = a.banner, bb = b.banner;
  if (JSON.stringify(ba || null) !== JSON.stringify(bb || null)) out.push({ kind: 'banner', text: bb ? `Banner: "${bb.title}"${bb.text ? ' — ' + cut(bb.text, 80) : ''}` : 'Banner removed' });
  if (JSON.stringify(a.experimental || []) !== JSON.stringify(b.experimental || [])) out.push({ kind: 'experimental', text: `Experimental switches: ${(b.experimental || []).map((e) => e.title).join(', ') || 'none'}` });
  const scA = a.screens || [], scB = b.screens || [];
  for (const x of scB) {
    const o = scA.find((y) => y.id === x.id);
    if (!o) out.push({ kind: 'screen', text: `Add screen "${x.title}" (${countNodes(x.body)} elements, ${(x.show || []).join(' + ')})` });
    else if (JSON.stringify(o) !== JSON.stringify(x)) out.push({ kind: 'screen', text: `Update screen "${x.title}" (${countNodes(x.body)} elements)` });
  }
  for (const o of scA) if (!scB.find((y) => y.id === o.id)) out.push({ kind: 'screen', text: `Remove screen "${o.title}"` });
  return out;
}

module.exports = function mount({ app, express, guard, audit }) {
  if (!A) { console.warn('[decomp] live admin not mounted: live.js was not found next to site.js'); return false; }
  const B = '/api/staff/live';
  const jsonBody = express.json({ limit: '24kb' });
  const noStore = (res) => res.set({ 'Cache-Control': 'no-store' });
  const idx = (c) => A.CHANNELS.indexOf(c);

  /** the release the people on `channel` get right now (newest live one they are allowed to see) */
  function baseFor(channel) {
    const live = A.readJSON(A.F.rel, []).filter((r) => r.state === 'live' && idx(channel) >= idx(r.channel || 'stable')).sort((a, b) => b.rev - a.rev);
    return live[0] || null;
  }
  function plan(b) {
    b = b || {};
    const channel = A.CHANNELS.includes(b.channel) ? b.channel : 'beta';
    const percent = Math.max(0, Math.min(100, Number.isFinite(Number(b.percent)) ? Number(b.percent) : 100));
    const base = baseFor(channel), warnings = [];
    const baseCfg = (base && base.config) || {};
    const merged = merge(baseCfg, b.changes);
    const config = clean(merged, warnings);
    const cleanBase = clean(baseCfg, []);
    return { channel, percent, base: base ? base.rev : 0, baseCfg: cleanBase, config, diff: diff(cleanBase, config), warnings: uniq(warnings).slice(0, 10), note: cut(b.note, 120) };
  }

  app.get(`${B}/state`, guard, (req, res) => {
    noStore(res);
    const rels = A.readJSON(A.F.rel, []), rep = A.readJSON(A.F.rep, {}), k = A.keys();
    res.json({ ok: true, fingerprint: A.fingerprint(k.pub), releases: rels.slice().sort((a, b) => b.rev - a.rev).slice(0, 25).map((r) => {
      const e = rep[r.rev] || { applied: {}, failed: {} };
      return { rev: r.rev, at: r.at, note: r.note || '', channel: r.channel, percent: r.percent, state: r.state, applied: Object.keys(e.applied).length, failed: Object.keys(e.failed).length };
    }) });
  });

  app.post(`${B}/draft`, guard, jsonBody, (req, res) => {
    noStore(res);
    const p = plan(req.body);
    if (!p.diff.length) return res.status(422).json({ ok: false, error: 'That would not change anything compared with what people have now.', warnings: p.warnings });
    const before = new Map(((p.baseCfg && p.baseCfg.screens) || []).map((x) => [x.id, JSON.stringify(x)]));
    const changed = ((p.config && p.config.screens) || []).filter((x) => before.get(x.id) !== JSON.stringify(x));
    res.json({ ok: true, channel: p.channel, percent: p.percent, baseRev: p.base, config: p.config, diff: p.diff, warnings: p.warnings, screens: changed });
  });

  app.post(`${B}/publish`, guard, jsonBody, (req, res) => {
    noStore(res);
    const b = req.body || {}, p = plan(b);
    if (Number(b.baseRev) !== p.base) return res.status(409).json({ ok: false, error: `A newer release (#${p.base}) landed since this draft. Ask for the change again so you review the real diff.` });
    if (!p.diff.length) return res.status(422).json({ ok: false, error: 'That would not change anything.' });
    if (!p.note) return res.status(400).json({ ok: false, error: 'A release needs a short note (it shows in the app\'s update history).' });
    const rels = A.readJSON(A.F.rel, []);
    const rev = rels.reduce((m, r) => Math.max(m, r.rev), 0) + 1;
    rels.push({ rev, at: new Date().toISOString(), note: p.note, channel: p.channel, percent: p.percent, state: 'live', minApp: 0, config: p.config, native: null });
    A.writeJSON(A.F.rel, rels);
    try { audit(req, 'live-publish', `#${rev}`, `${p.channel} ${p.percent}% — ${p.note} — ${p.diff.map((d) => d.text).join('; ').slice(0, 300)}`); } catch {}
    res.json({ ok: true, rev, channel: p.channel, percent: p.percent });
  });

  app.post(`${B}/releases/:rev/:action`, guard, jsonBody, (req, res) => {
    noStore(res);
    const rels = A.readJSON(A.F.rel, []), r = rels.find((x) => x.rev === Number(req.params.rev));
    if (!r) return res.status(404).json({ ok: false, error: 'No such release.' });
    const act = String(req.params.action);
    if (act === 'rollout') r.percent = Math.max(0, Math.min(100, Number((req.body || {}).percent) || 0));
    else if (act === 'pause') r.state = 'paused';
    else if (act === 'resume') r.state = 'live';
    else if (act === 'rollback') r.state = 'rolledback';
    else return res.status(400).json({ ok: false, error: 'Unknown action.' });
    A.writeJSON(A.F.rel, rels);
    try { audit(req, 'live-' + act, `#${r.rev}`, act === 'rollout' ? r.percent + '%' : ''); } catch {}
    res.json({ ok: true, rev: r.rev, state: r.state, percent: r.percent });
  });

  // ---------------- recipes (on-device tools as data) ----------------
  const RDIR = process.env.RECIPES_DIR || path.join(__dirname, '..', '..', 'plugins', 'recipes');
  const rFile = (id) => path.join(RDIR, id + '.json'), HIST = path.join(RDIR, '.history');
  const rawOf = (id) => { try { return fs.readFileSync(rFile(id), 'utf8'); } catch { return ''; } };
  const sha = (t) => crypto.createHash('sha1').update(String(t)).digest('hex').slice(0, 10);
  const stamp = () => new Date().toISOString().replace(/[:.]/g, '-');

  function recipeDraft(body) {
    const warnings = [], rec = cleanRecipe(body && body.recipe, warnings);
    if (!rec) return { error: warnings[0] || 'That recipe is not valid.', warnings };
    const old = rawOf(rec.id); let oldV = null; try { oldV = old ? JSON.parse(old).version || '1.0' : null; } catch {}
    const lines = [`${rec.steps.length} step(s): ${rec.steps.map((x) => x.op + ' ' + (x.file || x.match)).join(', ').slice(0, 200)}`, `${rec.output.length} output section(s): ${rec.output.map((x) => x.kind + (x.title ? ' "' + x.title + '"' : '')).join(', ').slice(0, 200)}`];
    if (rec.capabilities && rec.capabilities.length) lines.push(`Capabilities: ${rec.capabilities.join(', ')}`);
    return { recipe: rec, warnings: uniq(warnings).slice(0, 10), exists: !!old, existingVersion: oldV, hash: old ? sha(old) : '', lines };
  }
  app.post(`${B}/recipes/draft`, guard, express.json({ limit: '48kb' }), (req, res) => {
    noStore(res);
    const d = recipeDraft(req.body);
    if (d.error) return res.status(422).json({ ok: false, error: d.error, warnings: d.warnings });
    res.json(Object.assign({ ok: true }, d));
  });
  app.post(`${B}/recipes/publish`, guard, express.json({ limit: '48kb' }), (req, res) => {
    noStore(res);
    const d = recipeDraft(req.body);
    if (d.error) return res.status(422).json({ ok: false, error: d.error });
    if (String((req.body || {}).hash || '') !== d.hash) return res.status(409).json({ ok: false, error: 'This recipe changed on the server since the draft. Ask again so you review the current version.' });
    try {
      fs.mkdirSync(HIST, { recursive: true });
      const old = rawOf(d.recipe.id);
      if (old) {
        fs.writeFileSync(path.join(HIST, `${d.recipe.id}.${stamp()}.json`), old);
        const mine = fs.readdirSync(HIST).filter((f) => f.startsWith(d.recipe.id + '.')).sort();
        for (const f of mine.slice(0, Math.max(0, mine.length - 8))) { try { fs.unlinkSync(path.join(HIST, f)); } catch {} }
      }
      const tmp = rFile(d.recipe.id) + '.tmp'; fs.writeFileSync(tmp, JSON.stringify(d.recipe, null, 2)); fs.renameSync(tmp, rFile(d.recipe.id));
    } catch (e) { return res.status(500).json({ ok: false, error: 'Could not write the recipe: ' + e.message }); }
    try { audit(req, 'recipe-publish', d.recipe.id, `${d.exists ? 'update' : 'new'} — ${d.recipe.name}`); } catch {}
    res.json({ ok: true, id: d.recipe.id, replaced: d.exists });
  });
  // withdraw: put the previous version back if there was one, else take the recipe down. Nothing is ever deleted outright.
  app.post(`${B}/recipes/:id/withdraw`, guard, express.json({ limit: '2kb' }), (req, res) => {
    noStore(res);
    const id = String(req.params.id); if (!/^[a-z0-9-]{2,40}$/.test(id)) return res.status(400).json({ ok: false, error: 'Bad id.' });
    if (!rawOf(id)) return res.status(404).json({ ok: false, error: 'That recipe is not published.' });
    try {
      fs.mkdirSync(HIST, { recursive: true });
      fs.writeFileSync(path.join(HIST, `${id}.${stamp()}.withdrawn.json`), rawOf(id));
      const prev = (req.body && req.body.restore) ? fs.readdirSync(HIST).filter((f) => f.startsWith(id + '.') && !f.endsWith('.withdrawn.json')).sort().pop() : null;
      if (prev) fs.writeFileSync(rFile(id), fs.readFileSync(path.join(HIST, prev))); else fs.unlinkSync(rFile(id));
      try { audit(req, 'recipe-withdraw', id, prev ? 'restored ' + prev : 'removed'); } catch {}
      res.json({ ok: true, restored: !!prev });
    } catch (e) { res.status(500).json({ ok: false, error: e.message }); }
  });
  return true;
};
module.exports._test = { clean, merge, diff };
