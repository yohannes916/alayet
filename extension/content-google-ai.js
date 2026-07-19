// Capture follow-up questions typed into Google's in-page AI (AI Mode / AI
// Overviews). The INITIAL query is in the URL and is logged as a search by the
// native host; but follow-ups in the AI window happen in-page with NO navigation,
// so we capture them here and forward them as prompts (service "google-ai").
//
// Best-effort + resilient: rather than depend on Google's churning class names, we
// hook Enter / send-button on any editable field that ISN'T the main search box,
// and skip text that equals the current URL's ?q= (already logged as a search).
// Selectors are the documented maintenance point — expect occasional tuning.
(function () {
  const DEBOUNCE_MS = 800;
  let last = { t: 0, text: "" };

  function readText(el) {
    if (!el) return "";
    if (el.value != null && el.tagName !== "DIV") return String(el.value).trim();
    return (el.innerText || el.textContent || "").trim();
  }

  function isMainSearchBox(el) {
    const name = (el.getAttribute && el.getAttribute("name")) || "";
    const al = ((el.getAttribute && el.getAttribute("aria-label")) || "").toLowerCase();
    const role = (el.getAttribute && el.getAttribute("role")) || "";
    return name === "q" || el.type === "search" || role === "combobox" ||
           al === "search" || al === "search by voice";
  }

  function currentQ() {
    try { return (new URLSearchParams(location.search).get("q") || "").trim(); }
    catch (_) { return ""; }
  }

  function report(text) {
    if (!text || text.length < 2) return;
    if (text === currentQ()) return;            // main search; already URL-logged
    const now = Date.now();
    if (text === last.text && now - last.t < DEBOUNCE_MS) return;
    last = { t: now, text };
    try {
      chrome.runtime.sendMessage({ type: "prompt", service: "google-ai", text });
    } catch (_) {}
  }

  function editableFrom(node) {
    let el = node;
    while (el && el.nodeType === 1) {
      const tag = el.tagName;
      if (tag === "TEXTAREA" || tag === "INPUT" || el.isContentEditable ||
          (el.getAttribute && el.getAttribute("role") === "textbox")) return el;
      el = el.parentElement;
    }
    return null;
  }

  // Submit via Enter (without Shift) inside the AI composer.
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" || e.shiftKey) return;
    const el = editableFrom(e.target);
    if (el && !isMainSearchBox(el)) report(readText(el));
  }, true);

  // Submit via a send/ask/submit button.
  document.addEventListener("click", (e) => {
    const btn = e.target.closest(
      'button[aria-label*="Send" i], button[aria-label*="Ask" i], button[aria-label*="Submit" i]'
    );
    if (!btn) return;
    const scope = btn.closest("form, search, div") || document;
    const el = scope.querySelector('textarea, [contenteditable="true"], [role="textbox"]');
    if (el && !isMainSearchBox(el)) report(readText(el));
  }, true);
})();
