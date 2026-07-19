#!/usr/bin/env bash
# Orchestrator — runs the full lockdown in order. Run as root from the repo:
#   sudo ./install.sh
# Idempotent: safe to re-run. Do the firmware/boot lockdown (PLAN.md §6) FIRST.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

[[ "${EUID}" -eq 0 ]] || { echo "Run with sudo."; exit 1; }

echo "=============================================="
echo " Locked-down child laptop — installation"
echo "=============================================="
echo "Reminder: complete the firmware/boot lockdown (BIOS password, disable USB"
echo "boot, GRUB password) from PLAN.md §6 — software controls are bypassable"
echo "without it. Continue? [y/N]"
read -r ans
[[ "${ans}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

bash scripts/00-preflight.sh
bash /opt/parental/scripts/01-accounts.sh
bash /opt/parental/scripts/02-app-lockdown.sh
bash /opt/parental/scripts/03-network.sh
bash /opt/parental/scripts/04-browser-policy.sh
bash /opt/parental/scripts/05-install-extension.sh
bash /opt/parental/scripts/regenerate.sh
bash /opt/parental/scripts/06-monitoring.sh

echo ""
echo "Done. Reboot and log in as the child (autologin)."
echo "Verify with the checklist in PLAN.md §9, then tune with: review-denied / allow-site."
echo "Set Telegram alerts: edit /etc/parental/telegram.env then 'sudo health-check --test'."
