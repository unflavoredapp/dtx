'use strict';
// Dylib Source — method body recovery. Ghidra-headless decompile of every ObjC IMP,
// rendered back to Objective-C and merged into headers / Tweak.x output.
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawn, execFile } = require('child_process');
const tool = require('./toolchain');
const macho = require('./macho');
const swift = require('./swift');
const emit = require('./emit');
const ovrLib = require('./overrides');
const diag = require('./diag');

const SCRIPT_DIR = __dirname;
const SCRIPT_VER = 'v7';
const CONCURRENCY = Number(process.env.DECOMP_CONCURRENCY || 1);

// Build only recompiles whatever .m files the LAST decompile/recipe run wrote to disk (see startJob() below) — it
// never re-runs augment()/fixBody(), so a library.js fix made after a part's recipe ran has no effect on that
// part's Build until the recipe is re-run. That's exactly how the earlier autoreleasepool retype fix went
// unnoticed for three rebuilds in a row: nothing told anyone the engine had moved on from what was on disk. This
// fingerprints library.js (the one file every recipe-time fix in this session has landed in) at recipe time and
// compares it again at Build time, so a stale part gets a loud warning in its own build log instead of silence.
function engineFingerprint() {
  try { return crypto.createHash('sha256').update(fs.readFileSync(path.join(__dirname, 'library.js'))).digest('hex').slice(0, 12); }
  catch { return null; }
}

// ---- tiny semaphore so we never run more Ghidra JVMs than the box can take ----
let active = 0; const waiting = [];
const acquire = () => new Promise((r) => { if (active < CONCURRENCY) { active++; r(); } else waiting.push(r); });
const release = () => { const n = waiting.shift(); if (n) n(); else active--; };

const sha256 = (f) => new Promise((res, rej) => { const h = crypto.createHash('sha256'); fs.createReadStream(f).on('data', (d) => h.update(d)).on('end', () => res(h.digest('hex'))).on('error', rej); });
const sh = (cmd, args) => new Promise((res, rej) => execFile(cmd, args, { maxBuffer: 1 << 26 }, (e, so, se) => (e ? rej(new Error(se || e.message)) : res(so))));

// ---- "Build dylib": runs the project's own generated build.sh (clang, cross-compiling against the server's iOS
// SDK — see toolchain.findSdk) and streams its output back as the job log. A second semaphore, separate from
// Ghidra's: compiling is cheap enough that a couple can run at once without this box choking. ----
let activeBuilds = 0; const waitingBuilds = [];
const BUILD_CONCURRENCY = Number(process.env.DECOMP_BUILD_CONCURRENCY || 2);
const acquireBuild = () => new Promise((r) => { if (activeBuilds < BUILD_CONCURRENCY) { activeBuilds++; r(); } else waitingBuilds.push(r); });
const releaseBuild = () => { const n = waitingBuilds.shift(); if (n) n(); else activeBuilds--; };

async function runBuild(dir, sdk, log, extraEnv = {}, timeoutMs = 10 * 60 * 1000) {
  await acquireBuild();
  try {
    await new Promise((resolve, reject) => {
      const env = { ...process.env, ...extraEnv };
      if (sdk) env.IOS_SDK_PATH = sdk;
      let p;
      try { p = spawn('bash', ['build.sh'], { cwd: dir, env, stdio: ['ignore', 'pipe', 'pipe'] }); }
      catch (e) { return reject(e); }
      let buf = '';
      const onData = (d) => {
        buf += d.toString();
        let i;
        while ((i = buf.indexOf('\n')) >= 0) { const line = buf.slice(0, i); buf = buf.slice(i + 1); if (line.trim()) log(line); }
      };
      p.stdout.on('data', onData); p.stderr.on('data', onData);
      const t = setTimeout(() => { p.kill('SIGKILL'); reject(new Error('build timed out')); }, timeoutMs);
      p.on('error', (e) => { clearTimeout(t); reject(e); });
      p.on('close', (code) => {
        clearTimeout(t);
        if (buf.trim()) log(buf);
        if (code === 0) resolve(); else reject(new Error(`build.sh exited ${code} — see the log above`));
      });
    });
  } finally { releaseBuild(); }
}

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out); else if (e.isFile()) out.push(p);
  }
  return out;
}

async function runGhidra(binFile, dataDir, { funcTimeout = Number(process.env.DECOMP_FUNC_TIMEOUT || 40), maxFuncs = Number(process.env.DECOMP_MAX_FUNCS || 20000), maxExtra = Number(process.env.DECOMP_MAX_EXTRA || 12000), timeoutMs = Number(process.env.DECOMP_TIMEOUT_MIN || 40) * 60 * 1000, log = () => {} } = {}) {
  const st = tool.status(dataDir);
  if (!st.ready) await tool.ensure(dataDir, log);
  const home = tool.findGhidraHome(dataDir);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'decomp-'));
  const outJson = path.join(work, 'out.json');
  const proj = path.join(work, 'proj'); fs.mkdirSync(proj);
  // function starts from the Mach-O (LC_FUNCTION_STARTS) -> the script creates + decompiles any the analysis missed
  const startsFile = path.join(work, 'starts.json');
  let nStarts = 0;
  try { const st0 = macho.info(binFile).functionStartAddrs || []; nStarts = st0.length; fs.writeFileSync(startsFile, JSON.stringify(st0)); } catch { fs.writeFileSync(startsFile, '[]'); }
  log(`function-starts table: ${nStarts} function(s)`);
  const args = [proj, 'p', '-import', binFile, '-scriptPath', SCRIPT_DIR, '-postScript', 'ghidra_objc_dump.py', outJson, String(funcTimeout), String(maxFuncs), String(maxExtra), String(Math.floor(timeoutMs / 1000 * 0.72)), startsFile, String(Number(process.env.DECOMP_ASM_BUDGET || 60000)), String(Number(process.env.DECOMP_PCODE_BUDGET || 150000)), '-deleteProject'];
  await acquire();
  try {
    await new Promise((resolve, reject) => {
      const p = spawn(path.join(home, 'support', 'analyzeHeadless'), args, { env: tool.env(dataDir), stdio: ['ignore', 'pipe', 'pipe'] });
      let tail = '';
      const onData = (d) => { tail = (tail + d.toString()).slice(-4000); };
      p.stdout.on('data', onData); p.stderr.on('data', onData);
      const t = setTimeout(() => { p.kill('SIGKILL'); reject(new Error('decompile timeout')); }, timeoutMs);
      p.on('error', (e) => { clearTimeout(t); reject(e); });
      p.on('close', (code) => { clearTimeout(t); if (fs.existsSync(outJson)) resolve(); else reject(new Error(`ghidra exit ${code}\n${tail}`)); });
    });
    return JSON.parse(fs.readFileSync(outJson, 'utf8'));
  } finally {
    release();
    fs.rmSync(work, { recursive: true, force: true });
  }
}

// Decompile one Mach-O (thin or fat). Cached by content hash.
async function decompileBinary(file, dataDir, opts = {}) {
  const cacheDir = path.join(dataDir, 'decomp-cache'); fs.mkdirSync(cacheDir, { recursive: true });
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'thin-'));
  try {
    const thin = macho.thin(file, path.join(tmp, 'arm64.bin'));
    if (!thin) throw new Error('no arm64 slice');
    const sha = await sha256(thin);
    const key = `${sha}.${SCRIPT_VER}.json`;
    const cp = path.join(cacheDir, key);
    if (fs.existsSync(cp) && !opts.force) { const d = JSON.parse(fs.readFileSync(cp, 'utf8')); d.sha256 = sha; return d; }
    const named = path.join(tmp, path.basename(file).replace(/[^\w.\-]/g, '_') || 'lib.dylib');
    fs.copyFileSync(thin, named);   // never move: thin() returns the caller's own file for a non-fat binary
    // An image with cryptid != 0 still has its code encrypted: Ghidra would spend the whole time budget decompiling
    // ciphertext into meaningless C. Stop early with a clear reason (DECOMP_ALLOW_ENCRYPTED=1 to analyze anyway).
    try {
      const pre = macho.info(named);
      if (pre.cryptid && !process.env.DECOMP_ALLOW_ENCRYPTED) throw Object.assign(new Error('this image is still encrypted (LC_ENCRYPTION_INFO cryptid=' + pre.cryptid + '): its code is ciphertext, so decompiling it would produce nothing meaningful. Supply an already-decrypted copy of the binary.'), { encrypted: true });
    } catch (e) { if (e && e.encrypted) throw e; }
    const data = await runGhidra(named, dataDir, opts);
    try { data.macho = macho.info(named); } catch (e) { data.macho = null; data.machoError = e.message; }
    if (data.macho && data.lib && data.lib.swift) { try { data.swift = swift.extract(named, data); } catch (e) { data.swift = null; data.swiftError = e.message; } }
    try { const lf = require('./analysis/lifter').summarize(named); if (lf && lf.length) data.lift = lf; } catch { /* the lifter is optional: the agreement report says when it did not run */ }
    data.classes = data.classes.filter((c) => c.name);
    data.sha256 = sha;
    fs.writeFileSync(cp, JSON.stringify(data));
    return data;
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
}

// Accepts dylib / framework binary / fat binary / zip. Returns [{name, data}]
async function decompileAny(file, dataDir, opts = {}) {
  const k = macho.kind(file);
  if (!k) throw new Error('not a Mach-O or zip');
  if (k !== 'zip') return [{ name: path.basename(file), data: await decompileBinary(file, dataDir, opts) }];
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'zip-'));
  try {
    try { await sh('unzip', ['-q', '-o', file, '-d', tmp]); } catch { await sh('python3', ['-m', 'zipfile', '-e', file, tmp]); }
    const bins = walk(tmp).filter((f) => { try { const kk = macho.kind(f); return kk && kk !== 'zip' && fs.statSync(f).size > 4096; } catch { return false; } });
    const out = [];
    for (const b of bins) {
      try { out.push({ name: path.relative(tmp, b), data: await decompileBinary(b, dataDir, opts) }); }
      catch (e) { out.push({ name: path.relative(tmp, b), error: e.message }); }
    }
    return out;
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
}

// A zip that is itself a recovered project (a folder with build.sh + manifest.json -- e.g. a "-recovered.zip" this
// tool produced, downloaded, edited and uploaded again) is imported as-is instead of being searched for binaries to
// decompile: its sources become a ready part, so Build compiles exactly the edited files. Only regular files are
// copied (no symlinks), and stale build output from the old run is dropped so build.sh starts clean.
async function importProject(zipFile, destBase, outRoot) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'proj-'));
  try {
    try { await sh('unzip', ['-q', '-o', zipFile, '-d', tmp]); } catch { await sh('python3', ['-m', 'zipfile', '-e', zipFile, tmp]); }
    const files = walk(tmp);
    const roots = files.filter((f) => path.basename(f) === 'build.sh' && fs.existsSync(path.join(path.dirname(f), 'manifest.json')))
      .map((f) => path.dirname(f)).sort((a, b) => a.split(path.sep).length - b.split(path.sep).length);
    if (!roots.length) return null;
    const root = roots[0];
    const name = (root === tmp ? path.basename(zipFile).replace(/\.zip$/i, '') : path.basename(root)).replace(/[^\w.\-]/g, '_');
    const dir = path.join(destBase, name);
    for (const f of files) {
      if (!f.startsWith(root + path.sep)) continue;
      const rel = path.relative(root, f);
      if (/^(?:obj\/|build-report\.txt$|build-errors\.txt$)/.test(rel)) continue;
      const to = path.join(dir, rel);
      fs.mkdirSync(path.dirname(to), { recursive: true });
      fs.copyFileSync(f, to);
    }
    let manifest = {}; try { manifest = JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8')); } catch { /* optional */ }
    const nm = /^NAME="([^"]+)"/m.exec(fs.readFileSync(path.join(dir, 'build.sh'), 'utf8'));
    const base = nm ? nm[1] : name.replace(/-decrypt\.team$/, '');
    let gate = null; try { gate = gateOf(fs.readFileSync(path.join(dir, 'Report', 'verification.json'), 'utf8')); } catch { /* older project */ }
    return { name, gate, stats: manifest.stats || {}, dir: path.relative(outRoot, dir), dylibName: `${base}.dylib`, buildState: 'idle', buildLog: [], engineFingerprint: engineFingerprint(), imported: true, overrideKey: ovrLib.keyOf(`${base}.dylib`), genSha: {} };
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
}

// Merge bodies into a method list produced by the existing metadata tool:
// methods: [{cls, sel, meta, ...}] -> adds .body (ObjC source) when recovered.
function attachBodies(methods, data) {
  const { objcify } = require('./objcify');
  const idx = new Map();
  for (const c of data.classes) for (const m of c.methods) idx.set(`${c.name}|${m.meta ? '+' : '-'}|${m.sel}`, { c, m });
  let n = 0;
  for (const mm of methods) {
    const hit = idx.get(`${mm.cls || mm.class}|${mm.meta || mm.isClass ? '+' : '-'}|${mm.sel || mm.selector}`);
    if (!hit || !hit.m.c) continue;
    const b = objcify(hit.m.c, { ivars: hit.c.ivars, stubs: data.stubs, cfstrings: data.cfstrings, ivarMode: 'arrow' });
    if (b) { mm.body = b; n++; }
  }
  return n;
}

// ---------------------------------------------------------------------------------
// Jobs + Express router
// ---------------------------------------------------------------------------------
const pmem = require('./project-memory');
const jobs = new Map();
const newId = () => crypto.randomBytes(6).toString('hex');
const JOB_TTL = Number(process.env.DECOMP_JOB_TTL_H || 6) * 3600000;
let pruneOut = null;   // set by mount(): removes finished jobs (and their output folders) after JOB_TTL
setInterval(() => {
  const now = Date.now();
  for (const [id, j] of jobs) if (j.ended && now - j.ended > JOB_TTL) { jobs.delete(id); if (pruneOut) { try { fs.rmSync(path.join(pruneOut, id), { recursive: true, force: true }); } catch {} } }
}, 600000).unref();

const ZIPPY = 'import sys,os,zipfile\nroot=sys.argv[1]\nz=zipfile.ZipFile(sys.stdout.buffer,"w",zipfile.ZIP_DEFLATED)\nfor d,_,fs in os.walk(root):\n  for f in sorted(fs):\n    p=os.path.join(d,f)\n    z.write(p,os.path.join(sys.argv[2],os.path.relpath(p,root)))\nz.comment=u"\\u1d0d\\u01a6\\u1d22\\u1d07\\ua730\\u039b | Decrypt.Team".encode("utf8")\nz.close()';
// Summary of Report/verification.json (the correctness gate, verify.js) as shown next to each part: status + the first few findings.
function gateOf(json) {
  try {
    const r = typeof json === 'string' ? JSON.parse(json) : json;
    return { status: r.verdict, errors: r.counts.error, warnings: r.counts.warn, top: r.findings.filter((f) => f.severity !== 'info').slice(0, 5).map((f) => ({ id: f.id, where: f.where, message: f.message })) };
  } catch { return null; }
}
function startJob(items, dataDir, outRoot, opts) {
  const id = newId();
  const job = { id, state: 'queued', started: Date.now(), log: [], items: items.map((it) => ({ name: it.name, state: 'queued' })) };
  jobs.set(id, job);
  const log = (m) => { job.log.push(`${new Date().toISOString().slice(11, 19)} ${m}`); if (job.log.length > 200) job.log.shift(); };
  (async () => {
    job.state = 'running';
    for (let i = 0; i < items.length; i++) {
      const it = items[i], ji = job.items[i];
      ji.state = 'running'; log(`${it.name}: analyzing`);
      try {
        const proj = macho.kind(it.path) === 'zip' ? await importProject(it.path, path.join(outRoot, id, String(i)), outRoot) : null;
        if (proj) {
          ji.parts = [proj]; ji.state = 'done';
          log(`${it.name}: imported project ${proj.name} as-is (no re-decompile) -- ready to Build ${proj.dylibName}`);
          if (it.cleanup) { try { fs.rmSync(path.dirname(it.path), { recursive: true, force: true }); } catch {} }
          continue;
        }
        const parts = await decompileAny(it.path, dataDir, { ...opts, log });
        ji.parts = [];
        for (const p of parts) {
          if (p.error) { ji.parts.push({ name: p.name, error: p.error }); continue; }
          const base = path.basename(p.name).replace(/\.\w+$/, '');
          const files = emit.buildFiles(p.data, { name: base });
          // library.js's augment() (called inside buildFiles, above) is the ONLY place fixBody()'s autoreleasePoolPush
          // retype runs — Build/Rebuild below just recompiles whatever .m files this step wrote to `dir`, it never
          // re-runs augment(). So this is the one moment that matters for "did the fix actually apply this time" —
          // logged to both the terminal and this job's own log (visible in the staff UI) so it doesn't require
          // inspecting the generated .m file by hand to find out.
          const fixes = require('./library').getAutoreleaseFixLog();
          const st = emit.stats(p.data);
          const recipeMsg = `${p.name}: recipe wrote ${Object.keys(files).length} files — ${st.riskyInitializers || 0} risky initializer(s), ${fixes.length} autoreleasePoolPush retype(s) (${fixes.map((f) => `${f.name || '?'}:${f.var}`).join(', ') || 'none'})`;
          log(recipeMsg); console.log('[decomp]', recipeMsg);   // job.log (staff UI) + terminal, so a terminal tail shows this without opening the UI
          const dir = path.join(outRoot, id, String(i), p.name.replace(/[^\w.\-\/]/g, '_'));
          const genSha = {};   // what the recipe generated for each file — lets a kept (hand-edited) file notice the engine moved on
          for (const [rel, txt] of Object.entries(files)) { const fp = path.join(dir, rel); fs.mkdirSync(path.dirname(fp), { recursive: true }); fs.writeFileSync(fp, txt); genSha[rel] = ovrLib.sha1(txt); }
          // Saved hook overrides: files marked "keep" in an earlier run of this same dylib are written back over the
          // fresh output (and their .raw twins dropped) so a re-run no longer wipes manual fixes.
          const overrideKey = ovrLib.keyOf(p.name);
          let kept = null;
          if (opts.overrides) { try { kept = opts.overrides.apply(overrideKey, dir, genSha, log); } catch (e) { log(`${p.name}: could not apply kept edits: ${e.message}`); } }
          // dylibName matches exactly what the generated build.sh writes as "$NAME.dylib" (NAME is this same `base`,
          // the file's own basename with the extension stripped) — see library.js's buildSh().
          ji.parts.push({ name: p.name, gate: gateOf(files['Report/verification.json']), stats: st, dir: path.relative(outRoot, dir), dylibName: `${base}.dylib`, buildState: 'idle', buildLog: [], engineFingerprint: engineFingerprint(), overrideKey, genSha, kept: kept ? { applied: kept.applied.length, orphaned: kept.orphaned.length, changed: kept.upstreamChanged.length } : null });
        }
        ji.state = 'done'; log(`${it.name}: done`);
      } catch (e) { ji.state = 'error'; ji.error = e.message; log(`${it.name}: ${e.message}`); }
      if (it.cleanup) { try { fs.rmSync(path.dirname(it.path), { recursive: true, force: true }); } catch {} }
    }
    job.state = job.items.every((x) => x.state === 'error') ? 'error' : 'done'; job.ended = Date.now();
  })();
  return job;
}

/**
 * mount(app, {
 *   dataDir,                              // writable dir for tools + cache
 *   requireStaff,                         // express middleware, staff only
 *   resolveLibrary(id) -> {name, path}|null   // a catalog library by id
 *   listSet(setId)     -> [{name, path}]       // all libraries of a set ("Analyze set")
 *   express                               // require('express')
 * })
 */
function mount(app, o) {
  try { require('./brand').load(o.dataDir); } catch { /* defaults */ }
  const express = o.express || require('express');
  const guard = o.requireStaff || ((req, res, next) => next());
  const outRoot = path.join(o.dataDir, 'decomp-out'); fs.mkdirSync(outRoot, { recursive: true });
  const B = '/api/staff/decomp';
  pruneOut = outRoot;

  // saved hook overrides (hand-edited files that survive a recipe re-run) + audit log / roles
  const ovr = ovrLib.create(o.dataDir);
  let R = o.roles || null;
  if (!R) { try { R = require('./roles').get(o.dataDir, { getUser: o.getUser }); } catch (e) { console.error('[decomp] roles/audit unavailable:', e.message); } }
  if (R && o.getUser) R.getUser = o.getUser;
  const audit = (req, action, target, detail) => { if (R) R.log(req, action, target, detail); };
  const actorOf = (req) => (R ? R.actorFrom(req) : '?');

  // Ai-Decrypt brief: plain text the chat reads when it opens. Edit <dataDir>/ai-knowledge.md any time (no app release needed).
  // First request copies the shipped default there so it survives deploys.
  const kFile = path.join(o.dataDir, 'ai-knowledge.md');
  const kDefault = path.join(__dirname, 'ai-knowledge.default.md');
  console.log('[ai] knowledge file:', kFile);
  app.get('/api/ai/knowledge', (req, res) => {
    let text = '';
    try {
      if (!fs.existsSync(kFile) && fs.existsSync(kDefault)) fs.copyFileSync(kDefault, kFile);
      text = fs.readFileSync(fs.existsSync(kFile) ? kFile : kDefault, 'utf8');
    } catch { /* empty brief */ }
    res.json({ text: text.slice(0, 20000) });
  });
  app.put('/api/staff/ai/knowledge', guard, express.text({ type: '*/*', limit: '200kb' }), (req, res) => {
    try { fs.writeFileSync(kFile, String(req.body || '')); audit(req, 'ai-knowledge', 'edit', ''); res.json({ ok: true }); }
    catch (e) { res.status(500).json({ error: e.message }); }
  });

  app.get(`${B}/status`, guard, (req, res) => res.json({ ...tool.status(o.dataDir), jobs: [...jobs.values()].slice(-10).map((j) => ({ id: j.id, state: j.state })) }));

  app.post(`${B}/setup`, guard, (req, res) => {
    const st = tool.status(o.dataDir);
    if (st.ready) return res.json({ ok: true, ...st });
    tool.ensure(o.dataDir, (m) => console.log('[decomp]', m)).catch((e) => console.error('[decomp] setup failed', e.message));
    res.status(202).json({ ok: true, installing: true });
  });

  app.post(`${B}/run`, guard, express.json({ limit: '1mb' }), async (req, res) => {
    try {
      const b = req.body || {};
      let items = [];
      if (b.setId && o.listSet) items = await o.listSet(b.setId);
      for (const id of b.libraryIds || []) { const l = await o.resolveLibrary(id); if (l) items.push(l); }
      if (!items.length) return res.status(400).json({ error: 'nothing to analyze' });
      const job = startJob(items, o.dataDir, outRoot, { force: !!b.force, overrides: ovr });
      audit(req, 'analyze', items.map((x) => x.name).slice(0, 5).join(', ') + (items.length > 5 ? ` +${items.length - 5}` : ''), `job ${job.id}${b.setId ? ` set ${b.setId}` : ''}${b.force ? ' force' : ''}`);
      res.status(202).json({ id: job.id });
    } catch (e) { res.status(500).json({ error: e.message }); }
  });

  // raw upload: POST body = file bytes, ?name=foo.dylib
  app.post(`${B}/upload`, guard, express.raw({ type: '*/*', limit: process.env.DECOMP_MAX_UPLOAD || '400mb' }), (req, res) => {
    try {
      const nm = String(req.query.name || 'upload.bin').replace(/[^\w.\-]/g, '_');
      const p = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'up-')), nm);   // own folder, so the project is named after the file and nothing else
      fs.writeFileSync(p, req.body);
      const job = startJob([{ name: nm, path: p, cleanup: true }], o.dataDir, outRoot, { force: req.query.force === '1', overrides: ovr });
      audit(req, 'analyze', nm, `job ${job.id} upload ${req.body ? req.body.length : 0} bytes${req.query.force === '1' ? ' force' : ''}`);
      res.status(202).json({ id: job.id });
    } catch (e) { res.status(500).json({ error: e.message }); }
  });

  app.get(`${B}/jobs/:id`, guard, (req, res) => {
    const j = jobs.get(req.params.id);
    if (!j) return res.status(404).json({ error: 'no such job' });
    res.json({ id: j.id, state: j.state, log: j.log.slice(-30), items: j.items.map((it) => ({ name: it.name, state: it.state, error: it.error, parts: (it.parts || []).map((p) => ({ name: p.name, gate: p.gate || null, stats: p.stats, error: p.error, dylibName: p.dylibName, buildState: p.buildState || 'idle', buildCount: (p.builds || []).length, kept: p.kept || null, pinned: p.overrideKey ? ovr.list(p.overrideKey).length : 0 })) })) });
  });

  // ---- Build dylib: compiles the already-generated project in place with the project's own build.sh. ----
  function findPart(req) {
    const j = jobs.get(req.params.id);
    const it = j && j.items[Number(req.query.item || 0)];
    const part = it && it.parts && it.parts[Number(req.query.part || 0)];
    return part && part.dir ? part : null;
  }
  app.post(`${B}/jobs/:id/build`, guard, (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    if (part.buildState === 'running') return res.status(409).json({ error: 'already building' });
    const sdk = tool.findSdk(o.dataDir);
    if (!sdk) {
      const msg = 'No iOS SDK found on this server. Set DECOMP_IOS_SDK_PATH, or extract one to <data>/tools/sdks/iPhoneOS*.sdk, /opt/decrypt-team/sdks/, or $THEOS/sdks/.';
      part.buildState = 'error'; part.buildLog = [msg];
      return res.status(409).json({ error: msg });
    }
    const dir = path.join(outRoot, part.dir);
    // MR_SKIP_INIT=1 turns every recovered __attribute__((constructor))/(destructor)) function into a no-op (see
    // Report/initializers.md / library.js) — surfaced here as a checkbox so testing it doesn't require a terminal.
    const skipInit = /^(1|true|on|yes)$/i.test(String(req.query.skipInit || ''));
    const buildStarted = Date.now();
    // See engineFingerprint() above: Build only recompiles what the last recipe run wrote to disk, so if
    // library.js has changed since THIS part's recipe last ran, this build will not contain whatever that
    // change fixed — loudly, instead of silently, which is what let the autoreleasepool retype fix go unverified
    // for three rebuilds in a row earlier this session.
    const curFp = engineFingerprint();
    const stale = curFp && part.engineFingerprint && curFp !== part.engineFingerprint;
    part.buildState = 'running';
    const who = { actor: actorOf(req), ip: R ? R.ipFrom(req) : null };
    if (R) R.audit({ ...who, action: 'build', target: part.dylibName, detail: `job ${req.params.id}${skipInit ? ' MR_SKIP_INIT' : ''}${stale ? ' (stale recipe)' : ''}` });
    part.buildLog = [
      ...(stale ? [`⚠ library.js has changed since this part's decompile/recipe step last ran (recipe fingerprint ${part.engineFingerprint}, current ${curFp}) — this build will NOT include whatever changed. Re-run the decompile/recipe step first (re-upload or re-run analysis), then Build.`] : []),
      `using SDK: ${sdk}`, ...(skipInit ? ['MR_SKIP_INIT=1 — recovered constructors/destructors are no-ops this build'] : []),
    ];
    const log = (m) => { part.buildLog.push(m); if (part.buildLog.length > 400) part.buildLog.shift(); console.log('[decomp:build]', part.dylibName, '—', m); };
    // build.sh writes the actual per-file clang errors (not just which files FAILED) to build-errors.txt — it never
    // prints them to stdout itself, so without this a failure here would only say "exited 1" with no way to see why
    // short of SSHing in and cat-ing the file by hand. Appended on any nonzero exit, since -undefined,dynamic_lookup
    // can also let the script exit 1 after a real link-time problem that has nothing in build-report.txt at all.
    const appendBuildErrors = () => {
      try {
        const txt = fs.readFileSync(path.join(dir, 'build-errors.txt'), 'utf8').trim();
        if (txt) { log('--- build-errors.txt ---'); for (const line of txt.split('\n')) log(line); }
      } catch { /* not written yet, or build.sh failed before reaching that step */ }
    };
    runBuild(dir, sdk, log, skipInit ? { MR_SKIP_INIT: '1' } : {})
      .then(() => {
        part.buildState = 'done'; snapshotBuild(dir, part, skipInit);
        try { pmem.recordBuild(dir, { ok: true, durationMs: Date.now() - buildStarted, config: { sdk, skipInit, dylibName: part.dylibName } }); } catch { /* memory is best effort */ }
        // This is what a device's .ips calls usedImages[].uuid — logging it here, straight from the just-built
        // file (not from memory of what "should" have changed), is the one way to actually confirm a rebuild
        // produced new bytes: compare this value against the next crash log's uuid for this dylib. Identical ==
        // the fix did not make it into this binary; different == it did.
        try {
          const built = path.join(dir, part.dylibName);
          const uuid = macho.info(built).uuid;
          part.lastBuiltUuid = uuid;   // what POST jobs/:id/check-crash below compares a pasted .ips against
          log(`built ${part.dylibName} — Mach-O UUID ${uuid} (compare against a crash log's usedImages[].uuid for this dylib)`);
          if (R) R.audit({ ...who, action: 'build-result', target: part.dylibName, detail: `ok uuid ${uuid}` });
        } catch (e) { log(`could not read UUID of the built dylib: ${e.message}`); if (R) R.audit({ ...who, action: 'build-result', target: part.dylibName, detail: 'ok (uuid unreadable)' }); }
      })
      .catch((e) => {
        part.buildState = 'error'; log(e.message); appendBuildErrors();
        let nfail = 0; try { nfail = (fs.readFileSync(path.join(dir, 'build-report.txt'), 'utf8').match(/^FAILED/gm) || []).length; } catch { /* not written */ }
        try { pmem.recordBuild(dir, { ok: false, nfail, durationMs: Date.now() - buildStarted, config: { sdk, skipInit, dylibName: part.dylibName }, error: e.message }); } catch { /* memory is best effort */ }
        if (R) R.audit({ ...who, action: 'build-result', target: part.dylibName, detail: `failed: ${String(e.message).slice(0, 200)}` });
      });
    res.status(202).json({ ok: true });
  });

  // ---- Build history: each successful build overwrites <dir>/<dylibName> (so "Download .dylib" always serves
  // the latest), but a copy is also kept in .builds/ so a MR_SKIP_INIT A/B test — or any other edit-and-rebuild —
  // doesn't lose the previous result the moment the new one finishes. Capped, oldest dropped first. ----
  const BUILD_HISTORY_LIMIT = 5;
  function snapshotBuild(dir, part, skipInit) {
    try {
      const src = path.join(dir, part.dylibName);
      if (!fs.existsSync(src)) return;
      const histDir = path.join(dir, '.builds');
      fs.mkdirSync(histDir, { recursive: true });
      const ts = new Date().toISOString().replace(/[:.]/g, '-');
      const file = `${ts}${skipInit ? '-skipinit' : ''}.dylib`;
      fs.copyFileSync(src, path.join(histDir, file));
      part.builds = part.builds || [];
      part.builds.push({ ts, file, skipInit: !!skipInit });
      while (part.builds.length > BUILD_HISTORY_LIMIT) {
        const old = part.builds.shift();
        try { fs.unlinkSync(path.join(histDir, old.file)); } catch { /* already gone */ }
      }
    } catch { /* history is a convenience, never block the build result on it */ }
  }
  app.get(`${B}/jobs/:id/builds`, guard, (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    res.json({ builds: (part.builds || []).slice().reverse() });
  });
  app.get(`${B}/jobs/:id/builds/file`, guard, (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    const name = String(req.query.file || '');
    const entry = (part.builds || []).find((b) => b.file === name);
    if (!entry) return res.status(404).json({ error: 'no such build in history' });
    const fp = path.join(outRoot, part.dir, '.builds', entry.file);
    if (!fs.existsSync(fp)) return res.status(404).json({ error: 'file no longer on disk' });
    const outName = `${(part.dylibName || 'build').replace(/\.dylib$/, '')}-${entry.ts}${entry.skipInit ? '-skipinit' : ''}.dylib`.replace(/[^\w.-]/g, '_');
    audit(req, 'download', outName, `job ${req.params.id} build history`);
    res.setHeader('Content-Type', 'application/octet-stream');
    res.setHeader('Content-Disposition', `attachment; filename="${outName}"`);
    fs.createReadStream(fp).pipe(res);
  });

  // ---- Crash-log -> function mapping: paste a device .ips (or a plain-text symbolicated crash report) and get
  // back which recovered Functions/*.m file each frame lands in. Apple's crash reporter already gives every
  // frame an `imageOffset` relative to THAT image's own load address — exactly what manifest.json's function
  // table stores as `addr`, so no ASLR/slide math is needed: just match frames whose image is this dylib. ----
  function parseCrashInput(raw, dylibName) {
    const base = String(dylibName || '').replace(/\.dylib$/i, '');
    let report = null;
    // an .ips file is two JSON objects, one per line (a short header, then the full report) — try parsing from
    // each line onward since someone pasting the whole file will have the header line first.
    const lines = raw.split('\n');
    for (let i = 0; i < lines.length && !report; i++) {
      const chunk = lines.slice(i).join('\n').trim();
      if (!chunk || chunk[0] !== '{') continue;
      try { const j = JSON.parse(chunk); if (j && (j.usedImages || j.threads)) report = j; } catch { /* not a JSON object starting here */ }
    }
    const offsets = [];
    let matchedImage = null; let candidateImages = [];
    if (report && Array.isArray(report.usedImages)) {
      const score = (img) => {
        const n = (img.name || path.basename(img.path || '')).toLowerCase();
        if (!n) return 0;
        if (n === String(dylibName || '').toLowerCase() || n === base.toLowerCase()) return 2;
        return base && n.includes(base.toLowerCase()) ? 1 : 0;
      };
      candidateImages = report.usedImages.map((img, idx) => ({ idx, name: img.name || path.basename(img.path || `image${idx}`) })).filter((c) => c.name);
      const best = report.usedImages.map((img, idx) => ({ idx, name: img.name || path.basename(img.path || `image${idx}`), s: score(img) })).filter((c) => c.s > 0).sort((a, b) => b.s - a.s)[0];
      if (best) {
        matchedImage = { idx: best.idx, name: best.name };
        for (const th of report.threads || []) {
          for (const fr of th.frames || []) {
            if (fr.imageIndex === best.idx && typeof fr.imageOffset === 'number') {
              offsets.push({ offset: fr.imageOffset, symbol: fr.symbol || null, thread: th.id, triggered: !!th.triggered });
            }
          }
        }
      }
    }
    if (!matchedImage) {
      // plain-text fallback: symbolicated lines like "3   MRzefvAM_13.dylib   0x... 0x<base> + 212259" — the
      // trailing decimal after "+" is the same image-relative offset concept as imageOffset above.
      for (const line of lines) {
        if (base && !new RegExp(base.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i').test(line)) continue;
        const m = /\+\s*(\d+)\s*$/.exec(line.trim());
        if (m) offsets.push({ offset: Number(m[1]), symbol: null, thread: null, triggered: /crashed|triggered/i.test(line) });
      }
      if (offsets.length) matchedImage = { idx: -1, name: dylibName, textFallback: true };
    }
    if (!matchedImage) {
      // last resort: bare hex tokens anywhere in the pasted text, treated as already image-relative offsets —
      // for when someone just pastes "0x4290" or a lone address rather than a report.
      for (const m of raw.matchAll(/\b0x([0-9a-fA-F]{3,8})\b/g)) offsets.push({ offset: parseInt(m[1], 16), symbol: null, thread: null, triggered: false });
      if (offsets.length) matchedImage = { idx: -1, name: dylibName, bareHex: true };
    }
    return { matchedImage, candidateImages, offsets, report };
  }
  function findFunctionAt(table, offset) {
    const inRange = table.find((f) => offset >= f.addr && (f.size ? offset < f.addr + f.size : offset === f.addr));
    if (inRange) return { fn: inRange, confidence: 'exact' };
    const below = table.filter((f) => f.addr <= offset).sort((a, b) => b.addr - a.addr)[0];
    return below ? { fn: below, confidence: 'nearest' } : null;
  }
  app.post(`${B}/jobs/:id/locate`, guard, express.text({ type: '*/*', limit: '2mb' }), (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    const raw = String(req.body || '');
    if (!raw.trim()) return res.status(400).json({ error: 'paste a crash address, a crash-report line, or a full .ips file' });
    const dir = path.join(outRoot, part.dir);
    let manifest = null;
    try { manifest = JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8')); } catch (e) { return res.status(500).json({ error: 'manifest.json missing or unreadable: ' + e.message }); }
    const table = manifest.functions || [];
    const riskyFiles = new Set((manifest.initOrder || []).filter((i) => i.risky && i.risky.length).map((i) => i.file));
    const { matchedImage, candidateImages, offsets } = parseCrashInput(raw, part.dylibName);
    if (!matchedImage) {
      return res.json({ matched: false, candidateImages: candidateImages.map((c) => c.name), matches: [] });
    }
    const matches = offsets.map((o) => {
      const hit = findFunctionAt(table, o.offset);
      const out = { offset: o.offset, hex: '0x' + o.offset.toString(16), thread: o.thread, triggered: o.triggered, symbol: o.symbol };
      if (hit) { out.function = hit.fn.name; out.kind = hit.fn.kind; out.file = hit.fn.file; out.confidence = hit.confidence; out.risky = riskyFiles.has(hit.fn.file); }
      return out;
    });
    res.json({ matched: true, image: matchedImage.name, imageMatchKind: matchedImage.bareHex ? 'bare-hex' : matchedImage.textFallback ? 'text' : 'ips-json', matches });
  });

  // ---- UUID-verification loop: is a pasted .ips actually evidence about the CURRENT build, or a stale/duplicate
  // crash from before the last fix landed? This is the exact check that, done by hand across several chat
  // messages this session, caught two crash logs that turned out to be re-sends of an earlier crash (same
  // incident, same Mach-O UUID, predating a rebuild) — formalized here instead of eyeballing timestamps. ----
  app.post(`${B}/jobs/:id/check-crash`, guard, express.text({ type: '*/*', limit: '8mb' }), (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    const raw = String(req.body || '');
    if (!raw.trim()) return res.status(400).json({ error: 'paste the full .ips crash report' });
    const { matchedImage, report } = parseCrashInput(raw, part.dylibName);
    if (!matchedImage || matchedImage.idx < 0 || !report || !Array.isArray(report.usedImages)) {
      return res.json({ verdict: 'no-match-found', matchedImage: matchedImage ? matchedImage.name : null });
    }
    const img = report.usedImages[matchedImage.idx];
    const crashUuid = img && img.uuid ? String(img.uuid) : null;
    const builtUuid = part.lastBuiltUuid || null;
    const norm = (u) => String(u || '').toLowerCase().replace(/-/g, '');
    const verdict = !crashUuid ? 'no-match-found' : !builtUuid ? 'unverified-no-build-yet' : norm(crashUuid) === norm(builtUuid) ? 'fresh' : 'stale';
    const incidentId = report.incident_id || report.incident || null;
    const captureTime = report.captureTime || null;
    part.crashChecks = part.crashChecks || [];
    const duplicate = !!(incidentId && part.crashChecks.some((c) => c.incidentId === incidentId));
    part.crashChecks.push({ incidentId, captureTime, crashUuid, verdict, ts: Date.now() });
    if (part.crashChecks.length > 20) part.crashChecks.shift();
    res.json({ verdict, duplicate, crashUuid, builtUuid, incidentId, captureTime, matchedImage: matchedImage.name });
  });

  app.get(`${B}/jobs/:id/build`, guard, (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    res.json({ state: part.buildState || 'idle', log: (part.buildLog || []).slice(-120), dylibName: part.buildState === 'done' ? part.dylibName : null });
  });

  app.get(`${B}/jobs/:id/dylib`, guard, (req, res) => {
    const part = findPart(req);
    if (!part || part.buildState !== 'done') return res.status(404).json({ error: 'not built yet' });
    const fp = path.join(outRoot, part.dir, part.dylibName);
    if (!fs.existsSync(fp)) return res.status(404).json({ error: 'not built yet' });
    audit(req, 'download', part.dylibName, `job ${req.params.id} dylib`);
    res.setHeader('Content-Type', 'application/octet-stream');
    res.setHeader('Content-Disposition', `attachment; filename="${part.dylibName.replace(/[^\w.\-]/g, '_')}"`);
    fs.createReadStream(fp).pipe(res);
  });

  // zip of generated sources for one item/part
  // every generated file of one item/part (relative paths), for the viewer
  app.get(`${B}/jobs/:id/files`, guard, (req, res) => {
    const j = jobs.get(req.params.id);
    const it = j && j.items[Number(req.query.item || 0)];
    const part = it && it.parts && it.parts[Number(req.query.part || 0)];
    if (!part || !part.dir) return res.status(404).json({ error: 'not ready' });
    const dir = path.join(outRoot, part.dir);
    const out = walk(dir).map((f) => ({ path: path.relative(dir, f).split(path.sep).join('/'), size: fs.statSync(f).size })).sort((a, b) => a.path.localeCompare(b.path)).slice(0, 5000);
    res.json({ files: out });
  });

  app.get(`${B}/jobs/:id/download`, guard, (req, res) => {
    const j = jobs.get(req.params.id);
    const it = j && j.items[Number(req.query.item || 0)];
    const part = it && it.parts && it.parts[Number(req.query.part || 0)];
    if (!part || !part.dir) return res.status(404).json({ error: 'not ready' });
    const dir = path.join(outRoot, part.dir);
    audit(req, 'download', `${path.basename(part.name)}-recovered.zip`, `job ${req.params.id} project zip`);
    res.setHeader('Content-Type', 'application/zip');
    res.setHeader('Content-Disposition', `attachment; filename="${path.basename(part.name).replace(/[^\w.\-]/g, '_')}-recovered.zip"`);
    const t = spawn('python3', ['-c', ZIPPY, dir, path.basename(part.name).replace(/\.\w+$/, '').replace(/[^\w.\-]/g, '_') + '-decrypt.team']);
    t.stdout.pipe(res);
    t.on('error', () => res.end());
  });

  // single file preview
  app.get(`${B}/jobs/:id/file`, guard, (req, res) => {
    const j = jobs.get(req.params.id);
    const it = j && j.items[Number(req.query.item || 0)];
    const part = it && it.parts && it.parts[Number(req.query.part || 0)];
    if (!part || !part.dir) return res.status(404).json({ error: 'not ready' });
    const dir = path.join(outRoot, part.dir);
    const fp = path.resolve(dir, String(req.query.path || 'Tweak.x'));
    if (!fp.startsWith(path.resolve(dir) + path.sep) || !fs.existsSync(fp)) return res.status(404).json({ error: 'no file' });
    res.type('text/plain').send(fs.readFileSync(fp, 'utf8'));
  });

  // save an edit to a single generated file — lets a change be made before "Build dylib" picks the directory back
  // up. Can only overwrite a file that's already there (never creates a new path): raw body = the new file text.
  app.put(`${B}/jobs/:id/file`, guard, express.raw({ type: '*/*', limit: '4mb' }), (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    const dir = path.join(outRoot, part.dir);
    const fp = path.resolve(dir, String(req.query.path || ''));
    if (!req.query.path || !fp.startsWith(path.resolve(dir) + path.sep) || !fs.existsSync(fp) || !fs.statSync(fp).isFile()) return res.status(404).json({ error: 'no file' });
    // keep the file exactly as the engine generated it, the first time it is edited, so the editor can diff against it.
    // Lives outside the project dir (outRoot/.orig/<part.dir>/...) so it never shows in file lists, zips or builds.
    try { const ofp = origPath(part, path.relative(dir, fp)); if (ofp && !fs.existsSync(ofp)) { fs.mkdirSync(path.dirname(ofp), { recursive: true }); fs.copyFileSync(fp, ofp); } } catch { /* no baseline is not fatal to a save */ }
    try { fs.writeFileSync(fp, req.body); } catch (e) { return res.status(500).json({ error: e.message }); }
    // build.sh's compile_one(), when the "readable" rewrite of a .m under Classes/Functions/Hooks/Library fails to
    // compile, silently copies its .raw/ twin (Ghidra's literal, unprettified recovery) over it and retries — a
    // deliberate fallback for an untouched file, but it would just as happily discard a person's own saved edit the
    // same way, with nothing in the UI to say so. Removing the .raw twin here makes a saved edit authoritative: if
    // it doesn't compile, the build now reports it FAILED (loud, in build-errors.txt) instead of quietly reverting
    // to code the person never asked for. Harmless no-op for a path with no .raw counterpart (most generated files
    // don't have one — only the per-function dumps under Classes/Functions/Hooks do).
    try { fs.rmSync(path.join(dir, '.raw', String(req.query.path)), { force: true }); } catch { /* no raw twin for this path, or dir layout changed */ }
    // a file already marked "keep" stays in sync with every save, so the stored copy is never older than the editor's
    const rel = ovrLib.safeRel(req.query.path);
    let kept = false;
    if (rel && part.overrideKey) { try { kept = ovr.refresh(part.overrideKey, rel, req.body.toString('utf8'), actorOf(req)); } catch { /* store problem must not fail a save */ } }
    audit(req, 'edit', `${part.dylibName}:${req.query.path}`, `job ${req.params.id}${kept ? ' (kept)' : ''}`);
    res.json({ ok: true, kept });
  });

  // ---- Saved hook overrides: mark a generated file "hand-edited" so re-running the recipe stops overwriting it.
  // Keyed by the dylib's name (not the job id), so it carries over to the next upload/re-analysis of the same dylib. ----
  app.get(`${B}/jobs/:id/overrides`, guard, (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    res.json({ files: part.overrideKey ? ovr.list(part.overrideKey) : [] });
  });
  app.post(`${B}/jobs/:id/overrides`, guard, express.json({ limit: '4kb' }), (req, res) => {
    const part = findPart(req);
    if (!part || !part.overrideKey) return res.status(404).json({ error: 'not ready' });
    const rel = ovrLib.safeRel((req.body || {}).path);
    if (!rel) return res.status(400).json({ error: 'bad path' });
    const dir = path.join(outRoot, part.dir);
    const fp = path.resolve(dir, rel);
    if (!fp.startsWith(path.resolve(dir) + path.sep) || !fs.existsSync(fp) || !fs.statSync(fp).isFile()) return res.status(404).json({ error: 'no file' });
    try {
      if ((req.body || {}).pinned === false) { ovr.unpin(part.overrideKey, rel); audit(req, 'unkeep', `${part.dylibName}:${rel}`, `job ${req.params.id}`); }
      else {
        // the file as it is on disk right now (save first — the editor does) becomes the kept copy
        ovr.pin(part.overrideKey, rel, fs.readFileSync(fp, 'utf8'), part.genSha ? part.genSha[rel] : null, actorOf(req));
        audit(req, 'keep', `${part.dylibName}:${rel}`, `job ${req.params.id}`);
      }
      res.json({ ok: true, files: ovr.list(part.overrideKey) });
    } catch (e) { res.status(400).json({ error: e.message }); }
  });

  // Write one generated file exactly like the editor's Save does (diff baseline, .raw twin dropped, "keep" copies refreshed).
  // Used by the Ai-Decrypt patch Apply / Revert so an AI edit behaves like a hand edit. Throws on a bad path.
  function saveFile(part, rel, text, req) {
    const dir = path.join(outRoot, part.dir), fp = path.resolve(dir, String(rel || ''));
    if (!rel || !fp.startsWith(path.resolve(dir) + path.sep)) throw new Error('bad path');
    try { const ofp = origPath(part, path.relative(dir, fp)); if (ofp && !fs.existsSync(ofp) && fs.existsSync(fp)) { fs.mkdirSync(path.dirname(ofp), { recursive: true }); fs.copyFileSync(fp, ofp); } } catch { /* baseline is best-effort */ }
    fs.mkdirSync(path.dirname(fp), { recursive: true });
    fs.writeFileSync(fp, text);
    try { fs.rmSync(path.join(dir, '.raw', String(rel)), { force: true }); } catch { /* no raw twin */ }
    const r2 = ovrLib.safeRel(rel); let kept = false;
    if (r2 && part.overrideKey) { try { kept = ovr.refresh(part.overrideKey, r2, String(text), actorOf(req)); } catch { /* store problem must not fail a save */ } }
    return kept;
  }
  // brand-new dylibs written by Ai-Decrypt (see authored.js): scaffolded into a ready part, then built/edited like any other
  try { require('./authored')({ app, guard, audit, jobs, newId, outRoot, B }); } catch (e) { console.error('[decomp] authored dylib routes not mounted:', e.message); }
  // project-wide symbol index / references, and the dylib-starter catalog — both generic over any job's part.dir
  try { require('./symbols')({ app, guard, findPart, outRoot, findSdk: () => tool.findSdk(o.dataDir), B }); } catch (e) { console.error('[decomp] symbol routes not mounted:', e.message); }
  try { require('./dylib-templates')({ app, guard, B }); } catch (e) { console.error('[decomp] dylib template routes not mounted:', e.message); }
  // Live Sync releases drafted by Ai-Decrypt, reviewed and published from the app (see liveadmin.js)
  try { require('./liveadmin')({ app, express, guard, audit }); } catch (e) { console.error('[decomp] live admin routes not mounted:', e.message); }
  // Ai-Decrypt editing: chat -> reviewable patch -> Apply / Revert (see aiedit.js)
  // admin or staff get no char/context caps in the AI patch engine (see aiedit.js's `elevated`) -- everyone this
  // `guard` lets in already is staff in practice, but this checks the real role rather than assuming the guard is
  // always configured, since `guard` silently becomes a no-op when `o.requireStaff` isn't supplied.
  const isElevated = (req) => { if (!R) return false; const u = R.actorFrom(req); return R.isAdmin(u) || R.isStaff(u); };
  try { require('./aiedit')({ app, express, B, guard, findPart, outRoot, audit, saveFile, findSdk: () => tool.findSdk(o.dataDir), isElevated, env: process.env }); } catch (e) { console.error('[decomp] ai edit routes not mounted:', e.message); }

  // ---- Editor extras: diff baseline, changed-file list, per-function evidence ----
  function origPath(part, rel) {
    const base = path.resolve(outRoot, '.orig', part.dir);
    const fp = path.resolve(base, String(rel || ''));
    return rel && fp.startsWith(base + path.sep) ? fp : null;
  }
  // the file as the engine generated it (only exists once the file has been saved at least once)
  app.get(`${B}/jobs/:id/original`, guard, (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    const ofp = origPath(part, req.query.path);
    if (!ofp || !fs.existsSync(ofp)) return res.json({ baseline: false });
    res.json({ baseline: true, text: fs.readFileSync(ofp, 'utf8') });
  });
  // which files differ from what the engine generated
  app.get(`${B}/jobs/:id/changes`, guard, (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    const dir = path.join(outRoot, part.dir), base = path.resolve(outRoot, '.orig', part.dir), out = [];
    if (fs.existsSync(base)) for (const f of walk(base)) {
      const rel = path.relative(base, f).split(path.sep).join('/');
      try { out.push({ path: rel, changed: !fs.readFileSync(f).equals(fs.readFileSync(path.join(dir, rel))) }); } catch { out.push({ path: rel, changed: true }); }
    }
    res.json({ files: out });
  });
  // per-function evidence + the correctness gate. Uses Report/confidence.json; older jobs fall back to the markdown table.
  app.get(`${B}/jobs/:id/records`, guard, (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    const dir = path.join(outRoot, part.dir);
    const rd = (rel) => { try { return fs.readFileSync(path.join(dir, rel), 'utf8'); } catch { return null; } };
    let table = []; try { table = JSON.parse(rd('manifest.json') || '{}').functions || []; } catch { /* no manifest */ }
    const byAddr = new Map(table.map((f) => [Number(f.addr), f])), byName = new Map(table.map((f) => [f.name, f]));
    const fileOf = (label, addr) => {
      const a = addr == null ? NaN : parseInt(String(addr).replace(/^0x/, ''), 16);
      const hit = (Number.isFinite(a) && byAddr.get(a)) || byName.get(String(label).replace(/\(\)$/, ''));
      return hit ? hit.file : null;
    };
    let avg = 0, by = {}, total = 0, fns = [];
    const js = rd('Report/confidence.json');
    if (js) {
      try { const j = JSON.parse(js); avg = j.avg; by = j.by; total = j.total; fns = j.functions.map((f) => ({ label: f.label, addr: f.addr, file: fileOf(f.label, f.addr), score: f.score, level: f.level, capped: f.capped, evidence: f.evidence })); } catch { /* fall through to md */ }
    }
    if (!fns.length) {
      const md = rd('Report/confidence.md') || '';
      const a = /Average: \*\*(\d+)\*\*/.exec(md); if (a) avg = Number(a[1]);
      for (const ln of md.split('\n')) {
        const m = /^\| `(.+?)` \| (\d+)( \(capped\))? \| (\w+) \| (.*) \|$/.exec(ln); if (!m) continue;
        const gaps = m[5] === '-' ? [] : m[5].split('; ').map((t) => ({ ok: false, text: t, detail: '' }));
        fns.push({ label: m[1].replace(/\\\|/g, '|'), addr: null, file: fileOf(m[1], null), score: Number(m[2]), level: m[4], capped: !!m[3], evidence: gaps });
        by[m[4]] = (by[m[4]] || 0) + 1;
      }
      total = fns.length;
    }
    fns.sort((x, y) => x.score - y.score);
    res.json({ avg, by, total, functions: fns.slice(0, 5000), gate: gateOf(rd('Report/verification.json')) });
  });

  // ---- Build diagnostics grouped per file, for the editor: errors next to the file they belong to ----
  app.get(`${B}/jobs/:id/diagnostics`, guard, (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    res.json({ buildState: part.buildState || 'idle', ...diag.parse(path.join(outRoot, part.dir)) });
  });

  // Staff roles admin API + /staff/roles page ride along with this mount, so site.js needs no extra wiring for them.
  if (!o.noRoles && R) { try { require('./roles').mount(app, { ...o, getUser: o.getUser }); } catch (e) { console.error('[decomp] roles routes not mounted:', e.message); } }
  // API handed back to other modules (Reconstruct Studio) so they reuse the same Ghidra queue, overrides and clang build.
  return { startJob: (items, opts) => startJob(items, o.dataDir, outRoot, { overrides: ovr, ...(opts || {}) }), jobs, outRoot, runBuild, findSdk: () => tool.findSdk(o.dataDir), toolStatus: () => tool.status(o.dataDir), snapshotBuild };
}

module.exports = { mount, importProject, decompileAny, decompileBinary, attachBodies, buildFiles: emit.buildFiles, toolchain: tool, runBuild };
