# tetherless.dev OTA backend

Decrypt.team installs over **`ota.tetherless.dev`** using a Feather/backloop-shaped pack.

## 1. DNS (Dynadot)

| Name | Type | Value |
|------|------|--------|
| `ota` | A | `127.0.0.1` |
| `*` (optional) | A | `127.0.0.1` |

Apex `tetherless.dev` stays on the VPS (`198.96.93.10`) for hosting `pack.json`.

## 2. Generate the pack

```sh
./server/ota/scripts/gen-pack.sh
```

Writes:

- `server/ota/public/pack.json` (+ `server.crt` / `server.pem` / `ca.crt` / `index.html`)
- `server/ota/secrets/ca.key` — **keep private**, gitignored

This pack uses a **private CA** (not Let’s Encrypt), so it cannot be revoked the way backloop.dev was. Devices must trust the CA once (the app offers the profile on launch).

## 3. Deploy to the VPS (same box as decrypt.team)

```sh
export TETHERLESS_SSH_HOST=198.96.93.10   # or tetherless.dev
export TETHERLESS_SSH_USER=root            # or your deploy user
export TETHERLESS_SSH_KEY=~/.ssh/tetherless
export TETHERLESS_DOCROOT=/var/www/tetherless.dev
./server/ota/scripts/deploy-public.sh
```

Apache sample: `server/ota/apache/tetherless.dev.conf`

After deploy: `curl -fsS https://tetherless.dev/pack.json | head`

## 4. GitHub `certs` branch (app fallback)

The app tries `https://tetherless.dev/pack.json` first, then `unflavoredapp/dtx` @ `certs` (`pack.json` / `server.crt` / `server.pem`). Push public files there when the VPS is unreachable.

## 5. App behaviour

- Launch / foreground → `OTABootstrap.ensurePublicPack` pulls the pack
- If the pack CA is not trusted → one-time trust-profile share sheet
- User enables **Full Trust** under Settings → General → About → Certificate Trust Settings
- OTA installs then work against `https://ota.tetherless.dev/...` on loopback
