# Deployment Notes — real-hardware findings & reuse checklist

These notes capture what was learned deploying this kit on real hardware, the fixes
folded back into the scripts, and the exact steps to reuse the package on another laptop.

## Reference deployment

- **Hardware:** Google **"Jubilant"** Chromebook (board `Jubilant`, product `Jubileum`),
  8 GB RAM, 128 GB eMMC.
- **Firmware:** **MrChromebox / coreboot** with a UEFI (Tianocore) payload, booting in
  UEFI mode. The stock Chrome OS firmware was replaced (its backup `.rom` ships in the
  kit but is **not used** by this project).
- **OS:** Ubuntu 26.04 LTS.
- **Accounts:** child `alayet`; admin = the pre-existing login `yohannes` (kept sudo).
- **Settings:** `YOUTUBE_RESTRICT=strict`, logs local-only.

## Admin maintenance model (important)

The lockdown removes terminals, disables the GNOME command line, and **masks the TTYs for
every account — including the admin**. So the admin does NOT get a local shell. Maintenance
is done **over SSH**, locked to the admin account:

- `00-preflight.sh` installs `openssh-server`.
- `02-app-lockdown.sh` writes `/etc/ssh/sshd_config.d/parental.conf` with
  `PermitRootLogin no` + `AllowUsers ${PARENT_USER}`, and keeps sshd enabled.
- The child cannot use SSH: their password is **locked** (no auth) and the nftables
  firewall confines the child uid to loopback.

**Always confirm `ssh <PARENT_USER>@<ip>` works BEFORE rebooting** — after reboot the TTYs
are masked and SSH is the only way in. (A wifi DHCP reservation for the laptop is wise so
its IP doesn't move.) Emergency fallback if SSH is ever lost: GRUB → recovery (GRUB
password required) or a live USB (disk is unencrypted unless you added LUKS).

## Admin DNS (the `maintenance-dns` helper)

dnsmasq's catch-all confines DNS to the allowlist for **every** account, so the admin can't
`apt`/browse normally. Toggle it:

```
sudo maintenance-dns off   # unlock: use a public resolver
sudo maintenance-dns on    # re-lock: back through the dnsmasq allowlist
```

Unlocking DNS does **not** open the child's web access — the child is still confined by the
firewall + Squid allowlist.

## Chromebook / MrChromebox firmware reality (supersedes parts of PLAN §6)

The generic §6 checklist assumes a commercial BIOS. On MrChromebox firmware:

| §6 item | Reality on MrChromebox |
|---|---|
| BIOS/UEFI supervisor password | **Available on this MrChromebox/edk2 build — and SET during deployment.** Recent Tianocore payloads expose an admin/firmware password in the Setup menu; setting it gates the firmware Setup *and* the boot-device menu. (Older builds lacked this — verify on your firmware version.) |
| Disable USB/network boot | With the firmware password set (above), the boot-device menu requires it, so USB/external boot is effectively gated. Also set the internal disk first in the boot order. |
| Secure Boot | Supported by edk2 but unenrolled; doesn't stop booting a signed live USB. Low value here. |
| **GRUB password** | **Works and is the main lever.** Set with `grub-mkpasswd-pbkdf2` → `/etc/grub.d/40_custom` (`set superusers` + `password_pbkdf2`), and add `--unrestricted` to `CLASS` in `/etc/grub.d/10_linux` so normal boot stays password-free while edit (`e`)/console (`c`) require the password. |
| **Full-disk encryption (LUKS)** | **The real tamper-resistance.** Without a firmware password and with USB boot reachable, an unencrypted disk is mountable from any live USB → the whole software lockdown is bypassable. LUKS can't be added cleanly in place; it means reinstalling Ubuntu with encryption. Conflicts with no-password login unless you accept a boot passphrase or TPM/GSC auto-unlock. |
| Re-enable firmware write-protect (GSC/Ti50) | Optional: prevents reflashing stock/modified firmware. |

With the firmware password set the boot menu is gated, which closes the casual USB-boot path.
Without LUKS, though, anyone who pulls the eMMC (or learns the firmware password) can still
mount the unencrypted disk — LUKS remains the only true at-rest protection.

## Fixes folded into the scripts since the first build

All four were found during the reference deployment and are now in the repo:

1. **fapolicyd layout (`02-app-lockdown.sh`)** — fapolicyd 1.3.x on Ubuntu 26.04 does **not**
   pre-create `/etc/fapolicyd/rules.d`; it ships the default policy as
   `/usr/share/fapolicyd/sample-rules/`. The script now creates `rules.d`, seeds the sample
   rules, **deletes `22-buildroot.rules`** (references the Fedora-only `mock` user, which
   makes fapolicyd refuse to start), writes the parental deny rule, runs
   `fagenrules --load` + `fapolicyd-cli --update`, and starts in permissive mode.
2. **dnsmasq reload→restart (`regenerate.sh`)** — dnsmasq's SIGHUP/reload does **not** re-read
   config files (only hosts/leases/resolv.conf), so a regenerated allow-zone was never
   applied. Changed to `systemctl restart dnsmasq`. (Affects `allow-site`/`deny-site` too.)
3. **CRX packing (`05-install-extension.sh`)** — Chrome refuses `--pack-extension` as root
   without `--no-sandbox` and a writable `--user-data-dir`; the error was swallowed and the
   crx was never produced. Fixed, and the crx is `chmod 0644`.
4. **Extension perms (`05-install-extension.sh`)** — the child's Chrome runs as the child user
   and must read the crx/update.xml and exec the native host. The script now makes
   `/opt`, `/opt/parental`, the extension dir, the crx, update.xml, and `logger-host.py`
   world-readable/traversable while keeping the `.pem` signing key `0600`.

## Round 2 — fixes & hardening folded in (2026-06-30)

Found during extended on-device testing of the **child session**:

- **Screen never locks (autologin can't unlock it).** The child password is locked, so *any*
  lock screen = permanent lockout. `lock-enabled=false` does NOT stop a manual **Super+L** —
  the real switch is `org.gnome.desktop.lockdown disable-lock-screen=true` (blocks manual,
  idle, and resume-from-suspend locks). Set + locked in `02`, Super+L binding cleared.
- **Power management.** Screen off after 2 min; suspend after 5 min (battery) / 15 min (AC);
  no password on resume. Locked dconf in `02`. (Laptop leaves Wi-Fi while suspended — wake it
  to SSH in.)
- **No terminal.** Ubuntu 26.04 ships **ptyxis** (not gnome-terminal), which survived the old
  `apt remove` and can't be cleanly purged (a dependency repulls gnome-terminal). `02` now
  makes every terminal emulator non-executable for the child (`chmod 0750`), which also kills
  `x-terminal-emulator` and `Terminal=true` launchers (vim/python REPL).
- **App-grid lockdown (§9 audit).** Hid Settings, Files, Disk Utility, nm-connection-editor,
  snap-store, Resources, seahorse, Logs, baobab, update-manager, firmware-updater,
  desktop-security-center, Sysprof (NoDisplay). Locked `custom-keybindings` empty (blocks
  binding a key to a shell). polkit admin actions need `auth_admin` → the locked password
  can't authenticate (no package-install / user-admin).
- **Chrome keyring prompt.** Passwordless autologin made Chrome prompt to create a GNOME
  keyring; fixed with `--password-store=basic` on the Chrome launchers (`04`).
- **Downloads blocked** — `DownloadRestrictions=3` in the Chrome policy (`regenerate.sh`).
- **fapolicyd DISABLED (supersedes the permissive/rollout plan and fix #1 below).** On Ubuntu
  26.04 (fapolicyd 1.3.6) **permissive mode logs ZERO decisions** (nothing in
  journal/syslog/audit, no per-decision CLI dump), so `fapolicyd-review` is always empty — the
  review→enforce workflow can't show what would break. It also loads its trust DB into ~4.6 GB
  RAM and is slow to start. The practical exec vectors are already closed (no terminal,
  downloads blocked, launchers hidden, locked password), so `02` now **disables** fapolicyd and
  only pre-stages the deny rules. To enforce later: tune with `fapolicyd --debug-deny`
  (foreground, non-blocking), trust the legit binaries, then set `permissive=0` and enable it.
- **Google Search logging → `searches.log`.** Every Google query (incl. **AI Mode**, `udm=50`)
  is parsed from visited URLs by the native host (`logger-host.py`) — no extension change —
  with a 5-second same-query dedup.
- **Google AI-window follow-ups → `prompts.log` (service `google-ai`).** Follow-ups typed
  inside Google's AI Mode/AI-Overview window are in-page (no URL change), so
  `content-google-ai.js` (content script on www.google.com) captures them. Selectors are
  best-effort and may need tuning as Google's DOM changes.
- **Extension re-pack/update gotchas.** Pack the crx as root with
  `--no-sandbox --user-data-dir=<tmp>`; `chmod 0644` the crx + update.xml; bump `version` in
  `manifest.json` (update.xml reads it automatically). To make Chrome pick up a new version you
  must **fully** kill Chrome (`pkill -9 -u <child> -f chrome`, verify 0 procs) before relaunch —
  a partial kill re-attaches to the old instance and skips the forcelist re-check. If a
  half-broken record lingers, clear the ext id from `Default/Preferences` `extensions.settings`
  and delete `Extensions/<id>/`.

## Round 3 — YouTube hardening, managed storage, network robustness (2026-07-03)

Extension is now **v1.0.8**. New files: `extension/schema.json`, `extension/content-google-video.js`.

- **YouTube allowlist moved to `chrome.storage.managed`** (delivered by the `"3rdparty"` block
  in the Chrome managed policy that `regenerate.sh` writes). `allow-youtube` now updates the
  policy and the extension reads it **live — no crx repack** for allowlist changes (only a Chrome
  restart/policy refresh; `storage.onChanged` also re-evaluates open tabs). One-time cost was a
  single repack to add `storage.managed_schema`. `config.js` is kept as an empty=block-everything
  fail-safe. To force the child's Chrome onto a new extension version quickly: kill Chrome, delete
  the ext's `extensions.settings.<id>` (+ its `protection.macs…`) from `Default/Preferences`,
  `rm -rf Extensions/<id>`, relaunch → prompt fresh force-install (the slow updater timer is why
  just bumping the version isn't enough).
- **Fixed `05-install-extension.sh` self-`mv`** — Chrome writes `<dir>.crx` to exactly the CRX
  dest, so the old unconditional `mv` self-moved and aborted under `set -e`. Guarded.
- **Embedded/inline video was bypassing the allowlist.** Three-layer fix:
  1. `content-youtube.js` runs in **all frames** and blocks `/embed`,`/v`,`/e` player paths (and
     `youtube-nocookie.com`) unless the exact video id is allowlisted.
  2. **Google Search inline video preview** plays in an isolated frame content scripts can't
     enter; blocked at the **network layer** by sinkholing `youtube-nocookie.com`
     (`address=/youtube-nocookie.com/0.0.0.0` in dnsmasq **and** a Squid `http_access deny`).
     Needs a Chrome restart to drop stale keep-alive tunnels before it takes hold.
  3. `content-google-video.js` (content script on www.google.com) removes any
     `<video>`/`<fencedframe>`/YouTube-player-`<iframe>` from Google's DOM as insurance.
- **DNS/proxy robustness** (all in `03-network.sh`):
  - `filter-AAAA` — this LAN has no IPv6 egress; without it dual-stack sites resolve to a v6
    address Squid can't reach (`TCP_TUNNEL/503 HIER_NONE`).
  - `host-record=restrict.youtube.com,216.239.38.120` + `…restrictmoderate…,216.239.38.119` —
    pin the Restricted-Mode CNAME targets locally so the chain never re-resolves upstream
    (closes a transient "CNAME with no A on cache expiry" gap). Re-check IPs with
    `dig +short A restrict.youtube.com @8.8.8.8` if YouTube ever stops loading.
  - `min-cache-ttl=300` (dnsmasq) + **`positive_dns_ttl 1 minutes` / `negative_dns_ttl 10 seconds`
    (squid)** — Squid was caching a stale/dead IP for busy hosts (google/youtube) for hours,
    presenting as "can't reach ANY site"; now it re-resolves every minute and self-heals.
    `squid -k reconfigure` flushes immediately.
- **Approved-content page** `/opt/parental/approved.html` (curated STEM channels, grouped),
  delivered by `regenerate.sh` as a **managed (non-removable) bookmark + Home button**
  (`ManagedBookmarks`, `BookmarkBarEnabled`, `HomepageLocation`) and allowlisted so it works in
  locked mode too. Hand-maintained — edit the HTML when you change the channel list.
- **Google account caveat (important).** The allowlist only works while Chrome is **signed out**
  or into a **non-supervised** account. A Family Link **supervised** account forces YouTube to
  `families.youtube.com`, which ignores our allowlist. Reset the child's profile to sign out; add
  `"BrowserSignin": 0` to the policy to prevent re-sign-in. (GUI-less over SSH: launch Chrome as
  the child with env copied from a running chrome's `/proc/<pid>/environ` +
  `--ozone-platform=wayland --password-store=basic --no-first-run`.)

## Round 4 — self-monitoring + Telegram alerts (2026-07-08)

New: `scripts/06-monitoring.sh`, `bin/health-check` (Python), `bin/notify-telegram`.
A systemd timer (`parental-healthcheck.timer`, every `HEALTHCHECK_INTERVAL`, `Persistent=true`
so it catches up after suspend) runs `health-check`, which evaluates ~11 checks and alerts the
parent's Telegram when any fails `ALERT_THRESHOLD` consecutive cycles (default 3 ≈ 15 min), with
a recovery message and a re-alert every `ALERT_REPEAT_HOURS`. Per-check consecutive-fail state is
in `/var/lib/parental/health-state.json`; a local trail is `/var/log/parental/health.log`.

Checks: dnsmasq/squid active + squid config parses; **web reachable through the proxy** (directly
catches the "503 storm / can't reach any site" failure we hit); DNS resolves; YouTube still forced
to Restricted Mode; youtube-nocookie still sinkholed; disk <90%; parental logs present +
append-only; parental.json valid; monitoring extension installed.

Egress: alerts go **through Squid** (the box's only outbound path) — `03-network.sh` resolves
`api.telegram.org` in both modes (`server=/api.telegram.org/8.8.8.8`) and adds a scoped Squid
`http_access allow` for it. Secret creds are in **root-only** `/etc/parental/telegram.env` (0600)
— deliberately NOT in the world-readable `config/settings.env`, so the child can't read the token.
The child has no shell to invoke any of this anyway.

Gotcha: the laptop suspends when idle (drops Wi-Fi), so alerts only fire while it's awake — fine,
since problems only occur while the child is using it, but it means no dead-man's-switch from the
device itself. `ALERT_DAILY_OK=1` sends a daily "all healthy" heartbeat when awake if you want a
liveness signal.

## Round 5 — audio fixed (2026-07-20)

Sound was fully dead post-conversion ("no soundcards found"). Three stacked causes on this
RPL Chromebook (fix applied live over SSH; nothing in the install scripts yet):

1. **Missing RPL topology name.** The SOF driver wants `intel/sof-tplg/sof-rpl-rt1019-rt5682.tplg`;
   `firmware-sof-signed` ships it only under the ADL name (same file). Fixed with a symlink —
   and then replaced the ADL file itself with the downstream blob from
   `WeirdTreeThing/chromebook-linux-audio` (`blobs/adl/…`), since the upstream one is broken
   (DMIC PCM errors). Original saved at `/root/sof-adl-rt1019-rt5682.tplg.orig`.
2. **No UCM profile for the `sof-rt5682` card.** Stock `alsa-ucm-conf` has none, so PipeWire
   only offered a Dummy Output. Overlaid the `standalone` branch of
   `WeirdTreeThing/alsa-ucm-conf-cros` onto `/usr/share/alsa/ucm2/` (117 files: `conf.d/sof-rt5682`,
   `platforms/intel-sof`, codecs). Pre-overlay backup: `/root/ucm2-backup-2026-07-20.tar.gz`.
3. **`Google_Brox` not recognized.** The overlay's `platforms/intel-sof/platform.conf` matches
   ADL boards by `product_family` regex `^Google_(Brya|Brask|Nissa|Trulo)$` — this board reports
   `Google_Brox` (RPL refresh; same PCM layout: spk 0, headset 1, HDMI 2345, dmic 99). Patched the
   regex in place to add `|Brox` (worth an upstream PR).

Also installed the script's WirePlumber headroom conf →
`/etc/wireplumber/wireplumber.conf.d/51-increase-headroom.conf` (stability).

Result: Speaker / Headphones / 4×HDMI sinks + headset mic + internal DMIC (Mic1/Mic2 splits)
all up; `pw-play` test clean, no kernel errors on playback. The codec is an **RT5682S** — a live
`modprobe -r/modprobe` of the SOF stack fails with a clk `-EEXIST` leftover; use a full reboot
when touching the audio modules. One-time `STREAM_PCM_PARAMS` probe errors at session start are
benign. Caveat: a future `firmware-sof-signed` or `alsa-ucm-conf` package upgrade can clobber the
replaced tplg / overlay files — if sound dies after an upgrade, redo the overlay (backups above).

## Round 6 — YouTube verdicts by owner identity, ext v1.2.0 (2026-07-20)

**Problem:** videos from APPROVED channels were blocked when opened from the channel page
("video's channel not allowed"). Root cause: the extension verified a watch page by scraping
the owner link out of the page DOM; during YouTube's SPA navigation the owner `<a>` exists
with an EMPTY href before data loads, and the old code treated that as a definitive mismatch.
Two latent bugs on top: channels stored only as UC-id could never match (owner links render
as /@handle), and embeds honored only explicit video ids — so approved-channel videos failed
on allowlisted external sites too.

**New architecture (extension v1.2.0):** the background service worker is the single verdict
authority — `isVideoAllowed(videoId)`. It resolves the video's OWNER via YouTube's public
oEmbed endpoint (`youtube.com/oembed`, no API key; works through Squid + the Restricted-Mode
CNAME), compares against the allowlist, and caches video→owner identities (immutable) in
storage.local — verdicts recompute against the live allowlist so `allow-youtube` edits apply
instantly. Watch pages and /embed|/v|/e frames use the SAME verdict: approved-channel videos
play anywhere, others nowhere. The DOM owner-check survives only as fallback when oEmbed is
unreachable (fixed: empty href = "not loaded yet", never a mismatch; fail-closed otherwise).
youtube-nocookie stays sinkholed — Google's fenced-frame inline preview is unverifiable, so
it stays dead by design (click through to YouTube instead).

**Channel pairing:** allowlist channels are now stored in BOTH forms (UC id + @handle).
New helper `bin/yt-resolve <@handle|UCid>` parses `"externalId"` + `"vanityChannelUrl"` from
the channel page; `allow-youtube` auto-adds the paired form on every channel/handle add.
The live list was migrated (39 channels → 43 paired entries, 0 failures).

**Deployment gotchas learned (IMPORTANT for future extension updates):**
- After swapping extension files + repacking, Chrome may keep executing the OLD service
  worker from its **Service Worker script cache** even after a full Chrome restart and a
  correct new `Extensions/<id>/<ver>/` on disk. Symptom here: content scripts got
  "message port closed" (surfaced as "no background"), because the cached old worker had no
  `ytVerdict` handler; meanwhile visits still logged fine. Fix: with Chrome killed,
  `rm -rf "~child/.config/google-chrome/Default/Service Worker"` then relaunch.
- Force-install after the prefs-clean procedure is NOT immediate: the external-update check
  runs on a delayed timer (~5 min), and **every Chrome relaunch resets it** — impatient
  restart loops keep it from ever firing. Launch once (optionally with
  `--extensions-update-frequency=30`) and leave it alone; verify via Preferences
  (`extensions.settings.<id>.manifest.version`), NOT `ls` of the Extensions dir (admin can't
  read /home/<child> — a `2>/dev/null` there reads as "not installed").
- `echo pw | sudo -S cmd <<HEREDOC` breaks — the heredoc becomes sudo's stdin (password
  prompts eat the script). Prime the timestamp first (`echo pw | sudo -S true`), then run
  plain `sudo` commands.

**Verified test matrix (from child session, via logs):** Veritasium (allowed channel) watch
page ✓ plays, opened-from-channel ✓, /embed ✓ plays; MrBeast watch ✗ "video's channel not
allowed (@MrBeast)", /embed ✗ "embedded video not allowed (@MrBeast)"; allowed channel page
opens; home/search still blocked. Verdict identities cache (instant repeat answers).

## Reuse on another laptop — checklist

1. Untar the kit; `cd alayet`.
2. **Edit `config/settings.env`**: `CHILD_USER`, `CHILD_FULLNAME`, `PARENT_USER`
   (must be an existing admin/sudo account), `YOUTUBE_RESTRICT`. Leave `REMOTE_SYSLOG` empty
   unless shipping logs off-device.
3. Do the **firmware lockdown** appropriate to the device (see table above). At minimum set a
   GRUB password; strongly consider LUKS.
4. `sudo ./install.sh`.
5. **Before rebooting**, from another machine: `ssh <PARENT_USER>@<laptop-ip>` — confirm it works.
6. Reboot → autologin as the child. Run the child-session checks in PLAN §9 +
   README "Status" (extension loaded, logs growing, only allowlisted sites, YouTube restricted).
7. **Make sure the child's Chrome is signed OUT** (or into a **non-supervised** Google account) —
   a supervised account forces `families.youtube.com` and defeats the allowlist.
8. YouTube channels: the kit ships a curated STEM list in `config/youtube-allow.txt` (also shown on
   the `approved.html` start page). Add/remove with `sudo allow-youtube channel|handle|video <id>`,
   then restart the child's Chrome to apply. Edit `approved.html` to match if you change the list.
9. After a few days as the child: `sudo fapolicyd-review` → `fapolicyd-allow` → `fapolicyd-enforce`.
