'use strict';
// AI-authored dylibs. The model supplies plain Objective-C/C sources; the server writes them under src/, generates the
// build.sh itself (the model never writes or edits it), and registers the folder as a ready decomp part. After that the
// existing flow applies unchanged: Build, edit_code patches, the compile-error fixer, dylib/zip download.
//   POST /api/staff/decomp/ai/dylib/draft   { name, frameworks?, files:[{path,content}], note? } -> validated preview, writes nothing
//   POST /api/staff/decomp/ai/dylib/create  same body -> { jobID, item:0, part:0, dylibName, files }
const fs = require('fs');
const path = require('path');

const NAME_RE = /^[A-Za-z][A-Za-z0-9_]{1,39}$/;
const FW_RE = /^[A-Za-z][A-Za-z0-9]{1,40}$/;
const PATH_RE = /^[A-Za-z0-9_][A-Za-z0-9_.\-/]{0,79}$/;
const SRC_EXT = /\.(m|mm|c|cpp)$/i;
const OK_EXT = /\.(m|mm|c|cpp|h|hpp|txt|md)$/i;
const MAX_FILES = 30, MAX_TOTAL = 240000, MAX_FILE = 90000;
// frameworks that are always available in the iOS SDK and reasonable for a tweak; others are accepted if the name is sane
const DEFAULT_FW = ['Foundation', 'UIKit'];

// Structured, severity-leveled findings rather than a flat list of strings: 'error' throws (nothing is written),
// 'warn' and 'info' are shown on the draft card so the person can judge the risk themselves before Create project.
function validate(body) {
  const b = body || {};
  const findings = []; // {severity: 'warn'|'info', message}
  const fail = (m) => { throw new Error(m); };
  const name = String(b.name || '').trim();
  if (!NAME_RE.test(name)) fail('name must be 2-40 letters/digits/underscore and start with a letter (it becomes <name>.dylib)');
  const tmpl = b.template ? templates.get(String(b.template)) : null;
  if (b.template && !tmpl) fail(`unknown template "${b.template}"`);
  let frameworks = Array.isArray(b.frameworks) ? b.frameworks.map((x) => String(x).replace(/\.framework$/i, '').trim()).filter(Boolean) : [];
  if (tmpl) frameworks = [...frameworks, ...tmpl.frameworks];
  for (const f of frameworks) if (!FW_RE.test(f)) fail(`bad framework name "${f}"`);
  frameworks = [...new Set([...DEFAULT_FW, ...frameworks])].slice(0, 16);
  if (!Array.isArray(b.files) || !b.files.length) fail('files is empty: supply at least one .m source');
  if (b.files.length > MAX_FILES) fail(`too many files (max ${MAX_FILES})`);
  const seen = new Set(); const files = []; let total = 0;
  for (const f of b.files) {
    let p = String((f && f.path) || '').trim().replace(/^\.?\/+/, '').replace(/^src\//, '');
    const content = String((f && f.content) == null ? '' : f.content);
    if (!PATH_RE.test(p) || p.includes('..') || p.includes('//') || p.endsWith('/')) fail(`bad file path "${f && f.path}"`);
    if (!OK_EXT.test(p)) fail(`"${p}": only .m .mm .c .cpp .h .hpp files are allowed`);
    if (seen.has(p.toLowerCase())) fail(`duplicate file "${p}"`);
    if (!content.trim()) fail(`"${p}" is empty`);
    if (content.length > MAX_FILE) fail(`"${p}" is too large (max ${MAX_FILE} chars): split it`);
    total += content.length; seen.add(p.toLowerCase());
    // security review: things that are legal C/ObjC but have no business in a tweak source, flagged rather than
    // silently shipped
    if (/\b(system|popen|posix_spawn|execv|execve|fork)\s*\(/.test(content)) findings.push({ severity: 'warn', message: `${p}: uses a process-spawning call (system/popen/exec/fork)` });
    if (/\b(NSURLSession|NSURLConnection|CFSocket|SCNetworkReachability)\b/.test(content)) findings.push({ severity: 'info', message: `${p}: makes network calls — confirm that's intended` });
    if (/\b(NSFileManager\s*\*?\s*\w*\s*=\s*\[NSFileManager|unlink|remove)\s*\(/.test(content) && /\/(private\/)?var\/(mobile|root)/.test(content)) findings.push({ severity: 'warn', message: `${p}: touches a system path outside the app sandbox` });
    if (/\bdlopen\s*\(/.test(content)) findings.push({ severity: 'info', message: `${p}: loads another dylib at runtime (dlopen) — make sure that's expected` });
    files.push({ path: p, content: content.endsWith('\n') ? content : content + '\n' });
  }
  if (total > MAX_TOTAL) fail(`sources are too large in total (max ${MAX_TOTAL} chars)`);
  if (!files.some((f) => SRC_EXT.test(f.path))) fail('there is no .m/.mm/.c source file');
  const hasCtor = files.some((f) => /__attribute__\s*\(\s*\(\s*constructor/.test(f.content) || /%ctor/.test(f.content));
  if (!hasCtor) findings.push({ severity: 'warn', message: 'no __attribute__((constructor)) function: nothing runs when the dylib loads unless something calls into it' });
  if (files.some((f) => /%hook|%orig|%end/.test(f.content))) fail('Logos (%hook/%orig) is not supported: write plain Objective-C with method_exchangeImplementations / class_replaceMethod');
  // missing-import heuristic: a header this source clearly needs (by the APIs it uses) but doesn't #import
  for (const f of files) {
    if (/\bUI[A-Z]\w*/.test(f.content) && !/#import\s*<UIKit\/UIKit\.h>/.test(f.content) && !/#import\s*"/.test(f.content)) findings.push({ severity: 'info', message: `${f.path}: uses UIKit types — confirm it #imports <UIKit/UIKit.h>` });
  }
  // template-specific checks (see dylib-templates.js): does the written code actually do the thing the chosen
  // template promised, not just compile?
  if (tmpl) {
    const all = files.map((f) => f.content).join('\n');
    for (const c of tmpl.checks) if (!c.re.test(all)) findings.push({ severity: c.severity, message: `[${tmpl.name} template] ${c.message}` });
  }
  return { name, frameworks, files, note: String(b.note || '').slice(0, 500), template: tmpl ? tmpl.id : null, findings, warnings: findings.map((x) => x.message) };
}

function buildSh(name, frameworks, files) {
  const mm = files.some((f) => /\.(mm|cpp|hpp)$/i.test(f.path));
  const L = [
    '#!/bin/bash',
    '# Generated by the server for an AI-authored dylib. Do not edit: the AI only changes files under src/.',
    '# macOS: xcrun clang. Linux: clang + ld.lld cross-compiling against IOS_SDK_PATH (an extracted iPhoneOS SDK).',
    'set -u',
    'cd "$(dirname "$0")"',
    `NAME=${JSON.stringify(name)}`, 'ARCH=arm64', 'MINOS=13.0', 'INSTALL="@rpath/$NAME.dylib"',
    'if [ "$(uname -s)" = "Darwin" ]; then',
    '  SDK=$(xcrun --sdk iphoneos --show-sdk-path) || exit 1',
    '  CC="xcrun --sdk iphoneos clang"; TARGET_FLAGS="-arch $ARCH"',
    'else',
    '  SDK="${IOS_SDK_PATH:-}"',
    '  if [ -z "$SDK" ] && [ -n "${THEOS:-}" ]; then SDK=$(ls -d "$THEOS"/sdks/iPhoneOS*.sdk 2>/dev/null | sort -V | tail -1); fi',
    '  if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then echo "No iOS SDK found. Set IOS_SDK_PATH." >&2; exit 1; fi',
    '  command -v clang >/dev/null 2>&1 || { echo "clang not found" >&2; exit 1; }',
    '  command -v ld.lld >/dev/null 2>&1 || { echo "ld.lld not found" >&2; exit 1; }',
    '  CC="clang"; TARGET_FLAGS="-target $ARCH-apple-ios$MINOS -fuse-ld=lld"',
    'fi',
    'CFLAGS="$TARGET_FLAGS -isysroot $SDK -miphoneos-version-min=$MINOS -fobjc-arc -fobjc-exceptions -fvisibility=default -O1 -Wall -Wno-unused-function -Wno-unused-variable"',
    'rm -rf obj build-report.txt build-errors.txt; mkdir -p obj; : > build-report.txt',
    'nfail=0',
    // null-delimited end to end (find -print0 / read -d '') so a source path containing a space, newline or glob
    // character is still one file, not several words split on IFS -- the earlier $(find ... | sort) form broke on those.
    'while IFS= read -r -d "" src; do',
    '  o="obj/$(echo "${src%.*}" | tr "/" "_").o"',
    '  if ! $CC $CFLAGS -c "$src" -o "$o" 2> "$o.log"; then echo "FAILED   $src" >> build-report.txt; nfail=$((nfail+1)); rm -f "$o"; fi',
    'done < <(find src -type f \\( -name "*.m" -o -name "*.mm" -o -name "*.c" -o -name "*.cpp" \\) -print0 | sort -z)',
    'for l in obj/*.log; do [ -s "$l" ] && { echo "== $l"; head -30 "$l"; }; done 2>/dev/null | head -200 > build-errors.txt',
    'if [ $nfail -gt 0 ]; then echo "$nfail source file(s) did not compile. See build-errors.txt." >&2; cat build-errors.txt >&2; exit 1; fi',
    'ls obj/*.o >/dev/null 2>&1 || { echo "nothing was compiled" >&2; exit 1; }',
    `LDARGS=(-dynamiclib $TARGET_FLAGS -isysroot $SDK -miphoneos-version-min=$MINOS -install_name "$INSTALL" -fobjc-arc${mm ? ' -lc++' : ''} -lobjc)`,
    ...frameworks.map((f) => `LDARGS+=(-framework ${f})`),
    '$CC "${LDARGS[@]}" obj/*.o -o "$NAME.dylib" 2>> build-errors.txt || { echo "link failed" >&2; cat build-errors.txt >&2; exit 1; }',
    'echo "built $NAME.dylib" >> build-report.txt',
    'echo "built $NAME.dylib"',
    '',
  ];
  return L.join('\n');
}

function writeProject(dir, spec) {
  fs.mkdirSync(path.join(dir, 'src'), { recursive: true });
  for (const f of spec.files) {
    const to = path.join(dir, 'src', f.path);
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.writeFileSync(to, f.content);
  }
  fs.writeFileSync(path.join(dir, 'build.sh'), buildSh(spec.name, spec.frameworks, spec.files), { mode: 0o755 });
  fs.writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify({ name: spec.name, authored: true, frameworks: spec.frameworks, note: spec.note, stats: {} }, null, 2));
}

const pmem = require('./project-memory');
const templates = require('./dylib-templates');

module.exports = function mountAuthored({ app, guard, audit, jobs, newId, outRoot, B = '/api/staff/decomp' }) {
  app.post(`${B}/ai/dylib/draft`, guard, (req, res) => {
    try {
      const s = validate(req.body);
      res.json({ name: s.name, dylibName: `${s.name}.dylib`, frameworks: s.frameworks, warnings: s.warnings, findings: s.findings, files: s.files.map((f) => ({ path: f.path, bytes: f.content.length, content: f.content })) });
    } catch (e) { res.status(400).json({ error: e.message }); }
  });
  app.post(`${B}/ai/dylib/create`, guard, (req, res) => {
    let s; try { s = validate(req.body); } catch (e) { return res.status(400).json({ error: e.message }); }
    const id = newId();
    const dir = path.join(outRoot, id, '0', s.name);
    try { writeProject(dir, s); } catch (e) { return res.status(500).json({ error: `could not write the project: ${e.message}` }); }
    const part = { name: s.name, gate: null, stats: {}, dir: path.relative(outRoot, dir), dylibName: `${s.name}.dylib`, buildState: 'idle', buildLog: [], imported: true, authored: true, genSha: {} };
    jobs.set(id, { id, state: 'done', started: Date.now(), ended: Date.now(), log: [`authored dylib ${s.name} created by the AI`], items: [{ name: `${s.name} (authored)`, state: 'done', parts: [part] }] });
    try {
      pmem.setGoal(dir, s.note || `Build ${s.name}.dylib`);
      pmem.recordDecision(dir, { request: s.note || `Create ${s.name}.dylib`, summary: `Initial project: ${s.files.length} file(s), links ${s.frameworks.join(', ')}`, files: s.files.map((f) => f.path) });
      if (s.findings.length) pmem.recordIssue(dir, 'Review at creation: ' + s.findings.map((f) => `[${f.severity}] ${f.message}`).join(' | '));
    } catch { /* memory is best effort */ }
    try { audit(req, 'ai-dylib-create', `${s.name}.dylib`, `job ${id} files ${s.files.map((f) => f.path).join(',')}`); } catch { /* audit is best effort */ }
    res.json({ jobID: id, item: 0, part: 0, dylibName: part.dylibName, files: s.files.map((f) => f.path), warnings: s.warnings });
  });
};
module.exports._test = { validate, buildSh, writeProject };
