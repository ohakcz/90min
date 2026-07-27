#!/usr/bin/env bash
set -Eeuo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/90min-nginx-emergency-${STAMP}"
TMP="$(mktemp)"
NEWCONF="/etc/nginx/conf.d/00-90min-emergency-proxy.conf"

fail() {
  echo "CHYBA: $*" >&2
  exit 1
}

restore() {
  echo "Obnovuji původní konfiguraci Nginxu..."
  rm -rf /etc/nginx.failed-emergency
  mv /etc/nginx /etc/nginx.failed-emergency
  cp -a "$BACKUP/nginx" /etc/nginx
  nginx -t || true
  systemctl reload nginx || true
}

[ "$(id -u)" -eq 0 ] || fail "Spusť jako root."
command -v nginx >/dev/null || fail "Nginx není dostupný."
command -v python3 >/dev/null || fail "Python 3 není dostupný."
command -v curl >/dev/null || fail "curl není dostupný."

mkdir -p "$BACKUP"
cp -a /etc/nginx "$BACKUP/nginx"

echo "=== 1/5 Kontrola funkčního app.90min.cz ==="
APP_BODY="$(mktemp)"
APP_CODE="$(curl -ksS --resolve app.90min.cz:443:127.0.0.1 -o "$APP_BODY" -w '%{http_code}' https://app.90min.cz/ || true)"
[ "$APP_CODE" = "200" ] || fail "app.90min.cz na lokálním Nginxu nevrací HTTP 200."
if grep -qi "Welcome to nginx" "$APP_BODY"; then
  fail "app.90min.cz vrací výchozí stránku Nginxu."
fi

echo "=== 2/5 Načtení aktivní konfigurace ==="
nginx -T >"$TMP" 2>&1 || fail "Současná konfigurace Nginxu není platná."
mapfile -t FILES < <(sed -nE 's/^# configuration file ([^:]+):$/\1/p' "$TMP" | grep '^/etc/nginx/' | sort -u)
[ "${#FILES[@]}" -gt 0 ] || fail "Nebyly nalezeny aktivní konfigurační soubory."

echo "=== 3/5 Odstranění konfliktních bloků pouze pro 90min.cz a www ==="
python3 - "$NEWCONF" "${FILES[@]}" <<'PY'
from pathlib import Path
import re, sys

newconf = Path(sys.argv[1])
paths = []
seen = set()
for raw in sys.argv[2:]:
    try:
        p = Path(raw).resolve()
    except Exception:
        continue
    if p in seen or not p.is_file():
        continue
    seen.add(p)
    paths.append(p)

def matching_brace(text, opening):
    depth = 0
    quote = None
    esc = False
    i = opening
    while i < len(text):
        c = text[i]
        if quote:
            if esc:
                esc = False
            elif c == '\\':
                esc = True
            elif c == quote:
                quote = None
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
        elif c == '#':
            nl = text.find('\n', i)
            if nl < 0:
                return -1
            i = nl
            continue
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

def server_blocks(text):
    pat = re.compile(r'(?m)^[ \t]*server\s*\{')
    out = []
    pos = 0
    while True:
        m = pat.search(text, pos)
        if not m:
            break
        op = text.find('{', m.start(), m.end())
        cl = matching_brace(text, op)
        if cl < 0:
            break
        out.append((m.start(), cl + 1, text[m.start():cl + 1]))
        pos = cl + 1
    return out

cert = None
key = None
ssl_includes = []
removed = 0

for path in paths:
    text = path.read_text(encoding='utf-8', errors='replace')
    cuts = []
    for start, end, block in server_blocks(text):
        names = []
        for line in re.findall(r'(?m)^\s*server_name\s+([^;]+);', block):
            names.extend(re.split(r'\s+', line.strip()))
        tokens = set(names)
        if '90min.cz' not in tokens and 'www.90min.cz' not in tokens:
            continue
        if 'app.90min.cz' in tokens and not ({'90min.cz', 'www.90min.cz'} & tokens):
            continue
        removed += 1
        cuts.append((start, end))
        if cert is None:
            m = re.search(r'(?m)^\s*ssl_certificate\s+([^;]+);', block)
            if m:
                cert = m.group(1).strip()
        if key is None:
            m = re.search(r'(?m)^\s*ssl_certificate_key\s+([^;]+);', block)
            if m:
                key = m.group(1).strip()
        for inc in re.findall(r'(?m)^\s*include\s+([^;]*ssl[^;]*);', block):
            inc = inc.strip()
            if inc not in ssl_includes:
                ssl_includes.append(inc)
    if cuts:
        for start, end in reversed(cuts):
            text = text[:start] + text[end:]
        path.write_text(text, encoding='utf-8')

if removed == 0:
    print('ERROR:NO_APEX_BLOCKS')
    sys.exit(3)

if cert is None:
    candidate = Path('/etc/letsencrypt/live/90min.cz/fullchain.pem')
    if candidate.exists():
        cert = str(candidate)
if key is None:
    candidate = Path('/etc/letsencrypt/live/90min.cz/privkey.pem')
    if candidate.exists():
        key = str(candidate)
if not cert or not key:
    print('ERROR:NO_CERTIFICATE')
    sys.exit(4)

include_lines = ''.join(f'    include {x};\n' for x in ssl_includes)
config = f'''# Emergency bridge: public 90min.cz serves the known-working app.90min.cz\nserver {{\n    listen 80;\n    listen [::]:80;\n    server_name 90min.cz www.90min.cz;\n    return 301 https://90min.cz$request_uri;\n}}\n\nserver {{\n    listen 443 ssl;\n    listen [::]:443 ssl;\n    server_name www.90min.cz;\n    ssl_certificate {cert};\n    ssl_certificate_key {key};\n{include_lines}    return 301 https://90min.cz$request_uri;\n}}\n\nserver {{\n    listen 443 ssl;\n    listen [::]:443 ssl;\n    server_name 90min.cz;\n    ssl_certificate {cert};\n    ssl_certificate_key {key};\n{include_lines}\n    location / {{\n        proxy_pass https://127.0.0.1:443;\n        proxy_http_version 1.1;\n        proxy_ssl_server_name on;\n        proxy_ssl_name app.90min.cz;\n        proxy_set_header Host app.90min.cz;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto https;\n        proxy_set_header X-Forwarded-Host 90min.cz;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection $connection_upgrade;\n        proxy_redirect https://app.90min.cz/ https://90min.cz/;\n        proxy_cookie_domain app.90min.cz 90min.cz;\n    }}\n}}\n'''
newconf.write_text(config, encoding='utf-8')
print(f'REMOVED_BLOCKS={removed}')
print(f'CERT={cert}')
PY

# Ensure websocket connection map exists without duplicating it.
if ! nginx -T 2>/dev/null | grep -q 'map[[:space:]]\+\$http_upgrade[[:space:]]\+\$connection_upgrade'; then
  cat >/etc/nginx/conf.d/00-connection-upgrade-map.conf <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
EOF
fi

echo "=== 4/5 Kontrola a načtení ==="
if ! nginx -t; then
  restore
  fail "Nová konfigurace neprošla nginx -t."
fi
systemctl reload nginx
sleep 2

echo "=== 5/5 Ověření veřejné domény ==="
OUT="$(mktemp)"
CODE="$(curl -ksS --resolve 90min.cz:443:127.0.0.1 -o "$OUT" -w '%{http_code}' https://90min.cz/ || true)"
if [ "$CODE" != "200" ] || grep -qi "Welcome to nginx" "$OUT"; then
  restore
  fail "90min.cz po opravě nevrací funkční obsah."
fi

API_HEADERS="$(mktemp)"
API_BODY="$(mktemp)"
API_CODE="$(curl -ksS --resolve 90min.cz:443:127.0.0.1 -D "$API_HEADERS" -o "$API_BODY" -w '%{http_code}' https://90min.cz/api/health || true)"
CTYPE="$(awk 'BEGIN{IGNORECASE=1} /^content-type:/{gsub("\r",""); print $2; exit}' "$API_HEADERS")"
if [ "$API_CODE" != "200" ] || [[ "${CTYPE,,}" == text/html* ]]; then
  restore
  fail "API přes 90min.cz stále nevrací JSON."
fi

echo
printf '%s\n' '========================================'
printf '%s\n' 'HOTOVO: 90min.cz nyní bezpečně zrcadlí funkční app.90min.cz'
printf 'Frontend HTTP: %s\n' "$CODE"
printf 'API HTTP: %s, Content-Type: %s\n' "$API_CODE" "$CTYPE"
printf 'Záloha: %s\n' "$BACKUP"
printf '%s\n' '========================================'
