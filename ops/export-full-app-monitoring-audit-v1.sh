#!/usr/bin/env bash
set -Eeuo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="/var/www/web/_handoff"
NAME="90min-app-articles-monitoring-audit-${STAMP}"
WORK="/var/tmp/${NAME}"
OUT="${OUTDIR}/${NAME}.tar.gz"
SHA="${OUT}.sha256"
STATUS="${OUTDIR}/90min-app-audit-status.txt"

mkdir -p "$OUTDIR"
chmod 755 "$OUTDIR" 2>/dev/null || true

status() {
  printf '%s | %s\n' "$(date '+%F %T')" "$*" | tee "$STATUS"
  chmod 644 "$STATUS" 2>/dev/null || true
}

cleanup() {
  rm -rf "$WORK"
}

fail() {
  local rc=$?
  status "CHYBA (kód ${rc}, řádek ${BASH_LINENO[0]}). Podrobnosti jsou v /root/90min-app-audit.log"
  exit "$rc"
}

trap fail ERR INT TERM
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || { echo "Spusť jako root." >&2; exit 1; }
command -v tar >/dev/null
command -v find >/dev/null
command -v sha256sum >/dev/null

APP="/var/www/app.90min.cz"
WEB="/var/www/web"
[ -d "$APP" ] || { echo "Chybí $APP" >&2; exit 1; }
[ -d "$WEB" ] || { echo "Chybí $WEB" >&2; exit 1; }

FREE_MB="$(df -Pm /var/tmp | awk 'NR==2{print $4}')"
if [ "${FREE_MB:-0}" -lt 500 ]; then
  status "CHYBA: méně než 500 MB volného místa (${FREE_MB:-0} MB). Export nebyl spuštěn."
  exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/diagnostics" "$WORK/logs"

status "1/7 Výběr aktuálních zdrojů aplikace, článků, monitoringu a veřejného webu"

FILELIST="$WORK/filelist.txt"
: > "$FILELIST"

for ROOT in "$APP" "$WEB"; do
  find "$ROOT" -xdev -type f -size -8M \
    \( \
      -name '*.php' -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o \
      -name '*.ts' -o -name '*.tsx' -o -name '*.jsx' -o -name '*.html' -o \
      -name '*.css' -o -name '*.json' -o -name '*.sql' -o -name '*.sh' -o \
      -name '*.yml' -o -name '*.yaml' -o -name '*.conf' -o -name '*.ini' -o \
      -name '*.md' -o -name '*.txt' -o -name 'Dockerfile' -o -name 'Procfile' \
    \) \
    ! -path '*/uploads/*' \
    ! -path '*/node_modules/*' \
    ! -path '*/vendor/*' \
    ! -path '*/cache/*' \
    ! -path '*/sessions/*' \
    ! -path '*/backups/*' \
    ! -path '*/_handoff/*' \
    ! -path '*/.git/*' \
    ! -path '*.__rollback*/*' \
    ! -path '*.__old*/*' \
    ! -name '.env' ! -name '.env.*' \
    ! -name '*.pem' ! -name '*.key' ! -name '*.crt' \
    -print >> "$FILELIST"
done

sort -u "$FILELIST" -o "$FILELIST"
COUNT="$(wc -l < "$FILELIST")"
[ "$COUNT" -gt 0 ] || { echo "Nebyl nalezen žádný zdrojový soubor." >&2; exit 1; }

sed 's#^/##' "$FILELIST" > "$WORK/filelist.relative.txt"
tar -C / -cf - -T "$WORK/filelist.relative.txt" | tar -C "$WORK/source" -xf -

status "2/7 Sanitace citlivých hodnot v kopii zdrojů (${COUNT} souborů)"

while IFS= read -r -d '' FILE; do
  # Auditní kopie: odstranění nejčastějších hesel, tokenů a API klíčů.
  sed -Ei \
    -e 's/((password|passwd|db_pass|db_password|secret|client_secret|api[_-]?key|access[_-]?token|refresh[_-]?token)[[:space:]]*[:=][[:space:]]*)["'"'][^"'"']*["'"']/\1"[REDACTED]"/Ig' \
    -e 's/(Authorization:[[:space:]]*(Bearer|Basic)[[:space:]]+)[A-Za-z0-9._~+\/-]+/\1[REDACTED]/Ig' \
    "$FILE" 2>/dev/null || true
done < <(find "$WORK/source" -type f -print0)

status "3/7 Sběr konfigurace procesů, cronů, timerů a Nginxu"

{
  echo '=== DATUM A SERVER ==='
  date --iso-8601=seconds
  hostnamectl 2>/dev/null || hostname
  echo
  echo '=== DISK A PAMĚŤ ==='
  df -h
  free -h 2>/dev/null || true
  echo
  echo '=== PHP ==='
  php -v 2>/dev/null || true
  php -m 2>/dev/null || true
} > "$WORK/diagnostics/system.txt"

nginx -T > "$WORK/diagnostics/nginx-full.txt" 2>&1 || true
systemctl list-timers --all --no-pager > "$WORK/diagnostics/systemd-timers.txt" 2>&1 || true
systemctl list-units --type=service --all --no-pager > "$WORK/diagnostics/systemd-services.txt" 2>&1 || true
systemctl list-unit-files --no-pager > "$WORK/diagnostics/systemd-unit-files.txt" 2>&1 || true

{
  echo '=== ROOT CRONTAB ==='
  crontab -l 2>&1 || true
  echo
  echo '=== WWW-DATA CRONTAB ==='
  crontab -u www-data -l 2>&1 || true
  echo
  echo '=== /etc/cron* ==='
  grep -RInE '90min|monitor|article|clanek|publish|publik|feed|rss|sync|import|php' /etc/cron* 2>/dev/null || true
} > "$WORK/diagnostics/cron.txt"

find /etc/systemd/system -maxdepth 3 -type f \( -name '*.service' -o -name '*.timer' \) -print0 2>/dev/null |
  xargs -0 -r grep -IlE '90min|monitor|article|publish|feed|rss|sync|import|/var/www' 2>/dev/null |
  while IFS= read -r UNIT; do
    mkdir -p "$WORK/diagnostics/systemd-units$(dirname "$UNIT")"
    cp -a "$UNIT" "$WORK/diagnostics/systemd-units$UNIT"
  done

status "4/7 Sběr posledních logů a stavu publikačního řetězce"

for LOG in \
  /var/log/nginx/error.log \
  /var/log/nginx/access.log \
  /var/log/php8.2-fpm.log \
  /var/log/php8.3-fpm.log \
  /var/log/syslog; do
  [ -f "$LOG" ] || continue
  SAFE="$(echo "$LOG" | tr '/' '_')"
  tail -n 5000 "$LOG" > "$WORK/logs/${SAFE}.tail.txt" 2>&1 || true
done

journalctl --since '10 days ago' --no-pager -n 12000 \
  | grep -Ei '90min|monitor|article|clanek|publish|publik|feed|rss|sync|import|transaction|duplicate|error|fatal|exception' \
  > "$WORK/logs/journal-relevant-10-days.txt" 2>&1 || true

{
  echo '=== PROCESY ==='
  ps auxww | grep -Ei '90min|monitor|article|publish|feed|rss|sync|import|php' | grep -v grep || true
  echo
  echo '=== SOCKETY ==='
  ss -lntup 2>/dev/null || true
} > "$WORK/diagnostics/runtime.txt"

status "5/7 Index problémových míst v kódu"

{
  echo '=== TRANSAKCE A UKLÁDÁNÍ ČLÁNKŮ ==='
  grep -RInE --binary-files=without-match 'beginTransaction|inTransaction|commit\(|rollBack\(|INSERT[[:space:]]+INTO[[:space:]]+articles|UPDATE[[:space:]]+articles|client_request_id|idempot' "$WORK/source" 2>/dev/null || true
  echo
  echo '=== MONITORING, IMPORT, DUPLICITY A PUBLIKACE ==='
  grep -RInE --binary-files=without-match 'monitor|monitoring|duplicate|dedup|fingerprint|canonical|source_url|publish|published|publication|feed|rss|import|sync|scheduler|cron' "$WORK/source" 2>/dev/null || true
  echo
  echo '=== PWA A AKTUALIZACE ==='
  grep -RInE --binary-files=without-match 'serviceWorker|skipWaiting|controllerchange|updatefound|registration\.waiting|manifest|app.*version|new version|nová verze|aktualiz' "$WORK/source" 2>/dev/null || true
} > "$WORK/diagnostics/code-index.txt"

{
  echo '=== SOUBORY ZMĚNĚNÉ ZA 14 DNÍ ==='
  find "$APP" "$WEB" -xdev -type f -mtime -14 \
    ! -path '*/uploads/*' ! -path '*/node_modules/*' ! -path '*/vendor/*' \
    ! -path '*/_handoff/*' ! -path '*/backups/*' \
    -printf '%TY-%Tm-%Td %TH:%TM:%TS %10s %p\n' 2>/dev/null | sort -r | head -n 5000
  echo
  echo '=== PWA SOUBORY A HASH ==='
  find "$APP" -maxdepth 4 -type f \( -name 'sw.js' -o -name '*service*worker*.js' -o -name 'manifest*.json' -o -name 'index.html' -o -name 'script.js' \) \
    -print0 2>/dev/null | xargs -0 -r sha256sum 2>/dev/null || true
} > "$WORK/diagnostics/recent-files-and-pwa.txt"

status "6/7 Síťové a HTTP kontroly app, dev a veřejného webu"

{
  for HOST in app.90min.cz dev.90min.cz 90min.cz www.90min.cz; do
    echo
    echo "===== ${HOST} ====="
    curl -kIsS --max-time 15 "https://${HOST}/" | sed -n '1,30p' || true
    echo '-- API health --'
    curl -kIsS --max-time 15 "https://${HOST}/api/health" | sed -n '1,30p' || true
  done
} > "$WORK/diagnostics/http-checks.txt" 2>&1

cat > "$WORK/README.txt" <<EOF
90min.cz — auditní snapshot aktuálního stavu
Vytvořeno: $(date --iso-8601=seconds)
Server: $(hostname)

Rozsah:
- interní aplikace app.90min.cz
- modul Články a ukládání/publikace
- monitoring, importy, krátké zprávy a deduplikace
- veřejný web a stav, proč tři dny nepřibyl obsah
- cron, systemd timery, procesy, Nginx a poslední relevantní logy
- PWA/service worker a opakovaná výzva k aktualizaci

Citlivé .env, klíče, certifikáty, uploads, vendor a node_modules nejsou v balíku.
Nejčastější tajné hodnoty byly v auditní kopii nahrazeny [REDACTED].
EOF

status "7/7 Vytváření kompaktního archivu"

tar -C "$WORK" -czf "$OUT" README.txt source diagnostics logs
chmod 644 "$OUT"
sha256sum "$OUT" > "$SHA"
chmod 644 "$SHA"

SIZE="$(du -h "$OUT" | awk '{print $1}')"
FILES="$(tar -tzf "$OUT" | wc -l)"

cat > "$STATUS" <<EOF
HOTOVO
Archiv: https://dev.90min.cz/_handoff/${NAME}.tar.gz
SHA-256: https://dev.90min.cz/_handoff/${NAME}.tar.gz.sha256
Velikost: ${SIZE}
Souborů: ${FILES}
Rozsah: app + Články + monitoring + publikace na web + PWA aktualizace
EOF
chmod 644 "$STATUS"

printf '\n========================================\n'
printf 'AUDITNÍ BALÍK JE HOTOVÝ\n'
printf 'Archiv: https://dev.90min.cz/_handoff/%s.tar.gz\n' "$NAME"
printf 'SHA-256: https://dev.90min.cz/_handoff/%s.tar.gz.sha256\n' "$NAME"
printf 'Stav: https://dev.90min.cz/_handoff/90min-app-audit-status.txt\n'
printf 'Velikost: %s | Souborů: %s\n' "$SIZE" "$FILES"
printf '========================================\n'
