#!/usr/bin/env bash
set -Eeuo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/90min-nginx-backup-${STAMP}"
NEW_CONF="/etc/nginx/conf.d/00-90min-production.conf"
WEB_ROOT="/var/www/90min.cz/dist"
API_FRONT="/var/www/app.90min.cz/api/index.php"

log() { printf '\n=== %s ===\n' "$*"; }
fail() { printf '\nCHYBA: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Skript musí běžet jako root."
command -v nginx >/dev/null 2>&1 || fail "Nginx není dostupný."
command -v python3 >/dev/null 2>&1 || fail "Python 3 není dostupný."
command -v curl >/dev/null 2>&1 || fail "curl není dostupný."
command -v openssl >/dev/null 2>&1 || fail "openssl není dostupný."
[ -f "$WEB_ROOT/index.html" ] || fail "Chybí frontend $WEB_ROOT/index.html"
[ -f "$API_FRONT" ] || fail "Chybí API front controller $API_FRONT"

PHP_SOCKET=""
for s in /run/php/php8.2-fpm.sock /run/php/php8.3-fpm.sock /run/php/php8.1-fpm.sock /run/php/php*-fpm.sock; do
  [ -S "$s" ] || continue
  PHP_SOCKET="$s"
  break
done
[ -n "$PHP_SOCKET" ] || fail "Nebyl nalezen PHP-FPM socket."
PHP_SERVICE="$(basename "$PHP_SOCKET" .sock)"

CERT_DIR=""
while IFS= read -r d; do
  [ -r "$d/fullchain.pem" ] && [ -r "$d/privkey.pem" ] || continue
  if openssl x509 -in "$d/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | grep -q 'DNS:90min.cz'; then
    CERT_DIR="$d"
    break
  fi
done < <(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d -name '90min.cz*' 2>/dev/null | sort)
[ -n "$CERT_DIR" ] || fail "Nebyl nalezen certifikát pro 90min.cz."

mkdir -p "$BACKUP"
cp -a /etc/nginx "$BACKUP/nginx"

restore() {
  local rc=$?
  trap - ERR INT TERM
  printf '\nObnovuji původní konfiguraci Nginxu z %s ...\n' "$BACKUP"
  find /etc/nginx -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -a "$BACKUP/nginx/." /etc/nginx/
  nginx -t || true
  systemctl reload nginx || true
  exit "$rc"
}
trap restore ERR INT TERM

log "1/6 Záloha a načtené konfigurace"
NGINX_DUMP="$(mktemp)"
nginx -T >"$NGINX_DUMP" 2>&1
mapfile -t CONFIG_FILES < <(
  sed -nE 's/^# configuration file ([^:]+):$/\1/p' "$NGINX_DUMP" |
  grep '^/etc/nginx/' |
  sort -u
)
[ "${#CONFIG_FILES[@]}" -gt 0 ] || fail "Nebyly nalezeny načtené konfigurace."
printf 'Záloha: %s\n' "$BACKUP"
printf 'Certifikát: %s\n' "$CERT_DIR"
printf 'PHP-FPM: %s\n' "$PHP_SOCKET"

log "2/6 Odstranění konfliktních bloků pro 90min.cz a www.90min.cz"
python3 - "$NEW_CONF" "${CONFIG_FILES[@]}" <<'PY'
from pathlib import Path
import re, sys

new_conf = Path(sys.argv[1]).resolve()
paths = []
seen = set()
for raw in sys.argv[2:]:
    try:
        p = Path(raw).resolve()
    except Exception:
        continue
    if p == new_conf or p in seen or not p.is_file():
        continue
    seen.add(p)
    paths.append(p)

def matching_brace(text, opening):
    depth = 0
    quote = None
    escaped = False
    i = opening
    while i < len(text):
        c = text[i]
        if quote:
            if escaped:
                escaped = False
            elif c == '\\':
                escaped = True
            elif c == quote:
                quote = None
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
            i += 1
            continue
        if c == '#':
            nl = text.find('\n', i)
            if nl < 0:
                return -1
            i = nl + 1
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

def server_blocks(text):
    pattern = re.compile(r'(?m)^[ \t]*server[ \t]*\{')
    result = []
    pos = 0
    while True:
        m = pattern.search(text, pos)
        if not m:
            break
        op = text.find('{', m.start(), m.end())
        cl = matching_brace(text, op)
        if cl < 0:
            raise RuntimeError('Neuzavřený server blok')
        result.append((m.start(), cl + 1, text[m.start():cl + 1]))
        pos = cl + 1
    return result

def has_target_name(block):
    names = []
    for directive in re.findall(r'(?m)^[ \t]*server_name[ \t]+([^;]+);', block):
        names.extend(re.split(r'\s+', directive.strip()))
    return '90min.cz' in names or 'www.90min.cz' in names

removed = []
for path in paths:
    text = path.read_text(encoding='utf-8', errors='replace')
    blocks = server_blocks(text)
    targets = [(start, end) for start, end, block in blocks if has_target_name(block)]
    if not targets:
        continue
    for start, end in reversed(targets):
        text = text[:start] + '\n# 90min.cz block removed by emergency repair\n' + text[end:]
    path.write_text(text, encoding='utf-8')
    removed.append((str(path), len(targets)))

for path, count in removed:
    print(f'UPRAVENO: {path} ({count} bloků)')
print(f'CELKEM_ODSTRANENO={sum(c for _, c in removed)}')
PY

log "3/6 Vytvoření jednoznačné produkční konfigurace"
cat >"$NEW_CONF" <<EOF_CONF
# 90min.cz canonical production vhost — generated ${STAMP}

server {
    listen 80;
    listen [::]:80;
    server_name 90min.cz www.90min.cz;
    return 301 https://90min.cz\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name www.90min.cz;

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    return 301 https://90min.cz\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name 90min.cz;

    root ${WEB_ROOT};
    index index.html;

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    client_max_body_size 64m;

    location = /api {
        return 308 /api/;
    }

    location ^~ /api/ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME ${API_FRONT};
        fastcgi_param SCRIPT_NAME /api/index.php;
        fastcgi_param DOCUMENT_ROOT /var/www/app.90min.cz;
        fastcgi_param HTTP_AUTHORIZATION \$http_authorization;
        fastcgi_param PATH_INFO \$uri;
        fastcgi_pass unix:${PHP_SOCKET};
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF_CONF

log "4/6 Kontrola a načtení"
nginx -t
systemctl restart "$PHP_SERVICE"
systemctl reload nginx
sleep 2

log "5/6 Lokální ověření všech tří problémů"
APEX_HEADERS="$(mktemp)"
APEX_BODY="$(mktemp)"
APEX_HTTP="$(curl -ksS --resolve '90min.cz:443:127.0.0.1' -D "$APEX_HEADERS" -o "$APEX_BODY" -w '%{http_code}' 'https://90min.cz/?repair=1')"
APEX_TYPE="$(awk 'BEGIN{IGNORECASE=1} /^content-type:/{gsub("\r",""); print $2; exit}' "$APEX_HEADERS")"

WWW_HEADERS="$(mktemp)"
curl -ksS --resolve 'www.90min.cz:443:127.0.0.1' -D "$WWW_HEADERS" -o /dev/null 'https://www.90min.cz/test-redirect'
WWW_CODE="$(awk 'NR==1{print $2}' "$WWW_HEADERS")"
WWW_LOCATION="$(awk 'BEGIN{IGNORECASE=1} /^location:/{gsub("\r",""); print $2; exit}' "$WWW_HEADERS")"

API_HEADERS="$(mktemp)"
API_BODY="$(mktemp)"
API_HTTP="$(curl -ksS --resolve '90min.cz:443:127.0.0.1' -H 'Accept: application/json' -D "$API_HEADERS" -o "$API_BODY" -w '%{http_code}' 'https://90min.cz/api/health?repair=1')"
API_TYPE="$(awk 'BEGIN{IGNORECASE=1} /^content-type:/{gsub("\r",""); print $2; exit}' "$API_HEADERS")"

printf 'Apex: HTTP %s, Content-Type %s\n' "$APEX_HTTP" "${APEX_TYPE:-neuveden}"
printf 'WWW: HTTP %s, Location %s\n' "$WWW_CODE" "${WWW_LOCATION:-neuvedena}"
printf 'API: HTTP %s, Content-Type %s\n' "$API_HTTP" "${API_TYPE:-neuveden}"

[ "$APEX_HTTP" = "200" ] || fail "Hlavní web lokálně nevrací HTTP 200."
! grep -qi 'Welcome to nginx' "$APEX_BODY" || fail "Hlavní web stále vrací výchozí stránku Nginxu."
[ "$WWW_CODE" = "301" ] || [ "$WWW_CODE" = "308" ] || fail "WWW nevrací jediný redirect."
[ "$WWW_LOCATION" = "https://90min.cz/test-redirect" ] || fail "WWW přesměrování míří jinam: $WWW_LOCATION"
[ "$API_HTTP" -ge 200 ] 2>/dev/null && [ "$API_HTTP" -lt 500 ] 2>/dev/null || fail "API vrací HTTP $API_HTTP."
[[ "${API_TYPE,,}" != text/html* ]] || fail "API stále vrací HTML místo API odpovědi."

log "6/6 Výsledek"
trap - ERR INT TERM
printf 'HOTOVO — sjednocený Nginx pro IPv4 i IPv6.\n'
printf '90min.cz obsluhuje frontend z %s\n' "$WEB_ROOT"
printf 'www.90min.cz provádí jediný redirect na 90min.cz\n'
printf '/api/* je směrováno do %s\n' "$API_FRONT"
printf 'Záloha původního Nginxu: %s\n' "$BACKUP"
printf '\nVeřejná kontrola:\n'
curl -4 -ksSI --max-time 10 https://90min.cz/ | sed -n '1,8p' || true
curl -4 -ksSI --max-time 10 https://www.90min.cz/ | sed -n '1,8p' || true
curl -4 -ksS -D - --max-time 10 https://90min.cz/api/health -o /tmp/90min-api-public-body.txt | sed -n '1,10p' || true
