#!/usr/bin/env bash
# Accounts: a passworded admin (parent) and a no-sudo child with GDM autologin
# (no password typed at login). Idempotent.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SELF_DIR}/lib.sh"
require_root

# --- Parent (admin) -------------------------------------------------------
if ! id "${PARENT_USER}" >/dev/null 2>&1; then
  log "Creating admin user '${PARENT_USER}'..."
  adduser --gecos "Parent" "${PARENT_USER}"
  usermod -aG sudo "${PARENT_USER}"
  warn "Set a STRONG password for '${PARENT_USER}' now (prompted above)."
else
  ok "Admin user '${PARENT_USER}' exists."
  usermod -aG sudo "${PARENT_USER}"
fi

# --- Child (standard, no sudo) -------------------------------------------
if ! id "${CHILD_USER}" >/dev/null 2>&1; then
  log "Creating child user '${CHILD_USER}'..."
  adduser --disabled-password --gecos "${CHILD_FULLNAME}" "${CHILD_USER}"
else
  ok "Child user '${CHILD_USER}' exists."
fi
# Ensure NOT in sudo/admin groups.
deluser "${CHILD_USER}" sudo 2>/dev/null || true
deluser "${CHILD_USER}" adm  2>/dev/null || true
# LOCK the password (do NOT use `passwd -d`, which leaves an EMPTY password that
# would allow a no-password shell login on a virtual console / SSH). GDM
# autologin works fine with a locked password, so the child still logs in with
# no password typed, but cannot authenticate on a TTY or over SSH.
passwd -l "${CHILD_USER}" >/dev/null 2>&1 || true

# --- GDM autologin for the child (no password typed) ----------------------
GDM_CONF="/etc/gdm3/custom.conf"
if [[ -f "${GDM_CONF}" ]]; then
  log "Configuring GDM autologin for '${CHILD_USER}'..."
  # Replace or insert the [daemon] autologin block.
  python3 - "$GDM_CONF" "$CHILD_USER" <<'PY'
import configparser, sys
path, user = sys.argv[1], sys.argv[2]
cp = configparser.ConfigParser(); cp.optionxform = str
cp.read(path)
if not cp.has_section('daemon'): cp.add_section('daemon')
cp['daemon']['AutomaticLoginEnable'] = 'true'
cp['daemon']['AutomaticLogin'] = user
with open(path, 'w') as f: cp.write(f)
PY
  ok "GDM autologin configured."
else
  warn "${GDM_CONF} not found — is GDM installed? Set autologin manually."
fi

ok "Accounts configured."
