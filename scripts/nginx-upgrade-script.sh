#!/usr/bin/env bash
set -euo pipefail

echo "=== Nginx upgrade to official nginx.org mainline repo (Ubuntu 22.04) ==="

# 1) Safety check: must be root
if [[ "$EUID" -ne 0 ]]; then
  echo "[-] Please run this script as root (sudo)."
  exit 1
fi

# 2) Safety check: Ubuntu 22.04 (jammy)
if ! grep -q 'Ubuntu 22.04' /etc/os-release; then
  echo "[-] This script is designed for Ubuntu 22.04 (jammy) only."
  echo "    Aborting to avoid breaking shit on a different distro/version."
  exit 1
fi

DATE="$(date +%F-%H%M%S)"
BACKUP_DIR="/etc/nginx.bak_${DATE}"

# 3) Backup existing Nginx config
if [[ -d /etc/nginx ]]; then
  echo "[+] Backing up /etc/nginx to ${BACKUP_DIR} ..."
  cp -a /etc/nginx "${BACKUP_DIR}"
else
  echo "[!] /etc/nginx does not exist, skipping backup."
fi

# 4) Stop Nginx if running
echo "[+] Stopping nginx service if running ..."
systemctl stop nginx 2>/dev/null || true

# 5) Remove old Ubuntu nginx packages (but keep configs)
echo "[+] Removing old nginx packages from Ubuntu repo (without purge) ..."
apt-get update -y
apt-get remove -y nginx nginx-common nginx-full nginx-core nginx-light nginx-extras 2>/dev/null || true

# 6) Add official nginx.org mainline repo
echo "[+] Adding official nginx.org mainline repository ..."

# Keyring path
KEYRING="/usr/share/keyrings/nginx-archive-keyring.gpg"

curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee "${KEYRING}" >/dev/null

echo "deb [signed-by=${KEYRING}] http://nginx.org/packages/mainline/ubuntu jammy nginx" \
  > /etc/apt/sources.list.d/nginx.list

# 7) Install latest nginx from nginx.org
echo "[+] Installing nginx from nginx.org mainline repo ..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx

# 8) Ensure nginx runs as www-data (like Ubuntu default)
echo "[+] Ensuring nginx runs as www-data ..."

if grep -q "^user " /etc/nginx/nginx.conf; then
  sed -i 's/^user .*/user www-data;/' /etc/nginx/nginx.conf
else
  # If there's no user line, insert at top
  sed -i '1i user www-data;' /etc/nginx/nginx.conf
fi

# 9) Ensure sites-enabled is included
echo "[+] Ensuring /etc/nginx/sites-enabled is included from nginx.conf ..."

if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
  # Try to add include inside http {} block
  if grep -q "http {" /etc/nginx/nginx.conf; then
    sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
  else
    # Fallback: append at end of file
    echo "include /etc/nginx/sites-enabled/*;" >> /etc/nginx/nginx.conf
  fi
fi

# Ensure directories exist
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

# 10) Test nginx config before restarting
echo "[+] Testing nginx configuration ..."
nginx -t

# 11) Enable and restart nginx
echo "[+] Enabling and restarting nginx service ..."
systemctl enable nginx
systemctl restart nginx

# 12) Show nginx version
echo "[+] nginx version installed:"
nginx -v || true

# 13) Hold nginx to avoid downgrades from Ubuntu repo
echo "[+] Holding nginx package at this version (apt-mark hold nginx) ..."
apt-mark hold nginx || true

echo "=== Done. Backup of previous config: ${BACKUP_DIR} ==="
