#!/usr/bin/env bash
# Browser policy: make managed Google Chrome the only browser. The actual policy
# JSON (allowlist, proxy, extension forcelist, devtools/DoH/incognito off) is
# written by regenerate.sh, which runs last.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SELF_DIR}/lib.sh"
require_root

log "Removing other browsers (managed Chrome is the only allowed one)..."
apt-get remove -y firefox 2>/dev/null || true
snap remove firefox 2>/dev/null || true
snap remove chromium 2>/dev/null || true
apt-get remove -y chromium-browser chromium 2>/dev/null || true

log "Ensuring Chrome managed-policy directory exists..."
install -d -m 0755 /etc/opt/chrome/policies/managed
install -d -m 0755 /etc/opt/chrome/policies/recommended

# Pin Chrome as the default browser for the child session.
if command -v google-chrome-stable >/dev/null 2>&1; then
  update-alternatives --install /usr/bin/x-www-browser x-www-browser \
    "$(command -v google-chrome-stable)" 200 2>/dev/null || true
  update-alternatives --set x-www-browser "$(command -v google-chrome-stable)" 2>/dev/null || true
else
  warn "google-chrome-stable not found — run 00-preflight.sh first."
fi

# Make Chrome use the 'basic' password store so it never invokes GNOME Keyring.
# The child autologs in with NO password, so the login keyring can't be unlocked
# and Chrome would otherwise prompt to create one on every launch. (Kiosk: the
# child shouldn't be saving passwords anyway.)
log "Forcing Chrome to skip GNOME Keyring (--password-store=basic)..."
for df in /usr/share/applications/google-chrome.desktop \
          /usr/share/applications/com.google.Chrome.desktop; do
  [[ -f "$df" ]] || continue
  grep -q -- '--password-store=basic' "$df" || \
    sed -i 's#\(Exec=/usr/bin/google-chrome-stable\)#\1 --password-store=basic#g' "$df"
done
update-desktop-database /usr/share/applications 2>/dev/null || true

ok "Browser baseline ready (policy JSON written by regenerate.sh)."
