# Locked-Down Child Laptop — Deployment Plan

Target OS: **Ubuntu 26.04 LTS ("Resolute Raccoon")** — GNOME 50, Wayland-only, supported to 2031.
Managed browser: **Google Chrome (`.deb`)** — see §11 for why not Chromium.
Goal: a laptop a child can use, where they **cannot install software**, can only reach **whitelisted sites**, where **all visited URLs and AI prompts are recorded**, and where **no password is typed at login**. Allowed AI/sites: **Google + Gemini only**, with **selective YouTube** (forced Restricted Mode + a channel allowlist).

---

## 1. Design principles

1. **Defense in depth** — every control has a backstop. The browser is the convenient layer; the firewall + proxy is the layer the child can't talk their way around; the firmware/boot lock is what keeps those binding.
2. **Single source of truth** — one allowlist file drives every layer (Chromium policy, Squid ACL, local DNS). A regenerate script keeps them from drifting.
3. **Tamper resistance** — all configs and logs are root-owned. The child account has no `sudo`, no terminal, and cannot boot other media.
4. **Disclosed monitoring** — the child should be told the laptop is monitored. Disclosed monitoring is both more effective and avoids the legal grey areas of covert interception.
5. **No HTTPS interception (no MITM root CA)** — prompts and content are captured *inside the browser* via a locked, force-installed extension (the browser is already the TLS endpoint). This avoids breaking pinned sites and avoids installing a root CA. The network layer only sees/logs **domains** (via SNI), which is enough for enforcement and a tamper-proof backstop.

---

## 2. Architecture overview

```
                       ┌─────────────────────────────────────────────┐
                       │  child account (standard, no sudo, autologin)│
                       └─────────────────────────────────────────────┘
                                          │
        ┌─────────────────────────────────┼──────────────────────────────────┐
        │                                  │                                   │
  ┌───────────┐                  ┌──────────────────┐                 ┌────────────────┐
  │ fapolicyd │  app allowlist   │ managed Chrome   │  only browser   │  GNOME dconf   │
  │ (exec)    │  → no new SW     │ (.deb) + locked  │  that can run   │  lockdown      │
  │           │                  │ extension        │                 │                │
  └───────────┘                  └──────────────────┘                 └────────────────┘
                                          │ (all egress forced here)
                                          ▼
                         ┌──────────────────────────────────┐
                         │ nftables egress firewall          │  drop everything except
                         │  → local DNS (dnsmasq) + Squid     │  proxy + resolver
                         └──────────────────────────────────┘
                              │                        │
                    ┌───────────────────┐    ┌────────────────────────┐
                    │ dnsmasq            │    │ Squid (transparent)    │
                    │  • domain allowlist│    │  • domain allowlist     │
                    │  • YouTube Restrict│    │  • access.log (URLs)    │
                    │    via CNAME       │    │  • TCP_DENIED record    │
                    └───────────────────┘    └────────────────────────┘

           ▼ under all of it ▼
   BIOS password • boot from USB/net disabled • Secure Boot • GRUB password
```

---

## 3. Components

### 3.1 Accounts (`scripts/01-accounts.sh`)
- `parent` — admin, has a password, used only for maintenance. `PARENT_USER` may be an
  **existing** login (e.g. your own account); the script just ensures it's in `sudo` and
  does not reset it. Maintenance is performed **over SSH** (the lockdown leaves no local
  shell — see §3.2 and DEPLOYMENT-NOTES.md).
- `child` — standard, **no sudo**, **GDM autologin** (no password typed). The password is
  *locked* (`passwd -l`), not emptied: emptying breaks unlock/PAM and would allow a
  no-password TTY/SSH login. Autologin gives the no-password UX while the account stays
  protected from `su`/`sudo`/SSH.

### 3.2 Software lockdown (`scripts/02-app-lockdown.sh`)
- **fapolicyd** application allowlisting — only approved binaries execute. Blocks AppImages, `pip --user`, downloaded scripts, USB executables, alternate browsers.
- **dconf** system-wide lockdown — remove GNOME Software, lock settings, **disable GNOME Terminal**, disable extension installation, disable adding online accounts.

### 3.3 Network enforcement (`scripts/03-network.sh`)
- **nftables** egress firewall: child traffic may only reach the local resolver (53) and the local Squid proxy; everything else dropped (incl. DoH endpoints, direct IPs, alternate DNS).
- **dnsmasq** local resolver: answers only for allowlisted domains; CNAMEs YouTube hosts to `restrictmoderate.youtube.com` to force Restricted Mode network-wide.
- **Squid** (transparent, no SSL-bump): enforces the domain allowlist at the network layer, logs every request domain to `access.log`, records `TCP_DENIED` for blocked attempts (the parent's "what did they try" feed).

### 3.4 Managed browser (`scripts/04-browser-policy.sh`)
- **Google Chrome `.deb`** (installed from Google's apt repo). Chrome is *unconfined*,
  so managed policies and native messaging work reliably — unlike the snap-confined
  Chromium that ships on 26.04 (see §11).
- Chrome policy in `/etc/opt/chrome/policies/managed/`:
  - `URLBlocklist: ["*"]` + `URLAllowlist: [...]`
  - `ExtensionInstallForcelist` (our extension, cannot be removed)
  - `DeveloperToolsDisabled`, developer mode off, incognito off, guest off
  - DNS-over-HTTPS disabled (`DnsOverHttpsMode: "off"`)

### 3.5 Monitoring extension (`extension/`)
- MV3 extension, force-installed and locked:
  - logs every navigated **URL** (timestamped) → ships to root-owned log,
  - captures **Gemini prompts** from the input field → ships to log,
  - enforces the **YouTube channel allowlist**, redirects disallowed videos,
  - strips YouTube recommendations / Shorts / autoplay / comments,
  - logs **blocked navigations** with full URL (path-level detail the proxy can't see).

### 3.6 Boot / firmware lock (manual checklist — `PLAN.md` §6)
Not scriptable from the OS; documented steps the parent performs in firmware.

---

## 4. Allowlist (single source of truth)

`config/allowlist.txt` — Google/Gemini only (pre-seeded):
```
gemini.google.com
accounts.google.com
www.google.com
google.com
*.gstatic.com
*.googleapis.com
youtube.com
*.youtube.com
*.googlevideo.com
youtubei.googleapis.com
```

`config/youtube-allow.txt` — selective YouTube (channel-level, recommended):
```
# channel: <channelId>   (all videos from that channel)
# video:   <videoId>     (one specific video)
```

`scripts/regenerate.sh` reads these and (re)writes:
- Chromium `URLAllowlist` policy JSON,
- Squid allowlist ACL (+ reload),
- dnsmasq allow zone + YouTube Restrict CNAMEs (+ reload).

---

## 5. Parent maintenance commands (`bin/`)
- `allow-site <domain>` — append to allowlist, regenerate all layers, reload. No reboot.
- `deny-site <domain>` — remove it.
- `list-sites` — show current allowlist.
- `allow-youtube channel|video <id>` — add to YouTube allowlist.
- `review-denied` — deduped list of domains/URLs the child tried and got blocked (from Squid `TCP_DENIED` + the extension's block log), with counts and timestamps. This is the loop for expanding the whitelist.

Workflow: child hits a wall → `review-denied` shows the URL → `allow-site`/`allow-youtube` adds it everywhere at once → reloads live.

---

## 6. Boot / firmware lockdown checklist (manual, do this first)
Without this, a child can boot a USB stick and bypass everything.
- [ ] Set a **BIOS/UEFI supervisor password**.
- [ ] **Disable boot from USB / external / network** in firmware.
- [ ] Enable **Secure Boot**.
- [ ] Set a **GRUB password** (`grub-mkpasswd-pbkdf2` → `/etc/grub.d/40_custom`) so recovery/edit is locked.
- [ ] (Optional) Full-disk encryption (LUKS) so the disk can't be read by removing it.

> **Chromebooks / third-party firmware (MrChromebox, coreboot):** recent MrChromebox/edk2
> builds **do** expose a UEFI **firmware/admin password** in the Setup menu — it was set on the
> reference hardware, and gates the Setup + boot-device menus (so USB/external boot is now
> effectively locked too). Secure Boot stays low-value. The **GRUB password** and **disk
> encryption (LUKS)** still do real work — GRUB locks kernel-cmdline edits, LUKS is the only
> at-rest protection if the disk is pulled. See **DEPLOYMENT-NOTES.md** for the device-specific
> checklist actually used on the reference hardware.

---

## 7. Logging & review
- Logs are **root-owned** and append-only where possible; the child cannot read or clear them.
- Sources: Squid `access.log` (domains, browser-independent), extension log (URLs + Gemini prompts + blocked navigations).
- **Recommended:** ship logs off-device (remote syslog or a small cloud bucket) so they survive local tampering. Reviewed from the `parent` account or remotely.
- The extension's prompt/URL log is the rich record; the Squid log is the tamper-proof backstop.

---

## 8. Known limitations (honest caveats)
- **Desktop AI apps / cert-pinned sites** would break under MITM, so we don't MITM — the child uses **web Gemini in the managed browser** only. Native ChatGPT/Claude apps are intentionally not available (out of scope: Google/Gemini only).
- **YouTube redesigns** can change the page structure the extension reads; the YouTube content-script is the part most likely to need occasional upkeep. Forced Restricted Mode underneath means mature content stays blocked even if the script momentarily breaks.
- **Determined technical teen** — the OS controls hold only because of the firmware/boot lock and off-device logs. Keep those in place.
- **Big sites pull many sub-domains** — `review-denied` is how you discover the extra hosts a service needs; allow the site, use it once, add whatever else shows up denied.

---

## 9. Deployment order
1. Firmware/boot lockdown (§6) — manual.
2. `sudo ./install.sh` runs, in order:
   `00-preflight` → `01-accounts` → `02-app-lockdown` → `03-network` → `04-browser-policy` → `05-install-extension` → `regenerate.sh`.
3. Reboot. Log in as `child` (autologin). Verify: no terminal, only Chrome runs, only allowlisted sites load, Gemini works, YouTube shows only allowed channels, logs are being written.
4. Hand over. Use `review-denied` + `allow-site` to tune the whitelist over the first days.

---

## 10. Repository layout
```
alayet/
  PLAN.md                  ← this file
  install.sh               ← orchestrator
  config/
    allowlist.txt          ← single source of truth (domains)
    youtube-allow.txt      ← selective YouTube list
    settings.env           ← usernames, paths, restrict-mode level
  scripts/
    00-preflight.sh
    01-accounts.sh
    02-app-lockdown.sh
    03-network.sh
    04-browser-policy.sh
    05-install-extension.sh
    regenerate.sh
    lib.sh                 ← shared helpers
  bin/
    allow-site  deny-site  list-sites  allow-youtube  review-denied
  extension/
    manifest.json  background.js  content-gemini.js  content-youtube.js
    blocked.html   config.js  logger-host.py
```

---

## 11. Ubuntu 26.04 notes (why Chrome, and what carries over)

**Why Google Chrome `.deb` instead of Chromium:** On 26.04 the `chromium-browser`
package is a transitional shim that installs a **strictly-confined snap**. Snap
confinement breaks **native messaging** (our extension's only path to the
root-owned logger) and changes/limits where **managed policies** are read. Chrome's
`.deb` is unconfined: enterprise policies live in `/etc/opt/chrome/policies/managed/`,
native-messaging hosts in `/etc/opt/chrome/native-messaging-hosts/`, both work as
designed. Chrome also honors the same policy keys we use (`URLBlocklist`/`URLAllowlist`,
`ExtensionInstallForcelist`, `ProxySettings`, `DeveloperToolsAvailability`,
`DnsOverHttpsMode`). Bonus: a dpkg-installed Chrome is auto-trusted by fapolicyd.

**What carries over unchanged from the 24.04 design:**
- **Wayland-only / GNOME 50** — autologin (GDM), dconf lockdown, and TTY masking all
  operate above the display server; no change.
- **sudo-rs** (Rust sudo is now default) — we use only standard `sudo`; no change.
- **`/tmp` is tmpfs** — the fapolicyd `deny exec dir=/tmp/` rule still applies.
- **dnsmasq + nftables + Squid + fapolicyd** — all still packaged and used as-is.

**Free bonus available on 26.04 (not required by this plan):** GNOME 50 ships native
parental controls (per-account **screen-time limits + bedtime schedules**). These can
be enabled from Settings on top of this stack. Their built-in web filtering is only a
"foundation" and is **not** a substitute for our domain whitelist + logging.

**Hardware:** 26.04 raised the **minimum RAM to 6 GB** (GNOME 50 + Wayland). The
target laptop's **8 GB is sufficient** for this single-browser workload. Recommended:
enable **zram** swap and trim startup apps for headroom.
```
