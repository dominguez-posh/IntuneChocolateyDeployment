"use strict";

// Optional start view in the URL fragment, e.g. #view=settings
const START_VIEW = (location.hash.match(/view=(catalog|search|tenant|activity|settings)/) || [])[1] || null;

// Session token: handed over once in the URL fragment by Start-IntuneChocoGui.ps1, then kept for this tab only
const TOKEN = (() => {
  const match = location.hash.match(/token=([a-f0-9]+)/);
  if (match) {
    try { sessionStorage.setItem("icd-token", match[1]); } catch (e) { /* private mode */ }
    history.replaceState(null, "", location.pathname);
    return match[1];
  }
  try { return sessionStorage.getItem("icd-token") || ""; } catch (e) { return ""; }
})();

// Segoe Fluent Icons code points
const G = {
  check: "", cancel: "", warn: "", info: "", cloud: "", add: "",
  refresh: "", search: "", open: "", trash: "", upload: "", clock: "",
  person: "", pkg: "", down: "", up: "", play: "", minus: "",
  shield: "", sync: "", library: "", settings: ""
};

const ASSIGNMENTS = [
  { value: "Available", label: "Available", help: "Shown in the Company Portal for all users" },
  { value: "Required", label: "Required", help: "Installed automatically for all users" },
  { value: "None", label: "No assignment", help: "Create the app only, assign it in Intune yourself" }
];

const UPDATE_MODES = [
  { value: "Off", label: "Off", help: "No automatic updates. A version you release here is installed by Intune right away." },
  { value: "Startup", label: "At startup", help: "Updated at every startup of the device, after a random delay." },
  { value: "Custom", label: "User prompt and deadline", help: "The user is offered the update and can install it at once. When the grace period is over it is installed anyway, without a restart." }
];

const VERSION_MODES = [
  { value: "Latest", label: "Always the latest version", help: "Devices follow the newest package version (according to the update mode)." },
  { value: "Pinned", label: "Pin the current version", help: "New apps stay on today's version. You release newer versions in In tenant." }
];

function graceText(hours) {
  const h = Number(hours) || 48;
  return h % 24 === 0 ? `${h / 24} day${h === 24 ? "" : "s"}` : `${h} hour${h === 1 ? "" : "s"}`;
}

function modeText(mode, hours) {
  if (mode === "Custom") return `User prompt, installed after ${graceText(hours)}`;
  const m = UPDATE_MODES.find((x) => x.value === mode);
  return m ? m.label : mode;
}

// Compares two versions numerically, part by part (1.10 > 1.9)
function compareVersions(a, b) {
  const pa = String(a).split(/[.+-]/).map((p) => parseInt(p, 10) || 0);
  const pb = String(b).split(/[.+-]/).map((p) => parseInt(p, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return d;
  }
  return 0;
}

// Update mode, grace period (hours or days) and optionally the version, as form rows; read() returns the values
function policyControls(prefix, policy, versionOptions) {
  const mode = h("select", { class: "select", id: `${prefix}-mode` },
    UPDATE_MODES.map((m) => h("option", { value: m.value, selected: m.value === policy.updateMode }, m.label)));
  const hours = Number(policy.graceHours) || 48;
  const inDays = hours % 24 === 0;
  const graceValue = h("input", { class: "input", id: `${prefix}-grace`, type: "number", min: "1", max: inDays ? "90" : "2160", value: String(inDays ? hours / 24 : hours) });
  const graceUnit = h("select", { class: "select", id: `${prefix}-unit` },
    h("option", { value: "hours", selected: !inDays }, "hours"), h("option", { value: "days", selected: inDays }, "days"));
  const graceRow = h("div", { class: "range" }, graceValue, graceUnit, h("span", { class: "muted", text: "until it is installed anyway" }));
  const help = h("div", { class: "help" });
  const sync = () => {
    help.textContent = UPDATE_MODES.find((m) => m.value === mode.value).help;
    graceRow.hidden = mode.value !== "Custom";
  };
  mode.addEventListener("change", sync);
  sync();

  let version = null;
  const rows = [h("label", { for: mode.id, text: "Updates" }), h("div", { class: "field" }, mode, graceRow, help)];
  if (versionOptions) {
    version = h("select", { class: "select", id: `${prefix}-version` },
      versionOptions.map((o) => h("option", { value: o.value, selected: o.value === policy.version }, o.label)));
    rows.unshift(h("label", { for: version.id, text: "Version" }), h("div", { class: "field" }, version));
  }
  const read = () => {
    const graceHours = Math.round(Number(graceValue.value) * (graceUnit.value === "days" ? 24 : 1));
    if (mode.value === "Custom" && !(graceHours >= 1 && graceHours <= 2160)) throw new Error("The grace period must be between 1 hour and 90 days");
    return { updateMode: mode.value, graceHours: mode.value === "Custom" ? graceHours : hours, version: version ? version.value : undefined };
  };
  return { el: h("div", { class: "form" }, rows), read };
}

const ARCHITECTURES = [
  { value: "x64x86", label: "x64 and x86 (default)" },
  { value: "AllWithARM64", label: "x64, x86 and ARM64 (Windows 11 on ARM)" },
  { value: "x64", label: "x64 only" },
  { value: "arm64", label: "ARM64 only" },
  { value: "x86", label: "x86 only" }
];

const state = {
  view: "catalog",
  server: null,
  catalog: [],
  catalogLoading: false,
  category: "All",
  filter: "",
  search: { q: "", results: null, loading: false, error: null },
  tenant: { apps: null, loading: false, error: null },
  jobs: [],
  jobsKey: "",
  expanded: new Set(),
  selection: new Map(),
  icons: new Map(),
  assignment: null,
  connectJob: null
};

// ---------- small helpers ----------

function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === "class") el.className = value;
    else if (key === "text") el.textContent = value;
    else if (key.startsWith("on")) el.addEventListener(key.slice(2), value);
    else if (key === "dataset") Object.assign(el.dataset, value);
    else if (value === true) el.setAttribute(key, "");
    else el.setAttribute(key, value);
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

const glyph = (code, cls) => h("span", { class: "icon" + (cls ? " " + cls : ""), "aria-hidden": "true", text: code });

// Package descriptions are Markdown; shown as plain text (never as HTML)
function markdownToText(md) {
  return String(md)
    .replace(/\r/g, "")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/^#{1,6}\s*/gm, "")
    .replace(/(\*\*|__)(.*?)\1/g, "$2")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/^\s*[-*]\s+/gm, "• ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function safeUrl(url) {
  try {
    const parsed = new URL(url);
    return parsed.protocol === "http:" || parsed.protocol === "https:" ? parsed.href : null;
  } catch (e) { return null; }
}

function initials(text) {
  const words = String(text || "?").replace(/[^A-Za-z0-9 ]/g, " ").trim().split(/\s+/);
  return ((words[0] || "?")[0] + (words[1] ? words[1][0] : "")).toUpperCase();
}

function formatDate(value) {
  if (!value) return "";
  const date = new Date(value);
  return isNaN(date) ? "" : date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

function formatNumber(value) {
  const number = Number(value);
  return isFinite(number) && value !== null && value !== "" ? number.toLocaleString() : "";
}

function duration(start, end) {
  if (!start) return "";
  const seconds = Math.max(0, Math.round(((end ? new Date(end) : new Date()) - new Date(start)) / 1000));
  return seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
}

async function api(path, options = {}) {
  const init = { method: options.method || "GET", headers: { "X-Session-Token": TOKEN } };
  if (options.body !== undefined) {
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(options.body);
  }
  let response;
  try {
    response = await fetch(path, init);
  } catch (e) {
    console.error(`${init.method} ${path} failed:`, e);
    throw new Error("The GUI server is not reachable. Was Start-IntuneChocoGui.ps1 closed?");
  }
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
  if (!response.ok) throw new Error((data && data.error) || `Request failed (${response.status})`);
  return data;
}

function toast(text, kind = "info") {
  const code = kind === "ok" ? G.check : kind === "err" ? G.warn : G.info;
  const el = h("div", { class: `toast ${kind}`, role: "status" }, glyph(code), h("div", { class: "toast-text", text }));
  document.getElementById("toasts").append(el);
  setTimeout(() => el.remove(), kind === "err" ? 9000 : 5000);
}

function appIcon(name, url, size, base64) {
  const el = h("div", { class: "app-icon" + (size ? " " + size : "") });
  const src = base64 ? `data:image/png;base64,${base64}` : safeUrl(url);
  if (src) {
    const img = h("img", { src, alt: "", loading: "lazy", referrerpolicy: "no-referrer" });
    img.addEventListener("error", () => { el.classList.remove("has-img"); el.textContent = initials(name); });
    el.classList.add("has-img");
    el.append(img);
  } else {
    el.textContent = initials(name);
  }
  return el;
}

function dialog(title, body, okText = "OK", cancelText = "Cancel") {
  return new Promise((resolve) => {
    const dlg = h("dialog", { class: "modal" },
      h("h2", { class: "modal-title", text: title }),
      h("div", { class: "modal-body" }, body),
      h("div", { class: "modal-actions" },
        cancelText ? h("button", { class: "btn", onclick: () => dlg.close("cancel"), text: cancelText }) : null,
        h("button", { class: "btn primary", onclick: () => dlg.close("ok"), text: okText })
      )
    );
    dlg.addEventListener("close", () => { resolve(dlg.returnValue === "ok"); dlg.remove(); });
    document.body.append(dlg);
    dlg.showModal();
  });
}

// ---------- derived data ----------

function connected() { return !!(state.server && state.server.connected); }

function tenantPackages() {
  const set = new Set();
  for (const app of state.tenant.apps || []) {
    if (app.package) set.add(app.package.toLowerCase());
    if (app.displayName) set.add("name:" + app.displayName.toLowerCase());
  }
  return set;
}

function isDeployed(item, deployed) {
  if (!state.tenant.apps) return false;
  const title = item.meta && item.meta.Title ? item.meta.Title.toLowerCase() : null;
  return deployed.has(item.id.toLowerCase()) || (title && deployed.has("name:" + title));
}

// Selection and custom icons are keyed by the lower-case id: the feed's spelling (GoogleChrome) arrives later than the catalog's (googlechrome)
const keyOf = (id) => String(id).toLowerCase();

function select(view) {
  state.selection.set(keyOf(view.id), { id: view.id, name: view.name, licenseNote: view.licenseNote });
}

function iconFor(id) {
  const key = keyOf(id);
  const sources = [...state.catalog, ...(state.search.results || [])];
  const hit = sources.find((i) => keyOf(i.id) === key || (i.meta && i.meta.Name && keyOf(i.meta.Name) === key));
  return hit && hit.meta ? hit.meta.IconUrl : null;
}

function packageView(item) {
  const meta = item.meta || {};
  return {
    id: meta.Name || item.id,
    name: item.name || meta.Title || item.id,
    version: meta.Version || "",
    iconUrl: meta.IconUrl || null,
    licenseNote: item.licenseNote || meta.LicenseNote || null,
    found: meta.Found !== false,
    loaded: !!item.meta,
    downloads: meta.Downloads
  };
}

// ---------- header, nav, selection bar ----------

function renderAccount() {
  const root = document.getElementById("account");
  root.replaceChildren();
  const server = state.server;
  if (!server) return;

  if (server.connected) {
    const identity = server.identity || {};
    root.append(
      h("div", { class: "account-pill", title: identity.account || "" },
        h("div", { class: "avatar", text: initials(identity.name || identity.account) }),
        h("div", { class: "account-text" },
          h("div", { class: "account-name", text: identity.name || identity.account || "Signed in" }),
          h("div", { class: "account-tenant", text: server.settings.TenantID })
        ),
        h("span", { class: "dot on", title: "Connected" })
      ),
      h("button", { class: "btn subtle", onclick: signOut, text: "Sign out" })
    );
  } else {
    const busy = !!state.connectJob;
    root.append(
      h("div", { class: "account-pill" },
        h("div", { class: "avatar", text: "?" }),
        h("div", { class: "account-text" },
          h("div", { class: "account-name", text: busy ? "Signing in..." : "Not connected" }),
          h("div", { class: "account-tenant", text: server.settings.TenantID || "No tenant configured" })
        ),
        busy ? h("span", { class: "spinner" }) : h("span", { class: "dot" })
      ),
      h("button", { class: "btn primary", onclick: signIn, disabled: busy, text: "Sign in" })
    );
  }
}

function renderNav() {
  for (const item of document.querySelectorAll(".nav-item[data-view]")) {
    item.classList.toggle("active", item.dataset.view === state.view);
  }
  const running = state.jobs.filter((j) => j.status === "queued" || j.status === "running").length;
  const badge = document.getElementById("activity-badge");
  badge.hidden = running === 0;
  badge.textContent = running;
  const server = state.server;
  if (server) {
    document.getElementById("nav-foot").replaceChildren(
      h("div", { text: `Version ${server.version}` }),
      h("div", { text: `PowerShell ${server.powershell}` }),
      h("div", { text: `IntuneWin32App ${server.moduleVersion || "missing"}` })
    );
  }
}

function renderSelectionBar() {
  const bar = document.getElementById("selection-bar");
  const count = state.selection.size;
  bar.hidden = count === 0 || state.view === "settings";
  if (bar.hidden) return;
  if (!state.assignment) state.assignment = (state.server && state.server.settings.Assignment) || "Available";

  const items = [...state.selection.values()];
  const icons = h("div", { class: "selection-icons" }, items.slice(0, 5).map((p) => appIcon(p.name, iconFor(p.id), "sm", state.icons.get(keyOf(p.id)))));
  const segmented = h("div", { class: "segmented", role: "radiogroup", "aria-label": "Assignment" },
    ASSIGNMENTS.map((a) => h("button", {
      class: state.assignment === a.value ? "active" : "",
      title: a.help, role: "radio", "aria-checked": String(state.assignment === a.value),
      onclick: () => { state.assignment = a.value; renderSelectionBar(); },
      text: a.label
    }))
  );
  bar.replaceChildren(
    icons,
    h("div", { class: "selection-count", text: `${count} app${count === 1 ? "" : "s"} selected` }),
    h("div", { class: "selection-sep" }),
    segmented,
    h("button", { class: "btn subtle", onclick: () => { state.selection.clear(); renderAll(); }, text: "Clear" }),
    h("button", {
      class: "btn primary", disabled: !connected(), onclick: () => deploy(items),
      title: connected() ? "" : "Sign in first"
    }, glyph(G.cloud), "Deploy to Intune")
  );
}

// ---------- views ----------

function pageHead(title, sub, ...actions) {
  return h("div", { class: "page-head" },
    h("div", {}, h("h1", { class: "page-title", text: title }), sub ? h("p", { class: "page-sub", text: sub }) : null),
    actions.length ? h("div", { class: "toolbar", style: null }, actions) : null
  );
}

function statusBanners() {
  const server = state.server;
  if (!server) return [];
  const banners = [];
  if (!server.moduleOk) {
    banners.push(h("div", { class: "banner err" }, glyph(G.warn),
      h("div", { class: "banner-body" },
        h("div", { class: "banner-title", text: `IntuneWin32App ${server.moduleMinimum} or newer is required` }),
        h("p", { text: server.moduleVersion ? `Installed: ${server.moduleVersion}.` : "The module is not installed." }),
        h("div", { class: "banner-actions" }, h("button", { class: "btn primary", onclick: installComponents, text: "Install module" }))
      )));
  }
  if (!server.connected) {
    const configured = server.settings.TenantID && server.settings.ClientID;
    banners.push(h("div", { class: "banner" }, glyph(G.person),
      h("div", { class: "banner-body" },
        h("div", { class: "banner-title", text: configured ? "Sign in to deploy" : "Connect your Intune tenant" }),
        h("p", { text: configured
          ? "You can browse and select apps already. Deploying needs a sign-in to " + server.settings.TenantID + "."
          : "Enter your tenant and the client ID of your app registration in Settings, then sign in." }),
        h("div", { class: "banner-actions" },
          configured ? h("button", { class: "btn primary", onclick: signIn, disabled: !!state.connectJob, text: "Sign in" }) : null,
          h("button", { class: "btn", onclick: () => go("settings"), text: "Open settings" })
        )
      )));
  }
  return banners;
}

function packageCard(item, deployed) {
  const view = packageView(item);
  const key = keyOf(view.id);
  const selected = state.selection.has(key);
  const inTenant = isDeployed(item, deployed);
  const badges = [];
  if (inTenant) badges.push(h("span", { class: "badge ok" }, glyph(G.check), "In tenant"));
  if (view.licenseNote) badges.push(h("span", { class: "badge warn", title: view.licenseNote }, glyph(G.shield), "License"));
  if (!view.found) badges.push(h("span", { class: "badge err" }, "Not on feed"));
  if (state.icons.has(key)) badges.push(h("span", { class: "badge muted" }, "Custom icon"));

  const meta = view.loaded ? [view.id, view.version].filter(Boolean).join(" · ") : view.id;
  const toggle = () => {
    if (!view.found) { toast(`${view.id} was not found on the package feed`, "err"); return; }
    if (selected) state.selection.delete(key);
    else select(view);
    renderContent();
    renderSelectionBar();
  };
  return h("div", {
    class: "card" + (selected ? " selected" : "") + (inTenant ? " deployed" : ""),
    role: "checkbox", tabindex: "0", "aria-checked": String(selected),
    title: inTenant ? "Already in the tenant" : "",
    onclick: toggle,
    onkeydown: (e) => { if (e.key === " " || e.key === "Enter") { e.preventDefault(); toggle(); } }
  },
    h("span", { class: "check", "aria-hidden": "true", text: G.check }),
    appIcon(view.name, view.iconUrl, null, state.icons.get(key)),
    h("div", { class: "card-body" },
      h("div", { class: "card-title", text: view.name }),
      h("div", { class: "card-meta" + (view.loaded ? "" : " muted"), text: meta }),
      badges.length ? h("div", { class: "card-badges" }, badges) : null
    ),
    h("button", {
      class: "btn subtle", title: "Details", "aria-label": `Details for ${view.name}`,
      onclick: (e) => { e.stopPropagation(); openDrawer(view.id, view.name); }
    }, glyph(G.info))
  );
}

function renderCatalog() {
  const categories = ["All", ...new Set(state.catalog.map((i) => i.category))];
  const filter = state.filter.trim().toLowerCase();
  const visible = state.catalog.filter((i) =>
    (state.category === "All" || i.category === state.category) &&
    (!filter || i.name.toLowerCase().includes(filter) || i.id.toLowerCase().includes(filter)));
  const deployed = tenantPackages();

  const filterInput = h("input", {
    class: "input search", id: "catalog-filter", type: "search", placeholder: "Filter the catalog",
    value: state.filter, "aria-label": "Filter the catalog",
    oninput: (e) => { state.filter = e.target.value; renderContent(); }
  });
  const chips = h("div", { class: "chips", role: "tablist" }, categories.map((c) => h("button", {
    class: "chip" + (state.category === c ? " active" : ""), role: "tab", "aria-selected": String(state.category === c),
    onclick: () => { state.category = c; renderContent(); }
  }, c, h("span", { class: "count", text: c === "All" ? state.catalog.length : state.catalog.filter((i) => i.category === c).length }))));

  const selectable = visible.map(packageView).filter((v) => v.found);
  const allSelected = selectable.length > 0 && selectable.every((v) => state.selection.has(keyOf(v.id)));

  const sections = [];
  const groups = state.category === "All" ? categories.slice(1) : [state.category];
  for (const group of groups) {
    const items = visible.filter((i) => i.category === group);
    if (!items.length) continue;
    sections.push(h("h2", { class: "category-title", text: group }));
    sections.push(h("div", { class: "grid" }, items.map((i) => packageCard(i, deployed))));
  }

  return [
    pageHead("Software catalog", "Curated Chocolatey packages, ready for Intune. Click apps to select them, then deploy.",
      state.catalogLoading ? h("span", { class: "badge muted" }, h("span", { class: "spinner" }), "Loading package info") : null,
      h("button", {
        class: "btn", disabled: selectable.length === 0,
        onclick: () => {
          for (const v of selectable) {
            if (allSelected) state.selection.delete(keyOf(v.id));
            else select(v);
          }
          renderAll();
        },
        text: allSelected ? "Deselect visible" : "Select visible"
      })
    ),
    ...statusBanners(),
    h("div", { class: "toolbar" }, h("div", { class: "search-wrap" }, glyph(G.search), filterInput)),
    h("div", { class: "toolbar" }, chips),
    sections.length ? sections : h("div", { class: "empty" }, glyph(G.search), h("div", { class: "empty-title", text: "Nothing matches" }), "Try another filter, or search the whole Chocolatey repository.")
  ];
}

function renderSearch() {
  const run = async () => {
    const q = state.search.q.trim();
    if (q.length < 2) { toast("Enter at least two characters", "err"); return; }
    state.search.loading = true;
    state.search.error = null;
    renderContent();
    try {
      state.search.results = await api("/api/search?q=" + encodeURIComponent(q));
    } catch (e) {
      state.search.error = e.message;
    }
    state.search.loading = false;
    renderContent();
  };
  const input = h("input", {
    class: "input search", id: "search-input", type: "search", placeholder: "e.g. chrome, pdf, zip",
    value: state.search.q, "aria-label": "Search Chocolatey packages",
    oninput: (e) => { state.search.q = e.target.value; },
    onkeydown: (e) => { if (e.key === "Enter") run(); }
  });

  let body;
  if (state.search.loading) {
    body = h("div", { class: "grid" }, Array.from({ length: 6 }, () => h("div", { class: "card skeleton", style: null }, h("div", { class: "app-icon" }), h("div", { class: "card-body" }, " "))));
  } else if (state.search.error) {
    body = h("div", { class: "banner err" }, glyph(G.warn), h("div", { class: "banner-body" }, h("div", { class: "banner-title", text: "Search failed" }), h("p", { text: state.search.error })));
  } else if (state.search.results === null) {
    body = h("div", { class: "empty" }, glyph(G.search), h("div", { class: "empty-title", text: "Search the Chocolatey community repository" }), "More than 10,000 packages. Results show the latest version.");
  } else if (state.search.results.length === 0) {
    body = h("div", { class: "empty" }, glyph(G.search), h("div", { class: "empty-title", text: "No packages found" }), "Try a shorter or different term.");
  } else {
    const deployed = tenantPackages();
    body = h("div", { class: "grid" }, state.search.results.map((r) => packageCard(r, deployed)));
  }

  return [
    pageHead("Search packages", "Find any package on community.chocolatey.org and deploy it like a catalog app."),
    ...statusBanners(),
    h("div", { class: "toolbar" }, h("div", { class: "search-wrap" }, glyph(G.search), input), h("button", { class: "btn primary", onclick: run, text: "Search" })),
    body
  ];
}

function renderTenant() {
  const refresh = h("button", { class: "btn", onclick: () => loadTenant(true), disabled: !connected() || state.tenant.loading }, glyph(G.refresh), "Refresh");
  const head = pageHead("In your tenant", "Win32 apps this tool created in Intune.", refresh);
  if (!connected()) {
    return [head, ...statusBanners(), h("div", { class: "empty" }, glyph(G.cloud), h("div", { class: "empty-title", text: "Not signed in" }), "Sign in to see which apps are already deployed.")];
  }
  if (state.tenant.error) {
    return [head, h("div", { class: "banner err" }, glyph(G.warn), h("div", { class: "banner-body" }, h("div", { class: "banner-title", text: "Could not read the tenant" }), h("p", { text: state.tenant.error })))];
  }
  if (!state.tenant.apps) {
    if (!state.tenant.loading) loadTenant(false);
    return [head, h("div", { class: "empty" }, h("span", { class: "spinner", style: null }), h("div", { class: "empty-title", text: "Reading apps from Intune" }))];
  }
  if (state.tenant.apps.length === 0) {
    return [head, h("div", { class: "empty" }, glyph(G.pkg), h("div", { class: "empty-title", text: "No apps yet" }), "Deploy your first app from the catalog.")];
  }
  const apps = [...state.tenant.apps].sort((a, b) => (b.isChocolatey - a.isChocolatey) || a.displayName.localeCompare(b.displayName));
  const updates = apps.filter(updateAvailable).length;
  return [
    head,
    updates ? h("div", { class: "banner warn" }, glyph(G.sync), h("div", { class: "banner-body" },
      h("div", { class: "banner-title", text: `${updates} update${updates === 1 ? "" : "s"} to release` }),
      h("p", { text: "These apps are pinned to a version and the package feed has a newer one. Release it with the button in the row: devices install it according to the app's update mode." }))) : null,
    h("table", { class: "table" },
      h("thead", {}, h("tr", {}, h("th", { text: "App" }), h("th", { text: "Version" }), h("th", { text: "Updates" }), h("th", { text: "" }))),
      h("tbody", {}, apps.map((app) => h("tr", {},
        h("td", {}, h("div", { class: "cell-app" }, appIcon(app.displayName, app.iconUrl, "sm"),
          h("div", {},
            h("div", { text: app.displayName }),
            app.isChocolatey ? h("span", { class: "badge" }, "Package manager, dependency of all apps")
              : app.package ? h("span", { class: "mono muted", text: app.package }) : h("span", { class: "muted", text: "created by an older version" })))),
        h("td", {}, versionCell(app)),
        h("td", {}, updatesCell(app)),
        h("td", {}, h("div", { class: "toolbar" }, appActions(app)))
      )))
    )
  ];
}

// A pinned app whose package has a newer version on the feed
function updateAvailable(app) {
  return !app.isChocolatey && app.version && app.latest && compareVersions(app.latest, app.version) > 0;
}

function versionCell(app) {
  if (app.isChocolatey) return h("span", { class: "muted", text: "latest" });
  if (app.version) {
    return h("div", {},
      h("div", { text: app.version }),
      updateAvailable(app) ? h("span", { class: "badge warn" }, glyph(G.up), `${app.latest} available`) : h("span", { class: "muted", text: "released version" }));
  }
  return h("div", {}, h("div", { text: "Always latest" }), app.latest ? h("span", { class: "muted", text: `feed: ${app.latest}` }) : null);
}

function updatesCell(app) {
  if (app.isChocolatey || !app.package) return h("span", { class: "muted", text: "" });
  return h("div", {},
    h("div", { text: modeText(app.updateMode, app.graceHours) }),
    app.hasPolicy ? null : h("span", { class: "muted", text: "older app: Update settings rolls out the new scripts" }));
}

function appActions(app) {
  const intune = h("a", {
    class: "btn subtle",
    href: `https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/${encodeURIComponent(app.id)}`,
    target: "_blank", rel: "noopener noreferrer", title: "Open in the Intune admin center"
  }, glyph(G.open));
  if (app.isChocolatey || !app.package) return [intune];
  return [
    updateAvailable(app) ? h("button", { class: "btn primary", onclick: () => releaseUpdate(app), title: `Release version ${app.latest}` }, glyph(G.up), "Release") : null,
    h("button", { class: "btn", onclick: () => editPolicy(app), title: "Version, update mode and grace period" }, glyph(G.settings), "Update settings"),
    testButton({ id: app.package, name: app.displayName, version: app.version || "latest", updateMode: app.updateMode, graceHours: app.graceHours }, true),
    intune
  ];
}

function testButton(pkg, small) {
  const available = state.server && state.server.sandboxStudio;
  return h("button", {
    class: small ? "btn subtle" : "btn", disabled: !available,
    title: available ? "Test in Windows Sandbox: Install, Detect, Uninstall in the Win32 Test Lab of MSIX Sandbox Studio" : "MSIX Sandbox Studio (WindowsSandboxMSIXInstaller) was not found, see Settings",
    onclick: () => testPackage(pkg)
  }, glyph(G.play), small ? "Test" : "Test in sandbox");
}

const KIND_LABEL = { deploy: "Deployment", connect: "Sign-in", components: "Setup", policy: "Update settings", test: "Sandbox test" };

function jobStatus(job) {
  switch (job.status) {
    case "running": return [h("span", { class: "spinner" }), h("span", { class: "badge", text: "Running" })];
    case "queued": return [h("span", { class: "status-icon queued", text: G.clock }), h("span", { class: "badge muted", text: "Waiting" })];
    case "succeeded": return [h("span", { class: "status-icon ok", text: G.check }), h("span", { class: "badge ok", text: "Done" })];
    case "skipped": return [h("span", { class: "status-icon skip", text: G.minus }), h("span", { class: "badge muted", text: "Skipped" })];
    default: return [h("span", { class: "status-icon err", text: G.cancel }), h("span", { class: "badge err", text: "Failed" })];
  }
}

function renderActivity() {
  const finished = state.jobs.filter((j) => ["succeeded", "failed", "skipped"].includes(j.status)).length;
  const head = pageHead("Activity", "Deployments run one after another in the background. You can keep browsing.",
    h("button", { class: "btn", disabled: finished === 0, onclick: clearJobs }, glyph(G.trash), "Clear finished"));
  if (state.jobs.length === 0) {
    return [head, h("div", { class: "empty" }, glyph(G.clock), h("div", { class: "empty-title", text: "Nothing happened yet" }), "Deployments and sign-ins show up here with their full log.")];
  }
  const jobs = [...state.jobs].reverse();
  return [head, jobs.map((job) => {
    const open = state.expanded.has(job.id);
    const last = job.log.length ? job.log[job.log.length - 1].text : "";
    const sub = [KIND_LABEL[job.kind] || job.kind, job.package, job.started ? duration(job.started, job.finished) : "waiting"].filter(Boolean).join(" · ");
    return h("div", { class: "job" },
      h("button", {
        class: "job-head", "aria-expanded": String(open),
        onclick: () => { if (open) state.expanded.delete(job.id); else state.expanded.add(job.id); renderContent(); }
      },
        h("div", {},
          h("div", { class: "job-title", text: job.title }),
          h("div", { class: "job-sub", text: job.status === "running" && last ? `${sub} · ${last}` : sub })
        ),
        h("div", { class: "job-status" }, jobStatus(job), glyph(open ? G.up : G.down))
      ),
      open ? h("div", { class: "job-log" }, job.log.length
        ? job.log.map((l) => h("div", { class: `log-line ${l.level}` }, h("span", { class: "t", text: l.time }), h("span", { class: "m", text: l.text })))
        : h("div", { class: "muted", text: "No output yet" })) : null
    );
  })];
}

function renderSettings() {
  const server = state.server;
  if (!server) return [];
  const s = server.settings;
  const field = (label, input, help) => [h("label", { for: input.id, text: label }), h("div", { class: "field" }, input, help ? h("div", { class: "help" }, help) : null)];
  const text = (id, value, placeholder) => h("input", { class: "input", id, value: value || "", placeholder: placeholder || "", spellcheck: "false", autocomplete: "off" });
  const select = (id, options, value) => h("select", { class: "select", id }, options.map((o) => h("option", { value: o.value, selected: o.value === value }, o.label)));
  const number = (id, value) => h("input", { class: "input", id, type: "number", min: "0", max: "1440", value: String(value) });

  const updatePolicy = policyControls("s", { updateMode: s.UpdateMode, graceHours: s.GraceHours });
  const collect = () => {
    const policy = updatePolicy.read();
    return {
      TenantID: document.getElementById("s-tenant").value,
      ClientID: document.getElementById("s-client").value,
      Assignment: document.getElementById("s-assignment").value,
      Architecture: document.getElementById("s-arch").value,
      UpdateDelayMinMinutes: Number(document.getElementById("s-delay-min").value),
      UpdateDelayMaxMinutes: Number(document.getElementById("s-delay-max").value),
      UpdateMode: policy.updateMode,
      GraceHours: policy.graceHours,
      VersionMode: document.getElementById("s-version-mode").value,
      SandboxStudioPath: document.getElementById("s-studio").value,
      PackageSource: document.getElementById("s-source").value,
      ChocolateyDownloadUrl: document.getElementById("s-chocourl").value,
      MetadataFeed: document.getElementById("s-feed").value
    };
  };
  const save = async (andConnect) => {
    try {
      // collect() checks the grace period: errors go to the same toast as server errors
      state.server = await api("/api/settings", { method: "POST", body: collect() });
      state.assignment = null;
      toast("Settings saved", "ok");
      renderAll();
      if (andConnect) signIn();
    } catch (e) { toast(e.message, "err"); }
  };

  return [
    pageHead("Settings", "Saved in %LOCALAPPDATA%\\IntuneChocoDeployment\\settings.json on this machine."),
    h("section", { class: "panel" },
      h("h2", { text: "Tenant connection" }),
      h("p", { class: "hint", text: "Sign-in uses your own Entra ID app registration (Microsoft retired the shared Intune PowerShell app)." }),
      h("div", { class: "form" },
        field("Tenant", text("s-tenant", s.TenantID, "contoso.onmicrosoft.com"), "Domain or tenant ID"),
        field("Client ID", text("s-client", s.ClientID, "00000000-0000-0000-0000-000000000000"), "Application (client) ID of the app registration")
      ),
      h("details", { class: "help-box" },
        h("summary", { text: "How to create the app registration" }),
        h("ol", { class: "steps" },
          h("li", {}, "Entra admin center › App registrations › New registration, any name, single tenant."),
          h("li", {}, "Authentication › Add a platform › Mobile and desktop applications › redirect URI ", h("span", { class: "code", text: "http://localhost" }), "."),
          h("li", {}, "API permissions › Microsoft Graph › Delegated: ",
            ["DeviceManagementApps.ReadWrite.All", "DeviceManagementConfiguration.ReadWrite.All", "DeviceManagementRBAC.Read.All", "Group.Read.All"].map((p, i) => [i ? ", " : "", h("span", { class: "code", text: p })]),
            ", then grant admin consent."),
          h("li", {}, "Copy the Application (client) ID into the field above.")
        )
      )
    ),
    h("section", { class: "panel" },
      h("h2", { text: "Deployment defaults" }),
      h("p", { class: "hint", text: "Used for new apps. Existing apps in Intune are not changed." }),
      h("div", { class: "form" },
        field("Assignment", select("s-assignment", ASSIGNMENTS.map((a) => ({ value: a.value, label: `${a.label} – ${a.help}` })), s.Assignment)),
        field("Architecture", select("s-arch", ARCHITECTURES, s.Architecture), "Requirement rule. Windows 10 1607 or newer, which includes all Windows 11 versions."),
        [h("label", { for: "s-delay-min", text: "Update delay" }), h("div", { class: "field" },
          h("div", { class: "range" }, number("s-delay-min", s.UpdateDelayMinMinutes), h("span", { class: "muted", text: "to" }), number("s-delay-max", s.UpdateDelayMaxMinutes), h("span", { class: "muted", text: "minutes after startup" })),
          h("div", { class: "help", text: "Every device picks a random wait in this range for its update task, so a whole office behind one IP does not hit the Chocolatey rate limit (about 20 downloads per minute and IP) at once." }))]
      )
    ),
    h("section", { class: "panel" },
      h("h2", { text: "Updates for new apps" }),
      h("p", { class: "hint", text: "Defaults when deploying; each app can be changed later in In tenant with Update settings, which applies the change in Intune." }),
      h("div", { class: "form" },
        field("Version", select("s-version-mode", VERSION_MODES.map((v) => ({ value: v.value, label: v.label })), s.VersionMode),
          "Pinned apps show available updates in In tenant; you release them with one click.")),
      updatePolicy.el
    ),
    h("section", { class: "panel" },
      h("h2", { text: "Sandbox test" }),
      h("p", { class: "hint", text: "The Test buttons use the Win32 Test Lab of MSIX Sandbox Studio (WindowsSandboxMSIXInstaller) and need Windows Sandbox." }),
      h("div", { class: "form" },
        field("Sandbox Studio path", text("s-studio", s.SandboxStudioPath, "Empty = found automatically"),
          server.sandboxStudio ? `Found: ${server.sandboxStudio}` : "Not found: enter the folder of WindowsSandboxMSIXInstaller, e.g. C:\\git\\WindowsSandboxMSIXInstaller"))
    ),
    h("section", { class: "panel" },
      h("h2", { text: "Package sources" }),
      h("p", { class: "hint", text: "Chocolatey advises organizations not to install directly from the community repository. A caching proxy (ProGet, Nexus, Azure Artifacts) avoids rate limits and outages." }),
      h("div", { class: "form" },
        field("Package source on devices", text("s-source", s.PackageSource, "Empty = community.chocolatey.org"), "Passed to choco as --source, e.g. https://proget.contoso.com/nuget/choco/. Sources that need credentials must be registered on the devices first."),
        field("Chocolatey bootstrap URL", text("s-chocourl", s.ChocolateyDownloadUrl, "Empty = community.chocolatey.org"), "Optional URL of the chocolatey .nupkg the Chocolatey app installs from. Only used when the Chocolatey app is created."),
        field("Metadata feed", text("s-feed", s.MetadataFeed, "https://community.chocolatey.org/api/v2"), "NuGet v2 feed for search, package infos and icons in this tool.")
      )
    ),
    h("section", { class: "panel" },
      h("h2", { text: "Components" }),
      h("p", { class: "hint", text: "Chocolatey and Inkscape are not needed on this machine. SVG icons are converted with Microsoft Edge." }),
      h("div", { class: "list-row" },
        server.moduleOk ? h("span", { class: "badge ok" }, glyph(G.check), `IntuneWin32App ${server.moduleVersion}`) : h("span", { class: "badge err" }, glyph(G.warn), server.moduleVersion ? `IntuneWin32App ${server.moduleVersion} is too old` : "IntuneWin32App missing"),
        h("button", { class: "btn", onclick: installComponents, text: server.moduleOk ? "Update module" : "Install module" })
      )
    ),
    h("div", { class: "form-actions" },
      h("button", { class: "btn", onclick: () => save(false), text: "Save" }),
      h("button", { class: "btn primary", onclick: () => save(true), disabled: !!state.connectJob }, "Save and sign in")
    )
  ];
}

// ---------- drawer ----------

async function openDrawer(id, name) {
  const drawer = document.getElementById("drawer");
  const scrim = document.getElementById("scrim");
  const close = () => { drawer.hidden = true; scrim.hidden = true; document.removeEventListener("keydown", onKey); };
  const onKey = (e) => { if (e.key === "Escape") close(); };
  document.addEventListener("keydown", onKey);
  scrim.onclick = close;
  scrim.hidden = false;
  drawer.hidden = false;
  drawer.replaceChildren(
    h("div", { class: "drawer-head" }, appIcon(name, null, "lg"), h("div", {}, h("h2", { class: "drawer-title", text: name }), h("div", { class: "muted mono", text: id })),
      h("button", { class: "btn subtle drawer-close", onclick: close, "aria-label": "Close" }, glyph(G.cancel))),
    h("div", { class: "drawer-body" }, h("span", { class: "spinner" }))
  );

  let info;
  try {
    info = await api("/api/package?id=" + encodeURIComponent(id));
  } catch (e) {
    drawer.querySelector(".drawer-body").replaceChildren(h("div", { class: "banner err" }, glyph(G.warn), h("div", { class: "banner-body" }, h("div", { class: "banner-title", text: "Package not available" }), h("p", { text: e.message }))));
    return;
  }

  const key = keyOf(info.id);
  const view = { id: info.id, name: info.title, licenseNote: info.licenseNote };
  const render = () => {
    const selected = state.selection.has(key);
    const custom = state.icons.get(key);
    const fileInput = h("input", { type: "file", accept: "image/png,image/jpeg,image/svg+xml,image/x-icon,image/webp,image/gif", hidden: true, onchange: async (e) => {
      const file = e.target.files[0];
      if (!file) return;
      try {
        state.icons.set(key, await fileToPngBase64(file));
        render();
        renderContent();
        renderSelectionBar();
      } catch (err) { toast(err.message, "err"); }
    } });
    const project = safeUrl(info.projectUrl);
    const license = safeUrl(info.licenseUrl);
    const facts = h("dl", { class: "facts" },
      h("dt", { text: "Version" }), h("dd", { text: info.version }),
      info.authors ? [h("dt", { text: "Authors" }), h("dd", { text: info.authors })] : null,
      info.downloads ? [h("dt", { text: "Downloads" }), h("dd", { text: formatNumber(info.downloads) })] : null,
      project ? [h("dt", { text: "Website" }), h("dd", {}, h("a", { href: project, target: "_blank", rel: "noopener noreferrer", text: project }))] : null,
      license ? [h("dt", { text: "License" }), h("dd", {}, h("a", { href: license, target: "_blank", rel: "noopener noreferrer", text: license }))] : null,
      h("dt", { text: "Chocolatey" }), h("dd", {}, h("a", { href: `https://community.chocolatey.org/packages/${encodeURIComponent(info.id)}`, target: "_blank", rel: "noopener noreferrer", text: "Package page" }))
    );
    const toggle = () => {
      if (selected) state.selection.delete(key);
      else select(view);
      render();
      renderContent();
      renderSelectionBar();
    };

    drawer.replaceChildren(
      h("div", { class: "drawer-head" },
        appIcon(info.title, info.iconUrl, "lg", custom),
        h("div", { style: null }, h("h2", { class: "drawer-title", text: info.title }), h("div", { class: "muted mono", text: info.id })),
        h("button", { class: "btn subtle drawer-close", onclick: close, "aria-label": "Close" }, glyph(G.cancel))),
      h("div", { class: "drawer-body" },
        info.licenseNote ? h("div", { class: "banner warn" }, glyph(G.shield), h("div", { class: "banner-body" }, h("div", { class: "banner-title", text: "License note" }), h("p", { text: info.licenseNote }))) : null,
        info.summary ? h("p", { text: info.summary }) : null,
        facts,
        info.description ? h("div", { class: "description", text: markdownToText(info.description) }) : null,
        h("div", { class: "icon-picker" },
          appIcon(info.title, custom ? null : info.iconUrl, "sm", custom),
          h("div", { style: null, class: "card-body" },
            h("div", { class: "card-title", text: custom ? "Custom icon" : info.iconUrl ? "Icon from chocolatey.org" : "No icon on chocolatey.org" }),
            h("div", { class: "card-meta", text: custom ? "Converted to a 256 px PNG" : "PNG, JPEG, SVG or ICO" })),
          fileInput,
          h("button", { class: "btn", onclick: () => fileInput.click() }, glyph(G.upload), custom ? "Replace" : "Choose"),
          custom ? h("button", { class: "btn subtle", title: "Remove custom icon", onclick: () => { state.icons.delete(key); render(); renderContent(); renderSelectionBar(); } }, glyph(G.trash)) : null
        )
      ),
      h("div", { class: "drawer-foot" },
        testButton({ id: info.id, name: info.title }),
        h("button", { class: "btn", onclick: toggle, text: selected ? "Remove from selection" : "Add to selection" }),
        h("button", { class: "btn primary", disabled: !connected(), title: connected() ? "" : "Sign in first",
          onclick: () => { close(); deploy([view]); } }, glyph(G.cloud), "Deploy now")
      )
    );
  };
  render();
}

// Converts any image the browser can show into a square 256 px PNG (same result as the PowerShell side)
function fileToPngBase64(file) {
  return new Promise((resolve, reject) => {
    if (file.size > 4 * 1024 * 1024) { reject(new Error("The icon file is larger than 4 MB")); return; }
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const size = 256;
      const canvas = document.createElement("canvas");
      canvas.width = size;
      canvas.height = size;
      const ctx = canvas.getContext("2d");
      const w = img.naturalWidth || size;
      const hgt = img.naturalHeight || size;
      const scale = Math.min(size / w, size / hgt);
      ctx.drawImage(img, (size - w * scale) / 2, (size - hgt * scale) / 2, w * scale, hgt * scale);
      URL.revokeObjectURL(url);
      resolve(canvas.toDataURL("image/png").split(",")[1]);
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error("This file could not be read as an image")); };
    img.src = url;
  });
}

// ---------- actions ----------

async function deploy(items) {
  if (!items.length) return;
  const notes = items.filter((i) => i.licenseNote);
  const assignment = state.assignment || state.server.settings.Assignment;
  const assignmentLabel = ASSIGNMENTS.find((a) => a.value === assignment);
  const s = state.server.settings;
  const policy = policyControls("d", { updateMode: s.UpdateMode, graceHours: s.GraceHours, version: s.VersionMode === "Pinned" ? "current" : "latest" }, [
    { value: "latest", label: "Always the latest version" },
    { value: "current", label: "Pin the current version (release updates in In tenant)" }
  ]);
  const body = h("div", {},
    h("p", { text: `${items.length} app${items.length === 1 ? "" : "s"} will be created in ${s.TenantID}: ${assignmentLabel.label.toLowerCase()} (${assignmentLabel.help.toLowerCase()}).` }),
    policy.el,
    notes.length ? h("div", { class: "banner warn" }, glyph(G.shield), h("div", { class: "banner-body" },
      h("div", { class: "banner-title", text: "Check the licenses first" }),
      notes.map((n) => h("p", {}, h("strong", { text: n.name + ": " }), n.licenseNote))
    )) : null
  );
  if (!(await dialog("Deploy to Intune?", body, notes.length ? "Licenses are covered, deploy" : "Deploy"))) return;
  let chosen;
  try { chosen = policy.read(); } catch (e) { toast(e.message, "err"); return; }
  try {
    const jobs = await api("/api/deploy", {
      method: "POST",
      body: { assignment, ...chosen, packages: items.map((i) => ({ id: i.id, name: i.name, iconBase64: state.icons.get(keyOf(i.id)) || null })) }
    });
    for (const i of items) state.selection.delete(keyOf(i.id));
    toast(`${jobs.length} deployment${jobs.length === 1 ? "" : "s"} queued`, "ok");
    await loadJobs();
    go("activity");
  } catch (e) { toast(e.message, "err"); }
}

async function applyPolicy(app, body, okText) {
  try {
    await api("/api/app-policy", { method: "POST", body: { id: app.id, name: app.displayName, package: app.package, ...body } });
    toast(`${app.displayName}: ${okText}, see Activity`, "ok");
    await loadJobs();
    go("activity");
  } catch (e) { toast(e.message, "err"); }
}

async function releaseUpdate(app) {
  const body = h("div", {},
    h("p", { text: `${app.displayName} goes from ${app.version} to ${app.latest}. The package is rebuilt and uploaded, Intune then applies it on the devices:` }),
    h("p", { class: "muted", text: modeText(app.updateMode, app.graceHours) + ". " + UPDATE_MODES.find((m) => m.value === app.updateMode).help })
  );
  if (!(await dialog(`Release ${app.latest}?`, body, "Release"))) return;
  await applyPolicy(app, { version: app.latest }, `releasing ${app.latest}`);
}

async function editPolicy(app) {
  let versions = [];
  try { versions = await api("/api/versions?id=" + encodeURIComponent(app.package)); } catch (e) { toast(e.message, "err"); }
  const options = [{ value: "latest", label: "Always the latest version" }];
  for (const v of versions) options.push({ value: v, label: v === app.latest ? `${v} (newest)` : v });
  if (app.version && !versions.includes(app.version)) options.push({ value: app.version, label: app.version });
  const policy = policyControls("p", { updateMode: app.updateMode, graceHours: app.graceHours, version: app.version || "latest" }, options);
  const body = h("div", {},
    h("p", { class: "muted", text: "Applying rebuilds the package and changes the app in Intune. Devices no longer detect it as current and run its install script again, which applies these settings." }),
    policy.el);
  if (!(await dialog(`Update settings: ${app.displayName}`, body, "Apply in Intune"))) return;
  let chosen;
  try { chosen = policy.read(); } catch (e) { toast(e.message, "err"); return; }
  await applyPolicy(app, chosen, "applying the update settings");
}

async function testPackage(pkg) {
  const body = h("div", {},
    h("p", { text: `A fresh Windows Sandbox opens with the Win32 Test Lab of MSIX Sandbox Studio. It installs Chocolatey first (in Intune it is the dependency app), then you run Install, Detect and Uninstall of ${pkg.name} with one click each, as SYSTEM like Intune, and report the result there.` }),
    h("p", { class: "muted", text: `Tested with: ${pkg.version && pkg.version !== "latest" ? "version " + pkg.version : "the latest version"}, updates ${modeText(pkg.updateMode || state.server.settings.UpdateMode, pkg.graceHours || state.server.settings.GraceHours).toLowerCase()}. Windows Sandbox runs one at a time.` })
  );
  if (!(await dialog(`Test ${pkg.name} in the sandbox?`, body, "Start test"))) return;
  try {
    await api("/api/test", { method: "POST", body: { id: pkg.id, name: pkg.name, version: pkg.version, updateMode: pkg.updateMode, graceHours: pkg.graceHours } });
    toast("The sandbox starts, see Activity for the result", "ok");
    await loadJobs();
    go("activity");
  } catch (e) { toast(e.message, "err"); }
}

async function signIn() {
  const s = state.server.settings;
  if (!s.TenantID || !s.ClientID) { go("settings"); toast("Enter tenant and client ID first", "err"); return; }
  try {
    const job = await api("/api/connect", { method: "POST", body: { tenantId: s.TenantID, clientId: s.ClientID } });
    state.connectJob = job.id;
    toast("Complete the sign-in in the browser tab that just opened");
    renderAll();
  } catch (e) { toast(e.message, "err"); }
}

async function signOut() {
  try {
    state.server = await api("/api/disconnect", { method: "POST" });
    state.tenant = { apps: null, loading: false, error: null };
    renderAll();
  } catch (e) { toast(e.message, "err"); }
}

async function installComponents() {
  try {
    await api("/api/components", { method: "POST" });
    toast("Installing the IntuneWin32App module, see Activity");
    await loadJobs();
    go("activity");
  } catch (e) { toast(e.message, "err"); }
}

async function clearJobs() {
  try { await api("/api/jobs/clear", { method: "POST" }); await loadJobs(); renderContent(); } catch (e) { toast(e.message, "err"); }
}

async function quit() {
  const running = state.jobs.filter((j) => j.status === "running" || j.status === "queued").length;
  if (running && !(await dialog("Quit while deployments run?", h("p", { text: `${running} deployment(s) are not finished and will be stopped.` }), "Quit anyway"))) return;
  try { await api("/api/quit", { method: "POST" }); } catch (e) { /* already gone */ }
  stopped = true;
  document.body.replaceChildren(h("div", { class: "empty" }, h("img", { src: "icon.svg", alt: "", class: "brand-icon" }), h("div", { class: "empty-title", text: "Intune Choco Deployment stopped" }), "You can close this tab."));
}

// ---------- data loading ----------

async function loadState() {
  state.server = await api("/api/state");
}

async function loadCatalog() {
  const data = await api("/api/catalog");
  state.catalog = data.items;
  state.catalogLoading = data.loading;
}

async function loadTenant(force) {
  if (!connected()) return;
  state.tenant.loading = true;
  state.tenant.error = null;
  if (state.view === "tenant") renderContent();
  try {
    state.tenant.apps = await api("/api/tenant" + (force ? "?refresh=1" : ""));
  } catch (e) {
    state.tenant.error = e.message;
  }
  state.tenant.loading = false;
  if (["tenant", "catalog", "search"].includes(state.view)) renderContent();
}

async function loadJobs() {
  const previous = new Map(state.jobs.map((j) => [j.id, j.status]));
  state.jobs = await api("/api/jobs");
  let tenantChanged = false;
  for (const job of state.jobs) {
    const before = previous.get(job.id);
    const done = ["succeeded", "failed", "skipped"].includes(job.status);
    if (!done || !before || ["succeeded", "failed", "skipped"].includes(before)) continue;
    if (job.kind === "deploy") {
      tenantChanged = true;
      if (job.status === "succeeded") toast(`${job.title} is in Intune`, "ok");
      else if (job.status === "skipped") toast(`${job.title} was skipped: already in the tenant`);
      else toast(`${job.title} failed, see Activity`, "err");
    }
    if (job.kind === "connect" && job.id === state.connectJob) {
      state.connectJob = null;
      await loadState();
      if (job.status === "succeeded") { toast("Signed in", "ok"); state.tenant.apps = null; loadTenant(false); }
      else toast("Sign-in failed: " + ((job.log.find((l) => l.level === "error") || {}).text || "unknown error"), "err");
    }
    if (job.kind === "components") {
      await loadState();
      toast(job.status === "succeeded" ? "IntuneWin32App is installed" : "Module installation failed, see Activity", job.status === "succeeded" ? "ok" : "err");
    }
  }
  if (tenantChanged) loadTenant(true);
  // Lost track of a sign-in (page reloaded while it ran)
  if (state.connectJob && !state.jobs.some((j) => j.id === state.connectJob)) state.connectJob = null;
  const key = JSON.stringify(state.jobs.map((j) => [j.id, j.status, j.log.length]));
  const changed = key !== state.jobsKey;
  state.jobsKey = key;
  return changed;
}

// ---------- rendering ----------

function renderContent() {
  const content = document.getElementById("content");
  const active = document.activeElement;
  const focusId = active && active.id && content.contains(active) ? active.id : null;
  const caret = focusId && typeof active.selectionStart === "number" ? [active.selectionStart, active.selectionEnd] : null;
  const scroll = content.scrollTop;

  const views = { catalog: renderCatalog, search: renderSearch, tenant: renderTenant, activity: renderActivity, settings: renderSettings };
  content.replaceChildren(...[].concat(views[state.view]()).flat().filter(Boolean));
  content.scrollTop = scroll;

  if (focusId) {
    const el = document.getElementById(focusId);
    if (el) { el.focus(); if (caret && el.setSelectionRange) el.setSelectionRange(caret[0], caret[1]); }
  }
}

function renderAll() {
  renderAccount();
  renderNav();
  renderContent();
  renderSelectionBar();
}

function go(view) {
  if (state.view === view) { renderAll(); return; }
  state.view = view;
  document.getElementById("content").scrollTop = 0;
  renderAll();
}

// ---------- polling ----------

let stopped = false;
let tick = 0;

async function poll() {
  if (stopped) return;
  tick++;
  try {
    const running = state.jobs.some((j) => j.status === "running" || j.status === "queued") || !!state.connectJob;
    let changed = false;
    if (running || state.view === "activity" || tick % 4 === 0) changed = await loadJobs();
    if (tick % 8 === 0) {
      const before = JSON.stringify([state.server && state.server.connected, state.server && state.server.moduleVersion]);
      await loadState();
      if (JSON.stringify([state.server.connected, state.server.moduleVersion]) !== before) { renderAccount(); renderSelectionBar(); if (state.view !== "settings") renderContent(); }
    }
    if (state.catalogLoading) {
      await loadCatalog();
      if (state.view === "catalog") renderContent();
    }
    renderNav();
    renderAccount();
    if (changed && state.view === "activity") renderContent();
  } catch (e) {
    if (tick % 4 === 0) toast(e.message, "err");
  }
  setTimeout(poll, state.jobs.some((j) => j.status === "running") || state.catalogLoading || state.connectJob ? 1200 : 2500);
}

// ---------- start ----------

async function start() {
  for (const item of document.querySelectorAll(".nav-item[data-view]")) item.addEventListener("click", () => go(item.dataset.view));
  document.getElementById("quit").addEventListener("click", quit);
  if (!TOKEN) {
    document.getElementById("content").replaceChildren(h("div", { class: "empty" }, glyph(G.warn), h("div", { class: "empty-title", text: "Session token missing" }), "Start the interface with Start-IntuneChocoGui.ps1, it opens the right address."));
    return;
  }
  try {
    await loadState();
    await Promise.all([loadCatalog(), loadJobs()]);
  } catch (e) {
    document.getElementById("content").replaceChildren(h("div", { class: "empty" }, glyph(G.warn), h("div", { class: "empty-title", text: "Could not start" }), e.message));
    return;
  }
  if (START_VIEW) state.view = START_VIEW;
  else if (!state.server.settings.TenantID || !state.server.settings.ClientID) state.view = "settings";
  renderAll();
  if (connected()) loadTenant(false);
  setTimeout(poll, 1200);
}

start();
