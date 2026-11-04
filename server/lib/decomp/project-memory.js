'use strict';
// Per-project memory: a `project` block kept inside manifest.json so it survives download/re-upload of the project
// zip. Generic — used by both authored dylibs and reconstructed projects, by anything that has a project dir.
//   { goal, decisions: [{ts, request, files, patchID}], known_issues: [{ts, text}],
//     build_history: [{ts, ok, nfail, uuid, durationMs, config}], source_hashes: {relPath: sha1} }
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const CAP = { decisions: 60, known_issues: 40, build_history: 20 };

function read(dir) {
  try { return JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8')); } catch { return {}; }
}
function write(dir, manifest) {
  try { fs.writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify(manifest, null, 2)); } catch { /* best effort */ }
}
function ensure(manifest) {
  manifest.project = manifest.project || {};
  const p = manifest.project;
  p.decisions = p.decisions || []; p.known_issues = p.known_issues || []; p.build_history = p.build_history || [];
  p.source_hashes = p.source_hashes || {};
  return p;
}
function push(arr, entry, cap) { arr.push(entry); while (arr.length > cap) arr.shift(); }

/// Sha1 of every .m/.mm/.c/.cpp/.h file under `dir` (relative path -> hash) — a cheap way to tell "did the sources
/// actually change since the last build" without diffing full content.
function hashSources(dir) {
  const out = {};
  const walk = (d, rel) => {
    let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      if (e.name === 'obj' || e.name === '.builds' || e.name.startsWith('.')) continue;
      const p = path.join(d, e.name), r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) walk(p, r);
      else if (/\.(m|mm|c|cpp|h|hpp)$/i.test(e.name)) {
        try { out[r] = crypto.createHash('sha1').update(fs.readFileSync(p)).digest('hex').slice(0, 16); } catch { /* unreadable */ }
      }
    }
  };
  walk(dir, '');
  return out;
}

/// Called right after a build finishes (success or failure) — records the attempt plus the exact config used, so a
/// later "why did this build differently last time" has something concrete to compare against.
function recordBuild(dir, { ok, nfail, uuid, durationMs, config, error } = {}) {
  const manifest = read(dir); const p = ensure(manifest);
  const hashes = hashSources(dir);
  const changed = Object.keys(hashes).filter((k) => p.source_hashes[k] !== hashes[k]).length;
  push(p.build_history, { ts: new Date().toISOString(), ok: !!ok, nfail: nfail || 0, uuid: uuid || null, durationMs: durationMs || null, error: error ? String(error).slice(0, 300) : null, config: config || {}, filesChangedSinceLastBuild: changed }, CAP.build_history);
  p.source_hashes = hashes;
  write(dir, manifest);
}

/// Called when an AI-written patch is applied (or a project is created) — a log of *why* the code looks the way it
/// does, in the model's own words, so a later session asking "what have we done so far" has an answer besides
/// re-reading every diff.
function recordDecision(dir, { request, files, patchID, summary } = {}) {
  const manifest = read(dir); const p = ensure(manifest);
  push(p.decisions, { ts: new Date().toISOString(), request: request ? String(request).slice(0, 600) : null, summary: summary ? String(summary).slice(0, 400) : null, files: files || [], patchID: patchID || null }, CAP.decisions);
  write(dir, manifest);
}

function recordIssue(dir, text) {
  const manifest = read(dir); const p = ensure(manifest);
  push(p.known_issues, { ts: new Date().toISOString(), text: String(text).slice(0, 400) }, CAP.known_issues);
  write(dir, manifest);
}

function setGoal(dir, goal) {
  const manifest = read(dir); const p = ensure(manifest);
  if (goal) p.goal = String(goal).slice(0, 500);
  write(dir, manifest);
}

/// What a chat turn should be told about this project's history, trimmed to stay cheap: the goal, the last few
/// decisions and the last couple of build attempts (most recent first) rather than the whole log.
function summary(dir) {
  const manifest = read(dir); const p = manifest.project;
  if (!p) return null;
  const dec = (p.decisions || []).slice(-8).reverse().map((d) => `- ${d.ts.slice(0, 16)} ${d.request || d.summary || '(no description)'}${d.files && d.files.length ? ' [' + d.files.join(', ') + ']' : ''}`);
  const bh = (p.build_history || []).slice(-4).reverse().map((b) => `- ${b.ts.slice(0, 16)} ${b.ok ? 'OK' : 'FAILED' + (b.nfail ? ` (${b.nfail} file(s))` : '')}`);
  const iss = (p.known_issues || []).slice(-5).reverse().map((i) => `- ${i.text}`);
  const parts = [];
  if (p.goal) parts.push(`Goal: ${p.goal}`);
  if (dec.length) parts.push(`Recent changes:\n${dec.join('\n')}`);
  if (bh.length) parts.push(`Recent builds:\n${bh.join('\n')}`);
  if (iss.length) parts.push(`Known issues:\n${iss.join('\n')}`);
  return parts.length ? parts.join('\n\n') : null;
}

module.exports = { recordBuild, recordDecision, recordIssue, setGoal, summary, hashSources };
