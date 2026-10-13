/*
 * Halo Appointment Manager
 * Runs inside the Halo agent web app and uses the logged-in browser session.
 * Endpoints used (captured from Halo HARs):
 *   GET    /api/Appointment?...            list appointments
 *   POST   /api/Appointment   [ {...} ]    complete / update an appointment
 *   DELETE /api/Appointment/{id}           delete an appointment
 *   GET    /api/lookup?lookupid=17&use=0   charge rates (used for completion)
 */
(() => {
  console.info("[Halo Appointment Manager] content script loaded");
  if (window.__haloApptMgrLoaded) return;
  window.__haloApptMgrLoaded = true;

  const DEFAULTS = {
    agentId: "",
    teamId: "",
    pastDays: 30,
    futureDays: 30,
    chargeRate: "0", // Do Not Bill
    createFollowup: false,
    followupDays: 0
  };

  const state = {
    settings: { ...DEFAULTS },
    items: [],
    chargeRates: [],
    tab: "pastOpen",
    selected: new Set(),
    search: "",
    source: "all",
    busy: false
  };

  /* ---------------- helpers ---------------- */

  const HEADERS = {
    Accept: "application/json",
    "Content-Type": "application/json",
    "halo-app-name": "halo-agent-app"
  };

  const esc = (s) =>
    String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  // Halo returns UTC timestamps without a trailing "Z"
  const parseUtc = (s) => (s ? new Date(/[zZ]|[+-]\d\d:\d\d$/.test(s) ? s : s + "Z") : null);
  const toHaloUtc = (d) => d.toISOString().slice(0, 19);
  const utcOffset = () => new Date().getTimezoneOffset();

  const fmt = (d, allday) =>
    d
      ? allday
        ? d.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" }) + " (all day)"
        : d.toLocaleString(undefined, { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
      : "";

  const toLocalInput = (d) => {
    const p = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
  };

  /* ---- auth: Halo's SPA uses a bearer token, not cookies ---- */
  let authHeader = "";
  window.addEventListener("message", (e) => {
    if (e.source === window && e.data && e.data.__haloApptMgr === "auth" && e.data.value) authHeader = e.data.value;
  });
  window.postMessage({ __haloApptMgr: "requestAuth" }, location.origin);

  // Fallback: look for a token in web storage
  function tokenFromStorage() {
    const jwt = /^[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}$/;
    for (const store of [sessionStorage, localStorage]) {
      try {
        for (let i = 0; i < store.length; i++) {
          const raw = store.getItem(store.key(i)) || "";
          if (jwt.test(raw)) return "Bearer " + raw;
          if (raw.startsWith("{") && raw.includes("access_token")) {
            const o = JSON.parse(raw);
            const t = o.access_token || (o.token && o.token.access_token);
            if (t) return "Bearer " + t;
          }
        }
      } catch (_) {}
    }
    return "";
  }

  async function waitForAuth(ms = 6000) {
    const until = Date.now() + ms;
    while (!authHeader && Date.now() < until) {
      window.postMessage({ __haloApptMgr: "requestAuth" }, location.origin);
      await new Promise((r) => setTimeout(r, 300));
    }
    if (!authHeader) authHeader = tokenFromStorage();
    return authHeader;
  }

  async function api(path, options = {}, retried = false) {
    if (!authHeader) await waitForAuth();
    const headers = { ...HEADERS };
    if (authHeader) headers.Authorization = authHeader;
    const res = await fetch(path, { credentials: "include", ...options, headers });
    if (res.status === 401 && !retried) {
      // token may have rotated; wait for Halo's next call to relay a fresh one
      const stale = authHeader;
      authHeader = "";
      await waitForAuth(8000);
      if (authHeader && authHeader !== stale) return api(path, options, true);
      throw new Error("HTTP 401: no valid Halo session token captured yet. Click around Halo (e.g. open the Calendar) or refresh the page, then press Refresh.");
    }
    if (!res.ok) {
      let detail = "";
      try { detail = (await res.text()).slice(0, 300); } catch (_) {}
      throw new Error(`HTTP ${res.status}${detail ? ": " + detail : ""}`);
    }
    const text = await res.text();
    return text ? JSON.parse(text) : null;
  }

  const loadSettings = () =>
    new Promise((resolve) =>
      chrome.storage.local.get("haloApptMgr", (r) => {
        state.settings = { ...DEFAULTS, ...(r.haloApptMgr || {}), chargeRate: "0" };
        resolve();
      })
    );
  const saveSettings = () => chrome.storage.local.set({ haloApptMgr: state.settings });

  /* ---- logged-in agent detection ---- */
  const me = { id: "", name: "", source: "" };

  function decodeJwt(header) {
    try {
      const part = header.replace(/^bearer\s+/i, "").split(".")[1];
      const json = atob(part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "="));
      return JSON.parse(decodeURIComponent(escape(json)));
    } catch (_) { return null; }
  }

  async function detectLoggedInAgent() {
    if (me.id) return me;
    // 1) Halo API: current agent
    for (const path of ["/api/Agent/me", "/api/agent/me"]) {
      try {
        const a = await api(path, { method: "GET" });
        if (a && Number(a.id) > 0) {
          Object.assign(me, { id: String(a.id), name: a.name || "", source: "Halo /Agent/me" });
          return me;
        }
      } catch (_) {}
    }
    // 2) Claims in the session token
    const claims = authHeader ? decodeJwt(authHeader) : null;
    if (claims) {
      const id = claims.agent_id ?? claims.agentid ?? claims.agentId ?? claims.halo_agent_id;
      if (Number(id) > 0) {
        Object.assign(me, { id: String(id), name: claims.name || "", source: "session token" });
        return me;
      }
    }
    return me;
  }

  // Manual value in Settings is an override; blank = always use the logged-in agent
  async function detectAgentId() {
    if (state.settings.agentId) return state.settings.agentId;
    const a = await detectLoggedInAgent();
    return a.id;
  }

  function renderWho() {
    const el = $("who");
    if (!el) return;
    if (state.settings.agentId) el.textContent = `Agent ${state.settings.agentId} (manual override)`;
    else if (me.id) el.textContent = `${me.name || "Agent"} · ID ${me.id}`;
    else el.textContent = "Agent not detected";
  }

  /* ---------------- classification ---------------- */

  const isOpen = (a) => a.complete_status === -1;
  const isCompleted = (a) => a.complete_status === 0;
  const endOf = (a) => parseUtc(a.end_date) || parseUtc(a.start_date);
  const isPast = (a) => endOf(a) < new Date();
  const isRecurring = (a) => !!a.recurring_master_id || (a.halo_recurring_master_id ?? -1) > 0;
  const canComplete = (a) => isOpen(a) && a._cancomplete === true;
  const canDelete = (a) => a._candelete === true;
  const canEdit = (a) => isOpen(a) && a._canupdate === true;

  function sourceOf(a) {
    if (a.ticket_id > 0) return "ticket";
    if (a.is_task) return "task";
    if (a.entryid) return "outlook";
    return "halo";
  }
  const SOURCE_LABEL = { ticket: "Ticket", task: "Task", outlook: "Outlook-synced", halo: "Halo" };

  function tabItems(tab) {
    return state.items.filter((a) => {
      switch (tab) {
        case "pastOpen": return isOpen(a) && isPast(a);
        case "upcoming": return isOpen(a) && !isPast(a);
        case "completed": return isCompleted(a);
        default: return true;
      }
    });
  }

  function visibleItems() {
    const q = state.search.trim().toLowerCase();
    return tabItems(state.tab)
      .filter((a) => {
        const src = sourceOf(a);
        if (state.source === "nonticket" && src === "ticket") return false;
        if (state.source !== "all" && state.source !== "nonticket" && src !== state.source) return false;
        if (!q) return true;
        return [a.subject, a.client_name, a.ticket_id, a.id].some((v) => String(v ?? "").toLowerCase().includes(q));
      })
      .sort((x, y) => {
        const d = parseUtc(x.start_date) - parseUtc(y.start_date);
        return state.tab === "completed" ? -d : d;
      });
  }

  /* ---------------- Halo operations ---------------- */

  async function fetchAppointments() {
    const agent = await detectAgentId();
    if (!agent) throw new Error("Could not detect the logged-in Halo agent. Refresh the Halo tab, or set a manual override in Settings.");
    const now = new Date();
    const start = new Date(now); start.setDate(start.getDate() - Number(state.settings.pastDays || 30)); start.setHours(0, 0, 0, 0);
    const end = new Date(now); end.setDate(end.getDate() + Number(state.settings.futureDays || 30) + 1); end.setHours(0, 0, 0, 0);

    const p = new URLSearchParams({
      showholidays: "false",
      selectedAgents: agent,
      selectedTypes: "0,3,2,1",
      selectedStatuses: "0,1",
      selectedLocations: "0",
      workhoursonly: "false",
      showtasks: "true",
      utcoffset: String(utcOffset()),
      start_date: start.toISOString(),
      end_date: end.toISOString(),
      types: "0,3,2,1",
      statuses: "0,1",
      locations: "",
      agents: agent,
      appointmentsonly: "true",
      excluderecurringmaster: "true",
      showscheduledtickets: "false",
      showshifts: "false"
    });
    if (state.settings.teamId) p.set("selectedTeam", state.settings.teamId);

    const data = await api("/api/Appointment?" + p.toString(), { method: "GET" });
    state.items = Array.isArray(data) ? data : (data && data.appointments) || [];
    // drop selections that no longer exist
    const ids = new Set(state.items.map((a) => a.id));
    [...state.selected].forEach((id) => ids.has(id) || state.selected.delete(id));
  }

  const DO_NOT_BILL_FALLBACK = "0";
  function doNotBillId() {
    const r = state.chargeRates.find((x) => /^do not bill$/i.test(String(x.name).trim()));
    return r ? String(r.id) : DO_NOT_BILL_FALLBACK;
  }

  async function fetchChargeRates() {
    try {
      const data = await api("/api/lookup?lookupid=17&use=0", { method: "GET" });
      state.chargeRates = (data || []).filter((r) => !r.inactive);
    } catch (_) {
      state.chargeRates = [];
    }
  }

  async function deleteAppointment(a) {
    if (!canDelete(a)) throw new Error("Halo reports this appointment cannot be deleted");
    await api(`/api/Appointment/${a.id}`, { method: "DELETE" });
  }

  // Mirrors the payload the Halo UI sends when completing an appointment
  async function completeAppointment(a, opts) {
    if (!canComplete(a)) throw new Error("Halo reports this appointment cannot be completed");
    const body = {
      id: a.id,
      subject: a.subject,
      start_date: a.start_date,
      end_date: a.end_date,
      allday: !!a.allday,
      start_date_only: null,
      end_date_only: null,
      is_private: !!a.is_private,
      user_id: a.user_id ?? -1,
      is_task: !!a.is_task,
      shift_type_id: a.shift_type_id ?? 0,
      complete_status: "0",
      chargerate: String(opts.chargeRate ?? doNotBillId()),
      complete_date: new Date().toISOString(),
      utcoffset: utcOffset(),
      apfaultidremoved: true,
      agent_id: a.agent_id
    };
    if (opts.createFollowup) {
      const s = parseUtc(a.start_date), e = endOf(a);
      const dur = Math.max(e - s, 15 * 60000);
      const fs = new Date(); fs.setDate(fs.getDate() + Number(opts.followupDays || 0));
      fs.setHours(s.getHours(), s.getMinutes(), 0, 0);
      Object.assign(body, {
        followup_start_date: fs.toISOString(),
        followup_end_date: new Date(fs.getTime() + dur).toISOString(),
        followup_allday: !!a.allday,
        followup_is_private: !!a.is_private,
        followup_user_id: a.user_id ?? -1,
        followup_agent_id: a.agent_id
      });
    }
    await api("/api/Appointment", { method: "POST", body: JSON.stringify([body]) });
  }

  // Experimental: uses the same POST endpoint Halo uses for completion
  async function updateAppointment(a, changes) {
    if (!canEdit(a)) throw new Error("Halo reports this appointment cannot be updated");
    const body = {
      id: a.id,
      subject: changes.subject ?? a.subject,
      start_date: changes.start_date ?? a.start_date,
      end_date: changes.end_date ?? a.end_date,
      allday: changes.allday ?? !!a.allday,
      is_private: changes.is_private ?? !!a.is_private,
      user_id: a.user_id ?? -1,
      is_task: !!a.is_task,
      shift_type_id: a.shift_type_id ?? 0,
      utcoffset: utcOffset(),
      agent_id: a.agent_id
    };
    await api("/api/Appointment", { method: "POST", body: JSON.stringify([body]) });
  }

  /* ---------------- UI ---------------- */

  const host = document.createElement("div");
  host.id = "halo-appt-mgr-host";
  document.documentElement.appendChild(host);
  const root = host.attachShadow({ mode: "open" });

  root.innerHTML = `
  <style>
    :host { all: initial; }
    * { box-sizing: border-box; font-family: "Segoe UI", Lato, Arial, sans-serif; }
    .fab { position: fixed; right: 18px; bottom: 18px; z-index: 2147483646; background: #00A9E0; color: #fff;
      border: 0; border-radius: 22px; padding: 10px 16px; font-size: 13px; font-weight: 600; cursor: pointer;
      box-shadow: 0 4px 14px rgba(0,0,0,.25); }
    .fab:hover { background: #0090c0; }
    .overlay { position: fixed; inset: 0; background: rgba(0,0,0,.35); z-index: 2147483646; display: none; }
    .panel { position: fixed; top: 4vh; right: 2vw; width: min(1100px, 96vw); height: 92vh; z-index: 2147483647;
      background: #fff; border-radius: 10px; box-shadow: 0 10px 40px rgba(0,0,0,.35); display: none; flex-direction: column;
      color: #222; font-size: 13px; overflow: hidden; }
    .open .overlay { display: block; } .open .panel { display: flex; }
    header { background: #00A9E0; color: #fff; padding: 10px 16px; display: flex; align-items: center; gap: 10px; }
    header h2 { margin: 0; font-size: 16px; flex: 1; }
    button { font-size: 12px; border-radius: 5px; border: 1px solid #bbb; background: #f6f6f6; padding: 5px 10px; cursor: pointer; color: #222; }
    button:hover:not(:disabled) { background: #e9e9e9; }
    button:disabled { opacity: .4; cursor: not-allowed; }
    button.primary { background: #00A9E0; color: #fff; border-color: #0090c0; }
    button.danger { background: #d9534f; color: #fff; border-color: #c9302c; }
    button.ghost { background: transparent; color: #fff; border-color: rgba(255,255,255,.6); }
    .toolbar { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; padding: 10px 16px; border-bottom: 1px solid #e3e3e3; }
    .tabs { display: flex; gap: 4px; }
    .tab { border-radius: 14px; padding: 5px 12px; }
    .tab.active { background: #00A9E0; color: #fff; border-color: #0090c0; }
    .count { display: inline-block; min-width: 18px; padding: 0 5px; border-radius: 9px; background: rgba(0,0,0,.12); margin-left: 4px; font-size: 11px; }
    input[type=text], input[type=number], input[type=datetime-local], select { font-size: 12px; padding: 5px 7px; border: 1px solid #bbb; border-radius: 5px; }
    .spacer { flex: 1; }
    .list { flex: 1; overflow: auto; }
    table { width: 100%; border-collapse: collapse; }
    th { position: sticky; top: 0; background: #fafafa; text-align: left; font-weight: 600; padding: 7px 8px; border-bottom: 1px solid #ddd; z-index: 1; }
    td { padding: 7px 8px; border-bottom: 1px solid #f0f0f0; vertical-align: top; }
    tr:hover td { background: #f7fbfd; }
    .subj { font-weight: 600; }
    .meta { color: #777; font-size: 11px; margin-top: 2px; }
    .tag { display: inline-block; font-size: 10px; padding: 1px 6px; border-radius: 8px; margin-right: 4px; background: #eee; }
    .tag.ticket { background: #fff3cd; } .tag.outlook { background: #dbeafe; } .tag.task { background: #e8f5e9; }
    .tag.recurring { background: #f3e8ff; } .tag.done { background: #ddd; }
    .acts { white-space: nowrap; } .acts button { margin-right: 3px; padding: 3px 7px; }
    footer { border-top: 1px solid #e3e3e3; padding: 8px 16px; display: flex; gap: 8px; align-items: center; }
    .status { flex: 1; color: #555; }
    .log { max-height: 120px; overflow: auto; font-family: Consolas, monospace; font-size: 11px; background: #fafafa; border-top: 1px solid #eee; padding: 6px 16px; display: none; white-space: pre-wrap; }
    .log.show { display: block; }
    .ok { color: #2e7d32; } .err { color: #c62828; }
    .empty { padding: 40px; text-align: center; color: #888; }
    .modal-bg { position: fixed; inset: 0; background: rgba(0,0,0,.4); z-index: 2147483647; display: none; align-items: center; justify-content: center; }
    .modal-bg.show { display: flex; }
    .modal { background: #fff; border-radius: 8px; width: 440px; max-width: 94vw; padding: 18px; box-shadow: 0 10px 30px rgba(0,0,0,.3); }
    .modal h3 { margin: 0 0 12px; font-size: 15px; }
    .modal label { display: block; margin: 10px 0 4px; font-weight: 600; font-size: 12px; }
    .modal input[type=text], .modal input[type=number], .modal input[type=datetime-local], .modal select { width: 100%; }
    .modal .row { display: flex; gap: 8px; align-items: center; margin-top: 8px; }
    .modal .btns { display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px; }
    .note { font-size: 11px; color: #777; margin-top: 6px; }
  </style>
  <button class="fab" id="fab">📅 Appointment Manager</button>
  <div id="wrap">
    <div class="overlay" id="overlay"></div>
    <div class="panel">
      <header>
        <h2>Halo Appointment Manager</h2>
        <span id="who" style="font-size:12px;opacity:.9"></span>
        <button class="ghost" id="btnSettings">Settings</button>
        <button class="ghost" id="btnRefresh">Refresh</button>
        <button class="ghost" id="btnClose">✕</button>
      </header>
      <div class="toolbar">
        <div class="tabs" id="tabs"></div>
        <div class="spacer"></div>
        <select id="source">
          <option value="all">All sources</option>
          <option value="outlook">Outlook-synced</option>
          <option value="ticket">Ticket appointments</option>
          <option value="nonticket">Non-ticket</option>
          <option value="task">Tasks</option>
          <option value="halo">Halo-only</option>
        </select>
        <input type="text" id="search" placeholder="Search subject, client, ticket…" />
      </div>
      <div class="list" id="list"></div>
      <div class="log" id="log"></div>
      <footer>
        <div class="status" id="status">Loading…</div>
        <button id="btnSelectAll">Select all actionable</button>
        <button id="btnClear">Clear</button>
        <button class="primary" id="btnBulkComplete" disabled>Complete selected</button>
        <button class="danger" id="btnBulkDelete" disabled>Delete selected</button>
      </footer>
    </div>
  </div>
  <div class="modal-bg" id="modalBg"><div class="modal" id="modal"></div></div>
  `;

  const $ = (id) => root.getElementById(id);
  const wrap = $("wrap");

  const TABS = [
    ["pastOpen", "Past open"],
    ["upcoming", "Upcoming"],
    ["completed", "Completed"],
    ["all", "All"]
  ];

  function setStatus(msg) { $("status").textContent = msg; }

  function log(line, cls) {
    const el = $("log");
    el.classList.add("show");
    const div = document.createElement("div");
    if (cls) div.className = cls;
    div.textContent = `[${new Date().toLocaleTimeString()}] ${line}`;
    el.prepend(div);
  }

  function renderTabs() {
    $("tabs").innerHTML = TABS.map(([k, label]) =>
      `<button class="tab ${state.tab === k ? "active" : ""}" data-tab="${k}">${label}<span class="count">${tabItems(k).length}</span></button>`
    ).join("");
  }

  function renderList() {
    const rows = visibleItems();
    if (!rows.length) {
      $("list").innerHTML = `<div class="empty">No appointments in this view.</div>`;
    } else {
      $("list").innerHTML = `
      <table>
        <thead><tr>
          <th style="width:28px"><input type="checkbox" id="chkAll" /></th>
          <th style="width:190px">When</th>
          <th>Appointment</th>
          <th style="width:230px">Actions</th>
        </tr></thead>
        <tbody>
        ${rows.map((a) => {
          const src = sourceOf(a);
          const s = parseUtc(a.start_date), e = endOf(a);
          const actionable = canComplete(a) || canDelete(a);
          return `<tr data-id="${a.id}">
            <td><input type="checkbox" class="chk" data-id="${a.id}" ${state.selected.has(a.id) ? "checked" : ""} ${actionable ? "" : "disabled"} /></td>
            <td>${esc(fmt(s, a.allday))}${!a.allday && e ? `<div class="meta">to ${esc(e.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" }))}</div>` : ""}</td>
            <td>
              <div class="subj">${esc(a.subject || "(no subject)")}</div>
              <div class="meta">
                <span class="tag ${src}">${SOURCE_LABEL[src]}${a.ticket_id > 0 ? " #" + esc(a.ticket_id) : ""}</span>
                ${isRecurring(a) ? `<span class="tag recurring">Recurring occurrence</span>` : ""}
                ${isCompleted(a) ? `<span class="tag done">Completed</span>` : ""}
                ${a.client_name ? esc(a.client_name) : ""}
                <span style="color:#aaa">· ID ${esc(a.id)}</span>
              </div>
            </td>
            <td class="acts">
              <button data-act="open" data-id="${a.id}">Open</button>
              <button data-act="edit" data-id="${a.id}" ${canEdit(a) ? "" : "disabled"}>Edit</button>
              <button data-act="complete" data-id="${a.id}" class="primary" ${canComplete(a) ? "" : "disabled"}>Complete</button>
              <button data-act="delete" data-id="${a.id}" class="danger" ${canDelete(a) ? "" : "disabled"}>Delete</button>
            </td>
          </tr>`;
        }).join("")}
        </tbody>
      </table>`;
      const actionableIds = rows.filter((a) => canComplete(a) || canDelete(a)).map((a) => a.id);
      const chkAll = $("chkAll");
      chkAll.checked = actionableIds.length > 0 && actionableIds.every((id) => state.selected.has(id));
    }
    updateBulkButtons();
  }

  function updateBulkButtons() {
    const sel = selectedItems();
    $("btnBulkComplete").disabled = state.busy || !sel.some(canComplete);
    $("btnBulkDelete").disabled = state.busy || !sel.some(canDelete);
    $("btnBulkComplete").textContent = `Complete selected (${sel.filter(canComplete).length})`;
    $("btnBulkDelete").textContent = `Delete selected (${sel.filter(canDelete).length})`;
    if (!state.busy) setStatus(`${state.items.length} appointments loaded · ${sel.length} selected`);
  }

  function render() { renderTabs(); renderList(); }

  const byId = (id) => state.items.find((a) => String(a.id) === String(id));
  const selectedItems = () => state.items.filter((a) => state.selected.has(a.id));

  /* ---------------- modals ---------------- */

  function modal(html) {
    $("modal").innerHTML = html;
    $("modalBg").classList.add("show");
    return new Promise((resolve) => {
      $("modal").onclick = (ev) => {
        const b = ev.target.closest("button[data-r]");
        if (!b) return;
        const r = b.dataset.r;
        const form = {};
        $("modal").querySelectorAll("[name]").forEach((el) => (form[el.name] = el.type === "checkbox" ? el.checked : el.value));
        $("modalBg").classList.remove("show");
        resolve(r === "ok" ? form : null);
      };
    });
  }

  function chargeRateOptions(selected) {
    if (!state.chargeRates.length) return `<option value="${DO_NOT_BILL_FALLBACK}" selected>Do Not Bill</option>`;
    return state.chargeRates.map((r) =>
      `<option value="${esc(r.id)}" ${String(r.id) === String(selected) ? "selected" : ""}>${esc(r.name)}</option>`).join("");
  }

  async function confirmComplete(items) {
    const recurring = items.filter(isRecurring).length;
    return modal(`
      <h3>Complete ${items.length} appointment${items.length === 1 ? "" : "s"}</h3>
      <label>Charge rate</label>
      <select name="chargeRate">${chargeRateOptions(doNotBillId())}</select>
      <div class="note">Defaults to Do Not Bill. Only change this if billable time was actually performed.</div>
      <div class="row"><input type="checkbox" name="createFollowup" id="fu" ${state.settings.createFollowup ? "checked" : ""}/>
        <label for="fu" style="margin:0;font-weight:400">Create follow-up appointment</label></div>
      <label>Follow-up days from today</label>
      <input type="number" name="followupDays" min="0" value="${esc(state.settings.followupDays)}" />
      ${recurring ? `<div class="note">⚠ ${recurring} recurring occurrence(s) selected. Only these occurrences are completed, not the series.</div>` : ""}
      <div class="note">Completion date is set to now. Items Halo marks as non-completable are skipped.</div>
      <div class="btns"><button data-r="cancel">Cancel</button><button class="primary" data-r="ok">Complete</button></div>`);
  }

  async function confirmDelete(items) {
    const recurring = items.filter(isRecurring).length;
    const tickets = items.filter((a) => a.ticket_id > 0).length;
    const preview = items.slice(0, 8).map((a) => `<li>${esc(fmt(parseUtc(a.start_date), a.allday))} – ${esc(a.subject)}</li>`).join("");
    return modal(`
      <h3>Delete ${items.length} appointment${items.length === 1 ? "" : "s"}?</h3>
      <ul style="margin:0;padding-left:18px;font-size:12px">${preview}${items.length > 8 ? `<li>…and ${items.length - 8} more</li>` : ""}</ul>
      ${recurring ? `<div class="note">⚠ ${recurring} recurring occurrence(s). Only these occurrences will be deleted from Halo.</div>` : ""}
      ${tickets ? `<div class="note">⚠ ${tickets} appointment(s) are linked to tickets.</div>` : ""}
      <div class="note">This cannot be undone from this tool.</div>
      <div class="row"><input type="checkbox" name="ack" id="ack"/><label for="ack" style="margin:0;font-weight:400">I understand, delete these appointments</label></div>
      <div class="btns"><button data-r="cancel">Cancel</button><button class="danger" data-r="ok">Delete</button></div>`);
  }

  async function editDialog(a) {
    const s = parseUtc(a.start_date), e = endOf(a);
    return modal(`
      <h3>Edit appointment</h3>
      <label>Subject</label><input type="text" name="subject" value="${esc(a.subject)}" />
      <label>Start</label><input type="datetime-local" name="start" value="${toLocalInput(s)}" />
      <label>End</label><input type="datetime-local" name="end" value="${toLocalInput(e)}" />
      <div class="row"><input type="checkbox" name="is_private" id="pv" ${a.is_private ? "checked" : ""}/><label for="pv" style="margin:0;font-weight:400">Private</label></div>
      <div class="note">Experimental: uses the same endpoint Halo uses for completion. For complex changes (attendees, recurrence) use Open.</div>
      <div class="btns"><button data-r="cancel">Cancel</button><button class="primary" data-r="ok">Save</button></div>`);
  }

  async function settingsDialog() {
    const s = state.settings;
    const r = await modal(`
      <h3>Settings</h3>
      <label>Agent ID override</label><input type="text" name="agentId" value="${esc(s.agentId)}" placeholder="Blank = logged-in agent${me.id ? " (" + esc(me.id) + ")" : ""}" />
      <div class="note">Leave blank to always use whoever is logged in to Halo. Enter an ID only to view another agent's calendar.</div>
      <label>Team ID (optional)</label><input type="text" name="teamId" value="${esc(s.teamId)}" />
      <label>Days in the past to load</label><input type="number" name="pastDays" min="1" max="365" value="${esc(s.pastDays)}" />
      <label>Days in the future to load</label><input type="number" name="futureDays" min="0" max="365" value="${esc(s.futureDays)}" />
      <div class="row"><input type="checkbox" name="createFollowup" id="sfu" ${s.createFollowup ? "checked" : ""}/><label for="sfu" style="margin:0;font-weight:400">Create follow-up by default when completing</label></div>
      <label>Default follow-up days from today</label><input type="number" name="followupDays" min="0" value="${esc(s.followupDays)}" />
      <div class="btns"><button data-r="cancel">Cancel</button><button class="primary" data-r="ok">Save</button></div>`);
    if (!r) return;
    state.settings = {
      ...state.settings,
      agentId: r.agentId.trim(),
      teamId: r.teamId.trim(),
      pastDays: Number(r.pastDays) || 30,
      futureDays: Number(r.futureDays) || 0,
      chargeRate: "0",
      createFollowup: r.createFollowup,
      followupDays: Number(r.followupDays) || 0
    };
    saveSettings();
    refresh();
  }

  /* ---------------- actions ---------------- */

  async function runBulk(label, items, fn) {
    state.busy = true;
    updateBulkButtons();
    let ok = 0, fail = 0;
    for (let i = 0; i < items.length; i++) {
      const a = items[i];
      setStatus(`${label} ${i + 1} of ${items.length}…`);
      try {
        await fn(a);
        ok++;
        state.selected.delete(a.id);
        log(`✓ ${label} ${a.id} – ${a.subject}`, "ok");
      } catch (err) {
        fail++;
        log(`✗ ${label} ${a.id} – ${a.subject}: ${err.message}`, "err");
      }
    }
    state.busy = false;
    log(`${label} finished: ${ok} succeeded, ${fail} failed`, fail ? "err" : "ok");
    await refresh();
  }

  async function doComplete(items) {
    items = items.filter(canComplete);
    if (!items.length) return;
    const r = await confirmComplete(items);
    if (!r) return;
    const opts = { chargeRate: r.chargeRate, createFollowup: r.createFollowup, followupDays: Number(r.followupDays) || 0 };
    await runBulk("Complete", items, (a) => completeAppointment(a, opts));
  }

  async function doDelete(items) {
    items = items.filter(canDelete);
    if (!items.length) return;
    const r = await confirmDelete(items);
    if (!r) return;
    if (!r.ack) { log("Delete cancelled: confirmation checkbox not ticked", "err"); return; }
    await runBulk("Delete", items, deleteAppointment);
  }

  async function doEdit(a) {
    const r = await editDialog(a);
    if (!r) return;
    const s = new Date(r.start), e = new Date(r.end);
    if (isNaN(s) || isNaN(e) || e <= s) { log("Edit cancelled: end must be after start", "err"); return; }
    await runBulk("Update", [a], (x) =>
      updateAppointment(x, { subject: r.subject, start_date: toHaloUtc(s), end_date: toHaloUtc(e), is_private: r.is_private }));
  }

  async function refresh() {
    try {
      state.busy = true;
      setStatus("Loading appointments…");
      await fetchAppointments();
      state.busy = false;
      renderWho();
      render();
    } catch (err) {
      renderWho();
      state.busy = false;
      setStatus("Error loading appointments");
      log(`Load failed: ${err.message}`, "err");
      render();
    }
  }

  /* ---------------- events ---------------- */

  let loaded = false;
  $("fab").onclick = async () => {
    wrap.classList.add("open");
    if (!loaded) {
      loaded = true;
      await loadSettings();
      await fetchChargeRates();
      await refresh();
    }
  };
  $("btnClose").onclick = $("overlay").onclick = () => wrap.classList.remove("open");
  $("btnRefresh").onclick = refresh;
  $("btnSettings").onclick = settingsDialog;
  $("search").oninput = (e) => { state.search = e.target.value; renderList(); };
  $("source").onchange = (e) => { state.source = e.target.value; renderList(); };
  $("tabs").onclick = (e) => {
    const b = e.target.closest("[data-tab]");
    if (!b) return;
    state.tab = b.dataset.tab;
    render();
  };
  $("btnSelectAll").onclick = () => {
    visibleItems().filter((a) => canComplete(a) || canDelete(a)).forEach((a) => state.selected.add(a.id));
    renderList();
  };
  $("btnClear").onclick = () => { state.selected.clear(); renderList(); };
  $("btnBulkComplete").onclick = () => doComplete(selectedItems());
  $("btnBulkDelete").onclick = () => doDelete(selectedItems());

  $("list").addEventListener("change", (e) => {
    if (e.target.id === "chkAll") {
      const ids = visibleItems().filter((a) => canComplete(a) || canDelete(a)).map((a) => a.id);
      ids.forEach((id) => (e.target.checked ? state.selected.add(id) : state.selected.delete(id)));
      renderList();
    } else if (e.target.classList.contains("chk")) {
      const id = Number(e.target.dataset.id);
      e.target.checked ? state.selected.add(id) : state.selected.delete(id);
      updateBulkButtons();
    }
  });

  $("list").addEventListener("click", (e) => {
    const b = e.target.closest("button[data-act]");
    if (!b || b.disabled || state.busy) return;
    const a = byId(b.dataset.id);
    if (!a) return;
    switch (b.dataset.act) {
      case "open": window.open(`/calendar?appointmentid=${a.id}`, "_blank"); break;
      case "edit": doEdit(a); break;
      case "complete": doComplete([a]); break;
      case "delete": doDelete([a]); break;
    }
  });

  /* ---- only show on the Halo Calendar page (SPA-aware) ---- */
  // Match "calendar" as a path segment anywhere (e.g. /calendar, /agent/calendar, #/calendar)
  const onCalendar = () =>
    /(^|\/)calendar(\/|$)/i.test(location.pathname) || /(^|[#\/])calendar(\/|\?|$)/i.test(location.hash);
  let lastHref = "";
  function syncVisibility() {
    if (!host.isConnected) document.documentElement.appendChild(host);
    if (location.href === lastHref) return;
    lastHref = location.href;
    const show = onCalendar();
    console.info(`[Halo Appointment Manager] ${location.pathname}${location.hash} → ${show ? "showing" : "hidden"}`);
    host.style.display = show ? "" : "none";
    if (!show) {
      wrap.classList.remove("open");
      $("modalBg").classList.remove("show");
    }
  }
  syncVisibility();
  window.addEventListener("popstate", syncVisibility);
  window.addEventListener("hashchange", syncVisibility);
  setInterval(syncVisibility, 500); // Halo navigates without page reloads

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && wrap.classList.contains("open") && !$("modalBg").classList.contains("show")) wrap.classList.remove("open");
  });
})();
