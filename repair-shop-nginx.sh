#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "CHYBA: spusťte jako root." >&2
  exit 1
fi

WP_PATH="/var/www/web/wordpress"
WP_URL="https://dev.90min.cz/admin/shop"
STAMP="$(date +%Y%m%d-%H%M%S)"

command -v nginx >/dev/null || { echo "CHYBA: chybí nginx" >&2; exit 1; }
command -v python3 >/dev/null || { echo "CHYBA: chybí python3" >&2; exit 1; }
command -v wp >/dev/null || { echo "CHYBA: chybí wp-cli" >&2; exit 1; }

[[ -f "$WP_PATH/wp-config.php" ]] || { echo "CHYBA: chybí $WP_PATH/wp-config.php" >&2; exit 1; }

PHP_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n1)"
[[ -n "$PHP_SOCK" ]] || { echo "CHYBA: nebyl nalezen PHP-FPM socket." >&2; exit 1; }

mkdir -p /root/90min-backups
cp -a /etc/nginx "/root/90min-backups/nginx-shop-repair-${STAMP}"

cat > /etc/nginx/conf.d/90min-shop-wordpress.conf <<EOF
server {
    listen 127.0.0.1:8099;
    server_name 127.0.0.1;
    root ${WP_PATH};
    index index.php;
    client_max_body_size 128m;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_param HTTP_X_FORWARDED_PROTO https;
        fastcgi_param HTTP_X_FORWARDED_HOST dev.90min.cz;
        fastcgi_param HTTP_X_FORWARDED_PREFIX /admin/shop;
    }

    location ~* /\.(?!well-known/) {
        deny all;
    }
}
EOF

cat > /etc/nginx/snippets/90min-shop-proxy.conf <<'EOF'
location = /admin/shop {
    return 301 /admin/shop/;
}

location /admin/shop/ {
    client_max_body_size 128m;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Prefix /admin/shop;
    proxy_pass http://127.0.0.1:8099/;
    proxy_redirect http://127.0.0.1:8099/ /admin/shop/;
}
EOF

NGINX_FILE="$(grep -RslE 'server_name[[:space:]]+dev\.90min\.cz' /etc/nginx/sites-enabled /etc/nginx/sites-available 2>/dev/null | head -n1 || true)"
[[ -n "$NGINX_FILE" ]] || { echo "CHYBA: nenalezen Nginx soubor pro dev.90min.cz." >&2; exit 1; }
NGINX_FILE="$(readlink -f "$NGINX_FILE")"
cp -a "$NGINX_FILE" "${NGINX_FILE}.before-shop-repair-${STAMP}"

python3 - "$NGINX_FILE" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()
include_line = "    include /etc/nginx/snippets/90min-shop-proxy.conf;\n"

if "/etc/nginx/snippets/90min-shop-proxy.conf" in s:
    print("Nginx include už existuje.")
    raise SystemExit(0)

matches = list(re.finditer(r'(?m)^\s*server\s*\{', s))
if not matches:
    raise SystemExit("CHYBA: v souboru nebyl nalezen žádný server blok.")

def block_end(start_brace: int) -> int | None:
    depth = 0
    for i in range(start_brace, len(s)):
        ch = s[i]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return i
    return None

chosen = None
for m in matches:
    brace = s.find('{', m.start(), m.end())
    end = block_end(brace)
    if end is None:
        continue
    block = s[m.start():end + 1]
    if re.search(r'(?m)^\s*server_name\s+[^;]*\bdev\.90min\.cz\b[^;]*;', block) and "/var/www/web/dist" in block:
        chosen = (m.start(), end)
        break

if chosen is None:
    for m in matches:
        brace = s.find('{', m.start(), m.end())
        end = block_end(brace)
        if end is None:
            continue
        block = s[m.start():end + 1]
        if "/var/www/web/dist" in block:
            chosen = (m.start(), end)
            break

if chosen is None:
    raise SystemExit("CHYBA: nenalezen server blok s root /var/www/web/dist.")

_, end = chosen
s = s[:end] + include_line + s[end:]
p.write_text(s)
print(f"Include vložen do {p}")
PY

if ! nginx -t; then
  cp -a "${NGINX_FILE}.before-shop-repair-${STAMP}" "$NGINX_FILE"
  echo "CHYBA: nginx -t neprošel. Hlavní konfigurace byla vrácena." >&2
  nginx -t || true
  exit 1
fi

systemctl reload nginx

chown -R www-data:www-data "$WP_PATH"
find "$WP_PATH" -type d -exec chmod 755 {} +
find "$WP_PATH" -type f -exec chmod 644 {} +
chmod 640 "$WP_PATH/wp-config.php"

wp plugin activate woocommerce packeta --path="$WP_PATH" --allow-root >/dev/null 2>&1 || true

# WordPress musí znát veřejnou cestu pod /admin/shop.
wp option update home "$WP_URL" --path="$WP_PATH" --allow-root >/dev/null
wp option update siteurl "$WP_URL" --path="$WP_PATH" --allow-root >/dev/null

# Zabraňuje přesměrování na interní port při reverse proxy.
if ! grep -q "90MIN_SHOP_PROXY_FIX" "$WP_PATH/wp-config.php"; then
  python3 - "$WP_PATH/wp-config.php" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
marker = "/* That's all, stop editing! Happy publishing. */"
block = r'''// 90MIN_SHOP_PROXY_FIX
if (!empty($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}
if (!empty($_SERVER['HTTP_X_FORWARDED_HOST'])) {
    $_SERVER['HTTP_HOST'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
}
'''
if marker in s:
    s = s.replace(marker, block + "\n" + marker, 1)
else:
    s += "\n" + block
p.write_text(s)
PY
fi

echo "=== Ověření WordPressu a pluginů ==="
wp core is-installed --path="$WP_PATH" --allow-root && echo "WordPress: OK"
wp plugin list --path="$WP_PATH" --allow-root --fields=name,status,version --format=table | grep -E 'woocommerce|packeta' || true

echo "=== Ověření HTTP ==="
HTTP_CODE="$(curl -ksS -o /dev/null -w '%{http_code}' "${WP_URL}/wp-login.php")"
echo "${WP_URL}/wp-login.php -> HTTP ${HTTP_CODE}"
if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "302" ]]; then
  echo "CHYBA: shop backend neodpovídá správně." >&2
  exit 1
fi

echo
echo "HOTOVO: ${WP_URL}/wp-admin/"
echo "Přihlašovací údaje: /root/90min-shop-credentials.txt"
