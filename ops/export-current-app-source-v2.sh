#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="/var/www/app.90min.cz"
OUTDIR="/var/www/web/_handoff"
STAMP="$(date +%Y%m%d-%H%M%S)"
NAME="90min-current-app-source-${STAMP}"
ARCHIVE="${OUTDIR}/${NAME}.tar.gz"
PARTIAL="${ARCHIVE}.partial"
NGINX_DUMP="${OUTDIR}/${NAME}-nginx.txt"
INFO="${OUTDIR}/${NAME}-info.txt"

fail() {
  echo
  echo "CHYBA: $*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "Spusť jako root."
[ -d "$APP_ROOT" ] || fail "Chybí $APP_ROOT"
mkdir -p "$OUTDIR"

# Odstraň pouze zbytky předchozího neúspěšného exportu vytvořené naším snapshot skriptem.
find /tmp -maxdepth 3 -type d -name '90min-current-app-source-*' -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUTDIR" -maxdepth 1 -type f -name '90min-current-app-source-*.partial' -delete 2>/dev/null || true

FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
FREE_MB="$((FREE_KB / 1024))"

echo "=== VOLNÉ MÍSTO ==="
echo "${FREE_MB} MB"

[ "$FREE_MB" -ge 150 ] || {
  echo
  echo "Na disku není bezpečná rezerva pro vytvoření archivu."
  echo "Největší adresáře na /var/www a /root:"
  du -xhd1 /var/www /root 2>/dev/null | sort -h | tail -n 20
  exit 2
}

rm -f "$PARTIAL" "$NGINX_DUMP" "$INFO"

cat >"$INFO" <<EOF
90min.cz – aktuální snapshot aplikace
Vytvořeno: $(date --iso-8601=seconds)
Zdroj: $APP_ROOT
Server: $(hostname)
PHP: $(php -r 'echo PHP_VERSION;' 2>/dev/null || echo nezjištěno)

Vyloučeno z bezpečnostních a kapacitních důvodů:
- uploads a mediální soubory
- dist, _handoff, node_modules, vendor
- cache, tmp, logs, sessions, backups
- .git
- .env a běžné soubory s přístupovými údaji
EOF

nginx -T >"$NGINX_DUMP" 2>&1 || true

echo "=== VYTVÁŘÍM ARCHIV PŘÍMO ZE ŽIVÉ APP ==="
set +e
tar \
  --warning=no-file-changed \
  --ignore-failed-read \
  -C "$APP_ROOT" \
  -czf "$PARTIAL" \
  --exclude='./uploads' \
  --exclude='./uploads/*' \
  --exclude='./dist' \
  --exclude='./dist/*' \
  --exclude='./_handoff' \
  --exclude='./_handoff/*' \
  --exclude='./node_modules' \
  --exclude='./node_modules/*' \
  --exclude='./vendor' \
  --exclude='./vendor/*' \
  --exclude='./cache' \
  --exclude='./cache/*' \
  --exclude='./tmp' \
  --exclude='./tmp/*' \
  --exclude='./logs' \
  --exclude='./logs/*' \
  --exclude='./sessions' \
  --exclude='./sessions/*' \
  --exclude='./backups' \
  --exclude='./backups/*' \
  --exclude='./.git' \
  --exclude='./.git/*' \
  --exclude='./.env' \
  --exclude='./.env.*' \
  --exclude='./config.php' \
  --exclude='./database.php' \
  --exclude='./db.php' \
  --exclude='./api/config.php' \
  --exclude='./api/database.php' \
  --exclude='./api/db.php' \
  --exclude='./credentials*' \
  --exclude='./secrets*' \
  --exclude='*.log' \
  --exclude='*.tmp' \
  .
TAR_RC=$?
set -e

[ -s "$PARTIAL" ] || fail "Archiv nevznikl."
gzip -t "$PARTIAL" || fail "Archiv je poškozený."

if [ "$TAR_RC" -gt 1 ]; then
  rm -f "$PARTIAL"
  fail "tar skončil s chybou $TAR_RC"
fi

mv "$PARTIAL" "$ARCHIVE"
chmod 644 "$ARCHIVE" "$NGINX_DUMP" "$INFO"
sha256sum "$ARCHIVE" >"${ARCHIVE}.sha256"
chmod 644 "${ARCHIVE}.sha256"

COUNT="$(tar -tzf "$ARCHIVE" | wc -l)"
SIZE="$(du -h "$ARCHIVE" | awk '{print $1}')"

echo
echo "========================================"
echo "AKTUÁLNÍ SNAPSHOT JE PŘIPRAVEN"
echo "Souborů v archivu: $COUNT"
echo "Velikost archivu: $SIZE"
echo
echo "ARCHIV:"
echo "https://dev.90min.cz/_handoff/${NAME}.tar.gz"
echo
echo "SHA-256:"
echo "https://dev.90min.cz/_handoff/${NAME}.tar.gz.sha256"
echo
echo "NGINX KONFIGURACE:"
echo "https://dev.90min.cz/_handoff/${NAME}-nginx.txt"
echo
echo "INFO:"
echo "https://dev.90min.cz/_handoff/${NAME}-info.txt"
echo "========================================"
