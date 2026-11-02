// Studio screens (browser side): the repository-first flow.  Import Repo -> Search Apps -> App (dylibs, frameworks, info) -> Decrypt & Inject.
// It reads repos with Repo Studio's own reader (repo-client.js) and hands the final build to Repo Studio's pipeline, so decrypting and injecting
// still run in one place. Plain JS (no build step), styles are added from here (no separate .css file). Exports window.DTSTUDIO.
(function () {
  "use strict";
  var root = typeof window !== "undefined" ? window : globalThis;
  var H = null;                                   // helpers from app.js: { el, api, go, t, refresh }
  var t = function (s, v) { return H && H.t ? H.t(s, v) : String(s).replace(/\{(\w+)\}/g, function (_, k) { return v && v[k] != null ? v[k] : "{" + k + "}"; }); };
  var K_REPOS = "dt-studio-repos", K_ACTIVE = "dt-studio-active", K_PROF = "dt-studio-profiles", K_RUN = "dt-studio-run";

  // ---------- small storage helpers (every read and write is guarded: private windows throw) ----------
  function lsGet(k, d) { try { var v = localStorage.getItem(k); return v ? JSON.parse(v) : d; } catch (e) { return d; } }
  function lsSet(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { /* storage off */ } }
  function ssSet(k, v) { try { sessionStorage.setItem(k, JSON.stringify(v)); } catch (e) { /* storage off */ } }

  // ---------- pure helpers ----------
  function verCmp(a, b) {
    var p = String(a || "").split(/[^0-9]+/).filter(Boolean).map(Number), q = String(b || "").split(/[^0-9]+/).filter(Boolean).map(Number);
    for (var i = 0; i < Math.max(p.length, q.length); i++) { var d = (p[i] || 0) - (q[i] || 0); if (d) return d > 0 ? 1 : -1; }
    return 0;
  }
  var enc = encodeURIComponent;
  var BID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,154}$/;
  function kb(n) { n = Number(n) || 0; return n >= 1048576 ? (n / 1048576).toFixed(1) + " MB" : Math.max(1, Math.round(n / 1024)) + " KB"; }
  function kindOfRepo(url, name) { var s = String(url) + " " + String(name); return /sidestore|sidecommunity/i.test(s) ? "side" : /altstore/i.test(s) ? "alt" : "custom"; }
  function majorOf(v) { var m = /\d+/.exec(String(v || "")); return m ? Number(m[0]) : -1; }
  var HOOKISH = /substrate|substitute|cydia|tweak|inject|hook|ellekit|libhooker/i, SWIFT = /^libswift/i;

  // How well a saved library should work in the version it is going into. This reads what was saved about it (CPU type, name, the version it came
  // from); the deep check of what a library links against runs during the build. level: ok | warn | bad
  function compat(item, setVer, target) {
    var notes = [], level = "ok", bump = function (l) { if (l === "bad" || (l === "warn" && level === "ok")) level = l; };
    if (item.arch && !/arm64/i.test(String(item.arch))) { bump("bad"); notes.push(t("No ARM64 code ({arch})", { arch: item.arch })); }
    if (SWIFT.test(item.name)) { bump("warn"); notes.push(t("Swift runtime library: the new version normally ships its own.")); }
    if (HOOKISH.test(item.name)) { bump("warn"); notes.push(t("Hooking library: check it supports this iOS release.")); }
    if (setVer && target && majorOf(setVer) >= 0 && majorOf(target) >= 0 && majorOf(setVer) !== majorOf(target)) { bump("warn"); notes.push(t("Saved from v{a}; the app moved to v{b}.", { a: setVer, b: target })); }
    else if (setVer && target && verCmp(setVer, target) !== 0) notes.push(t("Saved from v{a}.", { a: setVer }));
    if (item.manual) notes.push(t("Added by hand."));
    if (!notes.length) notes.push(t("Looks compatible."));
    return { level: level, notes: notes };
  }

  // ---------- recent repos and saved injection profiles ----------
  var DEFAULT_REPO = "https://delvek.net/repo.json";
  // until the person has saved a list of their own, the Delvek repo is the one searched
  function repos() { var r = lsGet(K_REPOS, null); if (r === null) return [{ url: DEFAULT_REPO, name: "Delvek", icon: "", count: 0, at: 0 }]; return Array.isArray(r) ? r.filter(function (x) { return x && typeof x.url === "string"; }) : []; }
  function onlyDefault() { var r = repos(); return !r.length || r.every(function (x) { return x.url === DEFAULT_REPO; }); }
  // a reminder to add repos of their own (shown while only the default one, or none, is there)
  function repoNotice() {
    if (!onlyDefault()) return null;
    var none = !repos().length, add = mk("a", { class: "st-mb pri", href: "/studio/import", "data-nav": "", text: t("Add a repo") });
    return mk("div", { class: "st-rn", role: "status" }, mk("span", { class: "st-tt" }, mk("b", { text: none ? t("No repos added") : t("Searching the Delvek repo") }), mk("small", { text: none ? t("Add a repo to search for apps.") : t("Add your own repo to find more apps.") })), add);
  }
  // a repo's own picture, else its first app's, else its site's favicon (the tile with a letter stays if none loads)
  function repoPic(src) {
    if (src.icon) return src.icon; var a = (src.apps || []).filter(function (x) { return x.icon; })[0]; if (a) return a.icon;
    try { return "https://" + new URL(src.url).host + "/favicon.ico"; } catch (e) { return ""; }
  }
  function rememberRepo(src) {
    var list = repos().filter(function (x) { return x.url !== src.url; }); list.unshift({ url: src.url, name: src.name, icon: repoPic(src), count: src.apps.length, at: Date.now() });
    lsSet(K_REPOS, list.slice(0, 12)); lsSet(K_ACTIVE, src.url);
  }
  function profilesOf(bid) { var all = lsGet(K_PROF, {}); return all && Array.isArray(all[bid]) ? all[bid] : []; }
  function saveProfile(bid, p) { var all = lsGet(K_PROF, {}) || {}, l = (Array.isArray(all[bid]) ? all[bid] : []).filter(function (x) { return x.name !== p.name; }); l.unshift(p); all[bid] = l.slice(0, 10); lsSet(K_PROF, all); }
  function dropProfile(bid, name) { var all = lsGet(K_PROF, {}) || {}; all[bid] = (all[bid] || []).filter(function (x) { return x.name !== name; }); lsSet(K_PROF, all); }

  // ---------- loading ----------
  var repoCache = {};
  function loadScript(src) { return new Promise(function (res, rej) { var s = document.createElement("script"); s.src = src; s.onload = res; s.onerror = function () { rej(new Error(t("Something went wrong."))); }; document.head.appendChild(s); }); }
  function repoLib() { return root.DTREPO ? Promise.resolve() : loadScript("/repo.js?v=56"); }
  function loadRepo(url) {
    if (repoCache[url]) return Promise.resolve(repoCache[url]);
    return repoLib().then(function () { return fetch("/api/repo/fetch?url=" + enc(url), { credentials: "same-origin" }); }).then(function (r) {
      return r.json().catch(function () { return null; }).then(function (j) {
        if (!r.ok || !j || !j.ok) throw new Error(j && j.error ? t(j.error) : t("Couldn't reach that repo."));
        var src; try { src = root.DTREPO.normalizeSource(j.source); } catch (e) { throw new Error(t(e.message)); }
        src.url = url; repoCache[url] = src; return src;
      });
    });
  }

  // everything the app screens need about one app
  var appCache = {}, UI = {};                     // UI[bid]: what the person has picked so far (survives going back and forth)
  function loadApp(bid, qs) {
    var repoUrl = qs.get("repo") || lsGet(K_ACTIVE, ""), aidQ = qs.get("id") || "";
    return Promise.all([
      H.api("GET", "/api/dylibs/app/" + enc(bid)),
      H.api("GET", "/api/repo/upstream?bids=" + enc(bid)),
      repoUrl ? loadRepo(repoUrl).catch(function () { return null; }) : Promise.resolve(null)
    ]).then(function (r) {
      var sets = (r[0] && r[0].ok ? r[0].sets : []).slice().sort(function (a, b) { return verCmp(b.version, a.version) || (b.created || 0) - (a.created || 0); });
      var up = r[1] && r[1].ok && r[1].items && r[1].items[bid] || {}, store = up.store || null, src = r[2];
      var ra = src ? (src.apps.filter(function (a) { return a.bid.toLowerCase() === bid.toLowerCase(); })[0] || null) : null;
      var s0 = sets[0] || {};
      var A = {
        bid: bid, name: (ra && ra.name) || (store && store.name) || s0.name || bid, icon: (ra && ra.icon) || (store && store.icon) || s0.icon || "",
        aid: aidQ || (store && store.id) || s0.aid || "", repo: src ? { url: src.url, name: src.name } : null, repoApp: ra,
        installed: ra && ra.current ? ra.current.version : (s0.version || ""), installedFrom: ra && ra.current ? "repo" : (s0.version ? "saved" : ""),
        latest: store ? store.ver : "", minos: store ? store.minos : "", storeUrl: store ? store.store : "", updated: store ? store.updated : "",
        sets: sets, library: up.library || []
      };
      appCache[bid] = A; return A;
    });
  }
  // the saved set that matches a version best: the same version, else the newest one
  function setFor(A, ver) { return A.sets.filter(function (s) { return ver && verCmp(s.version, ver) === 0; })[0] || A.sets[0] || null; }
  function stateOf(A) {
    var u = UI[A.bid]; if (u) return u;
    var s = setFor(A, A.installed), sel = {}; (s ? s.items : []).forEach(function (i) { if (compat(i, s.version, A.latest || A.installed).level !== "bad") sel[i.name] = true; });   // items that can't run on this CPU start unchecked
    var target = A.latest || A.installed || "";
    return (UI[A.bid] = { setId: s ? s.id : "", sel: sel, ver: target, tab: "dylibs", custom: [], inj: { base: "exe", folder: "Frameworks/" }, strip: {}, opt: { decrypt: true, resign: true, clean: true, preserve: false } });
  }
  function targetOf(A) { return A.latest || A.installed || ""; }

  // ---------- styles (added once) ----------
  function css() {   // the page's security policy allows styles only from the site itself, so they come as a file (/studio.css), never inline
    if (document.getElementById("st-css")) return;
    var l = document.createElement("link"); l.id = "st-css"; l.rel = "stylesheet"; l.href = "/studio.css?v=4"; document.head.appendChild(l);
  }

  // like the page's el(), but a style prop is applied through the CSSOM (an inline style attribute is blocked by the site's security policy)
  function mk(tag, props) {
    var st = null, p = props;
    if (props && props.style != null) { p = {}; for (var k in props) if (k !== "style") p[k] = props[k]; st = props.style; }
    var n = H.el.apply(null, [tag, p].concat([].slice.call(arguments, 2)));
    if (st) n.style.cssText = st;
    return n;
  }

  // ---------- drawing helpers ----------
  var ICONS = {
    layers: "M12 3l9 5-9 5-9-5zM3 12.500l9 5 9-5M3 16.500l9 5 9-5", search: "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20 20l-4-4", chev: "M9 6l6 6-6 6", back: "M15 6l-6 6 6 6",
    link: "M10 14a4 4 0 0 0 5.700 0l3-3a4 4 0 0 0-5.700-5.700l-1 1M14 10a4 4 0 0 0-5.700 0l-3 3a4 4 0 0 0 5.700 5.700l1-1", info: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 11v5M12 8h.01",
    plus: "M12 5v14M5 12h14", check: "M5 12.500l4.500 4.500L19 7.500", x: "M6 6l12 12M18 6L6 18", up: "M12 19V5M6 11l6-6 6 6", file: "M7 3h7l5 5v13H7zM14 3v5h5", bookmark: "M7 4h10v17l-5-4-5 4z",
    wrench: "M14 7a4 4 0 0 1 5 5l-8 8a2 2 0 0 1-3-3l8-8z", lock: "M6 11h12v9H6zM8 11V8a4 4 0 0 1 8 0v3", key: "M8 15a4 4 0 1 1 3.400-6H21v3h-2v2h-3v-2h-4.600A4 4 0 0 1 8 15z",
    db: "M4 6c0-1.700 3.600-3 8-3s8 1.300 8 3-3.600 3-8 3-8-1.300-8-3zM4 6v6c0 1.700 3.600 3 8 3s8-1.300 8-3V6M4 12v6c0 1.700 3.600 3 8 3s8-1.300 8-3v-6",
    cube: "M12 3l8 4.500v9L12 21l-8-4.500v-9zM4 7.500l8 4.500 8-4.500M12 12v9", log: "M7 3h8l4 4v14H7zM15 3v4h4M10 12h6M10 16h6", download: "M12 4v11M7 11l5 5 5-5M5 20h14", share: "M12 16V4M7 9l5-5 5 5M5 14v6h14v-6", phone: "M8 3h8a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zM11 18h2", refresh: "M20 11a8 8 0 1 0-2.300 5.700M20 5v6h-6", sliders: "M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M14 4v4M8 10v4M16 16v4", code: "M9 7l-5 5 5 5M15 7l5 5-5 5", cancel: "M6 6h12v12H6z", bars: "M5 20V10M12 20V4M19 20v-7", users: "M9 11a3.500 3.500 0 1 0 0-7 3.500 3.500 0 0 0 0 7zM2.500 20c0-3.300 2.800-5.500 6.500-5.500s6.500 2.200 6.500 5.500M16.500 5a3.500 3.500 0 0 1 0 6.500M18 14.800c2.300.6 3.800 2.400 3.800 5.200", people: "M9 11a3.500 3.500 0 1 0 0-7 3.500 3.500 0 0 0 0 7zM2.500 20c0-3.300 2.800-5.500 6.500-5.500s6.500 2.200 6.500 5.500M17 8a3 3 0 1 1 0 6M19 20c0-2 .8-3.200 2-3.800", cal: "M4 6h16v14H4zM4 10h16M8 3v4M16 3v4", fw: "M4 4h16v16H4zM4 9h16M9 9v11", play: "M7 4l13 8-13 8z"
  };
  function ic(name, size) {
    var NS = "http://www.w3.org/2000/svg", s = document.createElementNS(NS, "svg"), p = document.createElementNS(NS, "path");
    s.setAttribute("viewBox", "0 0 24 24"); s.setAttribute("width", size || 20); s.setAttribute("height", size || 20); s.setAttribute("aria-hidden", "true");
    p.setAttribute("d", ICONS[name]); p.setAttribute("fill", name === "play" ? "currentColor" : "none"); p.setAttribute("stroke", name === "play" ? "none" : "currentColor");
    p.setAttribute("stroke-width", "2"); p.setAttribute("stroke-linecap", "round"); p.setAttribute("stroke-linejoin", "round"); s.appendChild(p); return s;
  }
  // app icons: the repo's own picture first, then the App Store's, then a letter, so a tile is never an empty square
  var iconCache = {}, iconWait = [], iconTimer = 0;
  function https(u) { return String(u || "").replace(/^http:\/\//i, "https://"); }       // the site only loads pictures over https
  function flushIcons() {
    var w = iconWait.splice(0, 40); if (iconWait.length) iconTimer = setTimeout(flushIcons, 60); if (!w.length) return;
    H.api("GET", "/api/repo/upstream?bids=" + w.map(function (x) { return enc(x.bid); }).join(",")).then(function (j) {
      w.forEach(function (x) { var u = j && j.ok && j.items && j.items[x.bid]; x.res(u && u.store && u.store.icon || ""); });
    }, function () { w.forEach(function (x) { x.res(""); }); });
  }
  function storeIcon(bid) {
    if (!bid || !BID_RE.test(bid)) return Promise.resolve("");
    var k = bid.toLowerCase(); if (iconCache[k]) return iconCache[k];
    return (iconCache[k] = new Promise(function (res) { iconWait.push({ bid: bid, res: res }); clearTimeout(iconTimer); iconTimer = setTimeout(flushIcons, 60); }));
  }
  function mkImg(src, size, cls) { return mk("img", { class: cls, src: https(src), alt: "", width: String(size), height: String(size), loading: "lazy", referrerpolicy: "no-referrer" }); }
  // src may be empty or broken: tries the store icon for bid, then puts `ph` (a placeholder element) in its place
  function iconOr(src, bid, ph, size, cls) {
    var tried = false, img = null;
    function fail() {
      if (tried) { if (img && img.parentNode) img.replaceWith(ph); return; } tried = true;
      storeIcon(bid).then(function (u) { if (u && u !== src && img) { img.src = https(u); } else if (img && img.parentNode) img.replaceWith(ph); });
    }
    if (!src) { storeIcon(bid).then(function (u) { if (u && ph.parentNode) { img = mkImg(u, size, cls); img.addEventListener("error", function () { if (img.parentNode) img.replaceWith(ph); }); ph.replaceWith(img); } }); return ph; }
    img = mkImg(src, size, cls); img.addEventListener("error", fail); return img;
  }
  function icon(src, bid, name) { return iconOr(src, bid, mk("div", { class: "st-ic ph", text: String(name || bid || "?").replace(/^\W+/, "").charAt(0).toUpperCase() }), 44, "st-ic"); }
  function toast(msg) { var n = mk("div", { class: "st-toast", role: "status", text: msg }); document.body.appendChild(n); setTimeout(function () { if (n.parentNode) n.remove(); }, 2400); }
  function head(title, href) {
    var a = mk("a", { class: "st-bar", href: href || "/", "data-nav": "" }); a.appendChild(ic("back", 22)); a.appendChild(mk("span", { text: title })); return a;
  }
  function appHead(A) {
    var el = mk;
    return el("div", { class: "st-panel", style: "padding:14px" }, el("div", { style: "display:flex;gap:12px;align-items:center" }, icon(A.icon, A.bid, A.name),
      el("span", { class: "st-tt" }, el("b", { text: A.name, style: "font-size:17px;white-space:normal" }), el("small", { text: A.bid }))));
  }
  function sw(on, onChange) { var i = mk("input", { type: "checkbox", class: "st-sw", role: "switch" }); i.checked = !!on; i.addEventListener("change", function () { onChange(i.checked); }); return i; }

  // ---------- HOME: Changelog and Platform Stats (the search bar above them is the site's own) ----------
  var TONES = [["#2fa866", "layers"], ["#7c4dff", "wrench"], ["#2f7bf0", "cube"], ["#e0702a", "up"], ["#6b6f7a", "wrench"]], statTimer = 0;
  function spark(series, color) {
    var NS = "http://www.w3.org/2000/svg", s = document.createElementNS(NS, "svg"), n = series.length, w = 84, hh = 30, mx = Math.max.apply(null, series.concat([1])), mn = Math.min.apply(null, series.concat([0]));
    s.setAttribute("viewBox", "0 0 " + w + " " + hh); s.setAttribute("width", w); s.setAttribute("height", hh); s.setAttribute("aria-hidden", "true"); s.setAttribute("class", "st-spark");
    var pts = series.map(function (v, i) { return (n > 1 ? i * (w - 4) / (n - 1) + 2 : w / 2).toFixed(1) + "," + (hh - 3 - (mx === mn ? 0 : (v - mn) / (mx - mn) * (hh - 8))).toFixed(1); });
    var area = document.createElementNS(NS, "polygon"), line = document.createElementNS(NS, "polyline");
    area.setAttribute("points", pts.join(" ") + " " + (w - 2) + "," + hh + " 2," + hh); area.setAttribute("fill", color); area.setAttribute("opacity", ".16");
    line.setAttribute("points", pts.join(" ")); line.setAttribute("fill", "none"); line.setAttribute("stroke", color); line.setAttribute("stroke-width", "2"); line.setAttribute("stroke-linecap", "round"); line.setAttribute("stroke-linejoin", "round");
    s.appendChild(area); s.appendChild(line); return s;
  }
  // typing in the site's search box shows matching apps right under it and tucks the changelog and stats away
  var liveOff = null;
  function liveTyping(box, cards) {
    var inp = document.getElementById("q"); if (liveOff) liveOff(); liveOff = null; if (!inp) return;
    var S = null, timer = 0, last = null;
    function apply() {
      if (!box.isConnected || !document.body.classList.contains("v-home")) return;
      var v = inp.value.trim(); if (v === last) return; last = v;
      if (!v) { box.hidden = true; cards.hidden = false; return; }
      cards.hidden = true; box.hidden = false;
      if (!S) S = search(box, new URLSearchParams(), H, { bare: true });
      S.set(v);
    }
    function onIn() { clearTimeout(timer); if (!inp.value.trim()) { apply(); return; } timer = setTimeout(apply, 220); }
    inp.addEventListener("input", onIn);
    liveOff = function () { clearTimeout(timer); inp.removeEventListener("input", onIn); };
    if (inp.value.trim()) apply();
  }
  function home(host, h) {
    H = h; css(); clearInterval(statTimer);
    var el = mk, log = el("div", { class: "st-panel st-cl" }), ps = el("div", { class: "st-panel st-ps" });
    var cards = el("div", { class: "st-two" }, log, ps), liveBox = el("div", { class: "st-livebox" }); liveBox.hidden = true;
    host.replaceChildren(repoNotice(), cards, liveBox);
    liveTyping(liveBox, cards);
    // changelog: the newest entry of the site's own What's new list
    log.appendChild(el("div", { class: "st-ch" }, ic("log", 26), el("h3", { text: t("Changelog") })));
    H.api("GET", "/api/changelog").then(function (j) {
      var e = j && j.ok && j.entries && j.entries[0]; if (!e) { log.appendChild(el("p", { class: "st-empty", text: t("Nothing here yet.") })); return; }
      var d = new Date(e.date + "T12:00:00"), fresh = Date.now() - d.getTime() < 15 * 86400000, when = e.date;
      try { when = new Intl.DateTimeFormat(root.I18N && root.I18N.lang ? root.I18N.lang() : undefined, { year: "numeric", month: "short", day: "numeric" }).format(d); } catch (x) { /* plain date */ }
      log.appendChild(el("div", { class: "st-when" }, fresh ? el("span", { class: "st-new", text: t("NEW") }) : null, el("span", { text: when })));
      var rows = el("div", { class: "st-cl-rows" });
      (e.items || []).slice(0, 5).forEach(function (x, i) {
        var m = /^(.{12,70}?[.:])\s+(.+)$/.exec(String(x)), ttl = m ? m[1].replace(/[.:]$/, "") : String(x), desc = m ? m[2] : "", tone = TONES[i % TONES.length];
        var a = el("a", { class: "st-cr", href: "/changelog", "data-nav": "" }, el("span", { class: "st-ct", style: "background:" + tone[0] }, ic(tone[1], 20)),
          el("span", { class: "st-cx" }, el("b", { text: ttl }), desc ? el("small", { text: desc }) : null)); a.appendChild(ic("chev", 16)); rows.appendChild(a);
      });
      log.appendChild(rows);
      var all = el("a", { class: "st-all", href: "/changelog", "data-nav": "" }, ic("log", 18), el("span", { text: t("View Full Changelog") })); all.appendChild(ic("chev", 18)); log.appendChild(all);
    });
    // platform stats: real counts from /api/stats (visitors are counted from the day this was switched on)
    var live = el("span", { class: "st-live", text: t("LIVE") });
    ps.appendChild(el("div", { class: "st-ch" }, ic("bars", 26), el("h3", { text: t("Platform Stats") }), live));
    var box = el("div", { class: "st-srows" }); ps.appendChild(box);
    var DEFS = [["decrypts", "lock", t("Total Decrypts"), ""], ["injections", "layers", t("Dylib Injections"), ""], ["visitors", "users", t("Total Visitors"), ""], ["day", "cal", t("Visitors (24h)"), ""], ["now", "people", t("Online Now"), "g"]];
    function paint(j) {
      box.replaceChildren.apply(box, DEFS.map(function (d) {
        var v = j[d[0]] || { total: 0, series: [] }, green = d[3] === "g";
        return el("div", { class: "st-sr" + (green ? " g" : "") }, el("span", { class: "st-si" }, ic(d[1], 22)), el("span", { class: "st-sn" }, el("b", { text: Number(v.total || 0).toLocaleString() }), el("small", { text: d[2] })), spark(v.series && v.series.length ? v.series : [0, 0], green ? "#47d18c" : "#f0913f"));
      }));
    }
    function tick() {
      if (!document.body.classList.contains("v-home") || !box.isConnected) { clearInterval(statTimer); return; }
      H.api("GET", "/api/stats").then(function (j) { if (j && j.ok) { paint(j); live.hidden = false; } else if (!box.children.length) { live.hidden = true; box.appendChild(el("p", { class: "st-empty", text: t("Stats aren't available right now.") })); } });
    }
    tick(); statTimer = setInterval(tick, 30000);
    memberWall(ps, log);
  }

  // Members who chose to be on the home page: small name chips, each in its owner's colour on an animated background. Only opted-in names are ever shown.
  function memberWall(ps, log) {
    var el = mk, chips = el("div", { class: "st-mw-list" }), ctl = el("div", { class: "st-mw-ctl" }), open = false, total = 0;
    var more = el("button", { class: "st-mw-more", type: "button", "aria-expanded": "false", "aria-label": t("Show all") }, el("span", { text: "" }), ic("chev", 16)); more.disabled = true;
    var boxEl = el("div", { class: "st-mw-box" }, el("div", { class: "st-mw-h" }, el("span", { class: "st-si" }, ic("people", 20)), el("b", { text: t("Members") }), more), chips, ctl);
    ps.appendChild(boxEl);
    // collapsed, the names fill only the room the Changelog card already makes (whole rows, so nothing is cut in half); the chevron opens the full list
    function fit() {
      if (!ps.offsetParent || !chips.children.length) return;
      more.querySelector("span").textContent = total ? String(total) : "";
      more.className = "st-mw-more" + (open ? " open" : ""); more.setAttribute("aria-expanded", String(open)); more.setAttribute("aria-label", open ? t("Show less") : t("Show all"));
      if (open) { chips.style.maxHeight = "none"; more.disabled = false; return; }
      chips.style.maxHeight = "none"; var all = chips.scrollHeight; chips.style.maxHeight = "0px";
      var cs = getComputedStyle(ps), free = ps.getBoundingClientRect().bottom - parseFloat(cs.paddingBottom) - parseFloat(cs.borderBottomWidth) - boxEl.getBoundingClientRect().bottom, rows = 0;
      Array.prototype.forEach.call(chips.children, function (c) { var b = c.offsetTop + c.offsetHeight; if (b <= free && b > rows) rows = b; });
      if (all <= free) { chips.style.maxHeight = "none"; more.disabled = true; } else { chips.style.maxHeight = rows + "px"; more.disabled = false; }
    }
    more.addEventListener("click", function () { open = !open; fit(); });
    if (root.ResizeObserver) { var busy = false, ro = new root.ResizeObserver(function () { if (busy) return; busy = true; requestAnimationFrame(function () { try { fit(); } finally { busy = false; } }); }); ro.observe(log); ro.observe(ps); }
    root.addEventListener("resize", fit);
    function chip(m) { var c = el("span", { class: "st-mw st-mw-" + m.s, text: m.u }); c.style.color = m.c; return c; }
    function load() {
      H.api("GET", "/api/members").then(function (j) {
        if (!j || !j.ok) { chips.replaceChildren(); return; }
        total = j.total | 0;
        chips.replaceChildren.apply(chips, j.items.length ? j.items.map(chip) : [el("p", { class: "st-empty", text: t("Be the first to add your name.") })]);
        fit();
      });
    }
    function mine() {
      H.api("GET", "/api/members/me").then(function (j) {
        if (!j || !j.ok) { ctl.replaceChildren(); return; }                                    // not logged in: no button
        var st = { c: j.c, s: j.s }, picker = el("div", { class: "st-mw-pick", hidden: "" }), prev = el("span", { class: "st-mw" }), msg = el("small", { class: "st-mw-msg", role: "status" });
        var open = el("button", { class: "st-mw-btn", type: "button", text: j.joined ? t("Edit my name") : t("Add my name") });
        function paint() { prev.className = "st-mw st-mw-" + st.s; prev.style.color = st.c; prev.textContent = t("your name"); }
        var cs = el("div", { class: "st-mw-sw" }, j.colors.map(function (c) { var b = el("button", { type: "button", class: "st-mw-c", "aria-label": c }); b.style.background = c; b.addEventListener("click", function () { st.c = c; paint(); }); return b; }));
        var ss = el("div", { class: "st-mw-sw" }, j.styles.map(function (s) { var b = el("button", { type: "button", class: "st-mw-s st-mw-" + s, "aria-label": s }); b.addEventListener("click", function () { st.s = s; paint(); }); return b; }));
        var save = el("button", { class: "st-mw-btn pri", type: "button", text: t("Save") }), off = el("button", { class: "st-mw-btn", type: "button", text: t("Remove") }); off.hidden = !j.joined;
        function send(body) { msg.textContent = ""; H.api("POST", "/api/members/me", body).then(function (r) { if (!r || !r.ok) { msg.textContent = t((r && r.error) || "Couldn't save that."); return; } picker.hidden = true; open.textContent = r.joined ? t("Edit my name") : t("Add my name"); off.hidden = !r.joined; load(); }); }
        save.addEventListener("click", function () { send({ join: true, c: st.c, s: st.s }); }); off.addEventListener("click", function () { send({ join: false }); });
        open.addEventListener("click", function () { picker.hidden = !picker.hidden; });
        picker.appendChild(el("p", { class: "st-mw-p", text: t("Your username is shown to everyone on the home page while you're listed.") })); picker.appendChild(prev); picker.appendChild(cs); picker.appendChild(ss); picker.appendChild(el("div", { class: "st-mw-row" }, save, off)); picker.appendChild(msg);
        paint(); ctl.replaceChildren(open, picker);
      });
    }
    load(); mine();
  }

  // ---------- IMPORT REPO ----------
  function importRepo(host, h) {
    H = h; css();
    var el = mk, pre = new URLSearchParams(location.search).get("url") || "";
    var inp = el("input", { type: "url", inputmode: "url", placeholder: "https://example.com/repo.json", autocapitalize: "none", autocorrect: "off", spellcheck: "false", maxlength: "500", "aria-label": t("Repository link") });
    inp.value = pre;
    var fld = el("label", { class: "st-fld" }, ic("link", 20), inp), msg = el("p", { class: "st-msg", role: "status" }), go = el("button", { class: "st-go", type: "button", text: t("Import Repo") });
    var say = function (s, err) { msg.textContent = s || ""; msg.className = "st-msg" + (err ? " err" : ""); };
    function run() {
      var u = inp.value.trim(); if (!/^https:\/\//i.test(u)) { say(t("Use a full https:// link to the repo's JSON file."), true); return; }
      go.disabled = true; say(t("Reading the repo…"));
      loadRepo(u).then(function (src) { rememberRepo(src); H.go("/studio/search?tab=apps&scope=" + enc(src.url)); }).catch(function (e) { go.disabled = false; say(e.message, true); });
    }
    go.addEventListener("click", run); inp.addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); run(); } });
    function src(kind, name, sub, letter) { return el("div", { class: "st-sub" }, el("span", { class: "st-tile " + kind, text: letter }), el("span", {}, el("b", { text: name }), el("small", { text: sub }))); }
    var recent = repos(), recentBox = null;
    if (recent.length) {
      recentBox = el("div", { class: "st-panel", style: "overflow:hidden" });
      recent.forEach(function (r) { var k = kindOfRepo(r.url, r.name); recentBox.appendChild(el("a", { class: "st-rr", href: "/studio/search?tab=apps&scope=" + enc(r.url), "data-nav": "" }, iconOr(r.icon || "", "", el("span", { class: "st-tile " + k, text: k === "alt" ? "A" : k === "side" ? "S" : "D" }), 40, "st-ic"), el("span", { style: "min-width:0" }, el("b", { text: r.name }), el("small", { text: r.url })), el("span", { class: "st-ok" }, ic("check", 14)))); });
    }
    host.replaceChildren(el("div", { class: "st" }, head(t("Import Repo"), "/studio/search"),
      el("div", { class: "st-panel" }, el("div", { class: "st-hero" }, el("span", { class: "st-ico" }, ic("layers", 44)), el("h3", { text: t("Import Repository") }),
        el("p", { text: t("Add an AltStore, SideStore or custom IPA repo to browse and manage apps.") })), fld, go, msg),
      el("div", { class: "st-panel" }, el("h3", { class: "st-sech", text: t("Supported Sources") }),
        src("alt", "AltStore", t("AltStore JSON sources"), "A"), src("side", "SideStore", t("SideStore JSON sources"), "S"), src("custom", t("Custom Repo"), t("Any compatible IPA repository"), "R")),
      el("div", { class: "st-panel" }, el("div", { class: "st-note" }, ic("info", 18), el("span", { text: t("Repos are read-only. Apps, versions, dylibs and frameworks will be indexed for browsing and injection.") }))),
      recentBox ? el("div", { class: "st-h" }, el("h2", { text: t("Recent Repos") })) : null, recentBox));
    if (pre) run(); else inp.focus();
  }

  // ---------- SEARCH: All Results / Apps / Repos / Versions ----------
  function search(host, qs, h, opts) {
    H = h; css(); var bare = !!(opts && opts.bare);
    var el = mk, q = (qs.get("q") || "").trim(), tab = ["all", "apps", "repos", "versions"].indexOf(qs.get("tab")) >= 0 ? qs.get("tab") : "all", scope = qs.get("scope") || "", seq = 0, R = { apps: [], repos: [], versions: [] };
    var inp = el("input", { type: "search", value: q, placeholder: t("Enter app name, ID or store link"), autocomplete: "off", autocapitalize: "none", autocorrect: "off", spellcheck: "false", maxlength: "300", enterkeyhint: "search", "aria-label": t("Search apps") });
    var clr = el("button", { class: "st-x", type: "button", "aria-label": t("Clear") }), sub = el("button", { class: "st-sub2", type: "submit", "aria-label": t("Search") });
    clr.appendChild(ic("x", 14)); sub.appendChild(ic("up", 22)); sub.firstChild.style.transform = "rotate(90deg)"; clr.hidden = !q;
    var form = el("form", { class: "st-find", role: "search" }, el("label", { class: "st-fl" }, ic("search", 22), inp, clr), sub);
    var seg = el("div", { class: "st-seg four", role: "tablist" }), list = el("div", { class: "st-list" }), scopeNote = el("div", {});
    function sync() { if (bare) return; var p = new URLSearchParams(); if (q) p.set("q", q); if (tab !== "all") p.set("tab", tab); if (scope) p.set("scope", scope); try { history.replaceState(history.state, "", "/studio/search" + (p.toString() ? "?" + p : "")); } catch (e) { /* ignore */ } }
    function n(k) { return k === "all" ? R.apps.length + R.repos.length + R.versions.length : R[k].length; }
    function drawTabs() {
      var L = { all: t("All Results"), apps: t("Apps"), repos: t("Repos"), versions: t("Versions") };
      seg.replaceChildren.apply(seg, ["all", "apps", "repos", "versions"].map(function (k) { var b = el("button", { type: "button", role: "tab", "aria-selected": String(tab === k), text: L[k] + " (" + n(k) + ")" }); b.addEventListener("click", function () { tab = k; sync(); drawTabs(); drawList(); }); return b; }));
    }
    function pill(text, cls, arrow) { var s = el("span", { class: "st-pill" + (cls ? " " + cls : "") }); if (arrow) s.appendChild(ic("up", 11)); s.appendChild(document.createTextNode(text)); return s; }
    function appRow(x) {
      var p = new URLSearchParams(); if (x.aid) p.set("id", x.aid); if (x.repo) p.set("repo", x.repo); if (q) p.set("q", q);
      var pills = [];
      if (x.inst && x.sver && verCmp(x.sver, x.inst) > 0) pills.push(pill("v" + x.inst + " (" + t("Installed") + ")", "grey"), pill("v" + x.sver + " (" + t("Newer") + ")", "ok", true));
      else if (x.inst) pills.push(pill("v" + x.inst + " (" + t("Installed") + ")", "grey"));
      else if (x.sver) pills.push(pill("v" + x.sver, ""));
      var a = el("a", { class: "st-app", href: "/studio/app/" + enc(x.bid) + (p.toString() ? "?" + p : ""), "data-nav": "" }, icon(x.icon, x.bid, x.name),
        el("span", { class: "st-tt" }, el("b", { text: x.name }), el("small", { text: x.bid }), pills.length ? el("span", { class: "st-chips" }, pills) : null));
      a.appendChild(ic("chev", 18)); return a;
    }
    function repoRow(r) {
      var k = kindOfRepo(r.url, r.name), a = el("a", { class: "st-app", href: "/studio/search?tab=apps&scope=" + enc(r.url) + (q ? "&q=" + enc(q) : ""), "data-nav": "" }, iconOr(r.icon || "", "", el("span", { class: "st-tile " + k, text: k === "alt" ? "A" : k === "side" ? "S" : "D", style: "width:44px;height:44px;border-radius:11px" }), 44, "st-ic"),
        el("span", { class: "st-tt" }, el("b", { text: r.name }), el("small", { text: r.url }), el("span", { class: "st-chips" }, pill(q ? t("{n} matching", { n: r.match }) : t("{n} apps", { n: r.count }), "grey"))));
      a.appendChild(ic("chev", 18)); return a;
    }
    function verRow(v) {
      var p = new URLSearchParams(); if (v.aid) p.set("id", v.aid); if (q) p.set("q", q);
      var a = el("a", { class: "st-app", href: "/studio/app/" + enc(v.bid) + (p.toString() ? "?" + p : ""), "data-nav": "" }, icon(v.icon, v.bid, v.name),
        el("span", { class: "st-tt" }, el("b", { text: v.name }), el("small", { text: v.bid }), el("span", { class: "st-chips" }, pill("v" + v.ver, ""), pill(t("In library"), "ok"))));
      a.appendChild(ic("chev", 18)); return a;
    }
    function drawList() {
      var kids = [], sec = function (l, arr) { if (arr.length && tab === "all" && (R.apps.length ? 1 : 0) + (R.repos.length ? 1 : 0) + (R.versions.length ? 1 : 0) > 1) kids.push(el("h3", { class: "st-lbl", text: l })); };
      if (/^https:\/\/\S+$/i.test(q) && !/apple\.com/i.test(q)) { var imp = el("a", { class: "st-app", href: "/studio/import?url=" + enc(q), "data-nav": "" }, el("span", { class: "st-ico" }, ic("layers", 30)), el("span", { class: "st-tt" }, el("b", { text: t("Import this repo") }), el("small", { text: q }))); imp.appendChild(ic("chev", 18)); kids.push(imp); }
      if (tab === "all" || tab === "apps") { sec(t("Apps"), R.apps); R.apps.slice(0, 60).forEach(function (x) { kids.push(appRow(x)); }); }
      if (tab === "all" || tab === "repos") { sec(t("Repos"), R.repos); R.repos.forEach(function (x) { kids.push(repoRow(x)); }); if (tab === "repos") { var add = el("a", { class: "st-app", href: "/studio/import", "data-nav": "" }, el("span", { class: "st-ico" }, ic("layers", 30)), el("span", { class: "st-tt" }, el("b", { text: t("Import Repo") }), el("small", { text: t("Add AltStore/SideStore source or custom repo") }))); add.appendChild(ic("chev", 18)); kids.push(add); } }
      if (tab === "all" || tab === "versions") { sec(t("Versions"), R.versions); R.versions.forEach(function (x) { kids.push(verRow(x)); }); }
      if (!kids.length) kids.push(el("p", { class: "st-empty", text: q.length < 2 && !scope ? t("Type an app name to search your repos.") : t("No apps found in your repos. Add a repo with Import Repo.") }));
      list.replaceChildren.apply(list, kids);
    }
    function repoSources() {
      var urls = repos().map(function (r) { return r.url; }); if (scope && urls.indexOf(scope) < 0) urls.unshift(scope); if (scope) urls = [scope];
      return Promise.all(urls.slice(0, 6).map(function (u) { return loadRepo(u).catch(function () { return null; }); })).then(function (a) { return a.filter(Boolean); });
    }
    function storeSearch() {
      if (q.length < 2 || scope) return Promise.resolve([]);
      var sel = document.getElementById("region"), cc = sel && /^[a-z]{2}$/.test(sel.value) ? sel.value : "us";
      return H.api("GET", "/api/appsearch?q=" + enc(q) + "&cc=" + cc).then(function (j) { return j && j.ok ? (j.items || []).filter(function (a) { return BID_RE.test(a.bid); }) : []; });
    }
    function savedSearch() {
      if (scope) return Promise.resolve([]);
      return H.api("GET", "/api/dylibs/vault?view=apps&f=all&page=1&q=" + enc(q)).then(function (j) { return j && j.ok ? (j.items || []) : []; });
    }
    function run() {
      var my = ++seq, s = q.toLowerCase(); list.replaceChildren(el("p", { class: "st-empty", text: t("Searching…") }));
      Promise.all([repoSources(), storeSearch(), savedSearch()]).then(function (r) {
        if (my !== seq) return;
        var by = {}, apps = [], inst = {}, repoRows = [];
        var hit = function (a) { return !s || a.name.toLowerCase().indexOf(s) >= 0 || a.bid.toLowerCase().indexOf(s) >= 0 || (a.dev || "").toLowerCase().indexOf(s) >= 0; };
        r[0].forEach(function (src) {
          var m = src.apps.filter(hit);
          if (m.length || (!s && !scope)) repoRows.push({ url: src.url, name: src.name, icon: repoPic(src), count: src.apps.length, match: m.length });
          m.forEach(function (a) {
            var k = a.bid.toLowerCase(), v = a.current ? a.current.version : "";
            if (!inst[k] || verCmp(v, inst[k].v) > 0) inst[k] = { v: v, repo: src.url };
            if (!by[k]) { by[k] = { bid: a.bid, name: a.name, icon: a.icon, aid: "", sver: "", inst: "", repo: src.url }; apps.push(by[k]); }
          });
        });
        // only apps that are in a repo are listed; the saved libraries and the App Store only fill in details (App Store id, icon, newest version)
        r[1].forEach(function (a) { var x = by[a.bid.toLowerCase()]; if (!x) return; x.name = x.name || a.name; x.icon = x.icon || a.icon; x.aid = a.id || x.aid; x.sver = a.ver || x.sver; });
        r[2].forEach(function (a) { var x = by[a.bid.toLowerCase()]; if (!x) return; if (!x.aid && a.aid) x.aid = a.aid; if (!x.icon && a.icon) x.icon = a.icon; });
        apps.forEach(function (x) { var i = inst[x.bid.toLowerCase()]; if (i) { x.inst = i.v; if (!x.repo) x.repo = i.repo; } });
        R.apps = apps; R.repos = scope ? [] : repoRows; R.versions = [];
        scopeNote.replaceChildren(); if (scope && r[0][0]) scopeNote.appendChild(el("p", { class: "st-count", text: t("Showing apps in {name}", { name: r[0][0].name }) }));
        drawTabs(); drawList();
        // versions already in the library, for the first apps found
        var bids = apps.filter(function (x) { return x.bid; }).slice(0, 12).map(function (x) { return x.bid; });
        if (!bids.length || (q.length < 2 && !scope)) return;
        H.api("GET", "/api/repo/upstream?bids=" + bids.map(enc).join(",")).then(function (j) {
          if (my !== seq || !j || !j.ok) return; var vs = [];
          apps.forEach(function (x) { var u = j.items && j.items[x.bid]; if (u && u.library) u.library.slice(0, 3).forEach(function (l) { vs.push({ bid: x.bid, name: x.name, icon: x.icon, aid: l.appId || x.aid, ver: l.ver }); }); });
          R.versions = vs.slice(0, 30); drawTabs(); drawList();
        });
      });
    }
    form.addEventListener("submit", function (e) {
      e.preventDefault(); var v = inp.value.trim();
      q = v; clr.hidden = !q; sync(); run();
    });
    inp.addEventListener("input", function () { clr.hidden = !inp.value; });
    clr.addEventListener("click", function () { inp.value = ""; q = ""; clr.hidden = true; sync(); run(); inp.focus(); });
    drawTabs();
    host.replaceChildren(el("div", { class: "st" + (bare ? " st-dd" : "") }, form, bare ? null : repoNotice(), seg, scopeNote, list));
    if (bare) return { set: function (v) { q = String(v || "").trim(); inp.value = q; clr.hidden = !q; drawTabs(); run(); } };   // the site's own search box drives it
    run(); if (!q) inp.focus();
  }

  // ---------- APP ----------
  function items(set, type) { return set ? (set.items || []).filter(function (i) { return i.type === type; }) : []; }
  function chosen(set, sel) { return set ? (set.items || []).filter(function (i) { return sel[i.name]; }) : []; }
  function worst(list, setVer, target) { var lv = "ok"; list.forEach(function (i) { var c = compat(i, setVer, target).level; if (c === "bad") lv = "bad"; else if (c === "warn" && lv === "ok") lv = "warn"; }); return lv; }

  function app(host, bid, qs, h) {
    H = h; css();
    var el = mk; if (!BID_RE.test(bid)) { host.replaceChildren(el("div", { class: "st" }, head(t("Search Apps"), "/studio/search"), el("p", { class: "st-empty", text: t("That isn't a valid app.") }))); return; }
    host.replaceChildren(el("div", { class: "st" }, head(t("Loading…"), "/studio/search"), el("p", { class: "st-empty", text: t("Loading…") })));
    loadApp(bid, qs).then(function (A) { drawApp(host, A, qs); }).catch(function (e) { try { console.error("studio app", e); } catch (x) {} host.replaceChildren(el("div", { class: "st" }, head(t("Search Apps"), "/studio/search"), el("p", { class: "st-empty", text: t("Couldn't load this app.") }))); });
  }
  function drawApp(host, A, qs) {
    var el = mk, U = stateOf(A), back = "/studio/search" + (qs.get("q") ? "?q=" + enc(qs.get("q")) : "") + (A.repo && !qs.get("q") ? "?tab=repo&repo=" + enc(A.repo.url) : "");
    var target = targetOf(A), update = A.installed && A.latest && verCmp(A.latest, A.installed) > 0;
    var set = A.sets.filter(function (s) { return s.id === U.setId; })[0] || setFor(A, A.installed);
    var rv = A.repoApp && A.repoApp.current && A.repoApp.current.url ? A.repoApp.current : null, scanning = false;
    // reads the repo's own IPA (only the parts it needs), finds the added dylibs and frameworks, saves them to the library, then shows them here
    function collect(go, st) {
      if (scanning) return; scanning = true; go.disabled = true;
      var say = function (m, err) { st.textContent = m || ""; st.className = "st-msg" + (err ? " err" : ""); };
      say(t("Reading the package…"));
      engine().then(function () {
        var R = root.DTREPO;
        return R.openRemoteIpa(rv.url, function (a, b) { var got = a && typeof a === "object" ? a.got : a, tot = a && typeof a === "object" ? a.tot : b; if (tot) say(t("Reading the package… {p}%", { p: Math.floor(got * 100 / tot) })); })
          .then(function (blob) { return R.scanIpa(blob, function (i, n) { say(t("Checking libraries… {i} of {n}", { i: i + 1, n: n })); }); })
          .then(function (scan) {
            var pick = R.pickInjected(scan, false);
            if (!pick.length) throw new Error("No added dylibs or frameworks were found in this IPA.");
            say(t("Saving {n} libraries…", { n: pick.length }));
            return R.uploadPicked(scan, pick, { bid: A.bid, name: A.name, icon: A.icon }, rv.version, A.repo ? A.repo.name : "", true).catch(function (e) { if (e && e.exists) return 0; throw e; });
          });
      }).then(function () { delete appCache[A.bid]; delete UI[A.bid]; return loadApp(A.bid, qs); })
        .then(function (A2) { drawApp(host, A2, qs); })
        .catch(function (e) { scanning = false; go.disabled = false; say(e && e.http === 401 ? t("Log in to read and save libraries from a repo IPA.") : e && e.message ? t(e.message) : t("Couldn't read that package."), true); });
    }
    function repoPanel() {
      if (!rv) return el("p", { class: "st-empty", text: t("No saved libraries for this app yet. Open it in Repo Studio to collect them from a repo.") });
      var go = el("button", { class: "st-go", type: "button", text: t("Fetch libraries from repo IPA") }), st = el("p", { class: "st-msg", role: "status" });
      go.addEventListener("click", function () { collect(go, st); });
      var key = "dt-studio-scan-" + A.bid + "-" + rv.version, tried = false; try { tried = !!sessionStorage.getItem(key); sessionStorage.setItem(key, "1"); } catch (e) { /* storage off */ }
      if (!tried) setTimeout(function () { if (go.isConnected) collect(go, st); }, 0);   // the first time, it just does it
      return el("div", { class: "st-fetch" }, el("p", { class: "st-empty", text: t("No saved libraries for this app yet. They can be read from the repo's IPA.") }), go, st);
    }
    var body = el("div", { class: "st-card", style: "overflow:hidden" }), tabs = el("div", { class: "st-tabs", role: "tablist" }), foot = el("div", {}), chip = el("div", { class: "st-chips" });
    if (A.installed) chip.appendChild(el("span", { class: "st-pill", text: t(A.installedFrom === "repo" ? "Installed: v{v}" : "Saved: v{v}", { v: A.installed }) }));
    if (A.latest) chip.appendChild(el("span", { class: "st-pill ok", text: t("Latest: v{v}", { v: A.latest }) + (update ? " ↑" : "") }));
    var nameBox = el("div", { class: "st-panel", style: "padding:14px" }, el("div", { style: "display:flex;gap:12px;align-items:center" }, icon(A.icon, A.bid, A.name),
      el("span", { class: "st-tt" }, el("b", { text: A.name, style: "font-size:17px;white-space:normal" }), el("small", { text: A.bid }), chip)));
    var banner = update ? el("div", { class: "st-ban" }, ic("up", 22), el("span", {}, el("b", { text: t("Newer version available") }), el("small", { text: "v" + A.latest })),
      A.aid ? el("a", { href: "/app/" + A.aid, "data-nav": "", text: t("View Changelog") + " ›" }) : null) : null;
    function count(type) { return items(set, type).length; }
    function drawTabs() {
      var defs = [["dylibs", t("Dylibs ({n})", { n: count("dylib") })], ["frameworks", t("Frameworks ({n})", { n: count("framework") })], ["info", t("Info")], ["tools", t("Tools")]];
      tabs.replaceChildren.apply(tabs, defs.map(function (d) { var b = el("button", { type: "button", role: "tab", "aria-selected": String(U.tab === d[0]), text: d[1] }); b.addEventListener("click", function () { U.tab = d[0]; drawTabs(); drawBody(); }); return b; }));
    }
    function drawBody() {
      if (U.tab === "info") { body.replaceChildren.apply(body, infoRows()); drawFoot(); return; }
      if (U.tab === "tools") { body.replaceChildren(toolsPanel()); drawFoot(); return; }
      var type = U.tab === "frameworks" ? "framework" : "dylib", list = items(set, type), kids = [];
      if (!set) kids.push(repoPanel());
      else if (!list.length) kids.push(el("p", { class: "st-empty", text: type === "dylib" ? t("No dylibs in this set.") : t("No frameworks in this set.") }));
      body.replaceChildren.apply(body, kids);
      drawRows(list, type);
      drawFoot();
    }
    function drawRows(list, type) {
      list.forEach(function (it) {
        var cb = el("input", { type: "checkbox", "aria-label": it.name }); cb.checked = !!U.sel[it.name];
        var c = compat(it, set.version, target), more = el("div", { class: "st-detail", hidden: "" }, c.notes.map(function (n) { return el("p", { text: n }); }), el("p", { text: [it.arch ? String(it.arch) : "", it.rel || ""].filter(Boolean).join(" · ") }));
        var ib = el("button", { type: "button", class: "st-i", "aria-label": t("Details") }); ib.appendChild(ic("info", 20));
        ib.addEventListener("click", function () { more.hidden = !more.hidden; });
        cb.addEventListener("change", function () { if (cb.checked) U.sel[it.name] = true; else delete U.sel[it.name]; drawFoot(); });
        body.appendChild(el("div", { class: "st-it" }, cb, el("span", { style: "color:var(--mut);display:flex" }, ic(type === "dylib" ? "file" : "fw", 22)), el("span", { class: "nm", text: it.name }), el("span", { class: "st-dot " + c.level, title: c.notes[0] }), el("small", { text: kb(it.size) }), ib));
        body.appendChild(more);
      });
    }
    // tools: plugins the site offers (App Info, Load Commands, Strings…). They run on the server against the repo's IPA.
    function toolsPanel() {
      var box = el("div", { class: "st-tools" }), url = rv ? rv.url : "";
      if (!url) { box.appendChild(el("p", { class: "st-empty", text: t("Tools open the repo's IPA. This app has no repo IPA.") })); return box; }
      box.appendChild(el("p", { class: "st-empty", text: t("Loading tools…") }));
      H.api("GET", "/api/plugins").then(function (j) {
        var list = j && j.ok ? j.items || [] : []; box.replaceChildren();
        if (!list.length) { box.appendChild(el("p", { class: "st-empty", text: t("No tools are installed on this server.") })); return; }
        list.forEach(function (p) { box.appendChild(toolRow(p, url)); });
      }, function () { box.replaceChildren(el("p", { class: "st-empty", text: t("Couldn't load the tools.") })); });
      return box;
    }
    function toolRow(p, url) {
      var inputs = {}, out = el("div", { class: "st-tout" }), msg = el("p", { class: "st-msg", role: "status" }), timer = 0, jid = "";
      var go = el("button", { type: "button", class: "st-ab" }, ic("play", 18), el("span", { text: t("Run") }));
      var fields = (p.options || []).map(function (o) {
        var inp;
        if (o.type === "bool") { inp = el("input", { type: "checkbox", "aria-label": o.label }); inp.checked = !!o.def; }
        else { inp = el("input", { type: o.type === "number" ? "number" : "text", class: "st-in", "aria-label": o.label, placeholder: o.label, value: o.def === "" ? "" : String(o.def) }); }
        inputs[o.key] = { el: inp, o: o };
        return el("label", { class: "st-tf" }, o.type === "bool" ? inp : null, el("span", { text: o.label }), o.type === "bool" ? null : inp);
      });
      function say(m, err) { msg.textContent = m || ""; msg.className = "st-msg" + (err ? " err" : ""); }
      function stop() { clearTimeout(timer); go.disabled = false; go.lastChild.textContent = t("Run"); }
      function poll() {
        H.api("GET", "/api/plugins/jobs/" + jid).then(function (j) {
          if (!j || !j.ok) { stop(); say((j && j.error) || t("That run has expired."), true); return; }
          if (j.status === "done") { stop(); say(""); drawResult(out, j.result); return; }
          if (j.status === "err" || j.status === "cancel") { stop(); say(j.error || t("Stopped."), j.status === "err"); return; }
          say((j.msg || t("Working…")) + (j.pct ? " · " + j.pct + "%" : "")); timer = setTimeout(poll, 1200);
        }, function () { timer = setTimeout(poll, 3000); });
      }
      go.addEventListener("click", function () {
        if (jid && go.lastChild.textContent === t("Cancel")) { H.api("POST", "/api/plugins/jobs/" + jid + "/cancel", {}); return; }
        var opts = {}; Object.keys(inputs).forEach(function (k) { var x = inputs[k]; opts[k] = x.o.type === "bool" ? x.el.checked : x.el.value; });
        out.replaceChildren(); say(t("Starting…")); go.lastChild.textContent = t("Cancel");
        H.api("POST", "/api/plugins/" + enc(p.id) + "/run", { src: { url: url }, options: opts }).then(function (j) {
          if (!j || !j.ok) { stop(); say((j && j.error) || t("Couldn't start it."), true); return; } jid = j.id; poll();
        }, function (e) { stop(); say(String(e && e.message ? e.message : t("Couldn't start it.")), true); });
      });
      return el("div", { class: "st-tool" }, el("div", { class: "st-row" }, ic(p.icon in ICONS ? p.icon : "code", 22), el("span", { class: "st-tt" }, el("b", { text: p.name }), el("small", { text: p.description })), go), fields.length ? el("div", { class: "st-tfs" }, fields) : null, msg, out);
    }
    function drawResult(host2, r) {
      host2.replaceChildren.apply(host2, (r.sections || []).map(function (s) {
        var h = el("div", { class: "st-lab mut", text: s.title }), b;
        if (s.kind === "kv") b = el("div", {}, (s.rows || []).map(function (x) { return el("div", { class: "st-kv" }, el("span", { text: x[0] }), el("span", { text: x[1] })); }));
        else if (s.kind === "table") { var tb = el("table", { class: "st-tbl" }); if (s.cols && s.cols.length) tb.appendChild(el("tr", {}, s.cols.map(function (c) { return el("th", { text: c }); }))); (s.rows || []).forEach(function (row) { tb.appendChild(el("tr", {}, row.map(function (c) { return el("td", { text: c }); }))); }); b = el("div", { class: "st-tscroll" }, tb); }
        else if (s.kind === "list") { b = el("pre", { class: "st-logbox" }); b.textContent = (s.items || []).join("\n") || t("Nothing found."); }
        else { b = el("pre", { class: "st-logbox" }); b.textContent = s.text || ""; }
        return el("div", { class: "st-ts" }, h, b, s.note ? el("small", { class: "mut", text: s.note }) : null);
      }));
    }
    function infoRows() {
      var kv = function (k, v) { return el("div", { class: "st-kv" }, el("span", { text: k }), el("span", { text: v })); }, rows = [kv(t("Name"), A.name), kv(t("Bundle ID"), A.bid)];
      if (A.installed) rows.push(kv(t(A.installedFrom === "repo" ? "Installed" : "Saved"), "v" + A.installed));
      if (A.latest) rows.push(kv(t("Latest"), "v" + A.latest));
      if (A.minos) rows.push(kv(t("Minimum iOS"), A.minos));
      if (A.repo) rows.push(kv(t("Repo"), A.repo.name));
      rows.push(kv(t("Saved sets"), A.sets.length ? A.sets.map(function (s) { return "v" + s.version + " (" + s.count + ")"; }).join(", ") : t("None")));
      rows.push(kv(t("In the library"), A.library.length ? A.library.slice(0, 6).map(function (l) { return "v" + l.ver; }).join(", ") : t("Not decrypted yet")));
      if (A.aid) rows.push(el("div", { class: "st-kv" }, el("a", { href: "/app/" + A.aid, "data-nav": "", style: "color:var(--acc)", text: t("Open the app page") }), el("span", { text: "" })));
      return rows;
    }
    // everything under the list: set picker, saved sets, compatibility line and the two buttons
    function drawFoot() {
      var picked = chosen(set, U.sel), lv = worst(picked, set ? set.version : "", target), kids = [];
      if (A.sets.length > 1) {
        var sp = el("select", { class: "st-sel2", "aria-label": t("Saved library set") }); A.sets.forEach(function (s) { var o = el("option", { value: s.id, text: "v" + s.version + " · " + t("{n} items", { n: s.count }) }); if (set && s.id === set.id) o.selected = true; sp.appendChild(o); });
        sp.addEventListener("change", function () { U.setId = sp.value; set = A.sets.filter(function (s) { return s.id === U.setId; })[0] || set; U.sel = {}; (set ? set.items : []).forEach(function (i) { U.sel[i.name] = true; }); drawTabs(); drawBody(); });
        kids.push(el("div", { class: "st-lab mut", text: t("Library set") }), sp);
      }
      var profs = profilesOf(A.bid);
      if (profs.length) {
        var ps = el("select", { class: "st-sel2", "aria-label": t("Saved injection sets") }, el("option", { value: "", text: t("Saved sets…") }));
        profs.forEach(function (p) { ps.appendChild(el("option", { value: p.name, text: p.name + " (" + p.names.length + ")" })); });
        ps.addEventListener("change", function () {
          var p = profs.filter(function (x) { return x.name === ps.value; })[0]; if (!p) return;
          var have = {}; (set ? set.items : []).forEach(function (i) { have[i.name] = 1; }); U.sel = {}; var miss = 0;
          p.names.forEach(function (n) { if (have[n]) U.sel[n] = true; else miss++; });
          toast(miss ? t("Loaded “{n}”. {m} item(s) aren't in this version's set.", { n: p.name, m: miss }) : t("Loaded “{n}”.", { n: p.name })); drawTabs(); drawBody();
        });
        kids.push(ps);
      }
      kids.push(el("div", { class: "st-count", style: "display:flex;align-items:center;gap:8px" }, el("span", { class: "st-dot " + lv }),
        el("span", { text: !picked.length ? t("Nothing selected yet.") : lv === "ok" ? t("{n} selected · all look compatible with v{v}", { n: picked.length, v: target || "?" }) : lv === "warn" ? t("{n} selected · some need a look (tap the info buttons)", { n: picked.length }) : t("{n} selected · some can't be used on this version", { n: picked.length }) })));
      var nm = el("input", { type: "text", maxlength: "40", placeholder: t("Name this set"), class: "st-sel2", style: "display:none", "aria-label": t("Set name") });
      var save = el("button", { type: "button", class: "st-b2" }, ic("bookmark", 18), el("span", { text: t("Save Set") }));
      var go = el("button", { type: "button", class: "st-b2 fill" }, ic("wrench", 18), el("span", { text: t("Decrypt & Inject") }));
      save.addEventListener("click", function () {
        if (!picked.length) { toast(t("Pick at least one library first.")); return; }
        if (nm.style.display === "none") { nm.style.display = ""; nm.value = t("My set") + " " + (profilesOf(A.bid).length + 1); nm.focus(); nm.select(); return; }
        var n = nm.value.trim().slice(0, 40); if (!n) return;
        saveProfile(A.bid, { name: n, names: picked.map(function (i) { return i.name; }), setVersion: set ? set.version : "", at: Date.now() }); toast(t("Saved “{n}”.", { n: n })); nm.style.display = "none"; drawFoot();
      });
      nm.addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); save.click(); } });
      go.addEventListener("click", function () { if (!picked.length) { toast(t("Pick at least one library first.")); return; } UI[A.bid].setId = set ? set.id : ""; H.go("/studio/inject/" + enc(A.bid) + location.search); });
      kids.push(nm, el("div", { class: "st-btns" }, save, go));
      foot.replaceChildren.apply(foot, kids);
    }
    foot.style.display = "grid"; foot.style.gap = "10px";
    document.title = A.name + " · Decrypt.team";
    host.replaceChildren(el("div", { class: "st" }, head(A.name, back), nameBox, banner,
      el("p", { class: "st-sel", text: target ? t("Select dylibs to inject into v{v}", { v: target }) : t("Select the libraries to inject") }), tabs, body, foot));
    drawTabs(); drawBody();
  }

  // ---------- DECRYPT & INJECT ----------
  function inject(host, bid, qs, h) {
    H = h; css();
    var el = mk; if (!BID_RE.test(bid)) { H.go("/studio/search", null, true); return; }
    host.replaceChildren(el("div", { class: "st" }, head(t("Decrypt & Inject"), "/studio/app/" + enc(bid) + location.search), el("p", { class: "st-empty", text: t("Loading…") })));
    (appCache[bid] ? Promise.resolve(appCache[bid]) : loadApp(bid, qs)).then(function (A) { drawInject(host, A, qs); }).catch(function () { host.replaceChildren(el("div", { class: "st" }, head(t("Decrypt & Inject"), "/studio/search"), el("p", { class: "st-empty", text: t("Couldn't load this app.") }))); });
  }
  function drawInject(host, A, qs) {
    var el = mk, U = stateOf(A), set = A.sets.filter(function (s) { return s.id === U.setId; })[0] || setFor(A, A.installed), open = { dylib: false, framework: false };
    var versions = []; [A.latest].concat(A.library.map(function (l) { return l.ver; }), A.sets.map(function (s) { return s.version; })).forEach(function (v) { if (v && versions.indexOf(v) < 0) versions.push(v); });
    versions.sort(function (a, b) { return verCmp(b, a); });
    if (U.ver && versions.indexOf(U.ver) < 0) versions.unshift(U.ver);
    var verSel = el("select", { class: "st-sel2", "aria-label": t("Target version") });
    versions.forEach(function (v) { verSel.appendChild(el("option", { value: v, text: "v" + v + (v === A.latest ? " " + t("(Latest)") : ""), selected: v === U.ver ? "" : null })); });
    if (!versions.length) verSel.appendChild(el("option", { value: "", text: t("Latest on the App Store") }));
    verSel.value = U.ver || ""; verSel.addEventListener("change", function () { U.ver = verSel.value; drawGroups(); });
    var groups = el("div", { class: "st-card", style: "overflow:hidden" }), pv = el("div", { class: "st-card" }), start = el("button", { type: "button", class: "st-go wide" }, ic("play", 18), el("span", { text: " " + t("Start Decrypt & Inject") }));
    function groupRow(type, label) {
      var all = items(set, type), n = all.filter(function (i) { return U.sel[i.name]; }).length, kids = [];
      var cb = el("input", { type: "checkbox", class: "st-chk", "aria-label": label }); cb.checked = n > 0;
      cb.addEventListener("click", function (e) { e.stopPropagation(); });
      cb.addEventListener("change", function () { all.forEach(function (i) { if (cb.checked) U.sel[i.name] = true; else delete U.sel[i.name]; }); drawGroups(); });
      var row = el("button", { type: "button", class: "st-grp", "aria-expanded": String(open[type]) }, cb, el("span", { style: "display:flex;color:var(--mut)" }, ic(type === "dylib" ? "cube" : "layers", 22)),
        el("span", { class: "nm", text: label + " " + t("({n} selected)", { n: n }) }));
      var chev = ic("chev", 18); chev.setAttribute("class", "chev"); row.appendChild(chev);
      row.addEventListener("click", function () { open[type] = !open[type]; drawGroups(); });
      kids.push(row);
      if (open[type]) all.forEach(function (it) {
        var c = compat(it, set ? set.version : "", U.ver), x = el("input", { type: "checkbox", "aria-label": it.name }); x.checked = !!U.sel[it.name];
        x.addEventListener("change", function () { if (x.checked) U.sel[it.name] = true; else delete U.sel[it.name]; drawGroups(); });
        kids.push(el("div", { class: "st-it", style: "padding-left:26px" }, x, el("span", { class: "nm", text: it.name }), el("span", { class: "st-dot " + c.level, title: c.notes.join(" ") }), el("small", { text: kb(it.size) })));
      });
      return kids;
    }
    function drawGroups() {
      var kids = groupRow("dylib", t("Dylibs")).concat(groupRow("framework", t("Frameworks")));
      groups.replaceChildren.apply(groups, kids); drawPreview(); drawCustom(); readCmds(); start.disabled = !chosen(set, U.sel).length && !U.custom.length;
    }
    // what will happen, from what was saved. What is already inside the new IPA is only known once it has been decrypted.
    function drawPreview() {
      var picked = chosen(set, U.sel), left = (set ? set.items : []).filter(function (i) { return !U.sel[i.name]; }), loads = (set && set.loads ? set.loads : []).filter(function (l) { return picked.some(function (i) { return String(l.path).split("/").indexOf(i.name) >= 0; }); });
      var warn = picked.map(function (i) { return { i: i, c: compat(i, set ? set.version : "", U.ver) }; }).filter(function (x) { return x.c.level !== "ok"; });
      var names = function (l) { return l.length ? el("ul", {}, l.slice(0, 8).map(function (x) { return el("li", { text: x }); }).concat(l.length > 8 ? [el("li", { text: t("+{n} more", { n: l.length - 8 }) })] : [])) : el("p", { text: t("None") }); };
      pv.replaceChildren(el("h3", { class: "st-sech", text: t("Review changes") }), el("div", { class: "st-pv" },
        el("b", { text: t("Will be added ({n})", { n: picked.length + U.custom.length + 1 }) }), names(["dtx.dylib (" + t("always included") + ")"].concat(picked.map(function (i) { return i.name; }), U.custom.map(function (c) { return c.name + " (" + t("yours") + ")"; }))),
        el("b", { text: t("Load commands ({n})", { n: loads.length }) }), loads.length ? names(loads.map(function (l) { return l.path; })) : el("p", { text: t("Rebuilt from the selected items.") }),
        el("b", { text: t("Left out ({n})", { n: left.length }) }), left.length ? names(left.map(function (i) { return i.name; })) : el("p", { text: t("None") }),
        el("b", { text: t("Kept") }), el("p", { text: [U.opt.resign ? t("old signature removed so it can be signed again") : t("old signature kept"), U.opt.preserve ? t("bundle ID kept so app data stays") : ""].filter(Boolean).join(" · ") }),
        warn.length ? el("b", { text: t("Check these ({n})", { n: warn.length }) }) : null, warn.length ? el("ul", {}, warn.slice(0, 6).map(function (x) { return el("li", { text: x.i.name + ": " + x.c.notes[0] }); })) : null,
        el("p", { text: t("Anything already inside the new version is replaced. The build lists exactly what, once the app is decrypted.") })));
    }
    function opt(icn, label, key) { return el("div", { class: "st-row" }, ic(icn, 20), el("span", { text: label }), sw(U.opt[key], function (v) { U.opt[key] = v; drawPreview(); })); }
    var cust = el("div", { class: "st-card st-cust" }), pick = el("input", { type: "file", multiple: "", hidden: "", "aria-label": t("Add library") }), dirPick = el("input", { type: "file", multiple: "", hidden: "", webkitdirectory: "", directory: "" });
    var cmdsOpen = false, cmdsFor = null, cmds = null;   // cmds: null = not looked up, [] = none/unknown, else the load commands found in the repo's binary
    var SYS = /^(\/usr\/lib\/|\/System\/|@rpath\/(libswift|Frameworks\/libswift))/, DYL = [0x0c, 0x80000018, 0x8000001f, 0x20];
    function readCmds() {   // what the repo's package already loads, so the person can strip some of it
      var sc = sourceOf(A, U.ver || A.latest || A.installed || "", A.library.filter(function (l) { return U.ver && verCmp(l.ver, U.ver) === 0; })[0] || null, false);
      var url = sc.kind === "repo" ? sc.rp.url : ""; if (url === cmdsFor) return; cmdsFor = url; cmds = url ? null : [];
      if (!url) { drawCustom(); return; }
      engine().then(function () { return root.DTREPO.openRemoteIpa(url, null); }).then(function (blob) {
        var INJ = root.DTINJ; return INJ.zipList(blob).then(function (en) { var exe = INJ.pickExecutable(en); return exe ? INJ.zipReadHead(blob, exe, 524288) : null; });
      }).then(function (ab) {
        if (url !== cmdsFor) return; var buf = ab && ab.buffer ? ab.buffer.slice(ab.byteOffset, ab.byteOffset + ab.byteLength) : ab, seen = {};
        cmds = ab ? root.DTINJ.listCommands(buf).cmds.filter(function (c) { return c.path && DYL.indexOf(c.cmd) >= 0 && !SYS.test(c.path) && !seen[c.path] && (seen[c.path] = 1); }).map(function (c) { return c.path; }) : [];
        drawCustom();
      }).catch(function () { if (url === cmdsFor) { cmds = []; drawCustom(); } });
    }
    function seg(label, opts, key) {
      var row = el("div", { class: "st-ip" }, el("span", { text: label }));
      opts.forEach(function (o) { var b = el("button", { type: "button", "aria-pressed": String(U.inj[key] === o[0]), text: o[1] }); b.addEventListener("click", function () { U.inj[key] = o[0]; drawCustom(); }); row.appendChild(b); });
      return row;
    }
    function drawCustom() {
      var rows = U.custom.map(function (c, n) { var x = el("button", { type: "button", class: "st-crm", "aria-label": t("Remove") }, ic("x", 16)); x.addEventListener("click", function () { U.custom.splice(n, 1); drawGroups(); }); return el("div", { class: "st-row" }, ic(c.framework ? "layers" : "code", 20), el("span", { text: c.name }), el("small", { class: "mut", text: Math.max(1, Math.round(c.size / 1024)) + " KB" }), x); });
      rows.unshift(el("div", { class: "st-row st-lockrow" }, ic("lock", 20), el("span", { text: "dtx.dylib" }), el("small", { class: "mut", text: t("Always included") })));
      var prev = el("div", { class: "st-ipv", text: (U.inj.base === "rpath" ? "@rpath/" : "@executable_path/") + U.inj.folder + "xxx.dylib" });
      var nStrip = Object.keys(U.strip).length, head = el("button", { type: "button", class: "st-cmd" }, el("span", { text: cmds === null ? t("Reading the app's load commands…") : cmds.length ? t("Existing load commands ({n}) — tap to strip", { n: cmds.length }) + (nStrip ? " · " + t("{n} to strip", { n: nStrip }) : "") : t("Existing load commands (0)") }), ic("chev", 18));
      head.addEventListener("click", function () { if (cmds && cmds.length) { cmdsOpen = !cmdsOpen; drawCustom(); } });
      var list = cmdsOpen && cmds && cmds.length ? el("div", { class: "st-cl" }, cmds.map(function (p) {
        var cb = el("input", { type: "checkbox", "aria-label": p }); cb.checked = !!U.strip[p]; cb.addEventListener("change", function () { if (cb.checked) U.strip[p] = true; else delete U.strip[p]; drawCustom(); });
        return el("label", { class: "st-row" }, cb, el("span", { text: p }));
      })) : null;
      var drop = el("button", { type: "button", class: "st-drop" }, ic("plus", 30), el("b", { text: t("Add library (.dylib, .framework)") }), el("small", { text: t("Pick .dylib files, or use the folder button for a .framework") }));
      drop.addEventListener("click", function () { pick.click(); });
      var fw = el("button", { type: "button", class: "st-ab" }, ic("layers", 20), el("span", { text: t("Add a .framework folder") })); fw.addEventListener("click", function () { dirPick.click(); });
      cust.replaceChildren.apply(cust, [seg(t("Inject Path"), [["exe", "@executable"], ["rpath", "@rpath"]], "base"), seg(t("Inject Folder"), [["", "/"], ["Frameworks/", "Frameworks/"]], "folder"), prev, head, list].filter(Boolean).concat(rows, [drop, fw, pick, dirPick]));
    }
    pick.addEventListener("change", function () {
      var fs = Array.prototype.slice.call(pick.files || []); pick.value = ""; var bad = [];
      Promise.all(fs.map(function (f) {
        if (!/\.dylib$/i.test(f.name) || f.size > 150 * 1048576) { bad.push(f.name); return null; }
        return f.slice(0, 4).arrayBuffer().then(function (b) {
          var m = new DataView(b).getUint32(0, false);
          if ([0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca].indexOf(m) < 0) { bad.push(f.name); return; }
          var nm = f.name.replace(/[^A-Za-z0-9._+-]/g, "_"); if (nm.toLowerCase() === "dtx.dylib") return; if (U.custom.some(function (c) { return c.name === nm; })) return;
          U.custom.push({ name: nm, blob: f, size: f.size });
        });
      })).then(function () { drawGroups(); if (bad.length) toast(t("Skipped (not an iOS .dylib): {n}", { n: bad.slice(0, 3).join(", ") })); });
    });
    dirPick.addEventListener("change", function () {   // one .framework folder: its files keep their places inside it
      var fs = Array.prototype.slice.call(dirPick.files || []); dirPick.value = ""; if (!fs.length) return;
      var top = String(fs[0].webkitRelativePath || "").split("/")[0], fwk = top.replace(/\.framework$/i, "");
      if (!/\.framework$/i.test(top) || !/^[A-Za-z0-9._+-]+$/.test(fwk)) { toast(t("Pick a folder ending in .framework")); return; }
      var files = fs.map(function (f) { return { rel: String(f.webkitRelativePath).slice(top.length + 1), blob: f }; }).filter(function (x) { return x.rel && !/(^|\/)\.DS_Store$/.test(x.rel) && x.rel.indexOf("..") < 0; });
      var exe = files.filter(function (x) { return x.rel === fwk; })[0];
      if (!exe) { toast(t("That framework has no {n} binary inside.", { n: fwk })); return; }
      var size = files.reduce(function (n, x) { return n + x.blob.size; }, 0);
      if (size > 300 * 1048576) { toast(t("That framework is too big.")); return; }
      if (!U.custom.some(function (c) { return c.name === top; })) U.custom.push({ name: top, framework: fwk, exec: fwk, files: files, blob: null, size: size });
      drawGroups();
    });
    start.addEventListener("click", function () {
      if (!chosen(set, U.sel).length && !U.custom.length) return;
      U.setId = set ? set.id : ""; startFlow(host, A, U, set, qs);
    });
    document.title = t("Decrypt & Inject") + " · Decrypt.team";
    host.replaceChildren(el("div", { class: "st" }, head(t("Decrypt & Inject"), "/studio/app/" + enc(A.bid) + location.search), appHead(A),
      el("div", { class: "st-lab mut", text: t("Target Version") }), verSel,
      el("div", { class: "st-lab", text: t("Inject Into New Version") }), set ? groups : el("p", { class: "st-empty", text: t("No saved libraries for this app yet.") }), el("div", { class: "st-lab st-caps", text: t("Dylib Injection") }), cust, pv,
      el("div", { class: "st-lab", text: t("Options") }),
      el("div", { class: "st-card", style: "overflow:hidden" }, opt("lock", t("Decrypt IPA (Remove DRM)"), "decrypt"), opt("key", t("Re-sign IPA"), "resign"), opt("wrench", t("Clean Inject (Rebuild Load Commands)"), "clean"), opt("db", t("Preserve App Data (If Installed)"), "preserve")),
      start));
    if (set) drawGroups(); else { drawPreview(); drawCustom(); readCmds(); start.disabled = !U.custom.length; }
  }

  // ---------- RUN: preflight, progress, build log and result (the build itself is Repo Studio's buildApp) ----------
  function engine() {
    var needRepo = function () { return root.DTREPO && root.DTREPO.Libs && root.DTREPO.buildApp ? Promise.resolve() : loadScript("/repo.js?v=56"); };
    return (root.DTINJ ? Promise.resolve() : loadScript("/inject.js?v=1")).then(needRepo);
  }
  var clock = function () { return new Date().toTimeString().slice(0, 8); };
  var WEIGHT = { load: 5, dec: 45, inj: 35, chk: 10, fin: 5 };

  // the checks shown before anything starts
  // where the IPA to rebuild comes from: our library, else the repo's own package when it has this exact version (already decrypted, nothing to decrypt),
  // else a fresh decrypt from the App Store (a newer version than the repo has), else the repo's newest package when the app isn't on the store
  function sourceOf(A, target, lib, force) {
    if (lib) return { kind: "lib" };
    if (force && /^\d{5,12}$/.test(String(A.aid || ""))) return { kind: "store" };   // the person chose to decrypt from the App Store
    var ra = A.repoApp, vs = ra ? ra.versions || [] : [], pk = function (v, exact) { return { kind: "repo", exact: exact, rp: { url: v.url, ver: v.version, size: v.size || 0 } }; };
    var ex = vs.filter(function (x) { return x.url && target && verCmp(x.version, target) === 0; })[0];
    if (ex) return pk(ex, true);
    if (/^\d{5,12}$/.test(String(A.aid || ""))) return { kind: "store" };
    var c = ra && ra.current && ra.current.url ? ra.current : null;
    return c ? pk(c, false) : { kind: "none" };
  }
  // Is the repo's package still FairPlay-encrypted? Reads just the start of the main binary. true: encrypted, false: fine, null: couldn't tell.
  async function probeEncrypted(url) {
    try {
      await engine(); var R = root.DTREPO, INJ = root.DTINJ, blob = await R.openRemoteIpa(url, null), entries = await INJ.zipList(blob), exe = INJ.pickExecutable(entries); if (!exe) return null;
      var ab = await INJ.zipReadHead(blob, exe, 524288), buf = ab && ab.buffer ? ab.buffer.slice(ab.byteOffset, ab.byteOffset + ab.byteLength) : ab;
      return !!INJ.listCommands(buf).cryptid;
    } catch (e) { return null; }
  }
  function startFlow(host, A, U, set, qs, force) {
    var el = mk, picks = chosen(set, U.sel), target = U.ver || A.latest || A.installed || "";
    var lib = A.library.filter(function (l) { return target && verCmp(l.ver, target) === 0; })[0] || null, bad = picks.filter(function (i) { return compat(i, set.version, target).level === "bad"; });
    H.api("GET", "/api/auth/me").then(function (j) {
      var user = j && j.ok && j.user, aidOk = /^\d{5,12}$/.test(String(A.aid || "")), rows = [];
      var row = function (lvl, text, val) { var r = { lvl: lvl, text: text, val: val || "" }; rows.push(r); return r; };
      var sc = sourceOf(A, target, lib, force), rcur = A.repoApp && A.repoApp.current ? A.repoApp.current.version : "", encRow = null, alertBox = el("div", { class: "st-alert", role: "alert", hidden: "" });
      if (sc.kind === "lib") row("ok", t("App IPA / version found"), "v" + target + " · " + t("in library"));
      else if (sc.kind === "repo" && sc.exact) { row("ok", t("App IPA / version found"), "v" + sc.rp.ver + " · " + t("from the repo, no decrypt")); encRow = row("run", t("Checking the repo's IPA for encryption…"), ""); }
      else if (sc.kind === "store") row("ok", t("App IPA / version found"), "v" + (target || "?") + " · " + (force ? t("will decrypt") : rcur && target && verCmp(target, rcur) > 0 ? t("newer than the repo, will decrypt") : t("will decrypt")));
      else if (sc.kind === "repo") { row("warn", t("Not in the App Store. Using the repo's IPA"), "v" + sc.rp.ver); encRow = row("run", t("Checking the repo's IPA for encryption…"), ""); }
      else row("bad", t("No IPA found: not in the library, the App Store or a repo"), "");
      row(picks.length + U.custom.length ? "ok" : "bad", t("Dylibs & frameworks ({n}) ready", { n: picks.length + U.custom.length }), t("{n} items", { n: picks.length + U.custom.length }));
      row(bad.length ? "warn" : "ok", bad.length ? t("{n} item(s) have no ARM64 code", { n: bad.length }) : t("Injection config valid"), "");
      row(user ? "ok" : "bad", user ? t("Signed in") : t("Log in to build on the server"), user ? String(user.username || "") : "");
      row("ok", t("Build runs on"), t("Our server"));
      var bg = el("div", { class: "st-modal-bg", role: "dialog", "aria-modal": "true", "aria-label": t("Preflight Checks") }), box = el("div", { class: "st-modal" }), pf = el("div", { class: "st-pf" });
      var x = el("button", { class: "st-mx", type: "button", "aria-label": t("Cancel") }); x.appendChild(ic("x", 20));
      var cancel = el("button", { class: "st-mb", type: "button", text: t("Cancel") }), go = el("button", { class: "st-mb pri", type: "button" }, el("span", { text: t("Continue") }), ic("chev", 18));
      var close = function () { bg.remove(); };
      function draw() {
        pf.replaceChildren.apply(pf, rows.map(function (r) { var d = el("span", { class: "st-pd " + r.lvl }); if (r.lvl !== "run") d.appendChild(ic(r.lvl === "ok" ? "check" : r.lvl === "warn" ? "info" : "x", 14)); return el("div", { class: "st-pr" }, d, el("span", { class: "st-pt", text: r.text }), el("small", { text: r.val })); }));
        go.disabled = rows.some(function (r) { return r.lvl === "bad" || r.lvl === "run"; });
      }
      x.addEventListener("click", close); cancel.addEventListener("click", close); bg.addEventListener("click", function (e) { if (e.target === bg) close(); });
      go.addEventListener("click", function () { close(); runBuild(host, A, U, set, qs, target, lib, force); });
      box.appendChild(x); box.appendChild(el("span", { class: "st-ico st-mi" }, ic("layers", 40)));
      box.appendChild(el("h3", { text: t("Preflight Checks") })); box.appendChild(el("p", { class: "st-ms", text: t("Verifying your setup before starting…") }));
      box.appendChild(pf); box.appendChild(alertBox); box.appendChild(el("div", { class: "st-mbs" }, cancel, go)); bg.appendChild(box); document.body.appendChild(bg); draw(); go.focus();
      if (encRow) probeEncrypted(sc.rp.url).then(function (enc) {
        if (!bg.isConnected) return;
        if (enc === false) { encRow.lvl = "ok"; encRow.text = t("The repo's IPA is decrypted"); }
        else if (enc === null) { encRow.lvl = "warn"; encRow.text = t("Couldn't check the repo's IPA. The build will tell if it's encrypted."); }
        else if (aidOk) {
          encRow.lvl = "bad"; encRow.text = t("The repo's IPA is encrypted (FairPlay)");
          var yes = el("button", { class: "st-mb pri", type: "button", text: t("Decrypt from the App Store instead") }); yes.addEventListener("click", function () { close(); startFlow(host, A, U, set, qs, true); });
          alertBox.replaceChildren(el("p", { text: t("This IPA still has Apple's encryption. It has to be decrypted before libraries can be injected.") }), yes); alertBox.hidden = false;
        } else { encRow.lvl = "bad"; encRow.text = t("The repo's IPA is encrypted and the app isn't on the App Store, so it can't be decrypted."); }
        draw();
      });
    });
  }

  function runBuild(host, A, U, set, qs, target, lib, force) {
    var el = mk, picks = chosen(set, U.sel), names = picks.map(function (i) { return i.name; }), T0 = Date.now(), cancelled = false, view = "progress", done = null, failed = "";
    if (!A.icon && A.name) {   // App Store apps often have no icon yet: find it by name
      H.api("GET", "/api/appsearch?q=" + enc(A.name) + "&cc=us").then(function (j) { var its = j && j.ok && j.items || [], m = its.filter(function (x) { return String(x.bid).toLowerCase() === String(A.bid).toLowerCase(); })[0] || its.filter(function (x) { return x.icon; })[0]; if (m && m.icon && !A.icon) A.icon = m.icon; }, function () { });
    }
    var nDy = picks.filter(function (i) { return i.type === "dylib"; }).length + U.custom.length, nFw = picks.length - picks.filter(function (i) { return i.type === "dylib"; }).length;
    var sc = sourceOf(A, target, lib, force), viaRepo = sc.kind === "repo", rp = viaRepo ? sc.rp : null;
    var what = nDy && nFw ? t("Injecting {a} dylibs, {b} frameworks", { a: nDy, b: nFw }) : nFw ? t("Injecting {n} frameworks", { n: nFw }) : t("Injecting {n} dylibs", { n: nDy });
    var S = { load: "pending", dec: "pending", inj: "pending", loads: "pending", chk: "pending", fin: "pending", pg: null, msg: {}, log: [] };
    var LABEL = { dec: viaRepo ? t("Fetching the repo's IPA") : t("Decrypting (Removing DRM)"), inj: t("Injecting dylibs ({n})", { n: picks.length + U.custom.length }), loads: t("Rebuilding load commands"), chk: t("Checking the result"), fin: t("Finalizing output") };
    var ORDER = ["dec", "inj", "loads", "chk", "fin"];
    var log = function (m, mark) { if (!m) return; var last = S.log[S.log.length - 1]; if (last && last.m === m && last.mark === mark) return; S.log.push({ at: clock(), m: String(m), mark: mark || "" }); };
    function pct() {
      var p = 0; p += S.load === "done" ? WEIGHT.load : 0;
      var part = function (st, w, pg) { return st === "done" ? w : st === "run" && pg && pg.tot ? w * Math.min(1, pg.got / pg.tot) : 0; };
      p += part(S.dec, WEIGHT.dec, S.pg && S.pg.i === 1 ? S.pg : null) + part(S.inj, WEIGHT.inj, S.pg && S.pg.i === 3 ? S.pg : null) + (S.chk === "done" ? WEIGHT.chk : 0) + (S.fin === "done" ? WEIGHT.fin : 0);
      return Math.max(0, Math.min(100, Math.round(p)));
    }
    var current = function () { for (var i = 0; i < ORDER.length; i++) if (S[ORDER[i]] === "run") return ORDER[i]; return ""; };
    // progress reports from buildApp: 0 saved libraries, 1 decrypt, 2 carry over, 3 inject, 4 check
    function rep(i, st, m, pg) {
      if (cancelled) throw new Error(t("Cancelled."));
      var mark = st === "done" ? "ok" : st === "err" ? "err" : "";
      if (pg) S.pg = { i: i, got: pg.got, tot: pg.tot }; else if (S.pg && S.pg.i === i && st !== "run") S.pg = null;
      if (i === 0) S.load = st; else if (i === 1) { S.dec = st; S.msg.dec = m; } else if (i === 3) { S.inj = st; S.msg.inj = m; if (st === "done") S.loads = "done"; } else if (i === 4) { S.chk = st; S.msg.chk = m; }
      if (i === 3 && st === "run") S.loads = "pending";
      if (m && (st !== "run" || !pg)) log(m, mark);
      if (st === "err" && i !== 0) { var k = i === 1 ? "dec" : i === 3 ? "inj" : "chk"; S[k] = "err"; }
      paint();
    }
    function ring(p, tone) {
      var NS = "http://www.w3.org/2000/svg", s = document.createElementNS(NS, "svg"), C = 2 * Math.PI * 52;
      s.setAttribute("viewBox", "0 0 120 120"); s.setAttribute("class", "st-ring " + (tone || "")); s.setAttribute("aria-hidden", "true");
      var a = document.createElementNS(NS, "circle"), b = document.createElementNS(NS, "circle");
      [a, b].forEach(function (c) { c.setAttribute("cx", "60"); c.setAttribute("cy", "60"); c.setAttribute("r", "52"); c.setAttribute("fill", "none"); c.setAttribute("stroke", "currentColor"); c.setAttribute("stroke-width", "8"); });
      a.setAttribute("opacity", ".16"); b.setAttribute("stroke-linecap", "round"); b.setAttribute("stroke-dasharray", C.toFixed(1)); b.setAttribute("stroke-dashoffset", (C * (1 - p / 100)).toFixed(1)); b.setAttribute("transform", "rotate(-90 60 60)");
      s.appendChild(a); s.appendChild(b); return s;
    }
    function appCard(right) {
      var c = el("div", { class: "st-ac" }, icon(A.icon, A.bid, A.name), el("span", { class: "st-tt" }, el("b", { text: A.name }), el("small", { text: "v" + (target || "?") + " · " + right })));
      return c;
    }
    function stepIcon(st) { var s = el("span", { class: "st-sp " + st }); if (st === "done") s.appendChild(ic("check", 14)); else if (st === "err") s.appendChild(ic("x", 14)); return s; }
    function titleBlock(sub) { return el("div", { class: "st-tb" }, el("h2", { text: t("Decrypt & Inject") }), el("p", { text: sub })); }

    function progressView() {
      var p = pct(), cur = current(), label = cur ? (S.msg[cur] && cur === "dec" ? S.msg[cur] : LABEL[cur]) : t("Starting…");
      var toggle = el("button", { class: "st-lg", type: "button", "aria-label": t("Build Log") }); toggle.appendChild(ic("code", 22)); toggle.addEventListener("click", function () { view = "log"; paint(); });
      var ac = appCard(what); ac.appendChild(toggle);
      var center = el("div", { class: "st-rc" }, el("span", { class: "st-rci" }, ic(cur === "dec" || !cur ? "lock" : "wrench", 30)), el("b", { text: p + "%" }), el("small", { text: label.length > 28 ? label.slice(0, 27) + "…" : label }));
      var steps = el("div", { class: "st-card st-steps" }, ORDER.map(function (k) {
        var st = S[k], right = k === "dec" && st === "run" && S.pg && S.pg.i === 1 && S.pg.tot ? Math.round(S.pg.got * 100 / S.pg.tot) + "%" : "";
        return el("div", { class: "st-st " + st }, stepIcon(st), el("span", { class: "st-sl", text: LABEL[k] }), el("small", { text: right }));
      }));
      var cx = el("button", { class: "st-cancel", type: "button" }, ic("cancel", 16), el("span", { text: t("Cancel Build") })); cx.addEventListener("click", function () { cancelled = true; log(t("Cancelled."), "err"); failed = t("Cancelled."); paint(); });
      return [titleBlock(t("Working on your build. This may take a minute.")), ac, el("div", { class: "st-ringw" }, ring(p), center), steps, cx];
    }
    function logView() {
      var p = pct(), back = el("button", { class: "st-bar", type: "button" }); back.appendChild(ic("back", 22)); back.addEventListener("click", function () { view = "progress"; paint(); });
      var seg = el("div", { class: "st-seg", style: "grid-template-columns:1fr 1fr" }); [["progress", t("Progress")], ["log", t("Build Log")]].forEach(function (d) { var b = el("button", { type: "button", "aria-selected": String(view === d[0]), text: d[1] }); b.addEventListener("click", function () { view = d[0]; paint(); }); seg.appendChild(b); });
      var box = el("pre", { class: "st-logbox" }); box.textContent = S.log.map(function (l) { return "[" + l.at + "]  " + l.m + (l.mark === "ok" ? " ✓" : l.mark === "err" ? " ✗" : ""); }).join("\n") || t("Starting…");
      var bar = el("div", { class: "st-pbar" }, el("span", { text: done ? t("Done") : failed ? t("Stopped") : t("Building…") }), el("small", { text: p + "%" }), el("i", {}, el("u", { class: "st-fill" })));
      var kids = [back, titleBlock(t("Live build log.")), appCard(done ? t("Built") : failed ? t("Stopped") : t("Building…")), seg, box, bar];
      return kids;
    }
    function doneView() {
      var r = done, nm = r.out.fname || (safeNm(A.name) + "-" + safeNm(r.rel.ver) + ".ipa"), blob = r.out.blob, secs = Math.max(1, Math.round((Date.now() - T0) / 1000)), warn = (r.checks || []).filter(function (c) { return !c.ok; });
      var big = el("span", { class: "st-bigok" }); big.appendChild(ic("check", 44));
      var btn = function (icn, text, fn, cls) { var b = el("button", { type: "button", class: "st-ab" + (cls ? " " + cls : "") }, ic(icn, 20), el("span", { text: text })); b.addEventListener("click", function () { fn(b); }); return b; };
      var msg = el("p", { class: "st-cmsg", role: "status" });
      var say = function (s, err) { msg.textContent = s || ""; msg.className = "st-cmsg" + (err ? " err" : ""); };
      var hu = r.out.hosted && r.out.hosted.url ? new URL(r.out.hosted.url, location.href).href : (r.out.jobId ? new URL("/api/build/" + r.out.jobId + "/file", location.href).href : "");
      var save = function () {
        if (hu) { var a = document.createElement("a"); a.href = hu; a.download = nm; a.rel = "noopener"; document.body.appendChild(a); a.click(); a.remove(); return; }   // built on our server: download straight from it
        var R = root.DTREPO; (R.swSave ? R.swSave(blob, nm) : Promise.reject()).catch(function () { try { linkSave(blob, nm); } catch (e) { say(t("Couldn't start the download. Try Share."), true); } });
      };
      var share = function () {
        var n = root.navigator;
        if (hu && n && n.share) { n.share({ title: nm, url: hu }).catch(function (e) { if (e && e.name !== "AbortError") say(t("Couldn't share it."), true); }); return; }
        if (hu) { try { n.clipboard.writeText(hu); say(t("Link copied.")); } catch (e) { say(hu); } return; }
        sharePicked(blob, nm).catch(function (e) { if (e && e.name !== "AbortError") say(t(e && e.message ? e.message : "Couldn't share it."), true); });
      };
      var sheet = el("div", { class: "st-sheet", hidden: "" });
      var showSheet = function (u) {
        var APPS = [["Feather", function (x) { return "feather://install/" + x; }], ["E-Sign", function (x) { return "esign://install?url=" + enc(x); }], ["GBox", function (x) { return "gbox://install?url=" + enc(x); }], ["FlareStore", function (x) { return "flarestore://install?url=" + enc(x); }], ["AltStore", function (x) { return "altstore://install?url=" + enc(x); }]];
        sheet.replaceChildren.apply(sheet, [el("p", { text: t("Open it in your sideloader:") })].concat(APPS.map(function (a) { return el("a", { class: "st-sa", href: a[1](u), text: a[0] }); })));
        sheet.hidden = false;
      };
      var direct = function (b) {
        if (hu) return showSheet(hu);
        b.disabled = true; say(t("Uploading…"));
        root.DTREPO.hostBlob(blob, nm, function (got, tot) { say(t("Uploading… {p}%", { p: Math.floor(got * 100 / (tot || 1)) })); }).then(function (h) {
          say(""); b.disabled = false; showSheet(h && h.url ? new URL(h.url, location.href).href : "");
        }).catch(function (e) { b.disabled = false; say(t(e && e.message ? e.message : "Couldn't upload it."), true); });
      };
      var recipe = function (b) { var n = t("Recipe") + " " + new Date().toISOString().slice(0, 10); saveProfile(A.bid, { name: n, names: names, setVersion: set.version, opt: U.opt, at: Date.now() }); b.lastChild.textContent = t("Saved"); b.disabled = true; };
      var small = el("div", { class: "st-ab4" },
        btn("code", t("View Logs"), function () { view = "log"; paint(); }, "sm"), btn("refresh", t("Build Again"), function () { runBuild(host, A, U, set, qs, target, lib, force); }, "sm"),
        btn("sliders", t("Edit Injection"), function () { drawInject(host, A, qs); }, "sm"), btn("bookmark", t("Save Recipe"), recipe, "sm"));
      var sign = U.opt.resign ? t("Unsigned") : t("Original signature");
      return [big, el("h2", { class: "st-done", text: warn.length ? t("Build finished with warnings") : t("Build Completed") }),
        el("p", { class: "st-cmsg2", text: warn.length ? warn.map(function (c) { return c.text; }).join(" · ") : t("Your IPA has been decrypted, injected and rebuilt.") }),
        el("div", { class: "st-card st-rs" }, el("div", { class: "st-ac" }, icon(A.icon, A.bid, A.name), el("span", { class: "st-tt" }, el("b", { text: A.name }), el("small", { text: nm }))),
          el("div", { class: "st-chips" }, el("span", { class: "st-pill ok", text: "✓ " + (viaRepo ? t("Repo IPA") : t("Decrypted")) }), el("span", { class: "st-pill ok", text: "✓ " + t("Injected ({n})", { n: picks.length }) }), el("span", { class: "st-pill blue", text: sign })),
          el("div", { class: "st-stat3" }, el("span", {}, el("small", { text: t("Version") }), el("b", { text: "v" + (r.rel.ver || target) })), el("span", {}, el("small", { text: t("Size") }), el("b", { text: kb(blob.size) })), el("span", {}, el("small", { text: t("Time") }), el("b", { text: secs + "s" })))),
        btn("download", t("Download IPA"), save, "big"), el("div", { class: "st-ab2" }, btn("phone", t("Install (Direct)"), direct), btn("share", t("Share"), share)), sheet, msg, small];
    }
    function failView() {
      var big = el("span", { class: "st-bigok bad" }); big.appendChild(ic("x", 44));
      var again = el("button", { type: "button", class: "st-ab big" }, ic("refresh", 20), el("span", { text: t("Try Again") })); again.addEventListener("click", function () { runBuild(host, A, U, set, qs, target, lib, force); });
      var edit = el("button", { type: "button", class: "st-ab" }, ic("sliders", 20), el("span", { text: t("Edit Injection") })); edit.addEventListener("click", function () { drawInject(host, A, qs); });
      var logs = el("button", { type: "button", class: "st-ab" }, ic("code", 20), el("span", { text: t("View Logs") })); logs.addEventListener("click", function () { view = "log"; paint(); });
      var kids = [big, el("h2", { class: "st-done", text: t("Build didn't finish") }), el("p", { class: "st-cmsg2 err", text: failed })];
      if (/encrypted|fairplay/i.test(failed) && viaRepo && /^\d{5,12}$/.test(String(A.aid || ""))) {
        var dec = el("button", { type: "button", class: "st-ab big" }, ic("lock", 20), el("span", { text: t("Decrypt from the App Store and retry") })); dec.addEventListener("click", function () { runBuild(host, A, U, set, qs, target, lib, true); });
        kids.push(el("p", { class: "st-cmsg2", text: t("The repo's IPA is still encrypted.") }), dec);
      }
      return kids.concat([again, el("div", { class: "st-ab2" }, edit, logs)]);
    }
    function paint() {
      var kids = view === "log" ? logView() : done ? doneView() : failed ? failView() : progressView();
      host.replaceChildren(el("div", { class: "st st-run" }, kids));
      var f = host.querySelector(".st-fill"); if (f) f.style.width = pct() + "%";
      var lb = host.querySelector(".st-logbox"); if (lb) lb.scrollTop = lb.scrollHeight;
    }
    var safeNm = function (s) { return String(s || "app").replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60) || "app"; };
    paint(); log(t("Starting Decrypt & Inject…"));
    engine().then(function () {
      var R = root.DTREPO, settings = R.defaults(); settings.where = "server"; settings.base = U.inj.base; settings.folder = U.inj.folder; settings.remove = Object.keys(U.strip); settings.rewrite = U.opt.clean !== false; settings.stripSig = U.opt.resign !== false;
      var a = { name: A.name, bid: A.bid, icon: A.icon, current: null, store: true };
      var up = { ver: target, store: { id: A.aid, ver: A.latest, name: A.name, minos: A.minos }, lib: lib, source: lib ? t("Library") : t("App Store"), pinned: !!target && target !== A.latest, repoUrl: rp ? rp.url : "", repoSize: rp ? rp.size : 0, preferRepo: viaRepo };
      var useSet = Object.assign({}, set, { only: names });
      var cfg = { settings: settings, serverOnly: true, libs: U.custom.map(function (c) { return c.framework ? { name: c.name, framework: c.framework, exec: c.exec, files: c.files, size: c.size } : { name: c.name, blob: c.blob, size: c.size }; }), autoScan: false, useSet: function (prog) { return picks.length ? R.Libs.load(useSet, prog) : Promise.resolve({ keep: null, libs: [] }); } };
      if (picks.length) log(t("Loading saved libraries ({n})…", { n: picks.length })); if (U.custom.length) log(t("Adding your own: {n}", { n: U.custom.map(function (c) { return c.name; }).join(", ") }));
      return R.buildApp({ api: H.api, refresh: H.refresh }, a, up, cfg, rep);
    }).then(function (r) {
      if (cancelled) return; S.fin = "run"; paint(); log(t("Packaging output IPA…"));
      done = r; S.fin = "done"; log(t("Build completed."), "ok"); view = "progress"; paint();
    }).catch(function (e) { if (!failed) failed = String(e && e.message ? e.message : t("Something went wrong.")); log(failed, "err"); paint(); });
  }
  function sharePicked(blob, name) {
    var f = new File([blob], name, { type: "application/octet-stream" }), n = root.navigator;   // not async before navigator.share: the share sheet only opens straight from a tap
    if (!n || !n.share || !n.canShare || !n.canShare({ files: [f] })) return Promise.reject(new Error(t("This browser can't share files.")));
    return n.share({ files: [f], title: name });
  }
  function linkSave(blob, name) { var a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = name; document.body.appendChild(a); a.click(); a.remove(); setTimeout(function () { URL.revokeObjectURL(a.href); }, 600000); }

  var api = { home: home, importRepo: importRepo, search: search, app: app, inject: inject, loadRepo: loadRepo, compat: compat, verCmp: verCmp, K_RUN: K_RUN };
  root.DTSTUDIO = api; if (typeof module !== "undefined") module.exports = api;
})();
