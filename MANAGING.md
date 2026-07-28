# Managing the alayet child laptop

## Connect
- `ssh yohannes@192.168.86.222`  (admin account; helper commands need `sudo`)
- Laptop sleeps when idle (5 min on battery / 15 min on AC) and drops off Wi-Fi —
  if SSH says "no route to host", someone needs to wake it (open lid / press key).
- IP is DHCP; if it changes, find it on your router or try `alayet-laptop.local`.

## See what the child did
- Google searches (incl. AI Mode):  `sudo cat /var/log/parental/searches.log`
- Gemini prompts:                    `sudo cat /var/log/parental/prompts.log`
- Every page visited:               `sudo cat /var/log/parental/activity.log`
- Blocked attempts:                 `sudo cat /var/log/parental/blocked.log`
- Pretty-print any of them:
    `sudo jq -r '"\(.ts)  \(.query // .text // .url)"' /var/log/parental/searches.log`
- Live tail while they browse:       `sudo tail -f /var/log/parental/activity.log`
- Wipe all logs to a clean slate:    `sudo clear-logs`   (add `-y` to skip the prompt)
  Clears activity/searches/prompts/blocked + the Squid access log, then restores
  their append-only protection. DESTRUCTIVE + irreversible; logging keeps running.
  Handy right before `sudo open-web` so the observation period starts fresh.

## Open browsing mode — allow ALL sites for a while (applies live, no reboot)
Use this to observe what's actually used before curating the whitelist. Logging
and YouTube restriction stay fully ON the whole time.
- Allow everything:   `sudo open-web`
- See what's used:     `sudo top-sites`        (most-visited domains, from Squid)
                       `sudo cat /var/log/parental/activity.log`
- Re-lock to list:    `sudo close-web`
- Check current mode: `sudo list-sites`        (prints OPEN or LOCKED at the top)
- Workflow: `sudo open-web` → let the child use it a few days → `sudo top-sites`
  → `sudo allow-site <each domain you want>` → `sudo close-web`.
- YouTube stays restricted in open mode: browser YouTube is still forced into
  Restricted Mode and limited to the allowed channels/videos by the extension.

## Expand / change the website whitelist  (applies live, no reboot)
- See what got blocked (your "what to allow next" feed):  `sudo review-denied`
- Allow a site:    `sudo allow-site example.com`
- Remove a site:   `sudo deny-site example.com`
- List allowed:    `sudo list-sites`
- Tip: allow a site, have the child load it once, then `sudo review-denied` to catch
  any extra domains it needs, and allow those too.

## YouTube allowlist (channel / video level)
YouTube is always forced into Restricted Mode (network layer). On top of that, the
browser extension blocks EVERYTHING except the channels/videos you approve — home,
search, Shorts, trending, and non-approved videos all show a "not on your allowed
list" page. Recommendations, comments, and autoplay are stripped on allowed pages.
**When the allowlist is empty, ALL of YouTube is blocked** (that's the default).

How a video is judged (since ext v1.2.0): the extension looks up the video's OWNER
channel from YouTube metadata and allows it if that channel is on your list — so an
approved channel's videos play *everywhere*: opened from the channel page, direct
watch links, and even embedded players on other allowed websites. Non-approved
videos are blocked in all those same places. If the owner can't be verified
(network hiccup), the video is blocked rather than allowed (fail-closed).
The one exception: **Google Search's inline video preview** stays blocked for ALL
videos (its player frame can't be verified — blocked via `youtube-nocookie.com`);
clicking through to YouTube works for approved videos.

- Allow a whole channel:  `sudo allow-youtube channel UCxxxxxxxx`   (best — all its videos)
- Allow by @handle:       `sudo allow-youtube handle @SomeChannel`  (same, easier to find)
- Allow one video:        `sudo allow-youtube video VIDEOID`        (just that video)
- See/remove entries:     edit `/etc/parental/youtube-allow.txt` then `sudo /opt/parental/scripts/regenerate.sh`
- Note: adding a channel by either form auto-adds the other (UC id ↔ @handle are
  resolved from the channel page via `yt-resolve`) — matching needs both. When
  REMOVING a channel, delete BOTH its `channel:` and `handle:` lines.

**Finding a channel ID/handle:** open the channel in a browser. The URL shows either
`/@handle` (use that) or `/channel/UC…` (use the UC… id). Or view-source and search
for `"channelId"`.

**Applying a change:** the allowlist is delivered to the browser as a Chrome managed
policy (no extension rebuild needed). The child's Chrome picks it up when it reloads
its policy — the reliable way is to **restart the child's Chrome** (close & reopen, or
`sudo reboot`). It also refreshes on its own after a while.

### Approved-content start page
A friendly page listing every approved channel (grouped by subject, with links) lives at
`/opt/parental/approved.html`. It's wired in as:
- a **managed bookmark** "Approved Channels" (in an "Approved" folder on the bookmark bar) — the child can't delete it, and
- the **home button** (and homepage) — clicking Home goes to it.
It stays reachable even in locked mode (it's allowlisted).
**This page is hand-maintained** — it does NOT auto-update from the allowlist. If you add
or remove channels with `allow-youtube`, also edit `/opt/parental/approved.html` (and the
kit copy `~/alayet/approved.html`) to match, then it's served as-is (no regenerate needed
for the HTML itself; a Chrome restart shows bookmark/policy changes).

### Blocking Google sign-in (recommended)
The allowlist only works while Chrome is signed OUT or into a NON-supervised account. If a
**supervised (Family Link) account** signs in, YouTube forces `families.youtube.com` and the
allowlist stops working. To prevent the child from attaching any account, add
`"BrowserSignin": 0` to the Chrome policy (ask to have it enabled). To later sign in an
unsupervised account, remove that line and regenerate.

### IMPORTANT: the child's Chrome must be signed OUT (or use an UNsupervised account)
If Chrome is signed into a **Google Family Link *supervised* account**, YouTube forces
its own supervised experience (`families.youtube.com`) that IGNORES this allowlist and
only obeys Google's Family Link settings. The laptop is currently **signed out** so our
allowlist works. If you sign an account in, first make sure it is **not supervised**
(Family Link → Stop supervision, or use a normal adult/teen account) — otherwise the
allowlist silently stops working.

## Health monitoring & Telegram alerts
The laptop monitors itself every 5 minutes and messages you on Telegram when
something breaks (and again when it recovers) — so you don't have to check it.
- **Check status now:** `sudo health-check --status` (prints every check OK/FAIL).
- **Send a test alert:** `sudo health-check --test`.
- **Send yourself any message:** `sudo notify-telegram "hello"`.
- **Local log of checks:** `sudo cat /var/log/parental/health.log`.

**One-time setup** (fill in the bot token + chat id):
1. In Telegram, message **@BotFather** → `/newbot` → copy the **token**.
2. Message your new bot once (say "hi"), then open
   `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser → copy `chat.id`.
3. `sudo nano /etc/parental/telegram.env` and set:
   ```
   TELEGRAM_BOT_TOKEN=123456789:ABC...
   TELEGRAM_CHAT_ID=123456789
   ```
4. `sudo health-check --test` — you should get a Telegram message.

**What it watches:** dnsmasq & Squid running + valid config; the web actually
loads through the proxy (catches the "can't reach any site" / 503 problem);
DNS resolves; YouTube is still forced to Restricted Mode; youtube-nocookie stays
blocked; disk not full; the parental logs are intact & append-only; the Chrome
policy is valid; the monitoring extension is installed. It alerts after
**3 consecutive failures (~15 min)** and re-alerts every 6h while unresolved.
Tunables live in `config/settings.env` (`ALERT_THRESHOLD`, `ALERT_REPEAT_HOURS`,
`HEALTHCHECK_INTERVAL`, `ALERT_DAILY_OK`).
Note: alerts only fire while the laptop is awake — it can't message you while
suspended (there's nothing to go wrong while it's asleep).

## Notes
- fapolicyd is intentionally DISABLED (was useless on 26.04); the lockdown relies on
  the browser/DNS/firewall whitelist + no-terminal + hidden launchers.
- **IPv6 is filtered off at the DNS layer** (`filter-AAAA` in dnsmasq). This network has
  no working IPv6; without this, dual-stack sites like YouTube intermittently fail to
  load through Squid. Leave it in place unless the network gains real IPv6.
- To change power/lock/app settings, edit the dconf files under
  /etc/dconf/db/local.d/ then run `sudo dconf update`.
- Reboot if needed: `sudo reboot` (it autologs back into the child session).
