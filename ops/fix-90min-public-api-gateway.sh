#!/usr/bin/env bash
set -Eeuo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
CONF="/etc/nginx/conf.d/00-90min-production.conf"
BACKUP="/root/00-90min-production-before-public-api-${STAMP}.conf"
PUBLIC_API="/var/www/web/api/index.php"

fail() {
  echo "CHYBA: $*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "Spusť jako root."
[ -f "$CONF" ] || fail "Chybí $CONF"
[ -f "$PUBLIC_API" ] || fail "Chybí veřejná API brána $PUBLIC_API"

cp -a "$CONF" "$BACKUP"

rollback() {
  local rc=$?
  trap - ERR INT TERM
  cp -a "$BACKUP" "$CONF"
  nginx -t || true
  systemctl reload nginx || true
  echo "Změna byla vrácena ze zálohy: $BACKUP" >&2
  exit "$rc"
}
trap rollback ERR INT TERM

# Veřejný web zůstává na svém vlastním frontendu. Mění se pouze API front controller.
sed -i \
  -e 's#/var/www/app\.90min\.cz/api/index\.php#/var/www/web/api/index.php#g' \
  -e 's#fastcgi_param DOCUMENT_ROOT /var/www/app\.90min\.cz;#fastcgi_param DOCUMENT_ROOT /var/www/web;#g' \
  "$CONF"

grep -q 'fastcgi_param SCRIPT_FILENAME /var/www/web/api/index.php;' "$CONF" || fail "SCRIPT_FILENAME nebyl přepnut."
grep -q 'fastcgi_param DOCUMENT_ROOT /var/www/web;' "$CONF" || fail "DOCUMENT_ROOT nebyl přepnut."

nginx -t
systemctl reload nginx
sleep 2

check_json() {
  local host="$1"
  local path="$2"
  local headers body code type
  headers="$(mktemp)"
  body="$(mktemp)"

  code="$(curl -ksS --resolve "${host}:443:127.0.0.1" \
    -H 'Accept: application/json' \
    -D "$headers" -o "$body" -w '%{http_code}' \
    "https://${host}${path}")"

  type="$(awk 'BEGIN{IGNORECASE=1} /^content-type:/{gsub("\r",""); print $2; exit}' "$headers")"
  echo "${host}${path}: HTTP ${code}, Content-Type ${type:-neuveden}"

  [[ "$code" =~ ^2 ]] || { head -c 500 "$body"; echo; return 1; }
  [[ "${type,,}" != text/html* ]] || { head -c 500 "$body"; echo; return 1; }
  [ -s "$body" ] || return 1

  rm -f "$headers" "$body"
}

check_json dev.90min.cz '/api/articles?limit=1'
check_json 90min.cz '/api/articles?limit=1'

trap - ERR INT TERM

echo
echo '========================================'
echo 'HOTOVO: veřejný web zůstal samostatný.'
echo 'Frontend 90min.cz nebyl změněn.'
echo 'API 90min.cz nyní používá stejnou veřejnou API bránu jako dev.90min.cz:'
echo '/var/www/web/api/index.php'
echo 'Tato brána čte obsah z backendu app.90min.cz.'
echo "Záloha: $BACKUP"
echo '========================================'
