#!/usr/bin/env bash
# Preflight: install packages, lay out directories, copy repo + configs into
# place, and install the parent helper commands. Idempotent.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SELF_DIR}/lib.sh"
require_root

. /etc/os-release
[[ "${VERSION_ID:-}" == "26.04" ]] || warn "Designed for Ubuntu 26.04; found ${VERSION_ID:-unknown}."

log "Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  dnsmasq squid nftables fapolicyd openssh-server \
  dconf-cli python3 jq acl openssl curl gnupg bind9-dnsutils

# --- Google Chrome (.deb) — the managed browser ---------------------------
# On 26.04, Chromium is a confined snap that breaks native messaging + managed
# policy. Chrome's .deb is unconfined, so we use it instead (see PLAN.md §11).
if ! command -v google-chrome-stable >/dev/null 2>&1; then
  log "Adding Google Chrome apt repository..."
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
    > /etc/apt/sources.list.d/google-chrome.list
  apt-get update -y
  apt-get install -y google-chrome-stable
  ok "Google Chrome installed."
else
  ok "Google Chrome already installed."
fi

log "Creating directories..."
install -d -m 0755 "${ETC_DIR}"
install -d -m 0750 "${LOG_DIR}"
install -d -m 0755 /opt/parental

log "Copying repo to /opt/parental..."
cp -a "${REPO_ROOT}/scripts" /opt/parental/
cp -a "${REPO_ROOT}/extension" /opt/parental/
cp -a "${REPO_ROOT}/config" /opt/parental/
chmod +x /opt/parental/scripts/*.sh
chmod +x /opt/parental/extension/logger-host.py

# Install the live config (don't clobber an existing tuned allowlist).
if [[ ! -f "${ALLOWLIST}" ]]; then
  cp "${REPO_ROOT}/config/allowlist.txt" "${ALLOWLIST}"
  ok "Installed allowlist -> ${ALLOWLIST}"
else
  warn "Keeping existing ${ALLOWLIST}"
fi
if [[ ! -f "${YT_ALLOWLIST}" ]]; then
  cp "${REPO_ROOT}/config/youtube-allow.txt" "${YT_ALLOWLIST}"
  ok "Installed YouTube allowlist -> ${YT_ALLOWLIST}"
else
  warn "Keeping existing ${YT_ALLOWLIST}"
fi

log "Installing parent helper commands to /usr/local/sbin..."
for cmd in allow-site deny-site list-sites allow-youtube review-denied \
           open-web close-web top-sites clear-logs \
           fapolicyd-review fapolicyd-allow fapolicyd-enforce maintenance-dns; do
  install -m 0750 "${REPO_ROOT}/bin/${cmd}" "/usr/local/sbin/${cmd}"
done

ok "Preflight complete."
