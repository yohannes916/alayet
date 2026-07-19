# alayet laptop — RESUME STATE (saved 2026-06-30)

Locked-down child laptop. Ubuntu 26.04, hostname alayet-laptop.
Kit: ~/alayet (source) + /opt/parental (deployed). PLAN.md / README.md in ~/alayet.

## Accounts
- yohannes : admin, sudo (the "parent"/maintenance account).
- alayet   : child, NO sudo, password LOCKED, GDM autologin (no password typed).

## DONE & VERIFIED
- Firmware: MrChromebox UEFI Full ROM (ChromeOS wiped; WP disabled cable-free on Ti50).
- Installer ran fully: preflight (pkgs+Chrome .deb), accounts, app-lockdown (fapolicyd
  PERMISSIVE), network (dnsmasq+squid+nftables active), browser policy (parental.json),
  extension (force-installed id elnojnhiofbohmdijelpdnmlogcfaeko), regenerate.
- GRUB password set (/etc/grub.d/40_custom).
- Screen-lock DISABLED (locked dconf /etc/dconf/db/local.d/01-no-screenlock) — was
  locking the child out; fixed live + in kit scripts/02-app-lockdown.sh.
- MONITORING LOGGING VERIFIED end-to-end (all 3 paths): visit + blocked + Gemini prompt
  all captured to /var/log/parental/{activity,prompts,blocked}.log. Logs reset to clean
  slate after testing (currently 0 bytes — correct, awaiting real use).

## OPEN ITEMS (do tomorrow)
1. KEYRING: Chrome prompts to create a GNOME keyring (alayet has no login password).
   Fix = add --password-store=basic to alayet's Chrome launcher + bake into kit
   (or click through with an EMPTY keyring password once). NOT yet applied.
2. FAPOLICYD ROLLOUT: still permissive (logs, blocks nothing). After a few days of real
   use: sudo fapolicyd-review -> sudo fapolicyd-allow <path> -> sudo fapolicyd-enforce.
3. PLAN.md §9 verification AS alayet: no terminal, only Chrome runs, allowlist holds,
   extension shows force-installed/unremovable in chrome://extensions.
4. SSH is currently ENABLED for remote admin; lockdown design wants it masked
   (systemctl mask ssh) for the final locked posture — decide when done.

## Firmware caveat (known weak point)
MrChromebox edk2 has NO supervisor password; USB boot not fully blockable. GRUB password
blocks init=/bin/bash but not USB boot. No full-disk encryption. OK for younger child;
revisit (LUKS reinstall) for a savvy teen.

## Access (for the assistant)
ssh yohannes@192.168.86.222 (key-based from yohannes' ThinkPad already authorized).
IP is DHCP — may change; try hostname alayet-laptop / alayet-laptop.local if it moves.
sudo over ssh: pipe the admin password to `sudo -S` (ask the user for it; not stored).
