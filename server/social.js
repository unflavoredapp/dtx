"use strict";
// "Login with Telegram" and "Login with Discord" for decrypt.team. Each works once its keys are in the env file:
//   Telegram:  TG_BOT_TOKEN         (a bot from @BotFather; the person taps Open Telegram, then Confirm inside the bot)
//   Discord:   DISCORD_CLIENT_ID + DISCORD_CLIENT_SECRET   (discord.com/developers, redirect URL  <SITE_URL>/auth/discord )
// A first-time visitor gets an account automatically. site.js supplies socialUser(provider, id, nameHint) -> user id.
const crypto = require("crypto");

module.exports = function mountSocial({ app, env, SITE_URL, limited, fail, guard, jsonBody, jsonErr, cookieOf, cookieFlags, sign, safeEq, setSession, socialUser, me, userById, tierOfTg, betaTg, avatars }) {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const TG_TOKEN = String(env.TG_BOT_TOKEN || ""), TG_BASE = String(env.TG_API_BASE || "https://api.telegram.org").replace(/\/+$/, "");
  const TG_POLL_S = Number(env.TG_POLL_SEC) || 25;
  const DC_ID = String(env.DISCORD_CLIENT_ID || ""), DC_SECRET = String(env.DISCORD_CLIENT_SECRET || "");
  const DC_API = String(env.DISCORD_API_BASE || "https://discord.com/api").replace(/\/+$/, "");
  const DC_AUTH = String(env.DISCORD_AUTH_URL || "https://discord.com/oauth2/authorize");
  const DC_REDIRECT = SITE_URL + "/auth/discord";

  // ---------- which providers are set up (the popup shows both buttons either way) ----------
  let tgBot = ""; // the bot's @username, found once with getMe
  async function tg(method, body, ms) {
    const r = await fetch(`${TG_BASE}/bot${TG_TOKEN}/${method}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body || {}), signal: AbortSignal.timeout(ms || 10000) });
    const j = await r.json().catch(() => null);
    if (!j || !j.ok) throw new Error((j && j.description) || "Telegram error");
    return j.result;
  }
  async function botName() {
    if (tgBot) return tgBot;
    try { tgBot = String((await tg("getMe")).username || ""); } catch (e) { console.warn("Telegram login: getMe failed:", e.message); }
    return tgBot;
  }
  app.get("/api/tgbot", async (_req, res) => {
    res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
    const bot = TG_TOKEN ? await botName() : "";
    if (!bot) return res.status(404).json({ ok: false, error: "The Telegram bot isn't available right now." });
    return res.json({ ok: true, url: "https://t.me/" + bot });
  });
  app.get("/api/auth/providers", async (_req, res) => {
    res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
    res.json({ ok: true, telegram: !!(TG_TOKEN && (await botName())), discord: !!(DC_ID && DC_SECRET) });
  });

  // ---------- Telegram ----------
  // 1. The page asks for a login token. 2. The person opens t.me/<bot>?start=<token>. 3. The bot asks them to confirm.
  // 4. The page, polling with its own token, is then signed in. The token is only ever known to that browser.
  const pending = new Map(); // token -> { at, state: "open"|"confirm"|"done", from, tgId, hint }
  setInterval(() => { const old = Date.now() - 5 * 60000; for (const [k, v] of pending) if (v.at < old) pending.delete(k); }, 30000).unref();
  // The Dylib Source tool (tgbot-dylib.js) shares this poll loop: Telegram allows only ONE getUpdates consumer per bot token. With it on, the loop never stops.
  let dylibBot = null;
  if (TG_TOKEN && String(env.TG_DYLIB || "1") !== "0") { try { dylibBot = require("./tgbot-dylib")({ token: TG_TOKEN, base: TG_BASE, tg, env, tierOf: tierOfTg, app, site: SITE_URL, limited }); } catch (e) { console.warn("Telegram dylib tool not loaded (upload tgbot-dylib.js and tgbot-dylib-worker.js next to site.js):", e.message); } }
  let polling = false, offset = 0, badPolls = 0;
  async function pollLoop() {
    if (polling || !TG_TOKEN) return;
    polling = true;
    try {
      while (pending.size || dylibBot) {
        try {
          const ups = await tg("getUpdates", { offset, timeout: TG_POLL_S, allowed_updates: ["message", "callback_query"] }, (TG_POLL_S + 10) * 1000);
          badPolls = 0;
          for (const u of ups) { offset = u.update_id + 1; handle(u).catch((e) => console.warn("Telegram update:", e.message)); }
        } catch (e) { console.warn("Telegram poll:", e.message); await sleep(Math.min(30000, 3000 * ++badPolls)); }
      }
    } finally { polling = false; }
  }
  async function handle(u) {
    if (dylibBot && (await dylibBot.handle(u))) return;
    const m = u.message, cb = u.callback_query;
    if (m && m.chat && m.chat.type === "private" && typeof m.text === "string") {
      const t = /^\/start(?:@\w+)?\s+([A-Za-z0-9_-]{16,64})$/.exec(m.text.trim());
      if (!t) { await tg("sendMessage", { chat_id: m.chat.id, text: "To log in to Decrypt.team, open the site and tap Login with Telegram." }); return; }
      const p = pending.get(t[1]);
      if (!p || p.state === "done") { await tg("sendMessage", { chat_id: m.chat.id, text: "This login link has expired. Start again on the website." }); return; }
      p.state = "confirm"; p.from = { id: m.from.id, username: m.from.username || "", first: m.from.first_name || "" };
      await tg("sendMessage", { chat_id: m.chat.id, text: "Log in to Decrypt.team?\n\nOnly confirm if you just tapped Login with Telegram on the site yourself.", reply_markup: { inline_keyboard: [[{ text: "Confirm login", callback_data: "ok:" + t[1] }, { text: "Cancel", callback_data: "no:" + t[1] }]] } });
    } else if (cb && typeof cb.data === "string") {
      const d = /^(ok|no):([A-Za-z0-9_-]{16,64})$/.exec(cb.data), p = d && pending.get(d[2]);
      if (!p || p.state !== "confirm" || !p.from || p.from.id !== cb.from.id) { await tg("answerCallbackQuery", { callback_query_id: cb.id, text: "This login link has expired." }); return; }
      if (d[1] === "no") { pending.delete(d[2]); await tg("answerCallbackQuery", { callback_query_id: cb.id, text: "Cancelled." }); return; }
      p.state = "done"; p.tgId = String(cb.from.id); p.hint = p.from.username || p.from.first;
      await tg("answerCallbackQuery", { callback_query_id: cb.id, text: "Logged in." });
      if (cb.message && cb.message.chat) {
        const back = p.app ? { inline_keyboard: [[{ text: "Open the Decrypt.Team app", url: SITE_URL + "/app/open" }]] } : null;
        const done = { chat_id: cb.message.chat.id, text: back ? "Logged in to Decrypt.Team.\n\nTap the button to go back to the app." : "Done. Go back to Decrypt.team.", ...(back ? { reply_markup: back } : {}) };
        if (back && cb.message.message_id) await tg("editMessageText", { ...done, message_id: cb.message.message_id }).catch(() => tg("sendMessage", done).catch(() => {}));
        else await tg("sendMessage", done).catch(() => {});
      }
    }
  }
  if (dylibBot) { dylibBot.init(); pollLoop(); }
  app.post("/api/auth/telegram/start", guard, jsonBody, async (req, res) => {
    if (!TG_TOKEN) return fail(res, 404, "Telegram login isn't set up yet.");
    if (limited("ts|" + req.ip, 20, 3600000)) return fail(res, 429, "Too many attempts. Try again later.");
    const bot = await botName();
    if (!bot) return fail(res, 503, "Telegram login isn't available right now.");
    if (pending.size > 500) return fail(res, 503, "Busy. Try again in a minute.");
    const token = crypto.randomBytes(16).toString("hex");
    pending.set(token, { at: Date.now(), state: "open", app: !!(req.body && req.body.app) });
    pollLoop();
    res.json({ ok: true, token, url: `https://t.me/${bot}?start=${token}` });
  }, jsonErr);
  app.get("/api/auth/telegram/poll", async (req, res) => {
    res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
    if (limited("tp|" + req.ip, 120, 60000)) return fail(res, 429, "Slow down.");
    const token = String(req.query.token || ""), p = /^[0-9a-f]{32}$/.test(token) ? pending.get(token) : null;
    if (!p) return res.json({ ok: true, status: "expired" });
    if (p.state !== "done") return res.json({ ok: true, status: "waiting", step: p.state });
    pending.delete(token);
    if (p.app && !(betaTg && betaTg(p.tgId))) return fail(res, 403, "Closed beta. The Decrypt.Team app is only open to Decrypt.Team staff right now.");
    const id = socialUser("tg_id", p.tgId, p.hint);
    if (!id) return fail(res, 403, "This account is disabled.");
    setSession(res, id);
    // Best-effort: pull the person's Telegram profile photo so the app can show it. Never blocks or fails login.
    if (avatars) await avatars.fetchAndCache({ uid: id, tgId: p.tgId, tg, token: TG_TOKEN, base: TG_BASE });
    return res.json({ ok: true, status: "done", user: me(userById.get(id)) });
  });

  app.get("/app/open", (_req, res) => {
    res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'" });
    res.type("html").send('<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><meta http-equiv=refresh content="0;url=decryptteam://signed-in"><title>Decrypt.Team</title><style>body{background:#050507;color:#fff;font:17px -apple-system,sans-serif;text-align:center;padding:60px 24px}a{display:inline-block;margin-top:24px;padding:14px 26px;border-radius:99px;background:#ff8a1f;color:#fff;text-decoration:none;font-weight:700}</style><h2>Logged in</h2><p>Opening the Decrypt.Team app…</p><a href="decryptteam://signed-in">Open the app</a><script>setTimeout(function(){location.href="decryptteam://signed-in"},50)</script>');
  });

  // ---------- Discord ----------
  const redirect = (res, to) => res.status(302).set("Location", to).end();
  app.get("/auth/discord/start", (req, res) => {
    if (!DC_ID || !DC_SECRET) return redirect(res, "/?auth=off");
    if (limited("ds|" + req.ip, 30, 3600000)) return redirect(res, "/?auth=busy");
    const state = crypto.randomBytes(16).toString("hex");
    res.append("Set-Cookie", `dt_dstate=${state}.${sign("d|" + state)}; Max-Age=600; ${cookieFlags}`);
    const q = new URLSearchParams({ client_id: DC_ID, redirect_uri: DC_REDIRECT, response_type: "code", scope: "identify", state, prompt: "none" });
    return redirect(res, DC_AUTH + "?" + q);
  });
  app.get("/auth/discord", async (req, res) => {
    res.set({ "Cache-Control": "no-store" });
    try {
      const [st, sig] = cookieOf(req, "dt_dstate").split(".");
      res.append("Set-Cookie", `dt_dstate=; Max-Age=0; ${cookieFlags}`);
      const code = String(req.query.code || "");
      if (!DC_ID || !st || !sig || !safeEq(sig, sign("d|" + st)) || !safeEq(st, String(req.query.state || "")) || !code) return redirect(res, "/?auth=failed");
      const tr = await fetch(DC_API + "/oauth2/token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, signal: AbortSignal.timeout(10000),
        body: new URLSearchParams({ client_id: DC_ID, client_secret: DC_SECRET, grant_type: "authorization_code", code, redirect_uri: DC_REDIRECT }) });
      const tj = tr.ok ? await tr.json() : null;
      if (!tj || !tj.access_token) return redirect(res, "/?auth=failed");
      const ur = await fetch(DC_API + "/users/@me", { headers: { authorization: "Bearer " + tj.access_token }, signal: AbortSignal.timeout(10000) });
      const u = ur.ok ? await ur.json() : null;
      if (!u || !/^\d{5,25}$/.test(String(u.id || ""))) return redirect(res, "/?auth=failed");
      const id = socialUser("dc_id", String(u.id), u.username || u.global_name || "");
      if (!id) return redirect(res, "/?auth=disabled");
      setSession(res, id);
      return redirect(res, "/");
    } catch (e) { console.warn("Discord login failed:", e.message); return redirect(res, "/?auth=failed"); }
  });
};
