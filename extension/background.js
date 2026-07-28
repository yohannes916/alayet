// Service worker: central logging hub + URL recorder.
// All log lines are forwarded to a root-owned native messaging host
// (com.parental.logger) which appends them to /var/log/parental/activity.log.
// Native messaging is used (not network) so it isn't subject to URLBlocklist
// and the child cannot intercept or read the destination.

const NATIVE_HOST = "com.parental.logger";

// Persistent connection to the native logger; reconnect on drop.
let port = null;
function connect() {
  try {
    port = chrome.runtime.connectNative(NATIVE_HOST);
    port.onDisconnect.addListener(() => { port = null; });
  } catch (e) {
    port = null;
  }
}
function send(entry) {
  entry.ts = new Date().toISOString();
  if (!port) connect();
  try {
    port && port.postMessage(entry);
  } catch (e) {
    // Best effort; queue to storage so nothing is silently lost.
    chrome.storage.local.get({ pending: [] }, (d) => {
      d.pending.push(entry);
      chrome.storage.local.set({ pending: d.pending.slice(-500) });
    });
  }
}

// Flush any queued entries when the worker wakes.
chrome.storage.local.get({ pending: [] }, (d) => {
  if (d.pending.length) {
    if (!port) connect();
    d.pending.forEach((e) => { try { port && port.postMessage(e); } catch (_) {} });
    chrome.storage.local.set({ pending: [] });
  }
});

// --- Record every committed navigation (top frame) -----------------------
chrome.webNavigation.onCommitted.addListener((details) => {
  if (details.frameId !== 0) return;
  send({ type: "visit", url: details.url, transition: details.transitionType });
});

// --- Record navigations blocked by URLBlocklist policy --------------------
// Chromium aborts blocked navigations; capture the intended URL so the parent
// can see it in `review-denied` with full path detail.
chrome.webNavigation.onErrorOccurred.addListener((details) => {
  if (details.frameId !== 0) return;
  if (/BLOCKED_BY_ADMINISTRATOR|ERR_BLOCKED_BY_ADMINISTRATOR/.test(details.error || "")) {
    send({ type: "blocked", url: details.url });
  }
});

// ======================= YouTube verdict authority =========================
// Content scripts ask "may video ID play?" and the answer is computed HERE,
// identically for watch pages and embeds, from two ingredients:
//   1. the managed allowlist (channels / handles / explicit video ids), and
//   2. the video's OWNER identity, resolved via YouTube's public oEmbed
//      endpoint (no API key; youtube.com is already network-allowlisted, and
//      the endpoint works through the forced Restricted-Mode CNAME).
// A video's owner is immutable, so identities are cached in storage.local;
// the allow/deny verdict is recomputed against the CURRENT allowlist on every
// ask, so allowlist edits apply instantly with no cache invalidation.
// This replaces the old DOM-scrape of the watch page's owner link, which was
// racy (empty href during SPA navigation => false "channel not allowed").

importScripts("config.js"); // baked-in fail-safe (empty => block everything)

let ytLists = null; // {channels:Set, videos:Set, handles:Set(lowercased)}
function listsFrom(cfg) {
  return {
    channels: new Set(cfg.youtubeChannels || []),
    videos: new Set(cfg.youtubeVideos || []),
    handles: new Set((cfg.youtubeHandles || []).map((h) => String(h).toLowerCase())),
  };
}
function loadLists() {
  return new Promise((resolve) => {
    try {
      chrome.storage.managed.get(
        ["youtubeChannels", "youtubeVideos", "youtubeHandles"],
        (items) => {
          const managed =
            !chrome.runtime.lastError && items &&
            (Array.isArray(items.youtubeChannels) ||
             Array.isArray(items.youtubeVideos) ||
             Array.isArray(items.youtubeHandles));
          ytLists = listsFrom(managed ? items : (globalThis.PARENTAL_CONFIG || {}));
          resolve(ytLists);
        }
      );
    } catch (_) {
      ytLists = listsFrom(globalThis.PARENTAL_CONFIG || {});
      resolve(ytLists);
    }
  });
}
chrome.storage.onChanged.addListener((_c, area) => { if (area === "managed") loadLists(); });
function getLists() { return ytLists ? Promise.resolve(ytLists) : loadLists(); }

// --- video -> owner identity cache (identity never changes) ----------------
const OWNER_KEY = "ytOwnerCache";
const OWNER_MAX = 3000;
let ownerMem = null, ownerLoading = null, ownerSaveTimer = null;
function loadOwners() {
  if (ownerMem) return Promise.resolve(ownerMem);
  if (!ownerLoading) {
    ownerLoading = new Promise((resolve) => {
      try {
        chrome.storage.local.get({ [OWNER_KEY]: {} }, (d) => {
          ownerMem = (d && d[OWNER_KEY]) || {};
          resolve(ownerMem);
        });
      } catch (_) { ownerMem = {}; resolve(ownerMem); }
    });
  }
  return ownerLoading;
}
function saveOwners() {
  clearTimeout(ownerSaveTimer);
  ownerSaveTimer = setTimeout(() => {
    try {
      const keys = Object.keys(ownerMem);
      if (keys.length > OWNER_MAX) {
        keys.sort((a, b) => (ownerMem[a].t || 0) - (ownerMem[b].t || 0));
        keys.slice(0, keys.length - OWNER_MAX).forEach((k) => delete ownerMem[k]);
      }
      chrome.storage.local.set({ [OWNER_KEY]: ownerMem });
    } catch (_) {}
  }, 1000);
}

const ownerInflight = new Map(); // videoId -> Promise
function ownerOf(videoId) {
  if (ownerInflight.has(videoId)) return ownerInflight.get(videoId);
  const p = (async () => {
    const cache = await loadOwners();
    if (cache[videoId]) return cache[videoId];
    const url = "https://www.youtube.com/oembed?url=" +
      encodeURIComponent("https://www.youtube.com/watch?v=" + videoId) + "&format=json";
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 6000);
    try {
      const resp = await fetch(url, { signal: ctl.signal, credentials: "omit" });
      if (!resp.ok) {
        send({ type: "blocked", url: "debug://oembed/" + videoId, reason: "oembed http " + resp.status });
        return null; // private/removed/unknown -> unverifiable
      }
      const data = await resp.json();
      const au = String(data.author_url || "");
      const c = (au.match(/\/channel\/(UC[\w-]+)/) || [])[1] || null;
      const h = (au.match(/\/(@[\w.\-]+)/) || [])[1] || null;
      if (!c && !h) return null;
      const owner = { c, h, t: Date.now() };
      cache[videoId] = owner;
      saveOwners();
      return owner;
    } catch (e) {
      send({ type: "blocked", url: "debug://oembed/" + videoId, reason: "oembed fetch failed: " + (e && (e.name + " " + e.message)) });
      return null; // network failure -> unverifiable (caller fails closed)
    } finally {
      clearTimeout(t);
      ownerInflight.delete(videoId);
    }
  })();
  ownerInflight.set(videoId, p);
  return p;
}

async function ytVerdict(videoId) {
  if (!/^[\w-]{6,}$/.test(videoId || "")) {
    return { allowed: false, verified: true, why: "invalid video id" };
  }
  const L = await getLists();
  if (L.videos.has(videoId)) return { allowed: true, verified: true, why: "video allowed" };
  const owner = await ownerOf(videoId);
  if (!owner) return { allowed: false, verified: false, why: "owner unresolved" };
  const allowed =
    (owner.c && L.channels.has(owner.c)) ||
    (owner.h && L.handles.has(owner.h.toLowerCase()));
  return { allowed: !!allowed, verified: true, why: owner.h || owner.c };
}

// --- Messages from content scripts (prompts, youtube blocks, verdicts) -----
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || !msg.type) return;
  const base = { tabUrl: sender?.tab?.url };
  if (msg.type === "prompt") {
    send({ type: "prompt", service: msg.service, text: msg.text, ...base });
  } else if (msg.type === "blocked") {
    send({ type: "blocked", url: msg.url, reason: msg.reason, ...base });
  } else if (msg.type === "ytVerdict") {
    ytVerdict(msg.id)
      .then(sendResponse)
      .catch(() => sendResponse({ allowed: false, verified: false, why: "verdict error" }));
    return true; // async response
  }
});

connect();
