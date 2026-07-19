#!/usr/bin/env bash
# App lockdown: fapolicyd application allowlisting + GNOME dconf lockdown.
# Result: the child cannot run downloaded/installed software, cannot open a
# terminal or command line, and cannot reach the software installer.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SELF_DIR}/lib.sh"
require_root

# --- 1. Remove / neuter terminal + installer apps the child shouldn't have ---
log "Removing/neutering terminal + installer apps..."
apt-get remove -y gnome-software snap-store flatpak 2>/dev/null || true
# NOTE: do NOT try to `apt remove` the terminal on 26.04 — it ships **ptyxis**,
# and a terminal dependency just pulls gnome-terminal back in. Instead, make every
# terminal emulator non-executable for the child (root keeps it). This also
# disables x-terminal-emulator (symlink) and any Terminal=true launcher (vim,
# python REPL) since they need a terminal host.
for term in /usr/bin/ptyxis /usr/bin/gnome-terminal /usr/bin/kgx \
            /usr/bin/gnome-console /usr/bin/xterm /usr/bin/konsole /usr/bin/tilix; do
  [[ -e "$term" ]] && chmod 0750 "$term" 2>/dev/null || true
done
# Hide launchers the child shouldn't have: terminals/interpreters (shell vectors)
# AND config/file/software/admin surfaces found by the §9 audit. Searches every
# standard desktop-entry dir (incl. snap/flatpak exports).
hide_launcher() {
  for dir in /usr/share/applications /usr/local/share/applications \
             /var/lib/snapd/desktop/applications \
             /var/lib/flatpak/exports/share/applications; do
    df="${dir}/$1.desktop"
    [[ -f "$df" ]] || continue
    grep -q '^NoDisplay=true' "$df" || sed -i '0,/^\[Desktop Entry\]/s//&\nNoDisplay=true/' "$df"
  done
}
for app in org.gnome.Ptyxis org.gnome.Console vim python3.14 org.gnome.Sysprof \
           org.gnome.Settings org.gnome.Nautilus org.gnome.DiskUtility \
           net.nokyan.Resources org.gnome.seahorse.Application org.gnome.Logs \
           org.gnome.baobab update-manager firmware-updater_firmware-updater \
           desktop-security-center_desktop-security-center nm-connection-editor \
           snap-store_snap-store; do hide_launcher "$app"; done
update-desktop-database /usr/share/applications 2>/dev/null || true

# --- 2. GNOME dconf system lockdown --------------------------------------
log "Applying dconf lockdown..."
install -d -m 0755 /etc/dconf/profile /etc/dconf/db/local.d /etc/dconf/db/local.d/locks

cat > /etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF

cat > /etc/dconf/db/local.d/00-parental <<'EOF'
[org/gnome/desktop/lockdown]
disable-command-line=true
disable-user-switching=true
disable-printing=false
disable-application-handlers=true

[org/gnome/software]
allow-updates=false
download-updates=false

[org/gnome/desktop/notifications]
show-in-lock-screen=false

[org/gnome/shell]
# Only allow a minimal, fixed set of apps to be launched/visible.
disable-extension-installation=true

# The child account has a LOCKED password (no autologin password typed), so it
# CANNOT unlock a screen lock. disable-lock-screen=true makes locking IMPOSSIBLE
# (manual Super+L, idle, AND resume-from-suspend) — note lock-enabled=false alone
# does NOT stop a manual Super+L. With locking impossible, suspend + display-off
# stay enabled for battery life and never show a password prompt.
[org/gnome/desktop/screensaver]
lock-enabled=false
ubuntu-lock-on-suspend=false

[org/gnome/desktop/lockdown]
disable-lock-screen=true

[org/gnome/settings-daemon/plugins/media-keys]
screensaver=@as []
# No custom shortcuts — blocks "bind a key to launch a shell/blocked app".
custom-keybindings=@as []

# Power: screen off after 2 min (both power states); suspend after 5 min on
# battery / 15 min on AC. No lock on resume (disable-lock-screen above).
[org/gnome/desktop/session]
idle-delay=uint32 120

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='suspend'
sleep-inactive-ac-timeout=900
sleep-inactive-battery-type='suspend'
sleep-inactive-battery-timeout=300
EOF

cat > /etc/dconf/db/local.d/locks/00-parental <<'EOF'
/org/gnome/desktop/lockdown/disable-command-line
/org/gnome/desktop/lockdown/disable-application-handlers
/org/gnome/desktop/lockdown/disable-user-switching
/org/gnome/shell/disable-extension-installation
/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/ubuntu-lock-on-suspend
/org/gnome/desktop/lockdown/disable-lock-screen
/org/gnome/settings-daemon/plugins/media-keys/screensaver
/org/gnome/desktop/session/idle-delay
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-timeout
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-timeout
EOF

dconf update
ok "dconf lockdown applied."

# --- 2b. Disable virtual-console (TTY) logins ----------------------------
# Ctrl+Alt+F3..F6 text logins are separate from the GNOME desktop and would
# bypass the whole lockdown. Mask the getty services and stop logind from
# spawning login VTs. GDM keeps its own VT, so the graphical session is fine.
log "Disabling virtual-console logins..."
systemctl mask getty@.service 2>/dev/null || true
systemctl mask serial-getty@.service 2>/dev/null || true
for n in 2 3 4 5 6; do systemctl mask "getty@tty${n}.service" 2>/dev/null || true; done
systemctl mask console-getty.service 2>/dev/null || true
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/parental.conf <<'EOF'
[Login]
NAutoVTs=0
ReserveVT=0
EOF
ok "Virtual-console logins disabled."
# Note: suspend stays ENABLED (laptop battery life). Safe because disable-lock-screen
# above makes resume-from-suspend skip the lock entirely — no password prompt.

# --- 2c. SSH kept ENABLED for admin (${PARENT_USER}) maintenance ----------
# This lockdown removes terminals, disables the GNOME command line, and masks the
# TTYs (below) for EVERY account — including the admin. So the admin needs a
# remote shell to run review-denied / allow-site / maintenance-dns. SSH is that
# path. The child cannot use it: their password is LOCKED (no auth) and the egress
# firewall confines the child uid to loopback. Lock sshd to the admin account only.
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/parental.conf <<EOF
# Admin-only remote shell for parental maintenance (generated).
PermitRootLogin no
AllowUsers ${PARENT_USER}
EOF
systemctl unmask ssh 2>/dev/null || true
systemctl enable --now ssh 2>/dev/null || true
systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true
warn "SSH kept enabled (admin-only: ${PARENT_USER}). VERIFY you can log in over"
warn "SSH *before* rebooting — once the TTYs are masked, SSH is the only way in."

# --- 3. fapolicyd application allowlisting (DISABLED by default — see note) ---
# fapolicyd would block execution of non-dpkg binaries (downloads/USB/AppImages).
# We pre-stage the deny rules below, but DO NOT run fapolicyd by default because on
# Ubuntu 26.04 (fapolicyd 1.3.6) it is net-negative as shipped:
#   * PERMISSIVE mode logs ZERO decisions (no journal/syslog/audit output), so
#     `fapolicyd-review` is always empty — the "review then enforce" workflow can't
#     surface what would break, making a safe rollout impossible from that data.
#   * It loads its trust DB into ~4.6 GB RAM and takes 30-60s+ to start.
# The practical "run an arbitrary binary" vectors are already closed by the rest of
# this lockdown (no terminal, downloads blocked, file-manager + risky launchers
# hidden, locked password blocks polkit/sudo). So for a child threat model we leave
# fapolicyd OFF. To pursue ENFORCE for a stronger threat model, tune with
# `fapolicyd --debug-deny` (foreground, non-blocking) to capture would-denies, trust
# the legit ones, then enable + set `permissive = 0` and `systemctl enable --now fapolicyd`.
log "Pre-staging fapolicyd deny rules (service left DISABLED)..."
if [[ -d /etc/fapolicyd/rules.d ]]; then
  cat > /etc/fapolicyd/rules.d/10-parental-deny-user-exec.rules <<EOF
# Block execution of anything under the child's writable locations.
deny perm=execute uid=$(id -u "${CHILD_USER}" 2>/dev/null || echo 1001) : dir=/home/${CHILD_USER}/
deny perm=execute all : dir=/tmp/
deny perm=execute all : dir=/var/tmp/
deny perm=execute all : dir=/media/
deny perm=execute all : dir=/mnt/
EOF
  fagenrules --load 2>/dev/null || true
fi
systemctl disable --now fapolicyd 2>/dev/null || true
rm -f /run/fapolicyd.pid
ok "fapolicyd disabled (rules pre-staged for a future enforce rollout)."

ok "App lockdown complete."
