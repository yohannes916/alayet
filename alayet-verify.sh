#!/usr/bin/env bash
# Post-reboot verification for the alayet locked-down laptop.
# Run as admin over SSH:   sudo bash /home/yohannes/alayet-verify.sh
# Backend checks are automated below; GUI (child-session) checks are listed at the end.
# Output is teed to /home/yohannes/alayet-verify.log so it can be reviewed later.

[[ "${EUID}" -eq 0 ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }
LOG=/home/yohannes/alayet-verify.log

{
pass(){ printf '  [PASS] %s\n' "$*"; }
warn(){ printf '  [WARN] %s\n' "$*"; }
fail(){ printf '  [FAIL] %s\n' "$*"; }

echo "==================================================================="
echo " alayet post-reboot verification — $(date)"
echo "==================================================================="

echo "[1] Services (active/enabled)"
for s in squid dnsmasq nftables fapolicyd ssh; do
  a=$(systemctl is-active "$s" 2>/dev/null); e=$(systemctl is-enabled "$s" 2>/dev/null)
  [[ "$a" == active ]] && pass "$s ($a/$e)" || fail "$s ($a/$e)"
done

echo "[2] System resolver"
grep -q '127.0.0.1' /etc/resolv.conf && pass "resolv.conf -> 127.0.0.1 (dnsmasq)" \
  || warn "resolv.conf not 127.0.0.1: $(tr '\n' ' ' </etc/resolv.conf)"

echo "[3] DNS allow/deny enforcement"
A=$(dig +short +timeout=3 @127.0.0.1 google.com 2>/dev/null | grep -E '^[0-9]' | head -1)
[[ -n "$A" && "$A" != 0.0.0.0 ]] && pass "google.com -> $A (allowed)" || fail "google.com did not resolve ('$A')"
B=$(dig +short +timeout=3 @127.0.0.1 example.com 2>/dev/null | grep -E '^[0-9]' | head -1)
[[ "$B" == 0.0.0.0 || -z "$B" ]] && pass "example.com blocked ('${B:-no answer}')" || fail "example.com -> $B (LEAK!)"

echo "[4] nftables child confinement"
CU=$(id -u alayet 2>/dev/null)
nft list ruleset 2>/dev/null | grep -q "skuid ${CU}" && pass "alayet (uid ${CU}) egress confined to loopback" \
  || fail "no nftables confinement rule for alayet"

echo "[5] fapolicyd (should be permissive = logging only)"
systemctl is-active --quiet fapolicyd && grep -qE '^permissive = 1' /etc/fapolicyd/fapolicyd.conf \
  && pass "fapolicyd active + permissive" || warn "fapolicyd not active/permissive — check before enforcing"

echo "[6] GDM autologin"
grep -qE 'AutomaticLogin *= *alayet' /etc/gdm3/custom.conf && pass "autologin -> alayet" || warn "autologin not set to alayet"

echo "[7] TTY masking"
m=0; for n in 2 3 4 5 6; do [[ $(systemctl is-enabled "getty@tty${n}.service" 2>/dev/null) == masked ]] && m=$((m+1)); done
[[ $m -eq 5 ]] && pass "tty2-6 masked" || warn "only ${m}/5 TTYs masked"

echo "[8] SSH (admin-only)"
systemctl is-active --quiet ssh && grep -q 'AllowUsers yohannes' /etc/ssh/sshd_config.d/parental.conf 2>/dev/null \
  && pass "ssh active + locked to yohannes" || warn "ssh state/drop-in unexpected"

echo "[9] Chrome managed policy"
POL=/etc/opt/chrome/policies/managed/parental.json
if jq -e . "$POL" >/dev/null 2>&1; then
  jq -e '.URLBlocklist==["*"]' "$POL" >/dev/null && pass "URLBlocklist locked to [*]" || fail "URLBlocklist wrong"
  grep -q 'elnojnhiofbohmdijelpdnmlogcfaeko' "$POL" && pass "extension force-install id in policy" || fail "ext id missing"
  jq -e '.DnsOverHttpsMode=="off"' "$POL" >/dev/null && pass "DoH off" || warn "DoH not off"
else fail "policy JSON INVALID (Chrome would ignore ALL policy)"; fi

echo "[10] Extension readable by child"
sudo -u alayet test -r /opt/parental/extension.crx && pass "alayet can read crx" || fail "alayet CANNOT read crx (force-install will fail)"
sudo -u alayet test -r /opt/parental/extension.pem 2>/dev/null && fail "alayet can read SECRET .pem key" || pass "alayet cannot read .pem key"

echo "[11] Extension loaded in alayet's Chrome profile"
EXTD=/home/alayet/.config/google-chrome/Default/Extensions/elnojnhiofbohmdijelpdnmlogcfaeko
[[ -d "$EXTD" ]] && pass "extension unpacked in alayet profile" \
  || warn "not yet present — open Chrome as alayet once, then re-run this check"

echo "[12] Tamper-resistant logs"
for f in activity prompts blocked; do
  p=/var/log/parental/${f}.log
  if [[ -f "$p" ]]; then
    sz=$(stat -c%s "$p"); lsattr "$p" 2>/dev/null | cut -d' ' -f1 | grep -q a && ap="append-only" || ap="NOT append-only"
    [[ $sz -gt 0 ]] && pass "${f}.log ${sz}B, ${ap}" || warn "${f}.log empty (no child activity yet), ${ap}"
  else fail "${f}.log missing"; fi
done

echo "[13] GRUB password"
grep -q 'password_pbkdf2' /boot/grub/grub.cfg && pass "GRUB superuser password present" || fail "no GRUB password in grub.cfg"
grep -q -- '--unrestricted' /boot/grub/grub.cfg && pass "normal boot is --unrestricted (no prompt)" || warn "no --unrestricted (boot may prompt)"

echo "[14] Squid proxy enforcement"
g=$(curl -x 127.0.0.1:3128 -s -o /dev/null -w '%{http_code}' --connect-timeout 6 https://www.google.com 2>/dev/null)
[[ "$g" == 200 ]] && pass "allowed via squid (google.com 200)" || warn "google via squid returned '$g'"
e=$(curl -x 127.0.0.1:3128 -s -o /dev/null -w '%{http_code}' --connect-timeout 6 https://example.com 2>/dev/null)
[[ "$e" != 200 ]] && pass "blocked via squid (example.com '$e')" || fail "example.com allowed via squid (LEAK!)"

echo ""
echo "==================================================================="
echo " MANUAL checks — do these in the alayet GUI session"
echo "==================================================================="
echo "  [ ] GRUB: hold ESC at boot -> press 'e' -> must ask for alayetadmin +"
echo "      password; a normal boot must NOT prompt."
echo "  [ ] No terminal app exists; cannot open a command line."
echo "  [ ] Chrome opens; only allowlisted sites load; Gemini works; others blocked."
echo "  [ ] chrome://extensions shows 'Family Activity Monitor' force-installed"
echo "      and NON-removable (no trash icon / 'Installed by your organization')."
echo "  [ ] YouTube loads in Restricted Mode."
echo "  [ ] After browsing as alayet, re-run this script: activity/prompts logs should grow,"
echo "      and check [11] now shows the extension unpacked."
echo ""
echo "  Reminder: YouTube allowlist is EMPTY -> add channels with:"
echo "      sudo allow-youtube channel <channelId>"
echo "  Admin internet when needed:  sudo maintenance-dns off   (re-lock: ... on)"
echo "==================================================================="
echo " Done. Log saved to ${LOG}"
} 2>&1 | tee "$LOG"
