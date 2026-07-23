#!/usr/bin/env bash
set -Eeuo pipefail

# 90min.cz — bootstrap technického WordPress/WooCommerce backendu pro dev.90min.cz
# Veřejný React web zůstává v /var/www/web/dist. WordPress je dostupný pod /admin/shop/.

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "CHYBA: spusťte jako root." >&2
  exit 1
fi

WP_PATH="/var/www/web/wordpress"
WP_URL="https://dev.90min.cz/admin/shop"
DB_NAME="90min_shop"
DB_USER="90min_shop"
ADMIN_USER="ondrej"
ADMIN_EMAIL="ondrej.hak@90min.cz"
CREDS_FILE="/root/90min-shop-credentials.txt"
STAMP="$(date +%Y%m%d-%H%M%S)"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "CHYBA: chybí příkaz $1" >&2; exit 1; }
}

for cmd in nginx mariadb php wp openssl curl python3; do need "$cmd"; done

PHP_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n1)"
[[ -n "$PHP_SOCK" ]] || { echo "CHYBA: nebyl nalezen PHP-FPM socket v /run/php." >&2; exit 1; }

echo "=== 1/7 Záloha ==="
mkdir -p /root/90min-backups
if [[ -d "$WP_PATH" ]]; then
  tar -czf "/root/90min-backups/wordpress-before-shop-${STAMP}.tar.gz" -C "$(dirname "$WP_PATH")" "$(basename "$WP_PATH")" 2>/dev/null || true
fi
cp -a /etc/nginx "/root/90min-backups/nginx-before-shop-${STAMP}" 

echo "=== 2/7 WordPress core ==="
mkdir -p "$WP_PATH"
if [[ ! -f "$WP_PATH/wp-settings.php" ]]; then
  wp core download --path="$WP_PATH" --locale=cs_CZ --force --allow-root
else
  echo "WordPress core již existuje — nepřepisuji wp-content."
fi

echo "=== 3/7 Databáze a wp-config.php ==="
if [[ ! -f "$WP_PATH/wp-config.php" ]]; then
  DB_PASS="$(openssl rand -hex 24)"
  ADMIN_PASS="$(openssl rand -base64 30 | tr -d '=+/\n' | cut -c1-28)"

  mariadb -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mariadb -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}'; ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}'; GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

  wp config create \
    --path="$WP_PATH" \
    --dbname="$DB_NAME" \
    --dbuser="$DB_USER" \
    --dbpass="$DB_PASS" \
    --dbhost="localhost" \
    --dbcharset="utf8mb4" \
    --skip-check \
    --allow-root

  wp config set WP_HOME "$WP_URL" --type=constant --path="$WP_PATH" --allow-root
  wp config set WP_SITEURL "$WP_URL" --type=constant --path="$WP_PATH" --allow-root
  wp config set FORCE_SSL_ADMIN true --raw --type=constant --path="$WP_PATH" --allow-root
  wp config set DISALLOW_FILE_EDIT true --raw --type=constant --path="$WP_PATH" --allow-root

  cat > "$CREDS_FILE" <<EOF
90min Shop backend
URL: ${WP_URL}/wp-admin/
Uživatel: ${ADMIN_USER}
Heslo: ${ADMIN_PASS}
Databáze: ${DB_NAME}
DB uživatel: ${DB_USER}
DB heslo: ${DB_PASS}
Vytvořeno: $(date -Is)
EOF
  chmod 600 "$CREDS_FILE"
else
  echo "wp-config.php již existuje — databázové údaje neměním."
  ADMIN_PASS=""
fi

echo "=== 4/7 Instalace WordPressu ==="
if ! wp core is-installed --path="$WP_PATH" --allow-root >/dev/null 2>&1; then
  [[ -n "${ADMIN_PASS:-}" ]] || { echo "CHYBA: WordPress není nainstalovaný a chybí nově vygenerované heslo." >&2; exit 1; }
  wp core install \
    --path="$WP_PATH" \
    --url="$WP_URL" \
    --title="90min.cz Shop backend" \
    --admin_user="$ADMIN_USER" \
    --admin_password="$ADMIN_PASS" \
    --admin_email="$ADMIN_EMAIL" \
    --skip-email \
    --allow-root
else
  echo "WordPress databáze již existuje."
fi

wp option update timezone_string 'Europe/Prague' --path="$WP_PATH" --allow-root >/dev/null
wp option update blog_public 0 --path="$WP_PATH" --allow-root >/dev/null
wp rewrite structure '/%postname%/' --hard --path="$WP_PATH" --allow-root >/dev/null || true

echo "=== 5/7 WooCommerce a oficiální Packeta ==="
wp plugin install woocommerce --activate --path="$WP_PATH" --allow-root
wp plugin install packeta --activate --path="$WP_PATH" --allow-root

# Pokus o vytvoření standardních WooCommerce stránek; neukončí instalaci, pokud už existují.
wp wc tool run install_pages --user=1 --path="$WP_PATH" --allow-root >/dev/null 2>&1 || true

echo "=== 6/7 Nginx proxy /admin/shop/ ==="
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
        try_files \$uri =404;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_param HTTP_X_FORWARDED_PROTO https;
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
    proxy_set_header X-Forwarded-Prefix /admin/shop;
    proxy_pass http://127.0.0.1:8099/;
    proxy_redirect off;
}
EOF

NGINX_FILE="$(grep -RslE 'server_name[[:space:]]+dev\.90min\.cz' /etc/nginx/sites-enabled /etc/nginx/sites-available 2>/dev/null | head -n1 || true)"
[[ -n "$NGINX_FILE" ]] || { echo "CHYBA: nenalezen Nginx soubor pro dev.90min.cz." >&2; exit 1; }
NGINX_FILE="$(readlink -f "$NGINX_FILE")"
cp -a "$NGINX_FILE" "${NGINX_FILE}.before-shop-${STAMP}"

python3 - "$NGINX_FILE" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
include_line = "    include /etc/nginx/snippets/90min-shop-proxy.conf;\n"
if "/etc/nginx/snippets/90min-shop-proxy.conf" in s:
    print("Nginx include už existuje.")
    raise SystemExit(0)

needle = "root /var/www/web/dist;"
pos = s.find(needle)
if pos < 0:
    raise SystemExit("CHYBA: v konfiguraci dev.90min.cz nebyl nalezen root /var/www/web/dist;")

start = s.rfind("server", 0, pos)
brace = s.find("{", start, pos)
if start < 0 or brace < 0:
    raise SystemExit("CHYBA: nelze najít začátek server bloku.")

depth = 0
end = None
for i in range(brace, len(s)):
    if s[i] == "{":
        depth += 1
    elif s[i] == "}":
        depth -= 1
        if depth == 0:
            end = i
            break
if end is None:
    raise SystemExit("CHYBA: nelze najít konec server bloku.")

s = s[:end] + include_line + s[end:]
p.write_text(s)
print(f"Include vložen do {p}")
PY

if ! nginx -t; then
  cp -a "${NGINX_FILE}.before-shop-${STAMP}" "$NGINX_FILE"
  rm -f /etc/nginx/conf.d/90min-shop-wordpress.conf /etc/nginx/snippets/90min-shop-proxy.conf
  echo "CHYBA: nginx -t neprošel. Konfigurace byla vrácena." >&2
  exit 1
fi
systemctl reload nginx

chown -R www-data:www-data "$WP_PATH"
find "$WP_PATH" -type d -exec chmod 755 {} +
find "$WP_PATH" -type f -exec chmod 644 {} +
chmod 640 "$WP_PATH/wp-config.php"

echo "=== 7/7 Ověření ==="
curl -kfsSI "${WP_URL}/wp-login.php" | head -n 1 || true
wp plugin list --path="$WP_PATH" --allow-root --fields=name,status,version --format=table | grep -E 'woocommerce|packeta' || true

echo
echo "HOTOVO."
echo "Administrace: ${WP_URL}/wp-admin/"
echo "Přihlašovací údaje: ${CREDS_FILE}"
echo "Zobrazíte je příkazem: cat ${CREDS_FILE}"
