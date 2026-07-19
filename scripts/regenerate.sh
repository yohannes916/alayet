#!/usr/bin/env bash
# Regenerate every enforcement layer from the single source of truth.
#   reads:  $ALLOWLIST, $YT_ALLOWLIST
#   writes: Chromium managed policy, Squid ACL, dnsmasq allow zone, extension config
#   then:   reloads squid + dnsmasq if they are running.
#
# Run directly, or via the `allow-site` / `deny-site` / `allow-youtube` helpers.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SELF_DIR}/lib.sh"
require_root

CHROME_POLICY_DIR="/etc/opt/chrome/policies/managed"      # Google Chrome (primary)
CHROMIUM_POLICY_DIR="/etc/chromium/policies/managed"      # only if Chromium also present
SQUID_ACL="/etc/squid/allowlist.acl"
SQUID_ACCESS="/etc/squid/parental-access.conf"            # http_access decision (included by squid.conf)
DNSMASQ_CONF="/etc/dnsmasq.d/parental.conf"
EXT_CONFIG="${EXT_DIR}/config.js"

# --- Open-browsing mode -----------------------------------------------------
# When the sentinel ${ETC_DIR}/open-mode exists, ALL websites are allowed
# (browsing is unrestricted) while EVERYTHING ELSE stays on: Squid still logs
# every request, the extension still logs visits/searches/prompts, and YouTube
# is still forced into Restricted Mode + the channel/video allowlist.
# Toggle with:  sudo open-web  /  sudo close-web
OPEN_FLAG="${ETC_DIR}/open-mode"
if [[ -f "$OPEN_FLAG" ]]; then OPEN_MODE=1; else OPEN_MODE=0; fi

mapfile -t DOMAINS < <(read_list "$(installed_allowlist)")
if [[ "$OPEN_MODE" -eq 0 && "${#DOMAINS[@]}" -eq 0 ]]; then
  die "Allowlist is empty: $(installed_allowlist)"
fi

# Restricted Mode CNAME target.
case "${YOUTUBE_RESTRICT}" in
  strict)   YT_TARGET="restrict.youtube.com" ;;
  moderate) YT_TARGET="restrictmoderate.youtube.com" ;;
  *)        die "YOUTUBE_RESTRICT must be 'strict' or 'moderate'." ;;
esac

# Extension id (deterministic; written by 05-install-extension.sh).
EXT_ID="$(cat "${EXT_DIR}/.extension-id" 2>/dev/null || echo PLACEHOLDER_EXTENSION_ID)"

# Parse the YouTube allowlist ONCE into channel / video / handle arrays. These
# feed BOTH the managed-storage policy (live, no repack) and the baked-in
# config.js fallback.
mapfile -t YT < <(read_list "$(installed_yt)")
YT_CHANNELS=(); YT_VIDEOS=(); YT_HANDLES=()
for line in "${YT[@]}"; do
  case "$line" in
    channel:*) YT_CHANNELS+=("$(echo "${line#channel:}" | tr -d '[:space:]')") ;;
    video:*)   YT_VIDEOS+=("$(echo "${line#video:}"   | tr -d '[:space:]')") ;;
    handle:*)  YT_HANDLES+=("$(echo "${line#handle:}"  | tr -d '[:space:]')") ;;
  esac
done

# Print the given args as a comma-separated JSON string list (no brackets).
json_array() {
  local first=1 x
  for x in "$@"; do
    [[ $first -eq 1 ]] && first=0 || printf ','
    printf '"%s"' "$x"
  done
}

# ---------------------------------------------------------------------------
# 1. Chromium / Chrome managed policy
# ---------------------------------------------------------------------------
build_chromium_policy() {
  local dir="$1"
  install -d -m 0755 "$dir"
  {
    echo '{'
    if [[ "$OPEN_MODE" -eq 1 ]]; then
      # OPEN mode: block nothing. (Extension + proxy still log; YouTube still restricted.)
      echo '  "URLBlocklist": [],'
    else
      echo '  "URLBlocklist": ["*"],'
      printf '  "URLAllowlist": ['
      local first=1
      for d in "${DOMAINS[@]}"; do
        d="${d#\*.}"                     # "*.gstatic.com" -> "gstatic.com" (host+subdomains)
        [[ $first -eq 1 ]] && first=0 || printf ','
        printf '\n    "%s"' "$d"
      done
      # Always allow the approved-content landing page (file://), even when locked.
      printf ',\n    "file:///opt/parental/approved.html"'
      echo ''
      echo '  ],'
    fi
    echo "  \"ProxySettings\": {\"ProxyMode\": \"fixed_servers\", \"ProxyServer\": \"${PROXY_LISTEN}:${PROXY_PORT}\"},"
    echo '  "DeveloperToolsAvailability": 2,'
    echo '  "DnsOverHttpsMode": "off",'
    echo '  "IncognitoModeAvailability": 1,'
    echo '  "BrowserGuestModeEnabled": false,'
    echo '  "DownloadRestrictions": 3,'
    # Approved-content landing page as a managed (non-removable) bookmark + home button.
    echo '  "BookmarkBarEnabled": true,'
    echo '  "ShowHomeButton": true,'
    echo '  "HomepageLocation": "file:///opt/parental/approved.html",'
    echo '  "ManagedBookmarks": ['
    echo '    {"toplevel_name": "Approved"},'
    echo '    {"name": "Approved Channels", "url": "file:///opt/parental/approved.html"}'
    echo '  ],'
    echo '  "ExtensionInstallForcelist": ["'"${EXT_ID};file:///opt/parental/update.xml"'"],'
    echo '  "ExtensionInstallBlocklist": ["*"],'
    # Deliver the YouTube allowlist to the extension via managed storage
    # (chrome.storage.managed). Regenerated on every allow-youtube run — the
    # extension picks it up live on the next policy refresh, NO repack needed.
    # Emitted in BOTH open and locked modes (YouTube stays restricted always).
    echo '  "3rdparty": {'
    echo '    "extensions": {'
    echo "      \"${EXT_ID}\": {"
    printf '        "youtubeChannels": [%s],\n' "$(json_array "${YT_CHANNELS[@]}")"
    printf '        "youtubeVideos": [%s],\n'   "$(json_array "${YT_VIDEOS[@]}")"
    printf '        "youtubeHandles": [%s],\n'  "$(json_array "${YT_HANDLES[@]}")"
    printf '        "restrictMode": "%s"\n'     "${YOUTUBE_RESTRICT}"
    echo '      }'
    echo '    }'
    echo '  }'
    echo '}'
  } > "${dir}/parental.json"
  chmod 0644 "${dir}/parental.json"
}
build_chromium_policy "$CHROME_POLICY_DIR"
[[ -d /etc/chromium/policies ]] && build_chromium_policy "$CHROMIUM_POLICY_DIR" || true
if [[ "$OPEN_MODE" -eq 1 ]]; then
  ok "Chrome policy written (OPEN mode — all sites allowed)."
else
  ok "Chrome policy written (${#DOMAINS[@]} allowed domains)."
fi

# ---------------------------------------------------------------------------
# 2. Squid: domain ACL + the http_access decision (included by squid.conf).
#    Closed mode -> allow only allowlisted domains. Open mode -> allow all
#    (Squid still logs every request either way).
# ---------------------------------------------------------------------------
if command -v squid >/dev/null 2>&1; then
  {
    for d in "${DOMAINS[@]}"; do
      if [[ "$d" == \*.* ]]; then echo ".${d#\*.}"; else echo "$d"; fi
    done
  } > "$SQUID_ACL"
  chmod 0644 "$SQUID_ACL"

  if [[ "$OPEN_MODE" -eq 1 ]]; then
    {
      echo "# AUTO-GENERATED by regenerate.sh (OPEN mode) — do not edit by hand."
      echo "http_access deny CONNECT !SSL_ports"
      echo "http_access allow all"
    } > "$SQUID_ACCESS"
  else
    {
      echo "# AUTO-GENERATED by regenerate.sh — do not edit by hand."
      echo 'acl allowed_domains dstdomain "/etc/squid/allowlist.acl"'
      echo "http_access deny CONNECT !SSL_ports"
      echo "http_access allow allowed_domains"
      echo "http_access deny all"
    } > "$SQUID_ACCESS"
  fi
  chmod 0644 "$SQUID_ACCESS"
  ok "Squid access rules written: $SQUID_ACCESS"
fi

# ---------------------------------------------------------------------------
# 3. dnsmasq whitelist zone (default-deny via address=/#/0.0.0.0 catch-all,
#    allowed domains forwarded to upstream, YouTube CNAMEd to Restricted Mode)
# ---------------------------------------------------------------------------
if command -v dnsmasq >/dev/null 2>&1; then
  UPSTREAM="8.8.8.8"
  {
    echo "# AUTO-GENERATED by regenerate.sh — do not edit by hand."
    echo "no-resolv"
    echo "bogus-priv"
    if [[ "$OPEN_MODE" -eq 1 ]]; then
      echo "# OPEN mode: resolve everything upstream (browsing unrestricted)."
      echo "server=${UPSTREAM}"
    else
      echo "# Catch-all: anything not explicitly allowed resolves to 0.0.0.0 (blocked)."
      echo "address=/#/0.0.0.0"
      echo ""
      echo "# Allowed domains -> forward to upstream resolver."
      for d in "${DOMAINS[@]}"; do
        d="${d#\*.}"
        echo "server=/${d}/${UPSTREAM}"
      done
    fi
    echo ""
    echo "# Force YouTube Restricted Mode (${YOUTUBE_RESTRICT}) via CNAME — active in BOTH modes."
    echo "server=/${YT_TARGET}/${UPSTREAM}"
    for host in www.youtube.com m.youtube.com youtube.com youtubei.googleapis.com; do
      echo "cname=${host},${YT_TARGET}"
    done
  } > "$DNSMASQ_CONF"
  chmod 0644 "$DNSMASQ_CONF"
  ok "dnsmasq zone written: $DNSMASQ_CONF"
fi

# ---------------------------------------------------------------------------
# 4. Extension baked-in config.js — FALLBACK ONLY.
#    The live allowlist is delivered via managed storage (the "3rdparty" block
#    in parental.json above). config.js is the fail-safe used only when managed
#    policy is unavailable; an empty list here means "block everything".
# ---------------------------------------------------------------------------
if [[ -d "${EXT_DIR}" ]]; then
  {
    echo '// AUTO-GENERATED by regenerate.sh — do not edit by hand.'
    echo '// FALLBACK only; the live allowlist comes from chrome.storage.managed.'
    echo 'globalThis.PARENTAL_CONFIG = {'
    printf '  youtubeChannels: [%s],\n' "$(json_array "${YT_CHANNELS[@]}")"
    printf '  youtubeVideos: [%s],\n'   "$(json_array "${YT_VIDEOS[@]}")"
    printf '  youtubeHandles: [%s],\n'  "$(json_array "${YT_HANDLES[@]}")"
    echo "  restrictMode: \"${YOUTUBE_RESTRICT}\","
    echo '};'
  } > "$EXT_CONFIG"
  chmod 0644 "$EXT_CONFIG"
  ok "Extension config written: $EXT_CONFIG"
fi

# ---------------------------------------------------------------------------
# 5. Reload running services
# ---------------------------------------------------------------------------
if systemctl is-active --quiet squid 2>/dev/null; then
  squid -k reconfigure && ok "Squid reloaded."
fi
if systemctl is-active --quiet dnsmasq 2>/dev/null; then
  # NOTE: dnsmasq SIGHUP/reload does NOT re-read config files (only hosts/leases/
  # resolv.conf). A restart is required to apply a regenerated allow-zone.
  systemctl restart dnsmasq
  ok "dnsmasq restarted (config reloaded)."
fi

if [[ "$OPEN_MODE" -eq 1 ]]; then
  warn "OPEN browsing mode is ON — every website is allowed (logging + YouTube restriction still active). Run 'sudo close-web' to re-lock."
fi
ok "Regeneration complete."
