'use strict';
// Decrawl = our own crawler + search index (crawl.decrypt.team). This is the one place the server talks to it.
// Never throws: when Decrawl is down or answers something unexpected, callers just get no extra context.
//   DECRAWL_URL          default https://crawl.decrypt.team
//   DECRAWL_SEARCH_PATH  default /api/search      (the route the Decrawl search page itself calls)
//   DECRAWL_QUERY_PARAM  default q
//   DECRAWL_KEY          optional, sent as  Authorization: Bearer <key>
//   DECRAWL_TIMEOUT_MS   default 5000
const env = process.env;
const BASE = () => String(env.DECRAWL_URL || 'https://crawl.decrypt.team').replace(/\/+$/, '');
const cache = new Map();   // query -> { at, v }
const TTL = 10 * 60 * 1000;

const text = (x, n) => String(x == null ? '' : x).replace(/\s+/g, ' ').trim().slice(0, n);
// Decrawl's reply shape isn't something this file controls, so read it loosely: any array of hits under a common key,
// each hit with some title / url / text, plus any list of confirmed facts.
function normalize(j) {
  const out = { results: [], facts: [], answer: '' };
  if (!j || typeof j !== 'object') return out;
  const arr = (...ks) => { for (const k of ks) if (Array.isArray(j[k])) return j[k]; return Array.isArray(j) ? j : []; };
  for (const h of arr('results', 'hits', 'items', 'pages', 'data').slice(0, 12)) {
    if (!h || typeof h !== 'object') { if (typeof h === 'string') out.results.push({ title: '', url: '', snippet: text(h, 400) }); continue; }
    out.results.push({ title: text(h.title || h.name || h.heading, 140), url: text(h.url || h.link || h.href, 240), snippet: text(h.snippet || h.summary || h.text || h.content || h.description || h.excerpt, 500) });
  }
  for (const f of (Array.isArray(j.facts) ? j.facts : Array.isArray(j.confirmed) ? j.confirmed : []).slice(0, 12)) {
    out.facts.push(text(typeof f === 'string' ? f : (f.text || f.fact || f.claim || JSON.stringify(f)), 300));
  }
  out.answer = text(j.answer || j.summary || '', 900);
  return out;
}

async function search(query, opts) {
  const q = text(query, 200); if (q.length < 3) return { ok: false, results: [], facts: [], answer: '' };
  const hit = cache.get(q); if (hit && Date.now() - hit.at < TTL) return hit.v;
  const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), Number(env.DECRAWL_TIMEOUT_MS) || 5000);
  try {
    const u = BASE() + (env.DECRAWL_SEARCH_PATH || '/api/search') + '?' + encodeURIComponent(env.DECRAWL_QUERY_PARAM || 'q') + '=' + encodeURIComponent(q) + '&limit=' + ((opts && opts.limit) || 8);
    const r = await fetch(u, { headers: Object.assign({ accept: 'application/json' }, env.DECRAWL_KEY ? { authorization: 'Bearer ' + env.DECRAWL_KEY } : {}), signal: ctl.signal });
    if (!r.ok) return { ok: false, results: [], facts: [], answer: '' };
    const v = Object.assign({ ok: true }, normalize(await r.json()));
    cache.set(q, { at: Date.now(), v }); if (cache.size > 300) cache.delete(cache.keys().next().value);
    return v;
  } catch { return { ok: false, results: [], facts: [], answer: '' }; }
  finally { clearTimeout(t); }
}

// Plain text for a model prompt.
function render(r, maxChars) {
  if (!r || !r.ok) return '';
  const L = [];
  if (r.answer) L.push(r.answer);
  for (const f of r.facts) L.push('- fact: ' + f);
  for (const h of r.results) L.push('- ' + [h.title, h.snippet].filter(Boolean).join(': ') + (h.url ? ' (' + h.url + ')' : ''));
  return L.join('\n').slice(0, maxChars || 3000);
}

// Looks up each query and returns one block, or '' when nothing useful came back.
async function context(queries, maxChars) {
  const qs = [...new Set((queries || []).map((x) => text(x, 120)).filter((x) => x.length >= 3))].slice(0, 3);
  const parts = [];
  for (const rs of await Promise.all(qs.map((q) => search(q, { limit: 5 })))) { const t = render(rs, 1400); if (t) parts.push(t); }
  const out = parts.join('\n').slice(0, maxChars || 3000);
  return out;
}

module.exports = { search, render, context, normalize };
