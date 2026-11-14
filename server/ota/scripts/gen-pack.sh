#!/usr/bin/env bash
# Generate a private OTA CA + wildcard leaf for *.tetherless.dev and write a
# Feather/backloop-compatible pack.json into server/ota/public/.
#
# CA private key → server/ota/secrets/ (gitignored).
# Leaf key → pack.json (intentional; devices trust our CA once).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS="$ROOT/secrets"
PUB="$ROOT/public"
WORK="$ROOT/dist"
DOMAIN="${OTA_DOMAIN:-tetherless.dev}"
DAYS_CA="${OTA_CA_DAYS:-3650}"
DAYS_LEAF="${OTA_LEAF_DAYS:-397}"

mkdir -p "$SECRETS" "$PUB" "$WORK"
cd "$WORK"

if [[ -f "$SECRETS/ca.key" && -f "$SECRETS/ca.crt" && "${OTA_FORCE_NEW_CA:-}" != "1" ]]; then
  echo "Reusing existing CA in $SECRETS"
  cp "$SECRETS/ca.key" ca.key
  cp "$SECRETS/ca.crt" ca.crt
else
  echo "Creating new OTA root CA"
  openssl genrsa -out ca.key 4096
  openssl req -new -x509 -days "$DAYS_CA" -key ca.key -out ca.crt \
    -subj "/CN=Uncrypt Tetherless OTA Root/O=Decrypt.team/C=US"
  cp ca.key ca.crt "$SECRETS/"
  chmod 600 "$SECRETS/ca.key"
fi

openssl genrsa -out server.key 2048
cat > san.cnf <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext
[dn]
CN = *.${DOMAIN}
O = Decrypt.team
C = US
[req_ext]
subjectAltName = @alt
[alt]
DNS.1 = *.${DOMAIN}
DNS.2 = ${DOMAIN}
[v3_leaf]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

openssl req -new -key server.key -out server.csr -config san.cnf
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days "$DAYS_LEAF" -extfile san.cnf -extensions v3_leaf
cat server.crt ca.crt > fullchain.pem
cp server.key privkey.pem
openssl verify -CAfile ca.crt server.crt

export WORK PUB DOMAIN
python3 <<'PY'
import json, pathlib, subprocess, datetime, os
work = pathlib.Path(os.environ["WORK"])
pub = pathlib.Path(os.environ["PUB"])
domain = os.environ["DOMAIN"]
cert = (work / "fullchain.pem").read_text()
key = (work / "privkey.pem").read_text()
ca = (work / "ca.crt").read_text()
mid = len(key) // 2
nl = key.rfind("\n", 0, mid)
if nl < 0: nl = mid
key1, key2 = key[:nl + 1], key[nl + 1:]
raw = subprocess.check_output(
    ["openssl", "x509", "-in", str(work / "server.crt"), "-noout", "-enddate"],
    text=True,
).split("=", 1)[1].strip()
dt = datetime.datetime.strptime(raw, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
not_after = dt.strftime("%Y-%m-%dT%H:%M:%SZ")
pack = {
    "version": {"num": "1", "message": "tetherless.dev OTA pack (private CA)"},
    "domain": domain,
    "cert": cert,
    "ca": ca,
    "key1": key1,
    "key2": key2,
    "key": key,
    "not_after": not_after,
    "sans": [f"*.{domain}", domain],
    "info": {
        "issuer": {"commonName": "Uncrypt Tetherless OTA Root"},
        "domains": {"commonName": f"*.{domain}"},
    },
}
pub.mkdir(parents=True, exist_ok=True)
(pub / "pack.json").write_text(json.dumps(pack, indent=2) + "\n")
(pub / "server.crt").write_text(cert)
(pub / "server.pem").write_text(key)
(pub / "ca.crt").write_text(ca)
(pub / "commonName.txt").write_text(f"*.{domain}\n")
(pub / "index.html").write_text(
    f"<h1>{domain}</h1>\n<p>OTA pack: <a href=\"/pack.json\">pack.json</a></p>\n"
)
print(f"Wrote {pub / 'pack.json'} (not_after={not_after})")
PY
