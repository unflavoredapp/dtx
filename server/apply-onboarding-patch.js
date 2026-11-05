#!/usr/bin/env node
"use strict";
// Patches site.js for the Telegram avatar + role-aware /api/auth/me response. Run this from /opt/dct AFTER
// uploading the new social.js and avatars.js next to it:
//   node apply-onboarding-patch.js
// Safe to re-run: it only writes site.js if BOTH exact anchors are found, and it keeps a one-time backup at
// site.js.bak (won't overwrite that backup on a second run, so your original is never lost).
const fs = require("fs");
const path = require("path");

const file = path.join(__dirname, "site.js");
if (!fs.existsSync(file)) { console.error("site.js not found next to this script at", file); process.exit(1); }
let s = fs.readFileSync(file, "utf8");

const oldRequireLine = 'require("./social")({ app, env, SITE_URL, limited, fail, guard, jsonBody, jsonErr, cookieOf, cookieFlags, sign, safeEq, setSession, socialUser, me, userById, betaTg });';
const newRequireBlock = [
  'const avatars = require("./avatars").init({ dataDir: DATA_DIR });',
  "avatars.mount(app);",
  'require("./social")({ app, env, SITE_URL, limited, fail, guard, jsonBody, jsonErr, cookieOf, cookieFlags, sign, safeEq, setSession, socialUser, me, userById, betaTg, avatars });',
].join("\n");

const oldMeLine = 'const me = (u) => (u ? { username: u.username, staff: STAFF.has(u.username.toLowerCase()), beta: betaUser(u), premium: premiumOn(u), premium_until: premiumOn(u) ? u.premium_until : null } : null);';
const newMeBlock = [
  'const dctRoles = require("./lib/decomp/roles").get(DATA_DIR);',
  "const roleOf = (u) => (dctRoles.isAdmin(u.username.toLowerCase()) ? \"admin\" : STAFF.has(u.username.toLowerCase()) ? \"staff\" : \"member\");",
  "const me = (u) => (u ? { username: u.username, staff: STAFF.has(u.username.toLowerCase()), admin: dctRoles.isAdmin(u.username.toLowerCase()), role: roleOf(u), beta: betaUser(u), premium: premiumOn(u), premium_until: premiumOn(u) ? u.premium_until : null, photoUrl: avatars.urlFor(u.id) } : null);",
].join("\n");

let ok = 0;
const results = [];

if (s.includes(oldRequireLine)) { s = s.replace(oldRequireLine, newRequireBlock); ok++; results.push("social require line: patched"); }
else results.push("social require line: NOT FOUND — site.js has likely changed since this was written, send me the current line that starts with require(\"./social\")");

if (s.includes(oldMeLine)) { s = s.replace(oldMeLine, newMeBlock); ok++; results.push("me() line: patched"); }
else results.push("me() line: NOT FOUND — send me the current line that starts with const me = (u) =>");

console.log(results.join("\n"));

if (ok === 2) {
  const bak = file + ".bak";
  if (!fs.existsSync(bak)) fs.writeFileSync(bak, fs.readFileSync(file));
  fs.writeFileSync(file, s);
  console.log("\nsite.js patched (" + ok + "/2). Original saved at site.js.bak. Restart the server to apply.");
} else {
  console.log("\nApplied " + ok + "/2 — site.js was NOT modified. Fix the mismatch above and re-run.");
  process.exit(1);
}
