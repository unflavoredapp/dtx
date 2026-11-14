# tetherless.dev OTA (backloop.dev replacement)

Decrypt.team’s on-device installer defaults to **`ota.tetherless.dev`**.

## DNS (required)

At your DNS host for `tetherless.dev`:

| Name | Type | Value |
|------|------|--------|
| `ota` | A | `127.0.0.1` |
| `*` (optional) | A | `127.0.0.1` |

Same idea as backloop.dev: the name resolves on-device to loopback so installd fetches the manifest/IPA from the app’s local HTTPS server.

## TLS (required for automated OTA)

The app defaults to **public pack** mode and calls `OTABootstrap.ensurePublicPack` on every launch (and when becoming active). Serve a Feather/backloop-compatible file at:

`https://tetherless.dev/pack.json`

Without that file, launch refresh fails and OTA falls back to any previously cached pack (or errors if none).

Do **not** publish a Let’s Encrypt wildcard private key in a public `pack.json` if you can avoid it — that is why [backloop.dev was discontinued](https://backloop.dev/). If you must automate like backloop, expect revocation and re-issue, or use Local CA under Settings → On-Device OTA.

## pack.json shape

```json
{
  "cert": "-----BEGIN CERTIFICATE-----\\n...\\n-----END CERTIFICATE-----\\n",
  "ca": "-----BEGIN CERTIFICATE-----\\n...\\n-----END CERTIFICATE-----\\n",
  "key1": "-----BEGIN PRIVATE KEY-----\\n...",
  "key2": "...\\n-----END PRIVATE KEY-----\\n",
  "info": {
    "issuer": { "commonName": "*.tetherless.dev" },
    "domains": { "commonName": "*.tetherless.dev" }
  }
}
```

`key1` + `key2` are concatenated (Feather/backloop shape). Only use this with a **local** or otherwise non-publicly-trusted CA, or accept that a public CA will revoke it.
