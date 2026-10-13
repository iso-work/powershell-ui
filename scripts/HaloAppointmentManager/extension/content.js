(function () {
  "use strict";
  if (window.__isoHaloBulkLoaded) return;
  window.__isoHaloBulkLoaded = true;
  const C = globalThis.HaloBulkCore;
  const recipient = crypto.randomUUID();
  let auth = "";
  const state = { items: [], rates: [], selected: new Set(), plan: null, report: null, scope: null, busy: false, stop: false, open: false, closeAfter: false };
  const esc = function (value) { return String(value == null ? "" : value).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); };
  const host = document.createElement("div");
  host.id = "iso-halo-appointment-manager";
  const root = host.attachShadow({ mode: "closed" });
  root.innerHTML = [
    "<style>",
    ":host{all:initial}*{box-sizing:border-box;font-family:'Segoe UI',Arial,sans-serif}button,input,select{font:inherit}button{padding:9px 14px;border:1px solid #b8c5d3;border-radius:6px;background:white;color:#173454;cursor:pointer}button:disabled{opacity:.5;cursor:default}.primary{background:#176b87;color:white}.fab{position:fixed;right:22px;bottom:22px;z-index:2147483646;box-shadow:0 4px 16px #0003;font-size:15px}.panel{position:fixed;inset:3vh 3vw;z-index:2147483647;background:#f2f5f9;border:1px solid #cbd5e1;border-radius:12px;box-shadow:0 12px 60px #0005;color:#173454;font-size:15px;display:none;flex-direction:column;overflow:hidden}.panel.open{display:flex}header{display:flex;gap:12px;align-items:center;padding:18px 22px;background:white;border-bottom:1px solid #cbd5e1}h2{margin:0;font-size:24px;flex:1}.intro{padding:12px 22px;background:#fff6df;color:#5c4616}.intro p{margin:0 0 6px}.intro ul{margin:0;padding-left:22px}.controls{display:flex;gap:12px;align-items:end;flex-wrap:wrap;padding:14px 22px}label{display:block;font-size:13px}input,select{padding:8px;border:1px solid #b8c5d3;border-radius:4px;background:white;color:#173454}input[type=number]{width:92px}#agent{width:180px}#search{min-width:230px}.scroll{overflow:auto;flex:1;background:white;margin:0 22px 12px;border:1px solid #d5dfe8}table{border-collapse:collapse;width:100%;font-size:14px}th{position:sticky;top:0;background:#eaf0f6;text-align:left;z-index:1}td,th{padding:11px;border-bottom:1px solid #e0e7ef;vertical-align:top}.sub{color:#526478;font-size:12px;margin-top:5px}.empty{padding:30px}footer{display:flex;gap:10px;flex-wrap:wrap;padding:14px 22px;background:white;border-top:1px solid #cbd5e1}#status{flex:1;min-width:200px;align-self:center}.audit{max-height:150px;overflow:auto;padding:0 22px 12px;white-space:pre-wrap;font-size:13px}.modal{position:absolute;inset:5% 8%;background:white;border:2px solid #176b87;border-radius:10px;box-shadow:0 8px 30px #0005;padding:22px;display:none;flex-direction:column;z-index:3}.modal.open{display:flex}.modal h3{margin:0 0 14px;font-size:23px}.modal .scroll{margin:12px 0}.modal .confirm{padding-top:12px}.modal label{margin:9px 0;font-size:14px}.modal input[type=text]{width:220px}.danger-text{color:#8c3d10}input[type=checkbox]{width:18px;height:18px}#counts{padding:0 22px 10px;color:#526478}#help{font-size:13px;color:#526478}a{color:#176b87}",
    "</style>",
    '<button class="fab primary" id="open">Halo appointments</button>',
    '<section class="panel" id="panel" aria-label="Halo appointment manager">',
    '<header><h2>Halo appointment manager</h2><button id="close">Close and clear session</button></header>',
    '<div class="intro"><p><strong>This tool changes Halo appointments.</strong></p><ul><li>Review exact IDs and dates before confirming. Completion uses Do Not Bill and creates no follow-ups.</li><li>Only selected appointments are processed. Delete and general editing are unavailable.</li><li>Halo remains responsible for permissions, automation and calendar synchronization.</li></ul></div>',
    '<div class="controls"><label>Agent ID (blank = current)<br><input id="agent" type="number" min="1" placeholder="Automatic"></label><label>Past days<br><input id="past" type="number" min="1" max="365" value="30"></label><label>Future days<br><input id="future" type="number" min="0" max="365" value="30"></label><button id="refresh">Read appointments</button><label>View<br><select id="view"><option value="past">Past open</option><option value="open">All open</option><option value="complete">Completed</option></select></label><label>Search<br><input id="search" type="text" placeholder="Subject, client, ticket or ID"></label><button id="select">Select visible eligible</button><button id="clear">Clear selection</button></div>',
    '<div id="counts">Read appointments to begin.</div><div class="scroll" id="list"></div><div class="audit" id="audit"></div>',
    '<footer><span id="status" role="status">Sign in to Halo using your normal browser session.</span><button id="stop" disabled>Stop after current item</button><button id="json" disabled>Download JSON</button><button id="md" disabled>Download report</button><button id="preview" class="primary" disabled>Preview completion</button></footer>',
    '<div class="modal" id="review" role="dialog" aria-modal="true" aria-labelledby="reviewTitle"><h3 id="reviewTitle">Review selected appointments</h3><div id="planSummary"></div><div class="scroll" id="planList"></div><div class="confirm"><label><input id="ack" type="checkbox"> I reviewed these exact appointments and authorize their completion.</label><label id="phrase"></label><input id="confirmation" type="text" autocomplete="off"><p id="help">The preview expires after five minutes. Changed items will be skipped. Stop prevents subsequent items; it cannot undo a request already sent.</p><button id="discard">Discard preview</button> <button id="execute" class="primary" disabled>Complete reviewed appointments</button></div></div>',
    "</section>"
  ].join("\n");
  document.documentElement.appendChild(host);
  const $ = function (name) { return root.getElementById(name); };
  function status(text) { $("status").textContent = text; }
  function invalidate() { state.plan = null; $("review").classList.remove("open"); $("execute").disabled = true; }
  function freeze(busy) {
    state.busy = busy;
    ["agent", "past", "future", "refresh", "view", "search", "select", "clear", "preview", "discard", "close"].forEach(function (key) { $(key).disabled = busy; });
    root.querySelectorAll(".pick").forEach(function (el) { el.disabled = busy; });
    $("stop").disabled = !busy;
    $("preview").disabled = busy || state.selected.size === 0 || !state.scope;
    $("json").disabled = $("md").disabled = busy || !state.report;
  }
  window.addEventListener("message", function (e) {
    if (e.source === window && e.origin === location.origin && e.data && e.data.isoHaloBulk === "auth" &&
        e.data.recipient === recipient && state.open && typeof e.data.value === "string" && /^Bearer\s+\S+$/i.test(e.data.value)) auth = e.data.value;
  });
  async function authentication() {
    window.postMessage({ isoHaloBulk: "requestAuth", recipient: recipient }, location.origin);
    const deadline = Date.now() + 7000;
    while (!auth && Date.now() < deadline && state.open) await new Promise(function (resolve) { setTimeout(resolve, 200); });
    if (!auth) throw new Error("Halo session not captured. While this panel is open, use Halo's own calendar navigation to make a request, then Read appointments again.");
  }
  async function api(path, method, payload) {
    const url = new URL(path, location.origin);
    const allowed = ["/api/appointment", "/api/lookup", "/api/agent/me"];
    if (url.origin !== location.origin || url.protocol !== "https:" || !allowed.includes(url.pathname.toLowerCase()) ||
        !["GET", "POST"].includes(method) || (method === "POST" && url.pathname.toLowerCase() !== "/api/appointment")) throw new Error("Request outside the reviewed API contract.");
    if (!auth) await authentication();
    const controller = new AbortController();
    const timer = setTimeout(function () { controller.abort(); }, 30000);
    try {
      const response = await fetch(url.href, {
        method: method, headers: { Accept: "application/json", "Content-Type": "application/json", "halo-app-name": "halo-agent-app", Authorization: auth },
        credentials: "omit", redirect: "error", cache: "no-store", signal: controller.signal,
        body: method === "POST" ? JSON.stringify(payload) : undefined
      });
      if (!response.ok) { if (response.status === 401) auth = ""; throw new Error("Halo request failed (HTTP " + response.status + ")."); }
      const text = await response.text();
      return text ? JSON.parse(text) : null;
    } finally { clearTimeout(timer); }
  }
  function listPath(scope) {
    const q = new URLSearchParams({
      showholidays: "false", selectedAgents: String(scope.agentId), selectedTypes: "0,3,2,1", selectedStatuses: "0,1",
      selectedLocations: "0", workhoursonly: "false", showtasks: "true", utcoffset: String(new Date().getTimezoneOffset()),
      start_date: scope.fromUtc, end_date: scope.toUtc, types: "0,3,2,1", statuses: "0,1", locations: "", agents: String(scope.agentId),
      appointmentsonly: "true", excluderecurringmaster: "true", showscheduledtickets: "false", showshifts: "false"
    });
    return "/api/Appointment?" + q.toString();
  }
  async function readItems(scope) { return C.normalize(await api(listPath(scope), "GET")); }
  function visible() {
    const text = $("search").value.trim().toLowerCase(), view = $("view").value, now = Date.now();
    return state.items.filter(function (a) {
      let past = false;
      try { past = C.utc(a.end_date || a.start_date).getTime() < now; } catch (_) { return false; }
      if (view === "past" && !(C.completion(a) === -1 && past)) return false;
      if (view === "open" && C.completion(a) !== -1) return false;
      if (view === "complete" && C.completion(a) !== 0) return false;
      return [a.id, a.subject, a.client_name, a.ticket_id].some(function (value) { return String(value || "").toLowerCase().includes(text); });
    }).sort(function (a, b) { return C.utc(a.start_date) - C.utc(b.start_date); });
  }
  function rowsHtml(items, selectable) {
    return '<table><thead><tr>' + (selectable ? "<th>Select</th>" : "") + "<th>ID</th><th>When (local)</th><th>Appointment</th><th>Client / ticket</th><th>Eligibility</th></tr></thead><tbody>" +
      items.map(function (a) {
        const allowed = state.scope && C.eligible(a, state.scope.agentId);
        const start = C.utc(a.start_date);
        return "<tr>" + (selectable ? '<td><input class="pick" type="checkbox" data-id="' + a.id + '" ' + (state.selected.has(a.id) ? "checked " : "") + (!allowed || state.busy ? "disabled" : "") + "></td>" : "") +
          "<td>" + a.id + '</td><td title="' + esc(start.toISOString()) + '">' + esc(start.toLocaleString()) + "</td><td>" + esc(a.subject || "(no subject)") +
          "</td><td>" + esc(a.client_name || "") + (Number(a.ticket_id) > 0 ? " · Ticket " + esc(a.ticket_id) : "") + "</td><td>" +
          (allowed ? "May complete" : C.completion(a) === 0 ? "Completed" : "Not eligible; use Halo") + "</td></tr>";
      }).join("") + "</tbody></table>";
  }
  function render() {
    const list = visible();
    $("list").innerHTML = list.length ? rowsHtml(list, true) : '<div class="empty">No appointments in this view. Empty results are not proof of complete calendar coverage.</div>';
    $("counts").textContent = state.items.length + " loaded · " + list.length + " visible · " + state.selected.size + " selected" + (state.scope ? " · Agent " + state.scope.agentId : "");
    freeze(state.busy);
  }
  async function refresh() {
    if (state.busy) return;
    invalidate(); state.selected.clear(); state.items = []; state.scope = null;
    freeze(true); status("Reading Halo appointments. No changes are being made.");
    try {
      await authentication();
      let agent = $("agent").value.trim();
      if (!agent) {
        const me = await api("/api/Agent/me", "GET");
        if (!me || !me.id) throw new Error("Current agent could not be detected. Enter your Halo agent ID explicitly.");
        agent = me.id;
      }
      agent = C.id(agent);
      const past = Number($("past").value), future = Number($("future").value);
      if (!Number.isInteger(past) || past < 1 || past > 365 || !Number.isInteger(future) || future < 0 || future > 365) throw new Error("Past days must be 1–365; future days must be 0–365.");
      const from = new Date(), to = new Date();
      from.setDate(from.getDate() - past); from.setHours(0, 0, 0, 0);
      to.setDate(to.getDate() + future + 1); to.setHours(0, 0, 0, 0);
      const scope = Object.freeze({ origin: location.origin, agentId: agent, fromUtc: from.toISOString(), toUtc: to.toISOString() });
      const items = await readItems(scope);
      const rates = await api("/api/lookup?lookupid=17&use=0", "GET");
      C.doNotBill(rates);
      state.items = items; state.rates = rates; state.scope = scope;
      status("Read complete. Select appointments, then preview the exact changes.");
    } catch (error) { status(error.message || "Read failed. No completion is enabled."); }
    finally { freeze(false); render(); if (state.closeAfter) clearSession(); }
  }
  function download(format) {
    if (!state.report) return;
    const blob = new Blob([format === "json" ? JSON.stringify(state.report, null, 2) : C.markdown(state.report)], { type: format === "json" ? "application/json;charset=utf-8" : "text/markdown;charset=utf-8" });
    const url = URL.createObjectURL(blob), a = document.createElement("a");
    a.href = url; a.download = "halo-appointments-" + state.report.planId + (format === "json" ? ".json" : ".md");
    root.appendChild(a); a.click(); a.remove(); setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }
  function confirmEnabled() {
    $("execute").disabled = state.busy || !state.plan || !$("ack").checked || $("confirmation").value !== state.plan.confirmationText;
  }
  $("preview").onclick = function () {
    try {
      state.plan = C.plan(state.items, Array.from(state.selected), state.scope, state.rates);
      const p = state.plan, future = p.items.filter(function (a) { return C.utc(a.start_date) > new Date(); }).length;
      $("planSummary").textContent = p.origin + " · Agent " + p.agentId + " · " + p.items.length + " selected · Do Not Bill (" + p.rate.id + ") · No follow-ups · " + future + " future appointment(s)";
      $("planList").innerHTML = rowsHtml(p.items, false);
      $("phrase").textContent = 'Type "' + p.confirmationText + '" to authorize this exact selection.';
      $("ack").checked = false; $("confirmation").value = ""; $("review").classList.add("open"); confirmEnabled();
    } catch (error) { status(error.message); }
  };
  $("execute").onclick = async function () {
    if ($("execute").disabled || state.busy || !state.plan) return;
    const p = state.plan, confirmation = $("confirmation").value, acknowledged = $("ack").checked;
    state.stop = false; $("review").classList.remove("open"); freeze(true); $("execute").disabled = true; $("audit").textContent = "";
    try {
      state.report = await C.execute({
        plan: p, confirmation: confirmation, acknowledged: acknowledged, origin: location.origin,
        confirmedUtc: new Date().toISOString(), shouldStop: function () { return state.stop; },
        read: async function (key) { return (await readItems(p)).find(function (a) { return a.id === key; }) || null; },
        readRates: async function () { return api("/api/lookup?lookupid=17&use=0", "GET"); },
        post: async function (payload) { await api("/api/Appointment", "POST", payload); },
        onResult: function (row) { $("audit").textContent += row.id + " · " + row.outcome + " · " + row.detail + "\n"; status("Processed appointment " + row.id + ". Stop prevents the next write."); }
      });
      $("list").innerHTML = "<table><thead><tr><th>Appointment ID</th><th>Subject</th><th>Outcome</th><th>Evidence</th></tr></thead><tbody>" +
        state.report.records.map(function (row) { return "<tr><td>" + row.id + "</td><td>" + esc(row.subject) + "</td><td>" + esc(row.outcome) + "</td><td>" + esc(row.detail) + "</td></tr>"; }).join("") + "</tbody></table>";
      $("counts").textContent = "Batch " + state.report.planId + " · " + state.report.status + " · Read appointments again for a fresh selection.";
      state.items = []; state.scope = null;
      status(state.report.status + ". Review results below. A Markdown report was requested for download; use the buttons if your browser blocked it.");
      download("md");
    } catch (_) { status("Batch did not start. Refresh and preview again; check the typed confirmation and preview expiry."); }
    finally { invalidate(); state.selected.clear(); freeze(false); if (state.closeAfter) clearSession(); }
  };
  function clearSession() {
    if (state.busy) { state.stop = true; state.closeAfter = true; status("Stop requested. Wait for the current item and save the results before closing."); return; }
    invalidate(); auth = ""; state.items = []; state.rates = []; state.selected.clear(); state.scope = null; state.report = null; state.open = false;
    state.closeAfter = false;
    $("panel").classList.remove("open"); $("audit").textContent = ""; $("list").textContent = "";
    window.postMessage({ isoHaloBulk: "clearAuth", recipient: recipient }, location.origin);
  }
  $("open").onclick = function () { state.open = true; $("panel").classList.add("open"); status("Read appointments to capture the existing Halo session. No password is stored by this tool."); };
  $("close").onclick = clearSession; $("refresh").onclick = refresh;
  $("stop").onclick = function () { state.stop = true; status("Stop requested; an in-flight request cannot be undone."); };
  $("ack").onchange = $("confirmation").oninput = confirmEnabled;
  $("discard").onclick = invalidate;
  $("select").onclick = function () { invalidate(); visible().filter(function (a) { return C.eligible(a, state.scope.agentId); }).slice(0, 100).forEach(function (a) { state.selected.add(a.id); }); render(); };
  $("clear").onclick = function () { invalidate(); state.selected.clear(); render(); };
  $("view").onchange = $("search").oninput = function () { invalidate(); state.selected.clear(); render(); };
  ["agent", "past", "future"].forEach(function (key) { $(key).onchange = function () { invalidate(); state.selected.clear(); state.items = []; state.scope = null; render(); status("Scope changed. Read appointments again."); }; });
  $("list").onchange = function (e) {
    if (state.busy || !e.target.classList.contains("pick")) return;
    invalidate(); const key = C.id(e.target.dataset.id);
    if (e.target.checked) state.selected.add(key); else state.selected.delete(key);
    render();
  };
  $("json").onclick = function () { download("json"); }; $("md").onclick = function () { download("md"); };
  window.addEventListener("pagehide", function () {
    state.stop = true; state.closeAfter = state.busy; auth = ""; state.items = []; state.rates = []; state.scope = null;
    state.report = null; state.plan = null; state.selected.clear(); state.open = false;
    $("panel").classList.remove("open");
    window.postMessage({ isoHaloBulk: "clearAuth", recipient: recipient }, location.origin);
  });
  let href = "";
  setInterval(function () {
    if (href === location.href) return; href = location.href;
    const calendar = /(^|\/)calendar(\/|$)/i.test(location.pathname) || /(^|[#/])calendar(\/|\?|$)/i.test(location.hash);
    host.style.display = calendar ? "" : "none";
    if (!calendar) clearSession();
  }, 700);
})();
