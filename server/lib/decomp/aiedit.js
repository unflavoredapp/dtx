'use strict';
// Ai-Decrypt editing for recovered decomp jobs: ask about a function / file / build error, get back a REVIEWABLE patch.
//
//   require('./aiedit')({ app, express, B, guard, findPart, outRoot, audit, saveFile, env })
//
// Same rules as Reconstruct Studio's Optimize assistant (reconstruct-optimize.js), applied to /api/staff/decomp jobs:
//   * A reply never says a patch was applied. A patch only touches the project when Apply is pressed.
//   * The model proposes; this module decides. Patches must match the file text exactly, may not delete methods or hooks,
//     may not add warning suppression, and may only edit existing generated source files (never build.sh / manifest.json /
//     Makefile / Report/ / Pseudo/ / .raw/ / obj/).
//   * Every applied patch keeps the original text of the files it touched and can be reverted.
// Model backend: the same OpenAI-compatible endpoint Optimize uses (OPTIMIZE_LLM_URL, OPTIMIZE_LLM_MODEL, *_DEEP, OPTIMIZE_LLM_TIMEOUT_MS,
// OPTIMIZE_LLM_MAX_TOKENS, OPTIMIZE_CTX_CHARS, OPTIMIZE_LLM_CONCURRENCY).
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const diag = require('./diag');

const EDIT_MAX = 2 * 1048576;
const sha = (s) => crypto.createHash('sha1').update(s == null ? '' : s).digest('hex');
const newId = () => crypto.randomBytes(5).toString('hex');
const readJson = (f, d) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return d; } };
const readText = (f) => { try { const b = fs.readFileSync(f); return b.includes(0) ? null : b.toString('utf8'); } catch { return null; } };

// ---- guards (mirrors reconstruct-optimize.js) ----
const METHOD = /^[-+]\s*\([^)]*\)\s*[A-Za-z_]/gm;
const metrics = (t) => ({
  methods: (t.match(METHOD) || []).length,
  hooks: (t.match(/^%hook\b/gm) || []).length + (t.match(/^%new\b/gm) || []).length + (t.match(/\bswz\s*\(/g) || []).length + (t.match(/\b(?:MSHook(?:Message|Function)Ex?|rebind_symbols)\s*\(/g) || []).length,
  suppress: (t.match(/#pragma\s+clang\s+diagnostic\s+ignored|-Wno-error|^\s*#if\s+0\b|\s-w\s/gm) || []).length,
});
function guardPatch(plan) {
  const why = [];
  for (const f of plan) {
    const a = metrics(f.old), b = metrics(f.neu);
    if (b.methods < a.methods) why.push(`${f.path}: removes ${a.methods - b.methods} method(s). A repair has to fix them, not delete them.`);
    if (b.hooks < a.hooks) why.push(`${f.path}: removes ${a.hooks - b.hooks} hook / swizzle install(s).`);
    if (b.suppress > a.suppress) why.push(`${f.path}: adds compiler-warning suppression or disables code with #if 0.`);
  }
  return why;
}

module.exports = function mountAiEdit(ctx) {
  const { app, express, B, guard, findPart, outRoot, audit, saveFile } = ctx;
  const env = ctx.env || process.env;

  const dirOf = (part) => path.join(outRoot, part.dir);
  const aiDir = (part) => path.join(outRoot, '.ai', part.dir);
  const patchesFile = (part) => path.join(aiDir(part), 'patches.json');
  const chatFile = (part) => path.join(aiDir(part), 'chat.json');
  const blobFile = (part, id) => path.join(aiDir(part), 'blobs', id.replace(/[^a-f0-9]/g, '') + '.json');
  const loadPatches = (part) => readJson(patchesFile(part), []);
  const savePatches = (part, v) => { fs.mkdirSync(aiDir(part), { recursive: true }); const t = patchesFile(part) + '.tmp'; fs.writeFileSync(t, JSON.stringify(v.slice(-40))); fs.renameSync(t, patchesFile(part)); };
  const loadChat = (part) => readJson(chatFile(part), []);
  const saveChat = (part, v) => { fs.mkdirSync(aiDir(part), { recursive: true }); fs.writeFileSync(chatFile(part), JSON.stringify(v.slice(-40))); };

  // an editable path: an existing generated source file, never a build-control file or a derived/report folder
  const BLOCKED = /^(?:\.|obj\/|Report\/|Pseudo\/|build\.sh$|build-report\.txt$|build-errors\.txt$|manifest\.json$|Makefile$)/;
  const EXT = /\.(?:m|mm|h|hpp|c|cc|cpp|x|xm|xi|xmi|swift|plist|json|txt|mk)$/i;
  function resolve(part, rel) {
    rel = String(rel || '').replace(/\\/g, '/').replace(/^\.\//, '');
    if (!rel || rel.includes('\0') || BLOCKED.test(rel) || !EXT.test(rel)) return null;
    const dir = path.resolve(dirOf(part)), full = path.resolve(dir, rel);
    if (!full.startsWith(dir + path.sep)) return null;
    try { if (!fs.statSync(full).isFile()) return null; } catch { return null; }
    return { norm: path.relative(dir, full).split(path.sep).join('/'), full };
  }

  // ---- edits -> exact new file contents. Writes nothing. ----
  function prepare(part, edits) {
    if (!Array.isArray(edits) || !edits.length) return { ok: false, error: 'The patch has no edits.' };
    if (edits.length > 40) return { ok: false, error: 'The patch has too many edits (limit 40).' };
    const work = new Map();
    for (const [i, e] of edits.entries()) {
      if (!e || e.op !== 'replace') return { ok: false, error: `Edit ${i + 1}: only "replace" edits are supported. Patches change existing files; they cannot create or delete files.` };
      const r = resolve(part, e.path);
      if (!r) return { ok: false, error: `Edit ${i + 1}: "${e.path}" is not an editable generated source file.` };
      let w = work.get(r.norm);
      if (!w) { const t = readText(r.full); if (t == null) return { ok: false, error: `Edit ${i + 1}: ${r.norm} is not a text file.` }; w = { path: r.norm, old: t, neu: t, full: r.full }; work.set(r.norm, w); }
      if (typeof e.find !== 'string' || !e.find.length || e.find.length > 20000 || typeof e.replace !== 'string') return { ok: false, error: `Edit ${i + 1}: needs the exact text to find and its replacement.` };
      if (e.find === e.replace) return { ok: false, error: `Edit ${i + 1}: the replacement is identical to the original.` };
      const n = w.neu.split(e.find).length - 1;
      if (n === 0) return { ok: false, error: `Edit ${i + 1}: the text to replace was not found in ${r.norm}. It may have changed since the patch was proposed.` };
      if (n > 1 && !e.all) return { ok: false, error: `Edit ${i + 1}: the text to replace appears ${n} times in ${r.norm}; it has to identify one place.` };
      w.neu = w.neu.split(e.find).join(e.replace);
      if (Buffer.byteLength(w.neu) > EDIT_MAX) return { ok: false, error: `${r.norm} would become larger than 2 MB.` };
    }
    const plan = [...work.values()].filter((w) => w.old !== w.neu);
    if (!plan.length) return { ok: false, error: 'The patch changes nothing.' };
    if (plan.length > 20) return { ok: false, error: 'The patch touches too many files (limit 20).' };
    return { ok: true, plan };
  }

  const view = (pt, withFiles, part) => {
    const v = { id: pt.id, created: pt.created, title: pt.title, summary: pt.summary, model: pt.model || null, inference: !!pt.inference, evidence: pt.evidence || [],
      status: pt.status, blockReason: pt.blockReason || null, appliedAt: pt.appliedAt || null, revertedAt: pt.revertedAt || null, files: [...new Set((pt.edits || []).map((e) => e.path))], attempt: pt.attempt || 1 };
    if (withFiles) {
      try {
        if (pt.status === 'applied' || pt.status === 'reverted') { const b = readJson(blobFile(part, pt.id), null); v.changes = b ? Object.keys(b.before).map((f) => ({ path: f, old: b.before[f] || '', neu: b.after[f] || '' })) : []; }
        else { const pr = prepare(part, pt.edits); v.changes = pr.ok ? pr.plan.map((f) => ({ path: f.path, old: f.old, neu: f.neu })) : []; if (!pr.ok) v.stale = pr.error; }
      } catch { v.changes = []; }
    }
    return v;
  };

  function propose(part, spec) {
    const pr = prepare(part, spec.edits);
    const pt = { id: newId(), created: Date.now(), title: String(spec.title || 'Patch').slice(0, 120), summary: String(spec.summary || '').slice(0, 1500), model: spec.model || null, inference: !!spec.inference,
      evidence: (Array.isArray(spec.evidence) ? spec.evidence : []).map((x) => String(x).slice(0, 300)).slice(0, 12), edits: spec.edits, status: 'proposed', attempt: spec.attempt || 1 };
    if (!pr.ok) { pt.status = 'blocked'; pt.blockReason = pr.error; }
    else { const why = guardPatch(pr.plan); if (why.length) { pt.status = 'blocked'; pt.blockReason = why.join(' '); } }
    const all = loadPatches(part);
    if (pt.status === 'proposed') for (const x of all) if (x.status === 'proposed' && x.title === pt.title) { x.status = 'rejected'; x.note = 'superseded'; }
    all.push(pt); savePatches(part, all);
    return pt;
  }

  // ---- the model (same transport as Optimize) ----
  const LLM = { url: () => env.OPTIMIZE_LLM_URL || '', model: () => env.OPTIMIZE_LLM_MODEL || 'local', urlDeep: () => env.OPTIMIZE_LLM_URL_DEEP || '', modelDeep: () => env.OPTIMIZE_LLM_MODEL_DEEP || '' };
  const maxConc = Math.max(1, Number(env.OPTIMIZE_LLM_CONCURRENCY || 1)); let running = 0; const waiting = [];
  const slot = () => new Promise((ok, no) => { if (running < maxConc) { running++; return ok(); } if (waiting.length >= 4) return no(new Error('The assistant is busy with other requests. Try again in a minute.')); waiting.push(ok); });
  const free = () => { const n = waiting.shift(); if (n) n(); else running--; };
  function postJson(url, body, ms) {
    return new Promise((ok, no) => {
      let u; try { u = new URL(url); } catch { return no(new Error('OPTIMIZE_LLM_URL is not a valid URL.')); }
      const lib = u.protocol === 'https:' ? require('https') : require('http'), data = JSON.stringify(body);
      const hdr = { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) };
      if (u.username) hdr.authorization = 'Basic ' + Buffer.from(decodeURIComponent(u.username) + ':' + decodeURIComponent(u.password)).toString('base64');
      const rq = lib.request({ protocol: u.protocol, hostname: u.hostname, port: u.port || undefined, path: u.pathname + u.search, method: 'POST', headers: hdr }, (rs) => {
        const parts = []; let n = 0;
        rs.on('data', (c) => { n += c.length; if (n > 16 * 1024 * 1024) { rq.destroy(new Error('The model reply is too large.')); return; } parts.push(c); });
        rs.on('end', () => { clearTimeout(timer); ok({ status: rs.statusCode, text: Buffer.concat(parts).toString('utf8') }); });
        rs.on('error', (e) => { clearTimeout(timer); no(e); });
      });
      const timer = setTimeout(() => { const e = new Error('timeout'); e.timedOut = true; rq.destroy(e); }, ms);
      rq.on('error', (e) => { clearTimeout(timer); no(e); });
      rq.setTimeout(0); rq.end(data);
    });
  }
  async function chatCompletion(messages, attempt) {
    const deep = attempt >= 2 && LLM.urlDeep();
    const url = deep ? LLM.urlDeep() : LLM.url(), model = deep ? LLM.modelDeep() || LLM.model() : LLM.model();
    await slot();
    try {
      const r = await postJson(url, { model, messages, temperature: 0.2, max_tokens: Number(env.OPTIMIZE_LLM_MAX_TOKENS || 4096), stream: false }, Number(env.OPTIMIZE_LLM_TIMEOUT_MS || 600000));
      if (r.status < 200 || r.status >= 300) throw new Error('The model server answered ' + r.status + (r.text ? ': ' + r.text.slice(0, 160).replace(/\s+/g, ' ') : '') + '.');
      let j; try { j = JSON.parse(r.text); } catch { throw new Error('The model server returned something that is not JSON.'); }
      const c = j && j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content;
      if (typeof c !== 'string') throw new Error('The model server returned no text.');
      return { text: c, model };
    } catch (e) {
      const code = (e && e.code) || '';
      if (e && e.timedOut) throw new Error('The model took too long and was stopped.');
      if (code === 'ECONNREFUSED' || code === 'ENOTFOUND') throw new Error('Could not reach the model server (' + code + '). Is it running?');
      if (code === 'ECONNRESET' || code === 'EPIPE') throw new Error('The model server closed the connection (' + code + ').');
      throw new Error((e && e.message) || 'The model request failed.');
    } finally { free(); }
  }
  const parseModelJson = (txt) => {
    let t = String(txt).replace(/<think>[\s\S]*?<\/think>/g, '').trim();
    const fence = /```(?:json)?\s*([\s\S]*?)```/.exec(t); if (fence) t = fence[1].trim();
    const a = t.indexOf('{'), b = t.lastIndexOf('}'); if (a < 0 || b <= a) return null;
    try { return JSON.parse(t.slice(a, b + 1)); } catch { return null; }
  };

  const SYSTEM = [
    'You are Ai-Decrypt, the editing assistant inside a decompilation toolchain. The project is Objective-C source reconstructed from an iOS dylib (Logos Tweak.x, plain-clang Tweak.m, Classes/Functions/Hooks .m files, headers, Library/ files). It is built with clang -fno-objc-arc.',
    'The evidence and the compiler are the authority, not you. Use only what the supplied file text, per-function evidence, Ghidra output and build log show. Reconstructed code is an approximation of the original; where evidence is weak (low confidence, param_N names, DAT_/LAB_ references), say so instead of inventing intent.',
    'Answer with ONE JSON object and nothing else: {"reply": string, "patch": null | {"title": string, "summary": string, "evidence": [string], "inference": boolean, "edits": [ {"op":"replace","path":string,"find":string,"replace":string} ]}}.',
    'Rules: a replace edit\'s "find" must be copied exactly from the file text (without the "N| " line-number prefixes) and match once. Make the smallest edit that fixes the root cause. NEVER delete methods, hooks or %hook blocks, never disable code with #if 0, never add #pragma clang diagnostic or -Wno flags to hide an error, never edit build.sh / Makefile / manifest.json / Report/ / Pseudo/ / .raw/.',
    'In "evidence" cite where each change comes from (file:line, a per-function evidence item, a compiler message). Set "inference" true when any part of the change is your own judgement rather than directly shown by that evidence, and say so in "reply". For a question that only needs an explanation, set "patch" to null and answer in "reply". If the request is ambiguous or cannot be done safely, set "patch" to null and say why.',
  ].join('\n');

  // ---- context: the open file, the function's own evidence + Ghidra/pseudo output, build errors, reports ----
  function pseudoBlock(dir, label) {
    const pd = path.join(dir, 'Pseudo'); let names = []; try { names = fs.readdirSync(pd); } catch { return null; }
    const head = '// ===== ' + label;
    for (const n of names) {
      const t = readText(path.join(pd, n)); if (!t) continue;
      const i = t.indexOf(head); if (i < 0) continue;
      const j = t.indexOf('\n// =====', i + head.length);
      return t.slice(i, j < 0 ? undefined : j);
    }
    return null;
  }
  function gather(part, b) {
    const dir = dirOf(part), cap = Number(env.OPTIMIZE_CTX_CHARS || 48000); let used = 0; const out = [];
    const add = (title, body, lim) => { if (!body) return; let s = String(body); if (s.length > lim) s = s.slice(0, lim) + '\n…(truncated)'; if (used + s.length > cap) s = s.slice(0, Math.max(0, cap - used)); if (!s) return; used += s.length; out.push(`=== ${title} ===\n${s}`); };
    const file = b.file ? resolve(part, b.file) : null;
    if (file) {
      const t = readText(file.full) || '', lim = 22000;
      add(`Open file ${file.norm}${t.length > lim ? ' (first ' + lim + ' characters)' : ''}`, t.split('\n').map((l, k) => `${k + 1}| ${l}`).join('\n'), lim);
      const raw = readText(path.join(dir, '.raw', file.norm));
      if (raw && raw !== t) add(`Ghidra literal recovery of ${file.norm} (before prettifying)`, raw, 6000);
    }
    if (b.selection) add(`Selected text${b.selectionLine ? ' (starts at line ' + Number(b.selectionLine) + ')' : ''}`, String(b.selection).slice(0, 4000), 4000);
    if (b.symbol) {
      const sym = String(b.symbol).slice(0, 300);
      const conf = readJson(path.join(dir, 'Report/confidence.json'), null);
      const fn = conf && (conf.functions || []).find((f) => f.label === sym);
      if (fn) add(`Evidence for ${sym} (score ${fn.score}, ${fn.level}${fn.capped ? ', capped' : ''})`, (fn.evidence || []).map((e) => `${e.ok ? '[ok]  ' : '[gap] '}${e.text}${e.detail ? ' — ' + e.detail : ''}`).join('\n'), 3000);
      const pb = pseudoBlock(dir, sym); if (pb) add(`P-Code pseudo-code for ${sym}`, pb, 5000);
    }
    const d = diag.parse(dir);
    if (d.hasReport || d.errors) {
      const lines = []; for (const [f, arr] of Object.entries(d.files)) for (const x of arr.slice(0, 6)) lines.push(`${f}:${x.line}:${x.col}: ${x.sev}: ${x.msg}`);
      add(`Build diagnostics (${d.errors} error(s))`, lines.slice(0, 60).join('\n'), 5000);
      const shown = new Set();
      for (const [f, arr] of Object.entries(d.files)) {
        if (file && f !== file.norm && !file.norm.endsWith(f) && !f.endsWith(file.norm)) continue;
        for (const x of arr.filter((y) => y.sev === 'error').slice(0, 3)) {
          const r = resolve(part, f); if (!r) continue; const key = r.norm + ':' + Math.floor(x.line / 30); if (shown.has(key) || shown.size > 5) continue; shown.add(key);
          const t = readText(r.full); if (t == null) continue; const ls = t.split('\n'), a = Math.max(0, x.line - 25), z = Math.min(ls.length, x.line + 25);
          add(`${r.norm} lines ${a + 1}-${z}`, ls.slice(a, z).map((l, k) => `${a + k + 1}| ${l}`).join('\n'), 4500);
        }
      }
    }
    add('Correctness gate', readText(path.join(dir, 'Report/verification.md')), 4000);
    add('Hook graph', readText(path.join(dir, 'Report/hookgraph.md')), 3500);
    add('Analyzer disagreements', readText(path.join(dir, 'Report/agreement.md')), 2500);
    return out.join('\n\n');
  }

  async function modelReply(part, b, history) {
    if (!LLM.url()) return { reply: 'No model is connected on this server. Set OPTIMIZE_LLM_URL to an OpenAI-compatible endpoint (the same one Reconstruct Studio\'s Optimize assistant uses) and restart.' };
    const hint = { explain: 'Explain what this code most likely does and how reliable the reconstruction is. Do not propose a patch unless something is clearly broken.', fix: 'Fix the build errors listed in the diagnostics with the smallest correct patch.', improve: 'Improve readability only: meaningful names for param_N / local variables where the evidence supports them, no behaviour change. Keep every method and hook.' }[b.action] || '';
    const ctxText = gather(part, b);
    const base = [{ role: 'system', content: SYSTEM }, ...history.filter((h) => !h.err).slice(-6).map((h) => ({ role: h.role, content: String(h.text).slice(0, 1500) })),
      { role: 'user', content: `Project context:\n${ctxText}\n\nRequest: ${b.message}${hint ? '\n\n' + hint : ''}` }];
    let messages = base, lastErr = '';
    for (let attempt = 1; attempt <= 3; attempt++) {
      const r = await chatCompletion(messages, attempt);
      const j = parseModelJson(r.text);
      if (!j) { lastErr = 'the answer was not valid JSON'; messages = [...base, { role: 'assistant', content: r.text.slice(0, 3000) }, { role: 'user', content: 'That was not a single valid JSON object. Answer again with only the JSON object described in the instructions.' }]; continue; }
      const reply = String(j.reply || '').slice(0, 4000);
      if (!j.patch) return { reply: reply || 'I could not find a safe change to propose.', model: r.model };
      const pt = propose(part, { model: r.model, title: j.patch.title, summary: j.patch.summary, evidence: j.patch.evidence, inference: !!j.patch.inference, edits: j.patch.edits, attempt });
      if (pt.status === 'proposed') return { reply: (reply || 'Here is the proposed change.') + '\n\nNothing has been changed yet. Review the diff and press Apply.', patch: pt, model: r.model };
      lastErr = pt.blockReason;
      if (/removes|suppression|not found|appears \d+ times|not an editable|identical|only "replace"/.test(pt.blockReason || '') && attempt < 3) messages = [...base, { role: 'assistant', content: r.text.slice(0, 3000) }, { role: 'user', content: 'The patch was rejected: ' + pt.blockReason + ' Fix that and answer again with only the JSON object.' }];
      else return { reply: (reply ? reply + '\n\n' : '') + 'I could not produce a patch that passes the safety checks: ' + pt.blockReason, patch: pt, model: r.model };
    }
    return { reply: 'I could not produce a valid patch after 3 attempts (' + lastErr + '). Nothing was changed.' };
  }

  // ---- routes ----
  const jobs = new Map();
  setInterval(() => { const t = Date.now(); for (const [k, j] of jobs) if (j.ended && t - j.ended > 1800000) jobs.delete(k); }, 300000).unref();
  const hits = new Map();
  const limited = (who, n) => { const now = Date.now(), a = (hits.get(who) || []).filter((t) => now - t < 3600000); a.push(now); hits.set(who, a); return a.length > n; };
  const actor = (req) => (req.me && req.me.id ? 'u' + req.me.id : req.ip || '?');
  const part404 = (req, res) => { const part = findPart(req); if (!part) res.status(404).json({ error: 'not ready' }); return part; };

  app.get(`${B}/jobs/:id/ai`, guard, (req, res) => {
    const part = part404(req, res); if (!part) return;
    res.json({ llm: { configured: !!LLM.url(), deep: !!LLM.urlDeep() }, patches: loadPatches(part).slice(-20).reverse().map((p) => view(p, false, part)), chat: loadChat(part).slice(-30) });
  });

  app.post(`${B}/jobs/:id/ai/chat`, guard, express.json({ limit: '40kb' }), (req, res) => {
    const part = part404(req, res); if (!part) return;
    const b = req.body || {}, message = String(b.message || '').trim().slice(0, 2000);
    if (!message) return res.status(400).json({ error: 'Type a request first.' });
    if (limited(actor(req), 40)) return res.status(429).json({ error: 'Too many requests. Try again later.' });
    const key = part.dir, live = jobs.get(key);
    if (live && live.state === 'running') return res.status(409).json({ error: 'A request is already running for this job. Wait for it to finish.' });
    const spec = { message, action: ['explain', 'fix', 'improve', 'chat'].includes(b.action) ? b.action : 'chat', file: typeof b.file === 'string' ? b.file : null,
      symbol: typeof b.symbol === 'string' ? b.symbol : null, selection: typeof b.selection === 'string' ? b.selection : null, selectionLine: Number(b.selectionLine) || null };
    const job = { id: crypto.randomBytes(6).toString('hex'), state: 'running', started: Date.now(), result: null, error: '' }; jobs.set(key, job);
    (async () => {
      const chat = loadChat(part); chat.push({ role: 'user', text: message, at: Date.now() });
      let out; try { out = await modelReply(part, spec, chat.slice(0, -1)); } catch (e) { out = { reply: String((e && e.message) || e), err: true }; }
      chat.push({ role: 'assistant', text: out.reply, at: Date.now(), patch: out.patch ? out.patch.id : null, err: out.err ? 1 : undefined }); saveChat(part, chat);
      audit(req, 'ai-chat', `${part.dylibName}${spec.file ? ':' + spec.file : ''}`, `job ${req.params.id}${out.patch ? ' patch ' + out.patch.id : ''}`);
      return { reply: out.reply, patch: out.patch ? view(out.patch, true, part) : null };
    })().then((r) => { job.result = r; job.state = 'done'; }, (e) => { job.error = String((e && e.message) || e).slice(0, 300); job.state = 'error'; }).finally(() => { job.ended = Date.now(); });
    res.status(202).json({ job: job.id });
  });

  app.get(`${B}/jobs/:id/ai/jobs/:jid`, guard, (req, res) => {
    const part = part404(req, res); if (!part) return;
    const job = jobs.get(part.dir);
    if (!job || job.id !== req.params.jid) return res.status(404).json({ error: 'That request is no longer available.' });
    if (job.state === 'running') return res.json({ state: 'running', seconds: Math.round((Date.now() - job.started) / 1000) });
    if (job.state === 'error') return res.json({ state: 'error', error: job.error });
    res.json({ state: 'done', result: job.result });
  });

  app.get(`${B}/jobs/:id/ai/patches/:pid`, guard, (req, res) => {
    const part = part404(req, res); if (!part) return;
    const pt = loadPatches(part).find((x) => x.id === req.params.pid); if (!pt) return res.status(404).json({ error: 'No such patch.' });
    res.json({ patch: view(pt, true, part) });
  });

  app.post(`${B}/jobs/:id/ai/patches/:pid/apply`, guard, (req, res) => {
    const part = part404(req, res); if (!part) return;
    if (part.buildState === 'running') return res.status(409).json({ error: 'A build is running. Apply the patch when it finishes.' });
    const all = loadPatches(part), pt = all.find((x) => x.id === req.params.pid); if (!pt) return res.status(404).json({ error: 'No such patch.' });
    if (pt.status !== 'proposed') return res.status(409).json({ error: pt.status === 'blocked' ? 'This patch was blocked: ' + pt.blockReason : 'This patch is already ' + pt.status + '.' });
    const pr = prepare(part, pt.edits); if (!pr.ok) return res.status(409).json({ error: pr.error });
    const why = guardPatch(pr.plan); if (why.length) return res.status(409).json({ error: why.join(' ') });
    try {
      const before = {}, after = {}, afterHash = {};
      for (const f of pr.plan) { before[f.path] = f.old; after[f.path] = f.neu; afterHash[f.path] = sha(f.neu); }
      fs.mkdirSync(path.dirname(blobFile(part, pt.id)), { recursive: true }); fs.writeFileSync(blobFile(part, pt.id), JSON.stringify({ before, after }));
      for (const f of pr.plan) saveFile(part, f.path, f.neu, req);   // same path as the editor's own Save: diff baseline, .raw twin dropped, "keep" copies refreshed
      Object.assign(pt, { status: 'applied', appliedAt: Date.now(), afterHash }); savePatches(part, all);
      audit(req, 'ai-apply', `${part.dylibName}:${pt.files ? pt.files.join(',') : pr.plan.map((f) => f.path).join(',')}`, `job ${req.params.id} patch ${pt.id}`);
      res.json({ patch: view(pt, true, part), message: 'Applied. Rebuild to check it; a build passing still does not mean the dylib behaves like the original.' });
    } catch (e) { res.status(500).json({ error: 'Could not write the files: ' + e.message }); }
  });

  app.post(`${B}/jobs/:id/ai/patches/:pid/revert`, guard, express.json({ limit: '2kb' }), (req, res) => {
    const part = part404(req, res); if (!part) return;
    if (part.buildState === 'running') return res.status(409).json({ error: 'A build is running.' });
    const all = loadPatches(part), pt = all.find((x) => x.id === req.params.pid); if (!pt) return res.status(404).json({ error: 'No such patch.' });
    if (pt.status !== 'applied') return res.status(409).json({ error: 'Only an applied patch can be reverted.' });
    const blob = readJson(blobFile(part, pt.id), null); if (!blob) return res.status(409).json({ error: 'The saved original text for this patch is gone.' });
    const force = !!(req.body && req.body.force), changed = [];
    for (const f of Object.keys(blob.before)) { const r = resolve(part, f); if (!r) return res.status(400).json({ error: 'Bad path in the patch.' }); const cur = readText(r.full); if (cur == null || sha(cur) !== pt.afterHash[f]) changed.push(f); }
    if (changed.length && !force) return res.status(409).json({ needForce: true, error: 'These files were edited after the patch was applied, so reverting would also undo those edits: ' + changed.join(', ') });
    try {
      for (const f of Object.keys(blob.before)) saveFile(part, f, blob.before[f], req);
      pt.status = 'reverted'; pt.revertedAt = Date.now(); savePatches(part, all);
      audit(req, 'ai-revert', `${part.dylibName}:${Object.keys(blob.before).join(',')}`, `job ${req.params.id} patch ${pt.id}`);
      res.json({ patch: view(pt, false, part) });
    } catch (e) { res.status(500).json({ error: 'Could not restore the files: ' + e.message }); }
  });

  app.post(`${B}/jobs/:id/ai/patches/:pid/reject`, guard, (req, res) => {
    const part = part404(req, res); if (!part) return;
    const all = loadPatches(part), pt = all.find((x) => x.id === req.params.pid); if (!pt) return res.status(404).json({ error: 'No such patch.' });
    if (pt.status !== 'proposed' && pt.status !== 'blocked') return res.status(409).json({ error: 'This patch is already ' + pt.status + '.' });
    pt.status = 'rejected'; savePatches(part, all);
    res.json({ patch: view(pt, false, part) });
  });
};
