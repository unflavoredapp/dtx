'use strict';
// Caches a signed-in person's Telegram profile photo locally, so the app can show it without the bot token
// ever reaching the client (Telegram's own file URLs embed it) and without hitting Telegram on every request.
// Keyed by the site's own numeric user id, not the Telegram id — survives someone switching Telegram accounts.
const fs = require('fs');
const path = require('path');

function init({ dataDir }) {
  const dir = path.join(dataDir, 'avatars');
  fs.mkdirSync(dir, { recursive: true });
  const idxFile = path.join(dir, '_index.json');
  let idx = {};
  try { idx = JSON.parse(fs.readFileSync(idxFile, 'utf8')) || {}; } catch { /* fresh */ }
  const save = () => { try { fs.writeFileSync(idxFile, JSON.stringify(idx)); } catch (e) { console.error('[avatars] index write failed:', e.message); } };

  const fileFor = (uid) => path.join(dir, `${uid}.jpg`);

  return {
    // A URL the app can load directly (relative — the client prefixes it with the server base). null if we
    // have nothing cached (never fetched yet, or the person has no Telegram profile photo).
    urlFor(uid) {
      if (uid == null) return null;
      const e = idx[uid];
      if (!e || e.none || !fs.existsSync(fileFor(uid))) return null;
      return `/avatar/${uid}.jpg?v=${e.at}`;
    },

    // Pulls the person's current Telegram profile photo (largest size) and caches it to disk. Safe to call on
    // every login: skips the Telegram round trip if we fetched within the last 24h. Never throws — a failed
    // fetch just means no photo shows, it never blocks login.
    async fetchAndCache({ uid, tgId, tg, token, base }) {
      if (!uid || !tgId || !tg || !token) return;
      const e = idx[uid];
      if (e && Date.now() - e.at < 24 * 3600000) return;
      try {
        const photos = await tg('getUserProfilePhotos', { user_id: Number(tgId), limit: 1 });
        const sizes = photos && photos.photos && photos.photos[0];
        if (!sizes || !sizes.length) { idx[uid] = { at: Date.now(), none: true }; save(); return; }
        const biggest = sizes[sizes.length - 1];
        const info = await tg('getFile', { file_id: biggest.file_id });
        const fp = info && info.file_path;
        if (!fp) return;
        const r = await fetch(`${base}/file/bot${token}/${fp}`, { signal: AbortSignal.timeout(15000) });
        if (!r.ok) return;
        const buf = Buffer.from(await r.arrayBuffer());
        fs.writeFileSync(fileFor(uid), buf);
        idx[uid] = { at: Date.now() };
        save();
      } catch (e) { console.warn('[avatars] fetch failed for uid', uid, ':', e.message); }
    },

    // One route, served from wherever this is mounted: GET /avatar/<uid>.jpg
    mount(app) {
      app.get('/avatar/:uid.jpg', (req, res) => {
        const uid = String(req.params.uid || '');
        if (!/^\d+$/.test(uid)) return res.status(404).end();
        const f = fileFor(uid);
        if (!fs.existsSync(f)) return res.status(404).end();
        res.set({ 'Cache-Control': 'public, max-age=86400', 'Content-Type': 'image/jpeg', 'X-Robots-Tag': 'noindex, nofollow' });
        fs.createReadStream(f).pipe(res);
      });
    },
  };
}

module.exports = { init };
