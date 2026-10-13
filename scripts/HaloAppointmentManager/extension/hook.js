/* Halo owns the login session. This bridge caches its Authorization header in page memory only. */
(function () {
  "use strict";
  if (window.__isoHaloBulkHook) return;
  window.__isoHaloBulkHook = true;
  let last = "", enabled = true, recipient = "";
  function sameApi(value) {
    try { const u = new URL(value, location.href); return u.origin === location.origin && u.pathname.toLowerCase().startsWith("/api/"); }
    catch (_) { return false; }
  }
  function relay(value) {
    if (!enabled || typeof value !== "string" || !/^Bearer\s+\S+$/i.test(value)) return;
    last = value;
    if (recipient) window.postMessage({ isoHaloBulk: "auth", recipient: recipient, value: value }, location.origin);
  }
  function header(headers) {
    try { return new Headers(headers || {}).get("Authorization") || ""; } catch (_) { return ""; }
  }
  const originalFetch = window.fetch;
  window.fetch = function (input, init) {
    try {
      const url = input instanceof URL ? input.href : typeof input === "string" ? input : input && input.url;
      if (sameApi(url)) relay(header(init && init.headers) || (input instanceof Request ? header(input.headers) : ""));
    } catch (_) {}
    return originalFetch.apply(this, arguments);
  };
  const open = XMLHttpRequest.prototype.open, set = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.open = function (method, url) { this.__isoHaloApi = sameApi(url); return open.apply(this, arguments); };
  XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
    if (this.__isoHaloApi && String(name).toLowerCase() === "authorization") relay(value);
    return set.apply(this, arguments);
  };
  window.addEventListener("message", function (e) {
    if (e.source !== window || e.origin !== location.origin || !e.data) return;
    if (e.data.isoHaloBulk === "requestAuth" && typeof e.data.recipient === "string") {
      enabled = true; recipient = e.data.recipient;
      if (last) relay(last);
    } else if (e.data.isoHaloBulk === "clearAuth" && (!recipient || e.data.recipient === recipient)) {
      last = ""; recipient = ""; enabled = false;
    }
  });
  window.addEventListener("pagehide", function () { last = ""; recipient = ""; enabled = false; });
})();
