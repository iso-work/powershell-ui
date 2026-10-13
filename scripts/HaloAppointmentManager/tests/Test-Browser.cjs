"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const C = require("../extension/core.js");
const source = name => fs.readFileSync(path.join(__dirname, "../extension", name), "utf8");
function classes() {
  const set = new Set();
  return { add: x => set.add(x), remove: x => set.delete(x), contains: x => set.has(x) };
}
function fixture() {
  const elements = new Map(), messages = [], requests = [], downloads = [], blobs = new Map();
  const el = key => {
    if (!elements.has(key)) elements.set(key, {
      value: "", checked: false, disabled: false, dataset: {}, style: {}, classList: classes(), textContent: "", innerHTML: "",
      appendChild() {}, remove() {}, querySelectorAll: () => [], click() { downloads.push({ filename: this.download, blob: blobs.get(this.href) }); }
    });
    return elements.get(key);
  };
  const root = { innerHTML: "", getElementById: el, querySelectorAll: () => [], appendChild() {} };
  const listeners = new Map(), intervals = [];
  const items = [{ id: 1, subject: '<img src=x onerror="steal()"> & ~~~~', agent_id: 7, start_date: "2026-01-01T10:00:00", end_date: "2026-01-01T11:00:00", complete_status: -1, _cancomplete: true, ticket_id: 42 }];
  const customURL = class extends URL {};
  customURL.createObjectURL = blob => { const key = "blob:fixture-" + blobs.size; blobs.set(key, blob); return key; };
  customURL.revokeObjectURL = () => {};
  let postGate = null;
  const context = {
    HaloBulkCore: C, crypto: crypto.webcrypto, URL: customURL, URLSearchParams, AbortController, Blob, Date, console,
    location: { origin: "https://halo.example", pathname: "/calendar", hash: "", href: "https://halo.example/calendar" },
    document: { documentElement: { appendChild() {} }, createElement(name) { const item = el("created-" + Math.random()); item.attachShadow = () => root; return item; } },
    addEventListener(name, fn) { if (!listeners.has(name)) listeners.set(name, []); listeners.get(name).push(fn); },
    postMessage(data) {
      messages.push(data);
      if (data.isoHaloBulk === "requestAuth") for (const fn of listeners.get("message") || []) fn({ source: context, origin: context.location.origin, data: { isoHaloBulk: "auth", recipient: data.recipient, value: "Bearer fixture-secret-token" } });
    },
    setTimeout() { return 1; }, clearTimeout() {}, setInterval(fn) { intervals.push(fn); return 1; },
    fetch: async (url, options) => {
      requests.push({ url, options: structuredClone(Object.assign({}, options, { signal: undefined })) });
      const parsed = new URL(url);
      let result;
      if (options.method === "POST") {
        if (postGate) await postGate;
        const payload = JSON.parse(options.body);
        items.find(a => a.id === payload[0].id).complete_status = 0;
        result = null;
      } else if (parsed.pathname === "/api/Agent/me") result = { id: 7 };
      else if (parsed.pathname === "/api/lookup") result = [{ id: 9, name: "Do Not Bill" }];
      else result = structuredClone(items);
      return { ok: true, status: 200, text: async () => JSON.stringify(result) };
    }
  };
  context.window = context; context.globalThis = context;
  // VM globals use a proxy for window identity. Message events must use that exact proxy.
  vm.createContext(context);
  const win = vm.runInContext("window", context);
  context.postMessage = data => {
    messages.push(data);
    if (data.isoHaloBulk === "requestAuth") for (const fn of listeners.get("message") || []) fn({ source: win, origin: context.location.origin, data: { isoHaloBulk: "auth", recipient: data.recipient, value: "Bearer fixture-secret-token" } });
  };
  vm.runInContext(source("content.js"), context);
  el("past").value = "30"; el("future").value = "30"; el("view").value = "past";
  return { context, el, root, items, messages, requests, downloads, listeners, intervals, setGate: p => { postGate = p; } };
}
test("UI reads only until exact preview authorization; output is escaped and credential-free", async () => {
  const f = fixture();
  f.el("open").onclick(); await f.el("refresh").onclick();
  assert.ok(f.requests.every(r => r.options.method === "GET"));
  assert.match(f.el("list").innerHTML, /&lt;img/);
  assert.ok(!f.el("list").innerHTML.includes('<img src=x'));
  const target = { dataset: { id: "1" }, checked: true, classList: { contains: x => x === "pick" } };
  f.el("list").onchange({ target });
  f.el("preview").onclick();
  assert.ok(f.el("review").classList.contains("open"));
  f.el("ack").checked = true; f.el("confirmation").value = "COMPLETE 2"; f.el("confirmation").oninput();
  assert.equal(f.el("execute").disabled, true);
  await f.el("execute").onclick();
  assert.equal(f.requests.filter(r => r.options.method === "POST").length, 0);
  f.el("confirmation").value = "COMPLETE 1"; f.el("confirmation").oninput();
  await f.el("execute").onclick();
  assert.equal(f.requests.filter(r => r.options.method === "POST").length, 1);
  assert.match(f.el("list").innerHTML, /VerifiedCompleted/);
  assert.equal(f.downloads.length, 1);
  const md = await f.downloads[0].blob.text();
  assert.match(md, /Instructions for an LLM/); assert.ok(!md.includes("fixture-secret-token"));
  assert.ok(f.requests.every(r => new URL(r.url).origin === "https://halo.example"));
  f.el("close").onclick();
  assert.ok(f.messages.some(m => m.isoHaloBulk === "clearAuth"));
  assert.equal(f.el("panel").classList.contains("open"), false);
});
test("double clicks do not duplicate a batch and stopping prevents the next appointment", async () => {
  const f = fixture();
  f.items.push(Object.assign({}, f.items[0], { id: 2, subject: "Second" }));
  f.el("open").onclick(); await f.el("refresh").onclick(); f.el("select").onclick(); f.el("preview").onclick();
  f.el("ack").checked = true; f.el("confirmation").value = "COMPLETE 2"; f.el("confirmation").oninput();
  let release; f.setGate(new Promise(resolve => { release = resolve; }));
  const pending = f.el("execute").onclick();
  while (!f.requests.some(r => r.options.method === "POST")) await new Promise(resolve => setImmediate(resolve));
  await f.el("execute").onclick();
  f.el("stop").onclick(); release(); await pending;
  assert.equal(f.requests.filter(r => r.options.method === "POST").length, 1);
  assert.match(f.el("list").innerHTML, /NotAttempted/);
});
test("hook captures only same-origin API auth, clears even before first manager connection", async () => {
  const listeners = new Map(), sent = [];
  function Xhr() {}
  Xhr.prototype.open = function () {}; Xhr.prototype.setRequestHeader = function () {};
  const c = { URL, Request, Headers, XMLHttpRequest: Xhr, location: { origin: "https://halo.example", href: "https://halo.example/calendar" },
    fetch: async () => ({}), postMessage: data => sent.push(data), addEventListener(name, fn) { listeners.set(name, fn); } };
  c.window = c; vm.createContext(c); const win = vm.runInContext("window", c);
  vm.runInContext(source("hook.js"), c);
  const message = data => listeners.get("message")({ source: win, origin: c.location.origin, data });
  await c.fetch("https://halo.example/api/Agent/me", { headers: { Authorization: "Bearer first-token" } });
  message({ isoHaloBulk: "clearAuth", recipient: "panel" });
  message({ isoHaloBulk: "requestAuth", recipient: "panel" });
  assert.equal(sent.length, 0);
  await c.fetch("https://other.example/api/Agent/me", { headers: { Authorization: "Bearer wrong-token" } });
  assert.equal(sent.length, 0);
  await c.fetch("https://halo.example/api/Agent/me", { headers: { Authorization: "Bearer valid-token" } });
  assert.equal(sent.length, 1); assert.equal(sent[0].value, "Bearer valid-token");
  message({ isoHaloBulk: "clearAuth", recipient: "panel" });
  await c.fetch("https://halo.example/api/Agent/me", { headers: { Authorization: "Bearer later-token" } });
  assert.equal(sent.length, 1);
});
