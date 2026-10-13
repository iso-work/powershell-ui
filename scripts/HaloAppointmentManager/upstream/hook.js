/*
 * Runs in the page (MAIN world) at document_start.
 * Watches Halo's own API calls and relays the Authorization header
 * to the extension's content script so it can call the same API.
 * The token is never stored to disk; it lives only in page memory.
 */
(() => {
  if (window.__haloApptMgrHook) return;
  window.__haloApptMgrHook = true;

  let last = "";
  const relay = (value) => {
    if (!value || value === last) return;
    if (!/^bearer\s+/i.test(value)) return;
    last = value;
    window.postMessage({ __haloApptMgr: "auth", value }, location.origin);
  };

  const isApi = (url) => {
    try {
      const u = new URL(url, location.href);
      return u.origin === location.origin && u.pathname.toLowerCase().startsWith("/api/");
    } catch (_) {
      return false;
    }
  };

  const readHeader = (headers) => {
    if (!headers) return "";
    try {
      if (headers instanceof Headers) return headers.get("Authorization") || "";
      if (Array.isArray(headers)) {
        const h = headers.find(([k]) => String(k).toLowerCase() === "authorization");
        return h ? h[1] : "";
      }
      for (const k of Object.keys(headers)) if (k.toLowerCase() === "authorization") return headers[k];
    } catch (_) {}
    return "";
  };

  // fetch
  const origFetch = window.fetch;
  window.fetch = function (input, init) {
    try {
      const url = typeof input === "string" ? input : input && input.url;
      if (isApi(url)) {
        relay(readHeader(init && init.headers) || (input instanceof Request ? readHeader(input.headers) : ""));
      }
    } catch (_) {}
    return origFetch.apply(this, arguments);
  };

  // XMLHttpRequest
  const origOpen = XMLHttpRequest.prototype.open;
  const origSet = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__haloApi = isApi(url);
    return origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
    try {
      if (this.__haloApi && String(name).toLowerCase() === "authorization") relay(value);
    } catch (_) {}
    return origSet.apply(this, arguments);
  };

  // Content script can ask for the latest value (e.g. after it loads late)
  window.addEventListener("message", (e) => {
    if (e.source === window && e.data && e.data.__haloApptMgr === "requestAuth" && last) {
      window.postMessage({ __haloApptMgr: "auth", value: last }, location.origin);
    }
  });
})();
