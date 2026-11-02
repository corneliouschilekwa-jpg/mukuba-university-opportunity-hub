// Shared core: Supabase client, auth, layout, helpers.
const CFG = window.HUB_CONFIG || {};
export const configured = !!(CFG.SUPABASE_URL && CFG.SUPABASE_ANON_KEY);
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
export const sb = configured ? createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY) : null;

export const $ = (s, r = document) => r.querySelector(s);
export const $$ = (s, r = document) => [...r.querySelectorAll(s)];
export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
export const fmtDate = (d) => d ? new Date(d).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: d.length > 10 ? "short" : undefined }) : "";
export const label = (s) => String(s || "").replace(/_/g, " ").replace(/^\w/, (c) => c.toUpperCase());
export const badge = (s) => `<span class="badge b-${esc(s)}">${esc(label(s))}</span>`;
export const DAYS = [["mon","Monday"],["tue","Tuesday"],["wed","Wednesday"],["thu","Thursday"],["fri","Friday"],["sat","Saturday"],["sun","Sunday"]];
export const TYPES = { part_time:"Part-time", weekend:"Weekend", internship:"Internship", temporary:"Temporary", attachment:"Attachment", volunteer:"Volunteer", remote:"Remote", holiday:"Holiday", full_time:"Full-time" };

export function msg(el, text, kind = "err") { el.innerHTML = text ? `<div class="notice ${kind}">${esc(text)}</div>` : ""; }
export function friendly(e) {
  const m = e?.message || String(e);
  if (/Failed to fetch|NetworkError/i.test(m)) return "Network problem. Check your connection and try again.";
  return m;
}
export function configBanner() {
  if (configured) return "";
  return `<div class="notice err"><b>Backend not connected.</b> Open <code>web/config.js</code> and add your Supabase URL and anon key (see README). Until then nothing can be saved or loaded.</div>`;
}

export async function session() { if (!sb) return null; const { data } = await sb.auth.getSession(); return data.session; }
export async function me() {
  const s = await session(); if (!s) return null;
  const { data } = await sb.from("profiles").select("*").eq("id", s.user.id).single();
  return data;
}
export async function requireRole(roles) {
  const p = await me();
  if (!p) { location.href = "login.html?next=" + encodeURIComponent(location.pathname.split("/").pop() + location.hash); return null; }
  if (p.suspended) { await sb.auth.signOut(); alert("This account has been suspended. Contact the administration."); location.href = "index.html"; return null; }
  if (!roles.includes(p.role)) { document.body.innerHTML = '<main><div class="notice err">You do not have access to this page.</div><a href="index.html">Home</a></main>'; return null; }
  return p;
}
export async function signOut() { await sb.auth.signOut(); location.href = "index.html"; }

const NAV = [["index.html","Home"],["jobs.html","Jobs"],["loan.html","Business Loans"],["opportunities.html","Opportunities"],["news.html","News & Updates"],["help.html","Help Centre"],["companies.html","Companies"]];
export async function layout(active) {
  const p = sb ? await me().catch(() => null) : null;
  const home = !p ? ["login.html","Login / Register"] : p.role === "admin" || p.role === "loan_officer" ? ["admin.html","Admin"] : p.role === "company" ? ["company.html","My Company"] : ["student.html","My Dashboard"];
  document.body.insertAdjacentHTML("afterbegin", `<header class="site"><div class="nav">
    <a class="brand" href="index.html">MUKUBA <span>OPPORTUNITY HUB</span></a>
    <button class="menu-btn" id="mb" aria-label="Menu">☰</button>
    <nav class="links" id="lk">${NAV.map(([h, t]) => `<a href="${h}" class="${h === active ? "on" : ""}">${t}</a>`).join("")}
      <a href="${home[0]}" class="${home[0] === active ? "on" : ""}">${home[1]}</a></nav>
    ${p ? `<button class="bell" id="bell" title="Notifications">🔔<b id="bn" hidden>0</b></button><button class="btn sm ghost" id="so">Sign out</button>` : ""}
  </div></header>`);
  document.body.insertAdjacentHTML("beforeend", `<footer>© Mukuba University Student Opportunity Hub · <a href="privacy.html">Privacy Policy</a> · <a href="terms.html">Terms of Use</a></footer>`);
  $("#mb").onclick = () => $("#lk").classList.toggle("open");
  if (p) { $("#so").onclick = signOut; $("#bell").onclick = openNotifications; refreshBell(); }
  return p;
}

export async function refreshBell() {
  const { count } = await sb.from("notifications").select("id", { count: "exact", head: true }).eq("read", false);
  const b = $("#bn"); if (b) { b.textContent = count || 0; b.hidden = !count; }
}
async function openNotifications() {
  const { data, error } = await sb.from("notifications").select("*").order("created_at", { ascending: false }).limit(50);
  const bg = document.createElement("div"); bg.className = "modal-bg";
  bg.innerHTML = `<div class="modal"><div style="display:flex;justify-content:space-between;gap:8px"><h2>Notifications</h2>
    <div><button class="btn sm ghost" id="mr">Mark all read</button> <button class="btn sm" id="cl">Close</button></div></div>
    ${error ? `<div class="notice err">${esc(friendly(error))}</div>` : !data.length ? '<div class="empty">No notifications yet.</div>' :
      data.map((n) => `<div class="card" style="margin:8px 0;${n.read ? "opacity:.65" : "border-left:4px solid var(--gold)"}">
        <b>${esc(n.title)}</b><div>${esc(n.body)}</div><small>${fmtDate(n.created_at)}</small>
        ${n.link ? ` · <a href="${esc(n.link)}">Open</a>` : ""}</div>`).join("")}</div>`;
  document.body.appendChild(bg);
  $("#cl", bg).onclick = () => bg.remove();
  $("#mr", bg).onclick = async () => { await sb.from("notifications").update({ read: true }).eq("read", false); bg.remove(); refreshBell(); };
}

// Upload to a bucket under <userId>/<random>-<name>; returns storage path
export async function upload(bucket, uid, file) {
  if (file.size > 8 * 1024 * 1024) throw new Error("File is too large (max 8 MB).");
  const ext = (file.name.split(".").pop() || "bin").toLowerCase().replace(/[^a-z0-9]/g, "");
  const path = `${uid}/${crypto.randomUUID()}.${ext}`;
  const { error } = await sb.storage.from(bucket).upload(path, file, { contentType: file.type, upsert: false });
  if (error) throw error;
  return path;
}
export async function signedUrl(bucket, path, secs = 120) {
  const { data, error } = await sb.storage.from(bucket).createSignedUrl(path, secs);
  if (error) throw error; return data.signedUrl;
}
export const publicUrl = (bucket, path) => sb.storage.from(bucket).getPublicUrl(path).data.publicUrl;

export function tabs(el, defs, initial) {
  el.innerHTML = `<div class="tabs">${defs.map(([k, t]) => `<button data-k="${k}">${t}</button>`).join("")}</div><div id="tabbody"></div>`;
  const go = (k) => { $$("button", el).forEach((b) => b.classList.toggle("on", b.dataset.k === k)); history.replaceState(null, "", "#" + k); defs.find((d) => d[0] === k)[2]($("#tabbody", el)); };
  $$("button", el).forEach((b) => (b.onclick = () => go(b.dataset.k)));
  go(defs.some((d) => d[0] === location.hash.slice(1)) ? location.hash.slice(1) : initial || defs[0][0]);
}

export function csv(rows, filename) {
  if (!rows.length) return;
  const keys = Object.keys(rows[0]);
  const cell = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;
  const blob = new Blob([[keys.join(","), ...rows.map((r) => keys.map((k) => cell(r[k])).join(","))].join("\n")], { type: "text/csv" });
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = filename; a.click();
}
