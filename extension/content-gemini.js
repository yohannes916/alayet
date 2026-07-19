// Capture prompts submitted to Gemini and forward them to the logger.
// Gemini's composer is a contenteditable rich-text box; submission happens on
// Enter (without Shift) or by clicking the send button. We read the text at
// submit time. Selectors are best-effort and may need updating if Gemini's
// markup changes — that's the documented maintenance point.

(function () {
  const SEND_DEBOUNCE_MS = 300;
  let lastSent = 0;

  function getComposer() {
    // Gemini uses a rich-textarea contenteditable. Try a few stable-ish hooks.
    return (
      document.querySelector('div.ql-editor[contenteditable="true"]') ||
      document.querySelector('rich-textarea [contenteditable="true"]') ||
      document.querySelector('[contenteditable="true"][role="textbox"]')
    );
  }

  function readText(el) {
    if (!el) return "";
    return (el.innerText || el.textContent || "").trim();
  }

  function report(text) {
    if (!text) return;
    const now = Date.now();
    if (now - lastSent < SEND_DEBOUNCE_MS) return;
    lastSent = now;
    try {
      chrome.runtime.sendMessage({ type: "prompt", service: "gemini", text });
    } catch (_) {}
  }

  // Capture on Enter in the composer.
  document.addEventListener(
    "keydown",
    (e) => {
      if (e.key !== "Enter" || e.shiftKey) return;
      const el = getComposer();
      if (el && (e.target === el || el.contains(e.target))) {
        report(readText(el));
      }
    },
    true
  );

  // Capture on click of the send button.
  document.addEventListener(
    "click",
    (e) => {
      const btn = e.target.closest(
        'button[aria-label*="Send" i], button[aria-label*="Submit" i], [data-test-id="send-button"]'
      );
      if (btn) report(readText(getComposer()));
    },
    true
  );
})();
