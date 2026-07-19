# Locked-down child laptop (Ubuntu 26.04)

A deployable set of scripts + a Chrome extension that turns an Ubuntu 26.04 LTS
laptop into a locked-down device for a child:

- **No new software** — non-sudo child account + `fapolicyd` app allowlisting + GNOME lockdown.
- **Whitelist-only web** — Google/Gemini only, enforced at the browser, DNS, and firewall layers.
- **Selective YouTube** — forced Restricted Mode + a channel/video allowlist (delivered live via Chrome managed storage, no rebuild); recommendations/Shorts/comments stripped; embedded & Google-Search inline players blocked; a managed "Approved Channels" start page. (Requires Chrome signed out / non-supervised — a Family Link supervised account forces `families.youtube.com` and defeats it.)
- **Everything recorded** — every visited URL, every Gemini prompt, and every blocked attempt, to root-owned append-only logs.
- **No password login** — GDM autologin for the child; a separate passworded admin account for maintenance.

See **[PLAN.md](PLAN.md)** for the full architecture, rationale, and honest caveats.

## Install

1. **Edit `config/settings.env`** for this deployment: `CHILD_USER` / `CHILD_FULLNAME`
   (the kid's account), `PARENT_USER` (an **existing** admin account that keeps sudo —
   on a one-laptop-one-admin setup this is just your own login), and
   `YOUTUBE_RESTRICT` (`moderate`/`strict`).
2. **Do the firmware/boot lockdown** (PLAN.md §6) — without it everything is bypassable
   via a USB boot. On a Chromebook running third-party firmware (MrChromebox/coreboot)
   see **DEPLOYMENT-NOTES.md** — recent builds **do** offer a UEFI firmware password (set it;
   it gates the Setup + boot menus), with the GRUB password + disk encryption as further layers.
3. From this repo on the target laptop:
   ```bash
   sudo ./install.sh
   ```
4. Reboot, log in as the child (autologin), and run the verification checklist (PLAN.md §9).

> **Admin access after lockdown:** the install removes terminals and masks the TTYs for
> every account, so the admin maintains the laptop **over SSH** (`ssh <PARENT_USER>@<ip>`,
> locked to the admin account). **Verify SSH works before rebooting** — once the TTYs are
> masked it's the only way in. See DEPLOYMENT-NOTES.md.

## Day-to-day (run as the admin account)

| Command | What it does |
|---|---|
| `sudo review-denied` | Show what the child tried to reach and was blocked — your "what to allow next" feed. |
| `sudo allow-site <domain>` | Add a domain to the whitelist and reload every layer live. |
| `sudo deny-site <domain>` | Remove a domain. |
| `sudo allow-youtube channel <id>` | Allow a YouTube channel (or `video <id>` / `handle <@h>`). |
| `sudo list-sites` | Show the current allowlists. |
| `sudo fapolicyd-review` | Show what app-allowlisting *would* block (while in permissive mode). |
| `sudo fapolicyd-allow <path>` | Trust a legitimate executable surfaced by the review. |
| `sudo fapolicyd-enforce` | Turn on app blocking once the review is clean (`--permissive` to revert). |
| `sudo maintenance-dns off` / `on` | Temporarily unlock DNS for admin work (apt, browsing), then re-lock. The child stays blocked regardless (firewall + proxy). |

Run these from an **SSH session as the admin** (`ssh <PARENT_USER>@<laptop-ip>`) — the child
session has no terminal.

Logs: `/var/log/parental/{activity,prompts,blocked,searches}.log` and Squid `access.log`.
(`searches.log` = Google Search queries incl. AI Mode; Gemini and Google-AI-window prompts land in `prompts.log`.)

## fapolicyd rollout (OPTIONAL — shipped DISABLED on 26.04)

> **Reference deployment ships fapolicyd disabled** (see DEPLOYMENT-NOTES "Round 2"):
> on Ubuntu 26.04 (fapolicyd 1.3.6) permissive mode logs *no* decisions, so the review below
> surfaces nothing, and the daemon is heavy (~4.6 GB). The other layers (no terminal, downloads
> blocked, launchers hidden, locked password) cover the exec vectors. Only pursue the rollout
> below if you specifically want app-execution allowlisting — tune via `fapolicyd --debug-deny`.

The rollout (only if you choose to enable it):

1. Install + reboot. Use the laptop as the child for a few days (run the real apps).
2. `sudo fapolicyd-review` — see what would have been blocked.
3. For each legitimate program in that list: `sudo fapolicyd-allow /path/to/it`.
4. When the review shows only things you *want* blocked: `sudo fapolicyd-enforce`.
5. If anything breaks afterward: `sudo fapolicyd-enforce --permissive` to revert instantly.

## Status / what still needs on-device testing

This build has been **deployed and back-end-verified on real hardware** (a Google
"Jubilant" Chromebook on Ubuntu 26.04 — see DEPLOYMENT-NOTES.md, which also lists the
fixes folded in since the first build). Verified working: accounts + autologin, dconf
lockdown, TTY masking, admin-only SSH, fapolicyd (permissive), the nftables firewall,
and dnsmasq + Squid enforcement (allowed domains resolve/proxy; blocked → `0.0.0.0`/denied).

Still requires a **child-session (post-reboot) runtime check** — these can't be confirmed
from a root shell:

- **Extension force-install** via self-hosted `file://` crx — confirm Chrome actually loads
  "Family Activity Monitor" and the child can't remove it (`chrome://extensions`).
- **Logging path** — confirm `/var/log/parental/{activity,prompts}.log` grow as the child browses.
- **dnsmasq YouTube Restricted-Mode CNAME** — confirm Restricted Mode is forced in the browser.
- **Gemini / YouTube content scripts** — selectors depend on current site markup and may need updates.
- **fapolicyd** — shipped **disabled** on 26.04 (permissive logs nothing there); enable + enforce only via the `--debug-deny` tuning in DEPLOYMENT-NOTES if you want it.
