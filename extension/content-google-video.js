// Kill Google Search's inline video preview player.
//
// When a video result is clicked, Google plays it inline in an isolated/embedded
// frame (fenced frame or youtube-nocookie player) that streams from
// youtube/googlevideo and BYPASSES the youtube.com channel allowlist — our
// content script cannot run inside that frame. But the frame's HOST element
// lives in Google's own page DOM, which this script (running on www.google.com)
// CAN edit. So we continuously remove the player surfaces as they appear.
// This is the belt-and-suspenders layer alongside the network block of
// youtube-nocookie.com. Runs on www.google.com in all frames.
(function () {
  const YT = /(youtube(-nocookie)?\.com\/(embed|v|e|watch)|googlevideo\.com|\/videoplayback)/i;
  let reported = false;

  function report() {
    if (reported) return;
    reported = true;
    try { chrome.runtime.sendMessage({ type: "blocked", url: location.href, reason: "google inline video removed" }); } catch (_) {}
  }

  function nuke() {
    try {
      let hit = false;
      document.querySelectorAll("video").forEach((v) => {
        try { v.pause(); v.removeAttribute("src"); v.load && v.load(); v.remove(); hit = true; } catch (_) {}
      });
      document.querySelectorAll("fencedframe").forEach((f) => {
        try { f.remove(); hit = true; } catch (_) {}
      });
      document.querySelectorAll("iframe").forEach((f) => {
        const s = (f.src || f.getAttribute("src") || "");
        if (YT.test(s)) { try { f.remove(); hit = true; } catch (_) {} }
      });
      if (hit) report();
    } catch (_) {}
  }

  function start() {
    nuke();
    try { new MutationObserver(() => nuke()).observe(document.documentElement, { childList: true, subtree: true }); } catch (_) {}
  }
  if (document.documentElement) start();
  document.addEventListener("DOMContentLoaded", start, true);
})();
