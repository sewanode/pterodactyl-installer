#!/usr/bin/env bash
pkill apt || true
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# --- Default Parameters ---
DOMAIN_PANEL=""
DOMAIN_WINGS=""
ADMIN_EMAIL=""
ADMIN_PASS=""
DPORT=2481
SFTPPORT=2482
ENABLE_SSL=false
TIMEZONE="Asia/Jakarta"
USE_ID_MIRROR=true

# --- CLI Arguments Parser ---
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --domainp)  DOMAIN_PANEL="$2"; shift ;;
    --domainw)  DOMAIN_WINGS="$2"; shift ;;
    --email)    ADMIN_EMAIL="$2"; shift ;;
    --pass)     ADMIN_PASS="$2"; shift ;;
    --dport)    DPORT="$2"; shift ;;
    --sftpport) SFTPPORT="$2"; shift ;;
    --timezone) TIMEZONE="$2"; shift ;;
    --ssl)      ENABLE_SSL=true ;;
    --no-id-mirror) USE_ID_MIRROR=false ;;
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$DOMAIN_PANEL" || -z "$DOMAIN_WINGS" || -z "$ADMIN_EMAIL" || -z "$ADMIN_PASS" ]]; then
  echo "Usage: $0 --domainp <panel.domain> --domainw <node.domain> --email <admin@email> --pass <secret> --dport <port> --sftpport <port> [--ssl] [--no-id-mirror]"
  exit 1
fi

# --- Non-interactive apt ---
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# Suppress needrestart prompt (kalau ada)
if [[ -f /etc/needrestart/needrestart.conf ]]; then
  sed -i "s/^#\?\$nrconf{restart} = .*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf || true
fi

# Deteksi OS & Arsitektur
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) WINGS_ARCH="amd64" ;;
  aarch64|arm64) WINGS_ARCH="arm64" ;;
  *) die "Arsitektur CPU $ARCH tidak didukung." ;;
esac

. /etc/os-release
OS_ID=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
OS_CODENAME=$(lsb_release -cs 2>/dev/null || echo "$VERSION_CODENAME")

info "[1/8] Menyiapkan repositori sistem..."
# --- Ganti mirror ke Indonesia biar low latency ---
if [[ "$USE_ID_MIRROR" == true ]]; then
  info "Mengganti mirror apt ke Indonesia (gunakan --no-id-mirror untuk skip)..."
  case "$OS_ID" in
    ubuntu)
      ID_MIRROR="http://id.archive.ubuntu.com/ubuntu"
      # Cek dulu mirror ID reachable
      if curl -sI --max-time 5 "${ID_MIRROR}/dists/${OS_CODENAME}/Release" >/dev/null 2>&1 \
         || curl -sI --max-time 5 "${ID_MIRROR}/dists/stable/Release" >/dev/null 2>&1; then
        # Format deb822 (Ubuntu 24.04+)
        if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
          sed -i -E "s#https?://(archive|security|ports)\.ubuntu\.com/ubuntu#${ID_MIRROR}#g" \
            /etc/apt/sources.list.d/ubuntu.sources || true
        fi
        # Format classic
        if [[ -f /etc/apt/sources.list ]]; then
          sed -i -E "s#https?://(archive|security|ports)\.ubuntu\.com/ubuntu#${ID_MIRROR}#g" \
            /etc/apt/sources.list || true
        fi
        info "Mirror diganti ke ${ID_MIRROR}"
      else
        warn "Mirror ID tidak reachable, skip penggantian mirror."
      fi
      ;;
    debian)
      ID_MIRROR="http://ftp.id.debian.org/debian"
      if curl -sI --max-time 5 "${ID_MIRROR}/dists/${OS_CODENAME}/Release" >/dev/null 2>&1; then
        if [[ -f /etc/apt/sources.list ]]; then
          sed -i -E "s#https?://deb\.debian\.org/debian#${ID_MIRROR}#g" /etc/apt/sources.list || true
        fi
        if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
          sed -i -E "s#https?://deb\.debian\.org/debian#${ID_MIRROR}#g" /etc/apt/sources.list.d/debian.sources || true
        fi
        info "Mirror diganti ke ${ID_MIRROR}"
      else
        warn "Mirror ID tidak reachable, skip penggantian mirror."
      fi
      ;;
    *)
      warn "OS '$OS_ID' tidak dikenal untuk auto-mirror, skip."
      ;;
  esac
fi

apt-get update -y -qq
apt-get install -y -qq curl apt-transport-https lsb-release ca-certificates gnupg git zip unzip tar cron jq

# Repo PHP Sury
curl -sSLo /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
echo "deb https://packages.sury.org/php/ ${OS_CODENAME} main" > /etc/apt/sources.list.d/php.list

# Repo Docker Resmi
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

apt-get update -y -qq

info "[2/8] Menginstal paket dependencies & Docker..."
apt-get install -y -qq \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold \
  php8.3 php8.3-{cli,common,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} \
  mariadb-server nginx redis-server \
  docker-ce docker-ce-cli containerd.io certbot python3-certbot-nginx

systemctl enable --now mariadb redis-server nginx php8.3-fpm docker

info "[3/8] Mengonfigurasi MariaDB..."
DB_NAME="panel"
DB_USER="pterodactyl"
DB_PASS=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)

mariadb -u root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
mariadb -u root -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
mariadb -u root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;"
mariadb -u root -e "FLUSH PRIVILEGES;"

info "[4/8] Mengunduh dan memasang Panel..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -sSLo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
cp .env.example .env
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

APP_SCHEME="http"
[[ "$ENABLE_SSL" == true ]] && APP_SCHEME="https"

php artisan key:generate --force
php artisan p:environment:setup \
  --author="${ADMIN_EMAIL}" \
  --url="${APP_SCHEME}://${DOMAIN_PANEL}" \
  --timezone="${TIMEZONE}" \
  --cache="redis" \
  --session="redis" \
  --queue="redis" \
  --redis-host="localhost" \
  --redis-pass="null" \
  --redis-port="6379" \
  --telemetry="false" \
  --settings-ui=true

php artisan p:environment:database \
  --host="127.0.0.1" \
  --port="3306" \
  --database="${DB_NAME}" \
  --username="${DB_USER}" \
  --password="${DB_PASS}"

php artisan migrate --seed --force

php artisan p:user:make \
  --email="${ADMIN_EMAIL}" \
  --username="admin" \
  --name-first="Panel" \
  --name-last="Admin" \
  --password="${ADMIN_PASS}" \
  --admin=1

chown -R www-data:www-data /var/www/pterodactyl/*
(crontab -l 2>/dev/null || true; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | sort -u | crontab -

# Service Queue Worker (pteroq)
cat << 'EOF' > /etc/systemd/system/pteroq.service
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pteroq

# Vhost Nginx (HTTP only, sebelum SSL)
cat << EOF > /etc/nginx/sites-available/pterodactyl.conf
server {
    listen 80;
    server_name ${DOMAIN_PANEL} ${DOMAIN_WINGS};
    root /var/www/pterodactyl/public;
    index index.html index.htm index.php;
    charset utf-8;

    location /.well-known/acme-challenge/ {
        root /var/www/pterodactyl/public;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t && systemctl reload nginx

info "[5/8] Konfigurasi SSL Let's Encrypt..."
if [[ "$ENABLE_SSL" == true ]]; then
  certbot certonly --webroot -w /var/www/pterodactyl/public \
    --non-interactive --agree-tos --email "${ADMIN_EMAIL}" \
    -d "${DOMAIN_PANEL}"

  certbot certonly --webroot -w /var/www/pterodactyl/public \
    --non-interactive --agree-tos --email "${ADMIN_EMAIL}" \
    -d "${DOMAIN_WINGS}"

  cat << EOF > /etc/nginx/sites-available/pterodactyl.conf
server {
    listen 80;
    server_name ${DOMAIN_PANEL} ${DOMAIN_WINGS};

    location /.well-known/acme-challenge/ {
        root /var/www/pterodactyl/public;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN_PANEL};
    root /var/www/pterodactyl/public;
    index index.html index.htm index.php;
    charset utf-8;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN_PANEL}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_PANEL}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

  nginx -t && systemctl reload nginx
fi

info "[6/8] Membuat Application API Key via artisan tinker..."
TINKER_OUT=$(php artisan tinker --execute='
  $key = new \Pterodactyl\Models\ApiKey();
  $key->user_id = 1;
  $key->key_type = \Pterodactyl\Models\ApiKey::TYPE_APPLICATION;
  $key->identifier = \Illuminate\Support\Str::random(16);
  $secret = \Illuminate\Support\Str::random(32);
  $key->token = encrypt($secret);
  $key->memo = "Auto Provision CLI";
  $key->allowed_ips = null;
  $cols = [
    "r_servers", "r_nodes", "r_allocations", "r_users", "r_locations",
    "r_nests", "r_eggs", "r_database_hosts", "r_server_databases"
  ];
  foreach ($cols as $col) { $key->{$col} = 3; }
  $key->save();
  echo "<<<TOKEN_START>>>" . $key->identifier . $secret . "<<<TOKEN_END>>>";
' 2>/dev/null)

API_TOKEN=$(echo "$TINKER_OUT" | sed -n 's/.*<<<TOKEN_START>>>\(.*\)<<<TOKEN_END>>>.*/\1/p' | tr -d '\r\n[:space:]')

if [[ -z "$API_TOKEN" ]]; then
  echo "--- RAW TINKER OUTPUT ---"
  echo "$TINKER_OUT"
  echo "-------------------------"
  die "API_TOKEN kosong. Cek output tinker di atas."
fi
info "API Token berhasil dibuat (${#API_TOKEN} chars)."

# --- Helper: API request ke panel via localhost ---
API_PORT=80
[[ "$APP_SCHEME" == "https" ]] && API_PORT=443

api_request() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  local url="${APP_SCHEME}://${DOMAIN_PANEL}${endpoint}"
  local args=(
    -sS
    -X "$method" "$url"
    --resolve "${DOMAIN_PANEL}:${API_PORT}:127.0.0.1"
    -H "Authorization: Bearer ${API_TOKEN}"
    -H "Content-Type: application/json"
    -H "Accept: application/json"
  )
  if [[ -n "$data" ]]; then
    args+=( -d "$data" )
  fi
  curl "${args[@]}"
}

info "[7/8] Mendaftarkan Location & Node ke Panel API..."

# 1. Create Location
LOC_RESP=$(api_request POST "/api/application/locations" '{"short": "local", "long": "Local Node"}')
LOC_ID=$(echo "$LOC_RESP" | jq -r '.attributes.id // empty')
if [[ -z "$LOC_ID" ]]; then
  echo "--- RAW RESPONSE ---"; echo "$LOC_RESP"; echo "--------------------"
  die "Gagal create location."
fi
info "Location dibuat dengan ID: ${LOC_ID}"

# Hitung RAM & Disk Server (MB)
TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
TOTAL_DISK=$(df -m / | awk 'NR==2 {print $2}')
RAM_ALLOC=$(( TOTAL_RAM > 1024 ? TOTAL_RAM - 512 : 512 ))
DISK_ALLOC=$(( TOTAL_DISK > 5120 ? TOTAL_DISK - 2048 : 2048 ))

SCHEME_VAL="http"
[[ "$ENABLE_SSL" == true ]] && SCHEME_VAL="https"

# 2. Create Node
NODE_PAYLOAD=$(cat << EOF
{
  "name": "Node-1",
  "location_id": ${LOC_ID},
  "fqdn": "${DOMAIN_WINGS}",
  "scheme": "${SCHEME_VAL}",
  "memory": ${RAM_ALLOC},
  "memory_overallocate": 0,
  "disk": ${DISK_ALLOC},
  "disk_overallocate": 0,
  "upload_size": 100,
  "daemon_sftp": ${SFTPPORT},
  "daemon_listen": ${DPORT},
  "behind_proxy": false
}
EOF
)

NODE_RESP=$(api_request POST "/api/application/nodes" "$NODE_PAYLOAD")
NODE_ID=$(echo "$NODE_RESP" | jq -r '.attributes.id // empty')
if [[ -z "$NODE_ID" ]]; then
  echo "--- RAW RESPONSE ---"; echo "$NODE_RESP"; echo "--------------------"
  die "Gagal create node."
fi
info "Node dibuat dengan ID: ${NODE_ID}"

# 3. Fetch Node Configuration
NODE_CONFIG=$(api_request GET "/api/application/nodes/${NODE_ID}/configuration")
if ! echo "$NODE_CONFIG" | jq -e '.uuid' >/dev/null 2>&1; then
  echo "--- RAW RESPONSE ---"; echo "$NODE_CONFIG"; echo "--------------------"
  die "Gagal fetch node configuration."
fi

# 3a. Inject SSL cert path ke config Wings (kalau SSL aktif)
if [[ "$ENABLE_SSL" == true ]]; then
  NODE_CONFIG=$(echo "$NODE_CONFIG" | jq \
    --arg cert "/etc/letsencrypt/live/${DOMAIN_WINGS}/fullchain.pem" \
    --arg key  "/etc/letsencrypt/live/${DOMAIN_WINGS}/privkey.pem" \
    '.api.ssl.enabled = true | .api.ssl.cert = $cert | .api.ssl.key = $key')
fi

# 3b. Inject allowed_origins (domain panel)
NODE_CONFIG=$(echo "$NODE_CONFIG" | jq \
  --arg panel "${APP_SCHEME}://${DOMAIN_PANEL}" \
  '.allowed_origins = [$panel]')

# 3c. Force allowed_mounts jadi empty list
NODE_CONFIG=$(echo "$NODE_CONFIG" | jq '.allowed_mounts = []')

mkdir -p /etc/pterodactyl
echo "$NODE_CONFIG" > /etc/pterodactyl/config.json

# Convert JSON -> YAML
php -r '
  $json = json_decode(file_get_contents("/etc/pterodactyl/config.json"), true);
  if ($json === null) {
      fwrite(STDERR, "Gagal decode JSON config\n");
      exit(1);
  }

  // Paksa list untuk field yang di Wings bertipe []string
  foreach (["allowed_mounts", "allowed_origins"] as $k) {
      if (!isset($json[$k]) || !is_array($json[$k])) {
          $json[$k] = [];
      }
  }

  function toYaml($arr, $indent = 0) {
      $out = "";
      $isList = array_is_list($arr);

      foreach ($arr as $k => $v) {
          $sp = str_repeat("  ", $indent);

          if ($isList) {
              if (is_array($v)) {
                  if (empty($v)) {
                      $out .= "{$sp}- {}\n";
                  } else {
                      $out .= "{$sp}-\n" . toYaml($v, $indent + 1);
                  }
              } elseif (is_bool($v)) {
                  $out .= "{$sp}- " . ($v ? "true" : "false") . "\n";
              } elseif (is_null($v)) {
                  $out .= "{$sp}- null\n";
              } elseif (is_numeric($v)) {
                  $out .= "{$sp}- {$v}\n";
              } else {
                  $out .= "{$sp}- " . json_encode((string)$v, JSON_UNESCAPED_SLASHES) . "\n";
              }
          } else {
              $key = (string)$k;
              if (is_array($v)) {
                  if (empty($v)) {
                      $empty = in_array($key, ["allowed_mounts", "allowed_origins"], true) ? "[]" : "{}";
                      $out .= "{$sp}{$key}: {$empty}\n";
                  } else {
                      $out .= "{$sp}{$key}:\n" . toYaml($v, $indent + 1);
                  }
              } elseif (is_bool($v)) {
                  $out .= "{$sp}{$key}: " . ($v ? "true" : "false") . "\n";
              } elseif (is_null($v)) {
                  $out .= "{$sp}{$key}: null\n";
              } elseif (is_numeric($v)) {
                  $out .= "{$sp}{$key}: {$v}\n";
              } else {
                  $out .= "{$sp}{$key}: " . json_encode((string)$v, JSON_UNESCAPED_SLASHES) . "\n";
              }
          }
      }
      return $out;
  }

  file_put_contents("/etc/pterodactyl/config.yml", toYaml($json));
'
rm -f /etc/pterodactyl/config.json

info "[8/8] Memasang Wings & Service..."
curl -sSL -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WINGS_ARCH}"
chmod u+x /usr/local/bin/wings

mkdir -p /var/run/wings /var/lib/pterodactyl/volumes

cat << 'EOF' > /etc/systemd/system/wings.service
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wings

# Sanity check: pastikan Wings benar-benar hidup
sleep 4
if ! systemctl is-active --quiet wings; then
  warn "Wings gagal start. Berikut log terakhirnya:"
  journalctl -u wings -n 40 --no-pager || true
  die "Wings tidak berjalan."
fi

echo "127.0.0.1 ${DOMAIN_WINGS}" | tee -a /etc/hosts >/dev/null

echo "=========================================================="
echo -e "${GREEN}Instalasi Berhasil!${NC}"
echo "Panel URL   : ${APP_SCHEME}://${DOMAIN_PANEL}"
echo "Wings Node  : ${DOMAIN_WINGS} (Daemon: ${DPORT}, SFTP: ${SFTPPORT})"
echo "Admin       : ${ADMIN_EMAIL}"
echo "Password    : ${ADMIN_PASS}"
echo "Wings State : $(systemctl is-active wings)"
echo "=========================================================="
