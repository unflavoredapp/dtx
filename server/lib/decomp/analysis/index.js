'use strict';
// Engine V2 analysis stage. Runs after Ghidra's dump has been parsed and before recovery.build():
//   P-Code -> micro-CFG -> SSA -> pseudo-code      (Pseudo/*.pseudo.txt)
//   instruction-level CFG, loops, dominators        (Report/cfg.md, Report/cfg/*.dot)
//   call graph / strings / globals cross-refs       (Report/xrefs.md, strings-by-function.md, globals-usage.md)
//   structure-layout inference                      (Headers/Inferred.h, Report/types.md)
//   evidence-based confidence                       (Report/confidence.md)
// It only ADDS files. It never modifies a generated source file, and never invents code for a function it cannot analyse.

const CFG = require('./cfg');
const PC = require('./pcode');
const XR = require('./xrefs');
const TY = require('./types');
const CONF = require('./confidence');
const AG = require('./agreement');

const safe = (n) => String(n).replace(/[^A-Za-z0-9_+\-]/g, '_').slice(0, 80);
const MAX_DOT = 300;

function collectItems(data) {
  const items = [], seen = new Set();
  for (const cls of data.classes || []) for (const m of cls.methods || []) {
    const k = `${cls.name}|${cls.category || ''}|${m.meta}|${m.sel}`; if (seen.has(k)) continue; seen.add(k);
    items.push({ item: m, kind: 'method', cls: cls.name + (cls.category ? `(${cls.category})` : ''), label: `${m.meta ? '+' : '-'}[${cls.name}${cls.category ? '(' + cls.category + ')' : ''} ${m.sel}]`, addr: m.addr || (m.imp != null ? Number(m.imp).toString(16) : null) });
  }
  for (const f of data.funcs || []) { if (/^MRV_/.test(f.name)) continue; items.push({ item: f, kind: 'func', cls: null, label: `${f.name}()`, addr: f.addr }); }
  return items;
}

function maps(data) {
  const lib = data.lib || {}; const m = { selrefs: {}, cstrAt: {}, globalAt: {} };
  for (const [a, v] of Object.entries(data.selrefs || {})) m.selrefs[a.toLowerCase()] = typeof v === 'string' ? v : v && (v.sel || v.name) || '';
  for (const s of lib.cstrings || []) m.cstrAt[String(s.a).toLowerCase()] = s.s;
  for (const g of lib.globals || []) m.globalAt[String(g.addr).toLowerCase()] = String(g.name).replace(/^_/, '');
  return m;
}

function build(files, data, name) {
  const lib = data.lib || {}; const items = collectItems(data); const mp = maps(data);
  const pseudoBy = new Map(); const tyRec = new Map(); const errs = [];
  const st = { pseudoFunctions: 0, pseudoLines: 0, cfgFunctions: 0, loops: 0, irreducible: 0, unreachableBlocks: 0, ssaPhis: 0, ssaInlined: 0 };
  const cfgRows = []; let dots = 0;
  for (const e of items) {
    const it = e.item;
    // instruction-level CFG (real basic blocks as Ghidra sees them)
    try {
      const addrN = e.addr && e.addr !== '?' ? parseInt(e.addr, 16) : NaN;
      const g = Array.isArray(it.cfg) && it.cfg.length ? CFG.build(it.cfg, Number.isNaN(addrN) ? parseInt(it.cfg[0].a, 16) : addrN) : null;
      if (g) {
        e.cfgStats = g.stats; st.cfgFunctions++; st.loops += g.stats.loops; st.irreducible += g.stats.irreducible; st.unreachableBlocks += g.stats.unreachable;
        cfgRows.push({ e, s: g.stats });
        if (dots < MAX_DOT && (g.stats.loops || g.stats.blocks > 3)) { files[`Report/cfg/${safe(e.label)}.dot`] = CFG.dot(g, e.label); dots++; }
      }
    } catch (x) { errs.push(`cfg ${e.label}: ${x.message}`); }
    // P-Code -> SSA -> pseudo-code
    try {
      if (Array.isArray(it.pcode) && it.pcode.length) {
        const r = PC.analyze(it, { maps: mp });
        if (r) {
          e.pseudo = r.text; e.pseudoStats = r.stats; st.pseudoFunctions++; st.pseudoLines += r.text.split('\n').length; st.ssaPhis += r.stats.phis || 0; st.ssaInlined += r.stats.inlined || 0;
          if (!e.cfgStats) e.cfgStats = { blocks: r.stats.blocks, loops: r.stats.loops, irreducible: r.stats.irreducible, unreachable: r.stats.unreachable };
          tyRec.set(e.label, { addr: e.addr, rec: TY.analyzeFn(r), e });
        }
      }
    } catch (x) { errs.push(`pcode ${e.label}: ${x.stack ? x.stack.split('\n').slice(0, 2).join(' ') : x}`); }
  }
  // ---- Pseudo/ files ----
  const group = new Map();
  for (const e of items) if (e.pseudo) { const k = e.cls ? e.cls.replace(/\(.*\)/, '') : '_functions'; if (!group.has(k)) group.set(k, []); group.get(k).push(e); }
  const hdr = '// Pseudo-code recovered from Ghidra P-Code via SSA. This is a readable approximation of the machine code, NOT original source and NOT compilable.\n// Registers appear as <reg>_<version>; <reg>_in is the value on entry; phi() joins values from different paths; goto/labels are kept where structured flow was not recovered.\n';
  for (const [k, list] of group) files[`Pseudo/${safe(k)}.pseudo.txt`] = hdr + '\n' + list.map((e) => `// ===== ${e.label}  @0x${e.addr}  ${e.item.c ? '(Ghidra C also recovered)' : '(NO Ghidra C: this is the only recovered logic)'}\n${e.pseudo}`).join('\n');
  // ---- CFG report ----
  const C = ['# Control-flow summary', '', 'Basic blocks, loops (natural loops from back edges), irreducible flow and unreachable blocks, per function. Graphviz sources for functions with loops or >3 blocks are in `Report/cfg/` (render with `dot -Tsvg`).', '',
    `Functions with CFG: **${st.cfgFunctions}** · loops: **${st.loops}** · irreducible regions: **${st.irreducible}** · unreachable blocks: **${st.unreachableBlocks}**`, '', '| Function | Blocks | Edges | Cond. | Loops | Max depth | Exits | Flags |', '|---|---|---|---|---|---|---|---|'];
  for (const { e, s } of cfgRows.sort((a, b) => b.s.blocks - a.s.blocks)) C.push(`| \`${e.label.replace(/\|/g, '\\|')}\` | ${s.blocks} | ${s.edges} | ${s.conditional} | ${s.loops} | ${s.maxLoopDepth} | ${s.exits} | ${[s.irreducible ? 'irreducible' : '', s.unreachable ? 'unreachable blocks' : ''].filter(Boolean).join(', ')} |`);
  files['Report/cfg.md'] = C.join('\n') + '\n';
  // ---- xrefs ----
  let xr = null; try { xr = XR.build(items, lib); Object.assign(files, xr.files); } catch (x) { errs.push('xrefs: ' + x.message); }
  // ---- types ----
  let nStructs = 0, merged = 0;
  try {
    merged = TY.infer(tyRec);
    const out = [], rows = [];
    for (const [label, v] of tyRec) for (const [reg, node] of Object.entries(v.rec.args)) {
      if (!node.fields.size) continue;
      const isSelf = v.e.kind === 'method' && reg === 'x0';
      const nm = `inferred_${safe(label).replace(/_+/g, '_').replace(/^_|_$/g, '')}_${isSelf ? 'self' : reg}`;
      out.push(TY.structC(nm, node, out)); nStructs++;
      rows.push(`| \`${label.replace(/\|/g, '\\|')}\` | ${isSelf ? 'self' : reg} | ${node.fields.size} | \`struct ${nm}\` |`);
    }
    if (out.length) {
      files['Headers/Inferred.h'] = '// Structure layouts INFERRED from memory accesses in the machine code (P-Code SSA).\n// Only fields the code actually touches appear; names are synthetic; sizes come from access width.\n// Not declared types: treat as evidence about layout, not as the original definitions.\n#include <stdint.h>\n\n' + out.join('\n\n') + '\n';
      files['Report/types.md'] = ['# Inferred structure layouts', '', `${nStructs} argument layouts inferred; ${merged} merges across direct calls (callee field usage propagated to the caller's arguments).`, '', 'Field types are access widths only. A field whose loaded value is itself dereferenced is shown as a pointer to a nested inferred struct. For Objective-C methods, \`self\` layouts approximate instance-variable offsets.', '', '| Function | Arg | Fields | Struct |', '|---|---|---|---|', ...rows].join('\n') + '\n';
    }
  } catch (x) { errs.push('types: ' + x.message); }
  // ---- confidence ----
  // ---- analyzer agreement (before confidence: a disagreement lowers the score) ----
  const agreeBy = new WeakMap(); let agreeStats = { agree: 0, partial: 0, disagree: 0, 'single-source': 0 };
  try {
    const actx = AG.contextFor(items, data, mp);
    for (const e of items) { try { e.agreement = AG.compare(e, actx); agreeBy.set(e.item, e.agreement); agreeStats[e.agreement.verdict]++; } catch (x) { errs.push(`agreement ${e.label}: ${x.message}`); } }
    const withAg = items.filter((e) => e.agreement);
    files['Report/agreement.md'] = AG.report(withAg, name, actx);
    files['Report/agreement.json'] = JSON.stringify({ summary: agreeStats, lifterRan: actx.liftRan, functions: withAg.filter((e) => e.agreement.checks.some((c) => c.result === 'disagree')).map((e) => ({ function: e.label, addr: e.addr, verdict: e.agreement.verdict, sources: e.agreement.sources, penalty: e.agreement.penalty, disagreements: e.agreement.checks.filter((c) => c.result === 'disagree') })) }, null, 1);
  } catch (x) { errs.push('agreement: ' + x.message); }
  data._agree = agreeBy;
  const confBy = new WeakMap(); let confText = null, avg = 0, byLvl = {};
  try {
    for (const e of items) { e.conf = CONF.score(e); confBy.set(e.item, e.conf); }
    const r = CONF.report(items, name); files['Report/confidence.md'] = r.text; avg = r.avg; byLvl = r.by;
    files['Report/confidence.json'] = JSON.stringify({ avg: r.avg, by: r.by, total: items.length, functions: items.map((e) => ({ label: e.label, addr: e.addr == null ? null : String(e.addr), kind: e.kind, cls: e.cls || null, score: e.conf.score, capped: !!e.conf.capped, level: e.conf.level, evidence: e.conf.evidence })) });
  } catch (x) { errs.push('confidence: ' + x.message); }
  data._conf = confBy;
  if (errs.length) files['Report/analysis-errors.txt'] = errs.join('\n') + '\n';
  return { ...st, ...(xr ? xr.stats : {}), inferredStructs: nStructs, typeMerges: merged, confidenceAvg: avg, confidenceHigh: byLvl.high || 0, confidenceMedium: byLvl.medium || 0, confidenceLow: byLvl.low || 0, confidenceMinimal: byLvl.minimal || 0, agreeStats, analysisErrors: errs.length };
}

module.exports = { build, collectItems };
