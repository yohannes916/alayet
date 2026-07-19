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

// --- Messages from content scripts (prompts, youtube blocks) --------------
chrome.runtime.onMessage.addListener((msg, sender) => {
  if (!msg || !msg.type) return;
  const base = { tabUrl: sender?.tab?.url };
  if (msg.type === "prompt") {
    send({ type: "prompt", service: msg.service, text: msg.text, ...base });
  } else if (msg.type === "blocked") {
    send({ type: "blocked", url: msg.url, reason: msg.reason, ...base });
  }
});

connect();
