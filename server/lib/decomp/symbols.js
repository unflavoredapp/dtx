'use strict';
// Project-wide code intelligence. Two layers:
//   1. Per-file indexing, AST-first: each file is parsed with `clang -ast-dump=json` (the exact cross-compile
//      flags build.sh already uses, so it succeeds whenever the project would actually build) and the real
//      Objective-C/C declarations are read out of the tree -- not guessed from regex. When clang can't parse a
//      file (no SDK configured, a genuine syntax error, clang missing entirely) that one file falls back to the
//      same regex scan this module used to do for everything; a project can be a mix of both, file by file.
//   2. An incremental, per-project cache keyed by file mtime+size: indexing a 500-file project after editing one
//      file re-parses that one file, not all 500 -- this is called on nearly every chat turn (aiedit.js's
//      gather()), so re-running clang over the whole project each time would make every turn slower as a project
//      grows.
// Cross-file dependencies (which files use a class/function/macro defined elsewhere) are derived from the same
// index and cached the same way, invalidated only when the underlying symbol set actually changed.
//   GET /api/staff/decomp/jobs/:id/symbols?q=foo        -> { symbols: [{name,kind,file,line,signature,source}] }
//   GET /api/staff/decomp/jobs/:id/references?symbol=X  -> { refs: [{file,line,text}] }
//   GET /api/staff/decomp/jobs/:id/symbols/graph         -> { edges: [{from,to,via:[names]}] }
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const SRC_RE = /\.(m|mm|h|hpp|c|cpp)$/i;
const AST_RE = /\.(m|mm|h|hpp|c|cpp)$/i;
const SKIP_DIRS = new Set(['obj', '.builds', '.raw', '.ai', '.git']);

function listSourceFiles(dir) {
  const out = [];
  const walk = (d, rel) => {
    let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      if (e.name.startsWith('.') || SKIP_DIRS.has(e.name)) continue;
      const p = path.join(d, e.name), r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) walk(p, r);
      else if (SRC_RE.test(e.name)) { try { if (fs.statSync(p).size < 500000) out.push({ full: p, rel: r }); } catch { /* unreadable */ } }
    }
  };
  walk(dir, '');
  return out;
}

// ---- regex fallback (used per-file when clang can't parse it) -----------------------------------------------
const METHOD_RE = /^\s*([+-])\s*\(([^)]*)\)\s*((?:\w+\s*:\s*(?:\([^)]*\)\s*\w*\s*)?)+|\w+)\s*\{?/;
const CLASS_RE = /^\s*@(interface|implementation)\s+(\w+)(?:\s*\(([^)]*)\))?/;
const FUNC_RE = /^[A-Za-z_][\w\s*]*?\b(\w+)\s*\(([^;{]*)\)\s*\{/;
const MACRO_RE = /^\s*#\s*define\s+(\w+)/;
const CTOR_RE = /__attribute__\s*\(\s*\(\s*constructor/;

function selectorOf(sig) {
  const parts = sig.match(/\w+\s*:/g);
  return parts ? parts.map((p) => p.replace(/\s*:$/, ':')).join('') : sig.trim();
}

function indexFileRegex(text, rel) {
  const out = [];
  const lines = text.split('\n');
  let curClass = null;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    let m;
    if ((m = CLASS_RE.exec(line))) { curClass = m[2]; out.push({ name: m[2], kind: m[3] ? 'category' : 'class', file: rel, line: i + 1, signature: line.trim().slice(0, 140), source: 'regex' }); continue; }
    if ((m = METHOD_RE.exec(line)) && /[-+]/.test(m[1])) {
      const sel = selectorOf(m[3]);
      out.push({ name: curClass ? `${m[1]}[${curClass} ${sel}]` : `${m[1]}${sel}`, kind: 'method', file: rel, line: i + 1, signature: line.trim().slice(0, 140), selector: sel, cls: curClass, source: 'regex' });
      continue;
    }
    if ((m = FUNC_RE.exec(line)) && !/^(if|for|while|switch|return|sizeof)$/.test(m[1])) { out.push({ name: m[1], kind: 'function', file: rel, line: i + 1, signature: line.trim().slice(0, 140), source: 'regex' }); continue; }
    if ((m = MACRO_RE.exec(line))) { out.push({ name: m[1], kind: 'macro', file: rel, line: i + 1, signature: line.trim().slice(0, 140), source: 'regex' }); continue; }
    if (CTOR_RE.test(line)) out.push({ name: '(constructor)', kind: 'constructor', file: rel, line: i + 1, signature: line.trim().slice(0, 140), source: 'regex' });
  }
  return out;
}

// ---- AST-backed indexing --------------------------------------------------------------------------------------
// Same target/ARC flags build.sh's Linux cross-compile path uses, so a file that will actually build also parses
// here; -isysroot is included only when an SDK is configured (findSdk), since the AST dump of a file whose
// #imports can't resolve degrades to just the builtin prelude -- caught below by requiring real output.
function langFor(file) {
  const ext = path.extname(file).toLowerCase();
  if (ext === '.mm') return 'objective-c++';
  if (ext === '.cpp') return 'c++';
  if (ext === '.c') return 'c';
  if (ext === '.h' || ext === '.hpp') return 'objective-c-header';
  return 'objective-c';
}

function astIndexFile(full, rel, sdk) {
  const args = ['-Xclang', '-ast-dump=json', '-fsyntax-only', '-fobjc-arc', '-fno-color-diagnostics',
    '-x', langFor(full), '-target', 'arm64-apple-ios13.0'];
  if (sdk) args.push('-isysroot', sdk);
  args.push(full);
  let r;
  try { r = spawnSync('clang', args, { maxBuffer: 32 * 1024 * 1024, timeout: 8000 }); } catch { return null; }
  if (!r || r.error || !r.stdout || !r.stdout.length) return null;
  let tree; try { tree = JSON.parse(r.stdout.toString('utf8')); } catch { return null; }
  let lines; try { lines = fs.readFileSync(full, 'utf8').split('\n'); } catch { return null; }
  const sigAt = (line) => (lines[line - 1] || '').trim().slice(0, 160);
  const out = [];
  let curFile = null;   // clang's JSON dedups 'loc.file' to only where it changes, in document order -- same rule here
  const walk = (n) => {
    if (!n || typeof n !== 'object') return;
    if (n.loc && n.loc.file) curFile = n.loc.file;
    const k = n.kind;
    if (curFile === full && n.loc && n.loc.line && !n.isImplicit) {
      const line = n.loc.line;
      if (k === 'ObjCInterfaceDecl' || k === 'ObjCImplementationDecl') out.push({ name: n.name, kind: 'class', file: rel, line, signature: sigAt(line), source: 'ast' });
      else if (k === 'ObjCCategoryDecl' || k === 'ObjCCategoryImplDecl') out.push({ name: n.name, kind: 'category', file: rel, line, signature: sigAt(line), source: 'ast' });
      else if (k === 'ObjCMethodDecl') {
        const mn = n.mangledName || null;
        const mm = mn && /^([+-])\[(\S+)\s+(.+)\]$/.exec(mn);
        out.push({ name: mn || `${n.instance === false ? '+' : '-'}${n.name}`, kind: 'method', file: rel, line, signature: sigAt(line), selector: mm ? mm[3] : n.name, cls: mm ? mm[2] : null, source: 'ast' });
      } else if (k === 'ObjCPropertyDecl') {
        out.push({ name: n.name, kind: 'property', file: rel, line, signature: sigAt(line), source: 'ast' });
      } else if (k === 'FunctionDecl') {
        out.push({ name: n.name, kind: 'function', file: rel, line, signature: sigAt(line), source: 'ast' });
        if ((n.inner || []).some((c) => c && c.kind === 'ConstructorAttr')) out.push({ name: '(constructor)', kind: 'constructor', file: rel, line, signature: sigAt(line), source: 'ast' });
      }
    }
    for (const c of n.inner || []) walk(c);
  };
  walk(tree);
  // the preprocessor runs before the AST exists, so clang's tree has no #define nodes at all -- one cheap regex
  // pass over the same file recovers them regardless of whether the AST parse itself succeeded.
  for (let i = 0; i < lines.length; i++) { const m = MACRO_RE.exec(lines[i]); if (m) out.push({ name: m[1], kind: 'macro', file: rel, line: i + 1, signature: sigAt(i + 1), source: 'ast' }); }
  return out.length ? out : null;
}

// ---- incremental per-project cache ------------------------------------------------------------------------------
const CACHE = new Map();   // absolute project dir -> { perFile: Map<rel, {mtimeMs,size,symbols}>, graph: {fp, edges} }
function cacheFor(dir) { let c = CACHE.get(dir); if (!c) { c = { perFile: new Map(), graph: null }; CACHE.set(dir, c); } return c; }

/// Re-parses only files that are new or whose mtime/size changed since the last call for this exact `dir`; an
/// unchanged file's symbols are served straight from the cache. clangDisabled is set in-process the first time a
/// `clang` spawn fails outright (not installed), so a box without clang doesn't retry it on every single file.
let clangUnavailable = false;
function indexProject(dir, { sdk = null, useAst = true } = {}) {
  const cache = cacheFor(dir);
  const present = new Set();
  const all = [];
  for (const { full, rel } of listSourceFiles(dir)) {
    present.add(rel);
    let stat; try { stat = fs.statSync(full); } catch { continue; }
    const cached = cache.perFile.get(rel);
    if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) { all.push(...cached.symbols); continue; }
    let symbols = null;
    if (useAst && !clangUnavailable && AST_RE.test(full)) {
      try { symbols = astIndexFile(full, rel, sdk); }
      catch (e) { if (e && e.code === 'ENOENT') clangUnavailable = true; }
    }
    let text = null;
    if (!symbols) { try { text = fs.readFileSync(full, 'utf8'); } catch { continue; } symbols = indexFileRegex(text, rel); }
    cache.perFile.set(rel, { mtimeMs: stat.mtimeMs, size: stat.size, symbols });
    all.push(...symbols);
  }
  for (const rel of [...cache.perFile.keys()]) if (!present.has(rel)) cache.perFile.delete(rel);   // file deleted/renamed
  return all;
}

function projectFingerprint(dir) {
  return listSourceFiles(dir).map(({ full, rel }) => { try { const st = fs.statSync(full); return `${rel}:${st.mtimeMs}:${st.size}`; } catch { return rel; } }).sort().join('|');
}

/// Which files use a class/function/macro that's actually *defined* in a different file -- a coarse but honest
/// dependency graph (textual, not semantic: it can't tell a real call from a comment mentioning the same word,
/// same limitation as references()), cached the same incremental way as the index itself.
function dependencyGraph(dir, opts) {
  const cache = cacheFor(dir);
  const fp = projectFingerprint(dir);
  if (cache.graph && cache.graph.fp === fp) return cache.graph.edges;
  const syms = indexProject(dir, opts);
  const homeOf = new Map();
  for (const s of syms) {
    if (s.kind !== 'class' && s.kind !== 'function' && s.kind !== 'macro') continue;
    if (!s.name || s.name.length < 3) continue;
    if (!homeOf.has(s.name)) homeOf.set(s.name, new Set());
    homeOf.get(s.name).add(s.file);
  }
  const files = [...new Set(syms.map((s) => s.file))];
  const textByFile = new Map();
  for (const f of files) { try { textByFile.set(f, fs.readFileSync(path.join(dir, f), 'utf8')); } catch { /* unreadable */ } }
  const edges = new Map();
  for (const [name, homes] of homeOf) {
    const re = new RegExp(`\\b${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`);
    for (const f of files) {
      if (homes.has(f)) continue;
      const t = textByFile.get(f); if (!t || !re.test(t)) continue;
      for (const h of homes) {
        const key = `${f}\u0000${h}`;
        if (!edges.has(key)) edges.set(key, new Set());
        edges.get(key).add(name);
      }
    }
  }
  const out = [...edges.entries()].map(([k, via]) => { const [from, to] = k.split('\u0000'); return { from, to, via: [...via].sort() }; });
  cache.graph = { fp, edges: out };
  return out;
}

/// What a file depends on, and what depends on it -- the "if I change this, what else might break" question,
/// fed into the chat's context for whichever file is open (see aiedit.js gather()).
function depsFor(dir, rel, opts) {
  const edges = dependencyGraph(dir, opts);
  const uses = edges.filter((e) => e.from === rel);
  const usedBy = edges.filter((e) => e.to === rel);
  const lines = [];
  if (uses.length) lines.push(`Depends on: ${uses.map((e) => `${e.to} (via ${e.via.join(', ')})`).join('; ')}`);
  if (usedBy.length) lines.push(`Used by: ${usedBy.map((e) => `${e.from} (via ${e.via.join(', ')})`).join('; ')}`);
  return lines.length ? lines.join('\n') : null;
}

function referencesOf(dir, symbolRaw) {
  const symbol = String(symbolRaw || '').replace(/^[+-]\[[^\]]*\s+/, '').replace(/\]$/, '').split(':')[0].trim();
  if (!symbol || symbol.length < 2) return [];
  const re = new RegExp(`\\b${symbol.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`);
  const refs = [];
  for (const { full, rel } of listSourceFiles(dir)) {
    let text; try { text = fs.readFileSync(full, 'utf8'); } catch { continue; }
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      if (re.test(lines[i])) { refs.push({ file: rel, line: i + 1, text: lines[i].trim().slice(0, 160) }); if (refs.length > 200) return refs; }
    }
  }
  return refs;
}

function summaryFor(dir, capChars = 3000, opts) {
  const syms = indexProject(dir, opts);
  const classes = new Map();
  const funcs = [];
  for (const s of syms) {
    if (s.kind === 'class' || s.kind === 'category') { if (!classes.has(s.name)) classes.set(s.name, { file: s.file, methods: new Set() }); }
    else if (s.kind === 'method' && s.cls) { if (!classes.has(s.cls)) classes.set(s.cls, { file: s.file, methods: new Set() }); classes.get(s.cls).methods.add(`${s.name.startsWith('+') ? '+' : '-'}${s.selector}`); }
    else if (s.kind === 'function') funcs.push(`${s.name}() — ${s.file}:${s.line}`);
  }
  const lines = [];
  for (const [name, info] of classes) lines.push(`${name} (${info.file}): ${[...info.methods].slice(0, 20).join(', ')}${info.methods.size > 20 ? ', …' : ''}`);
  if (funcs.length) lines.push(`Functions: ${funcs.slice(0, 30).join('; ')}${funcs.length > 30 ? ', …' : ''}`);
  const text = lines.join('\n');
  return text.length > capChars ? text.slice(0, capChars) + '\n…(truncated)' : text;
}

module.exports = function mountSymbols({ app, guard, findPart, outRoot, findSdk, B = '/api/staff/decomp' }) {
  const sdkOpts = () => ({ sdk: findSdk ? (() => { try { return findSdk(); } catch { return null; } })() : null });
  app.get(`${B}/jobs/:id/symbols`, guard, (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    const dir = path.join(outRoot, part.dir);
    let symbols = indexProject(dir, sdkOpts());
    const q = String(req.query.q || '').trim().toLowerCase();
    if (q) {
      symbols = symbols
        .map((s) => ({ s, rank: s.name.toLowerCase() === q ? 0 : s.name.toLowerCase().startsWith(q) ? 1 : s.name.toLowerCase().includes(q) ? 2 : -1 }))
        .filter((x) => x.rank >= 0).sort((a, b) => a.rank - b.rank).map((x) => x.s);
    }
    res.json({ symbols: symbols.slice(0, 500) });
  });
  app.get(`${B}/jobs/:id/references`, guard, (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    const symbol = String(req.query.symbol || '');
    if (!symbol.trim()) return res.status(400).json({ error: 'symbol is required' });
    res.json({ symbol, refs: referencesOf(path.join(outRoot, part.dir), symbol) });
  });
  app.get(`${B}/jobs/:id/symbols/graph`, guard, (req, res) => {
    const part = findPart(req);
    if (!part) return res.status(404).json({ error: 'not ready' });
    res.json({ edges: dependencyGraph(path.join(outRoot, part.dir), sdkOpts()).slice(0, 1000) });
  });
};
// summaryFor/depsFor are called directly on the required module by aiedit.js (gather()), not only by the routes
// this file mounts, so they're exposed here too, alongside the mount function itself.
module.exports.summaryFor = summaryFor;
module.exports.depsFor = depsFor;
module.exports._test = { indexProject, indexFileRegex, astIndexFile, referencesOf, summaryFor, dependencyGraph, depsFor, listSourceFiles };
