#!/usr/bin/env bash
# Install + force-deploy the monitoring extension, register its native logging
# host, and set up tamper-resistant append-only logs.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SELF_DIR}/lib.sh"
require_root

EXT_SRC="/opt/parental/extension"
KEY="/opt/parental/extension.pem"
CRX="/opt/parental/extension.crx"
UPDATE_XML="/opt/parental/update.xml"
HOST_NAME="com.parental.logger"

if command -v google-chrome-stable >/dev/null 2>&1; then CHROME=google-chrome-stable
elif command -v google-chrome >/dev/null 2>&1; then CHROME=google-chrome
else die "Google Chrome not found — run 00-preflight.sh first."; fi

# --- 1. Stable signing key (generate once) --------------------------------
if [[ ! -f "${KEY}" ]]; then
  log "Generating extension signing key..."
  openssl genrsa -out "${KEY}" 2048 2>/dev/null
  chmod 600 "${KEY}"
fi

# --- 2. Derive the deterministic extension ID from the key ----------------
EXT_ID="$(python3 - "$KEY" <<'PY'
import hashlib, subprocess, sys, os
key = sys.argv[1]
der = subprocess.check_output(
    ["openssl", "rsa", "-in", key, "-pubout", "-outform", "DER"],
    stderr=open(os.devnull, "wb"))
h = hashlib.sha256(der).hexdigest()[:32]
print("".join(chr(ord('a') + int(c, 16)) for c in h))
PY
)"
echo "${EXT_ID}" > "${EXT_SRC}/.extension-id"
ok "Extension ID: ${EXT_ID}"

# --- 3. Pack the .crx ------------------------------------------------------
log "Packing extension..."
rm -f "${CRX}"
# Chrome refuses to pack as root without --no-sandbox + a writable user-data-dir.
PACK_TMP="$(mktemp -d /tmp/chrome-pack.XXXXXX)"
"${CHROME}" --pack-extension="${EXT_SRC}" --pack-extension-key="${KEY}" \
  --no-message-box --no-sandbox --user-data-dir="${PACK_TMP}" >/dev/null 2>&1 || true
rm -rf "${PACK_TMP}"
# Chrome writes <dir>.crx next to the directory. With EXT_SRC=/opt/parental/extension
# that path IS ${CRX}, so only move when they actually differ (avoids a self-move
# error that aborts the script under `set -e`).
if [[ -f "${EXT_SRC}.crx" && "${EXT_SRC}.crx" != "${CRX}" ]]; then
  mv -f "${EXT_SRC}.crx" "${CRX}"
fi
if [[ -f "${CRX}" ]]; then
  # Chrome runs as the child; the crx must be world-readable to force-install.
  chmod 0644 "${CRX}"
else
  warn "CRX not produced; force-install may fall back to unpacked load."
fi

# --- 4. Self-hosted update manifest (file://) -----------------------------
# Version MUST match manifest.json so Chrome detects updates when the crx is
# re-packed (e.g. after editing a content script).
EXT_VER="$(python3 -c "import json;print(json.load(open('${EXT_SRC}/manifest.json'))['version'])" 2>/dev/null || echo 1.0.0)"
cat > "${UPDATE_XML}" <<EOF
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='${EXT_ID}'>
    <updatecheck codebase='file://${CRX}' version='${EXT_VER}' />
  </app>
</gupdate>
EOF
ok "Update manifest: ${UPDATE_XML} (v${EXT_VER})"

# --- 5. Register the native messaging logging host ------------------------
log "Registering native messaging host..."
# Chrome is primary; also register for Chromium if its config tree exists.
HOST_DIRS=(/etc/opt/chrome/native-messaging-hosts)
[[ -d /etc/chromium ]] && HOST_DIRS+=(/etc/chromium/native-messaging-hosts)
for hostdir in "${HOST_DIRS[@]}"; do
  install -d -m 0755 "$hostdir"
  cat > "${hostdir}/${HOST_NAME}.json" <<EOF
{
  "name": "${HOST_NAME}",
  "description": "Family Activity Monitor logger",
  "path": "${EXT_SRC}/logger-host.py",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://${EXT_ID}/"]
}
EOF
done
chmod +x "${EXT_SRC}/logger-host.py"
# The child's Chrome runs as the child user and must be able to TRAVERSE to and
# READ the crx + update manifest, and EXECUTE the native logging host. Make those
# world-readable/traversable; keep the signing key (.pem) secret. Without this,
# force-install silently fails because the child cannot read the crx.
chmod 0755 /opt /opt/parental "${EXT_SRC}"
chmod 0755 "${EXT_SRC}/logger-host.py"
[[ -f "${UPDATE_XML}" ]] && chmod 0644 "${UPDATE_XML}"
[[ -f "${CRX}" ]] && chmod 0644 "${CRX}"
find "${EXT_SRC}" -type f \( -name '*.js' -o -name '*.json' -o -name '*.html' \) \
  -exec chmod 0644 {} + 2>/dev/null || true
[[ -f "${KEY}" ]] && chmod 0600 "${KEY}"
ok "Native host registered."

# --- 6. Tamper-resistant append-only logs ---------------------------------
# The native host runs as the child, so logs are append-only (chattr +a):
# the child can write new lines but cannot read, edit, or delete them.
log "Setting up append-only logs..."
install -d -m 0755 "${LOG_DIR}"          # dir NOT writable by child -> can't unlink
for name in activity prompts blocked searches; do
  f="${LOG_DIR}/${name}.log"
  [[ -f "$f" ]] || : > "$f"
  chattr -a "$f" 2>/dev/null || true     # temporarily clear to set perms
  chown root:root "$f"
  chmod 0600 "$f"
  setfacl -m "u:${CHILD_USER}:w" "$f" 2>/dev/null || chmod 0622 "$f"
  chattr +a "$f" 2>/dev/null || warn "chattr +a failed on $f (non-ext4 fs?); logs writable but deletable."
done
ok "Logs ready under ${LOG_DIR} (append-only)."

ok "Extension installed and force-deployed."
