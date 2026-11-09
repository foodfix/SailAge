/* SailAge Model Studio frontend — vanilla JS, no frameworks. */
"use strict";

const $ = (sel, el) => (el || document).querySelector(sel);
const grid = $("#grid");
const cards = new Map();          // job_id -> {root, els, data}
let jobsData = [];
let filter = "all";
let lastCurrent = null;

const CAPTIONS = {
  coast: { draft: "shipped ledger strip (16 tiles)", raw: "re-roll strip",
           snapped: "wang mock preview · live map crop" },
  chrome: { draft: "shipped vendored strip (16 tiles)", raw: "re-roll strip",
            snapped: "nine-patch mock preview" },
  fx: { anim: "staged re-roll (API gif)", comp: "staged wake · frame 0 under the ship",
        shipped: "shipped — in game now" },
  icons: { raw: "staged re-roll (pending accept)", snapped: "canonical raw 64 — the shipped pixels" },
  glyphs: { raw: "staged re-roll (pending accept)", snapped: "canonical raw 64 — the shipped pixels" },
};

// the top-down strip: the compass order with the pinned rotation
// degrees (80-* §4.8 2026-11-07 — clockwise, screen y-down)
const TD_ROTATIONS = [["n", 0], ["ne", 45], ["e", 90], ["se", 135],
  ["s", 180], ["sw", 225], ["w", 270], ["nw", 315]];
const isTd = (job) => job && job.family === "topdown";
const isFx = (job) => job && job.family === "fx";
// a wake card's thumb kinds, in display order
const FX_KINDS = ["anim", "comp", "shipped"];

async function api(path, opts) {
  const r = await fetch(path, opts);
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || r.statusText);
  return body;
}

function thumbURL(job, kind) {
  const t = (job.thumbs || {})[kind];
  if (!t) return null;
  return `/thumb/${kind}/${job.id}.png?v=${t.v}`;
}

function statusHTML(job, current, queue) {
  const el = job => {
    // accept→ingest state supersedes the generation status
    const ing = job.ingest;
    if (ing && ing.state) {
      if (ing.state === "queued")
        return { cls: "queued", text: "queued for ingest" };
      if (ing.state === "running")
        return { cls: "generating", text: "ingesting…" };
      if (ing.state === "in-game")
        return { cls: "ingame", text: `in game ✓${ing.accepted_at ? " " + ing.accepted_at : ""} — restart the game to see it` };
      if (ing.state === "rejected")
        return { cls: "band-fail", text: `REJECTED: ${ing.reason || "?"}${ing.detail ? " — " + ing.detail : ""}` };
      if (ing.state === "game-flow-pending")
        return { cls: "queued", text: "accepted (game flow pending)" };
      if (ing.state === "error")
        return { cls: "error", text: `ingest error: ${ing.reason || "?"}` };
    }
    if (current && current.job === job.id) {
      const s = Math.max(0, Math.round(Date.now() / 1000 - current.started_epoch));
      const verb = current.type === "ingest" ? "ingesting" : "generating";
      return { cls: "generating", text: `${verb} ${s}s… (${current.stage})` };
    }
    const qi = queue.indexOf(job.id);
    if (qi >= 0) return { cls: "queued", text: `queued (#${qi + 1})` };
    if (job.status_source === "studio" || job.error) {
      const m = job.metrics || {};
      const extra = [];
      if (job.seconds != null) extra.push(`${job.seconds}s`);
      if (job.seed != null) extra.push(`seed ${job.seed}`);
      if (m.band && m.band.band) extra.push(`${m.band.long_axis_px != null ? m.band.long_axis_px + "px" : "?"} ∈ [${(m.band.band || []).join(",")}]? ${m.band.in_band ? "yes" : "NO"}`);
      if (job.status === "done") return { cls: "done", text: `done · ${extra.join(" · ")}` };
      if (job.status === "band-fail") return { cls: "band-fail", text: `band-fail · ${extra.join(" · ")}` };
      if (job.status === "error") return { cls: "error", text: `error: ${job.error || "?"}` };
    }
    const bits = [`canonical · ${job.status || "?"}`];
    if (job.seed != null) bits.push(`seed ${job.seed}`);
    if (job.seconds != null) bits.push(`${job.seconds}s`);
    return { cls: "", text: bits.join(" · ") };
  };
  const s = el(job);
  return { cls: s.cls, html: s.text };
}

function metricsLine(job) {
  const m = job.metrics;
  if (!m) return "";
  const bits = [];
  if (m.opaque_pct != null) bits.push(`opaque ${m.opaque_pct}%`);
  if (m.bbox && Array.isArray(m.bbox)) bits.push(`bbox [${m.bbox.join(",")}]`);
  if (m.pennant_red_px != null) bits.push(`red ${m.pennant_red_px}px`);
  return bits.join(" · ");
}

function headHTML(job) {
  // single source for the card head — buildCard and updateCard share it,
  // so a stale element reference can never come back
  const label = job.label || job.id;
  const acc = job.accepted;
  return `<span class="jid">${job.id}</span>
    <span class="lbl">${label}</span>
    <span class="badge acc" style="${acc ? "" : "display:none"}"
      title="${acc ? "accepted " + (acc.at || "") + " (" + (acc.source || "?") + ")" : ""}">★ accepted</span>`;
}

function buildCard(job) {
  const root = document.createElement("div");
  root.className = "card";
  root.dataset.job = job.id;
  const head = document.createElement("div");
  head.className = "card-head";
  head.innerHTML = headHTML(job);
  const isTdCard = job.family === "topdown";
  const isFxCard = isFx(job);
  let thumbs, strip = null;
  if (isTdCard) {
    // the top-down ship strip: one cell per heading (the raw generation
    // IS the art — no draft/raw/snapped trio, no gates); each cell
    // previews the runtime rotation of ONE north token
    strip = document.createElement("div");
    strip.className = "pxstrip";
    const cells = TD_ROTATIONS.map(([d, deg]) => [d, deg]);
    for (const [dir, deg] of cells) {
      const cell = document.createElement("div");
      cell.className = "thumb pxcell";
      cell.dataset.dir = dir;
      cell.innerHTML = `<img alt="${dir}"${deg === null
        ? "" : ` style="image-rendering:pixelated;transform:rotate(0deg)"`}`
        + `<div class="cap">${dir}${deg === null ? "" : " " + deg + "°"}</div>`;
      const img = $("img", cell);
      img.addEventListener("error", () => { cell.classList.add("missing"); });
      strip.appendChild(cell);
    }
    thumbs = strip;
  } else {
    thumbs = document.createElement("div");
    thumbs.className = "thumbs";
    const kinds = isFxCard ? FX_KINDS
      : job.family === "icons" || job.family === "glyphs"
        ? ["raw", "snapped"]   // prompt-only: no draft input image
        : ["draft", "raw", "snapped"];
    const caps = CAPTIONS[job.family] || {};
    const last = kinds[kinds.length - 1];
    for (const kind of kinds) {
      const d = document.createElement("div");
      d.className = "thumb";
      d.innerHTML = `<img alt="${kind}"><div class="cap">${caps[kind] || kind}</div>`;
      const img = $("img", d);
      img.addEventListener("error", () => { d.classList.add("missing"); });
      d.dataset.kind = kind;
      thumbs.appendChild(d);
      if (kind !== last) {
        const ar = document.createElement("span");
        ar.className = "arrow"; ar.textContent = "→";
        thumbs.appendChild(ar);
      }
    }
  }
  const taWrap = document.createElement("div");
  taWrap.className = "ta-wrap";
  const ta = document.createElement("textarea");
  ta.rows = 3;
  if (job.family === "coast") {
    ta.placeholder = "style clause — appended to the vendored sea/land/"
      + "beach descriptions (empty = vendored wording only)";
  } else if (job.family === "chrome") {
    ta.placeholder = "style clause — appended to the pinned frame/button "
      + "tileset descriptions (empty = vendored wording only)";
  }
  ta.spellcheck = false;
  ta.addEventListener("change", () => {
    ta.dataset.dirty = "1";
    savePrompt(job.id, ta.value);
  });
  const srcTag = document.createElement("span");
  srcTag.className = "src-tag";
  srcTag.title = "fidelity of the pre-filled original prompt";
  taWrap.append(ta, srcTag);
  const controls = document.createElement("div");
  controls.className = "controls";
  controls.innerHTML = `
    <button class="orig small" title="Revert the prompt box to the stored original wording">↺ original</button>
    <input class="seed" placeholder="random" inputmode="numeric">
    <button class="reroll">Re-roll</button>
    <button class="accept small">${job.family === "coast"
      || job.family === "chrome" ? "Accept + rebuild" : "Accept"}</button>
    <span class="spacer"></span>`;
  if (isFxCard) {
    // the /v2/vfx envelope has no seed — hide the field
    $(".seed", controls).style.display = "none";
  }
  const status = document.createElement("div");
  status.className = "status";
  const metrics = document.createElement("div");
  metrics.className = "metrics";
  root.append(head, thumbs, taWrap, controls, status, metrics);

  $(".reroll", controls).addEventListener("click", () => reroll(job.id, ta));
  $(".accept", controls).addEventListener("click", () => accept(job.id));
  $(".orig", controls).addEventListener("click", () => restoreOriginal(job.id));
  grid.appendChild(root);
  return { root, els: {
    head, ta, srcTag, status, metrics, seed: $(".seed", controls),
    controls, strip,
  }, data: job };
}

async function savePrompt(jobId, prompt) {
  try {
    await api("/api/prompt", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ job: jobId, prompt }),
    });
  } catch (e) { console.error("prompt save failed", e); }
}

async function restoreOriginal(jobId) {
  const card = cards.get(jobId);
  if (!card) return;
  const original = card.data.original_prompt;
  if (!original) { alert("no original prompt stored yet"); return; }
  try {
    // clear the saved custom edit so generation uses the original again
    await api("/api/prompt", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ job: jobId, prompt: "" }),
    });
  } catch (e) { console.error("prompt clear failed", e); }
  card.els.ta.value = original;      // byte-identical to the stored original
  card.els.ta.dataset.dirty = "";    // let refreshes track the server value
  refreshSoon();
}

async function reroll(jobId, ta) {
  const card = cards.get(jobId);
  const seedRaw = card ? card.els.seed.value.trim() : "";
  const body = { job: jobId };
  if (ta && ta.dataset.dirty === "1") body.prompt = ta.value;
  if (seedRaw) body.seed = Number(seedRaw);
  try {
    await api("/api/reroll", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    refreshSoon();
  } catch (e) { alert(e.message); }
}

async function accept(jobId) {
  try {
    await api("/api/accept", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ job: jobId }),
    });
    refreshSoon();
  } catch (e) { alert(e.message); }
}

$("#reroll-flagged").addEventListener("click", async () => {
  const flagged = jobsData.filter(j => j.flagged).map(j => j.id);
  if (!flagged.length) { alert("nothing is flagged"); return; }
  if (!confirm(`Queue ${flagged.length} flagged job(s) for re-roll?\n` +
               flagged.join("\n"))) return;
  for (const id of flagged) {
    const c = cards.get(id);
    await api("/api/reroll", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ job: id }),
    }).catch(e => alert(`${id}: ${e.message}`));
  }
  refreshSoon();
});

document.querySelectorAll(".tab").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    filter = btn.dataset.f;
    // the Layout tab swaps the card grid for the live layout editor
    document.body.classList.toggle("layout-mode", filter === "layout");
    const lay = document.getElementById("layout");
    if (lay) lay.hidden = filter !== "layout";
    if (filter === "layout") layoutOpen();
    else render();
  });
});

function visible(job) {
  if (filter === "flagged") return job.flagged;
  if (filter === "ingame") return !!(job.ingest && job.ingest.state === "in-game");
  if (filter === "all") return true;
  if (filter === "icons") return job.family === "icons";
  if (filter === "glyphs") return job.family === "glyphs";
  if (filter === "coast") return job.family === "coast";
  if (filter === "chrome") return job.family === "chrome";
  if (filter === "ships") return isTd(job);
  return job.family === filter;
}

function errorCard(jobId, err) {
  // a card that failed to build renders as an isolated error card —
  // ONE bad job must never abort the loop (the all-images-broken bug)
  const root = document.createElement("div");
  root.className = "card error-card";
  root.dataset.job = jobId;
  root.innerHTML = `<div class="card-head"><span class="jid">${jobId}</span></div>
    <div class="status error">⚠ this job failed to render: ${String((err && err.message) || err)}</div>`;
  grid.appendChild(root);
  cards.set(jobId, { root, error: true, els: {}, data: { id: jobId } });
}

function render() {
  if (filter === "layout") return;  // the layout editor owns the page
  const seen = new Set();
  for (const job of jobsData) {
    if (!visible(job)) continue;
    seen.add(job.id);
    try {
      const existing = cards.get(job.id);
      if (!existing || existing.error || existing.root.removed) {
        if (existing) existing.root.remove();
        cards.set(job.id, buildCard(job));
      }
    } catch (e) {
      console.error("card build failed for", job.id, e);
      const old = cards.get(job.id);
      if (old && old.root && !old.root.removed) old.root.remove();
      errorCard(job.id, e);
      continue;
    }
    try {
      updateCard(job);
    } catch (e) {
      console.error("card update failed for", job.id, e);
      // replace with an error card rather than leaving a half-updated one
      const old = cards.get(job.id);
      if (old && old.root && !old.root.removed) old.root.remove();
      errorCard(job.id, e);
    }
  }
  for (const [id, card] of cards) {
    if (!seen.has(id)) { try { card.root.remove(); } catch (e) {} cards.delete(id); }
  }
}

function updateCard(job) {
  const card = cards.get(job.id);
  if (!card || card.error) return;
  const { root, els } = card;
  const current = window._status && window._status.current;
  const queue = (window._status && window._status.queue) || [];
  const thumbs = job.thumbs || {};
  root.classList.toggle("flagged", !!job.flagged);
  root.classList.toggle("accepted", !!job.accepted);
  root.classList.toggle("running", !!(current && current.job === job.id));
  els.head.innerHTML = headHTML(job);
  // thumbs + captions
  if (isTd(job)) {
    // the top-down strip: per-degree rotation previews of ONE north token
    for (const [dir, deg] of TD_ROTATIONS) {
      const cell = root.querySelector(`.pxcell[data-dir="${dir}"]`);
      if (!cell) continue;
      const r = (job.rotations || []).find(x => x.dir === dir);
      const url = r && r.v
        ? `/thumb/td/${job.subject}/${deg}.png?v=${r.v}` : null;
      if (url) {
        cell.classList.remove("missing");
        const img = $("img", cell);
        if (img.dataset.src !== url) { img.dataset.src = url; img.src = url; }
      } else {
        cell.classList.add("missing");
      }
    }
  } else {
    const isFxCard = isFx(job);
    const kinds = isFxCard ? FX_KINDS
      : job.family === "icons" || job.family === "glyphs"
        ? ["raw", "snapped"]   // prompt-only: no draft input image
        : ["draft", "raw", "snapped"];
    const caps = CAPTIONS[job.family] || {};
    for (const kind of kinds) {
      const d = root.querySelector(`.thumb[data-kind="${kind}"]`);
      if (!d) continue;
      const url = isFxCard
        ? (thumbs[kind] ? `/thumb/fx/${job.subject}/${kind}`
           + (kind === "anim" ? ".gif" : ".png") + `?v=${thumbs[kind].v}`
           : null)
        : thumbURL(job, kind);
      $(".cap", d).textContent = caps[kind] || kind;
      if (url) {
        d.classList.remove("missing");
        const img = $("img", d);
        if (img.dataset.src !== url) {
          img.dataset.src = url;
          img.src = url;
        }
      } else {
        d.classList.add("missing");
      }
    }
  }
  // prompt (never stomp user edits; never blank) + fidelity tag
  const ta = els.ta;
  if (document.activeElement !== ta && ta.dataset.dirty !== "1"
      && ta.value !== job.prompt) ta.value = job.prompt || "";
  ta.placeholder = job.prompt ? "" : "prompt unavailable — type here";
  ta.title = job.custom_prompt ? "persisted studio prompt"
    : `original (${job.original_prompt_source})`;
  els.srcTag.textContent = job.original_prompt_source || "default";
  els.srcTag.className = "src-tag " + (job.original_prompt_source || "default");
  const st = statusHTML(job, current, queue);
  els.status.className = `status ${st.cls}`;
  els.status.textContent = st.html;
  els.metrics.textContent = metricsLine(job);
  // disabled states while this card's job runs or waits in the queue
  const busy = (current && current.job === job.id) || queue.includes(job.id);
  for (const b of els.controls.querySelectorAll("button")) {
    b.disabled = !!busy;
  }
  els.seed.placeholder = job.canonical_seed != null
    ? `random (canon ${job.canonical_seed})` : "random";
}

async function refreshJobs() {
  try {
    const data = await api("/api/jobs");
    // top-down ships lead the list, then the wake cards, then icon
    // group sheets, then the rest
    const rank = (f) => (f === "topdown" ? 0 : f === "fx" ? 1
                         : f === "icons" ? 2 : f === "glyphs" ? 3 : 4);
    data.jobs.sort((a, b) => rank(a.family) - rank(b.family));
    jobsData = data.jobs;
    $("#counts-chip").textContent =
      `coast ${data.counts.coast || 0} · chrome ${data.counts.chrome || 0}`
      + ` · top-down ${data.counts.topdown || 0}`
      + ` · wake ${data.counts.fx || 0} · icons ${data.counts.icons || 0}`
      + ` · glyphs ${data.counts.glyphs || 0} — flagged`
      + ` ${data.flagged.length} · in game ${data.counts.ingame || 0}`;
    $("#flagged-n").textContent = data.flagged.length;
    $("#flagged-n2").textContent = data.flagged.length;
    $("#ingame-n").textContent = data.counts.ingame || 0;
    render();
  } catch (e) { console.error(e); }
}

async function refreshStatus() {
  try {
    const st = await api("/api/status");
    window._status = st;
    const chip = $("#worker-chip");
    chip.textContent = `worker: ${st.worker}`;
    chip.className = `chip ${st.worker}`;
    $("#queue-chip").textContent = `queue: ${st.queue.length}`;
    const line = $("#current-line");
    if (st.current) {
      const s = Math.max(0, Math.round(Date.now() / 1000 - st.current.started_epoch));
      const verb = st.current.type === "ingest" ? "ingesting into the game build" : "generating";
      line.textContent = `${st.current.job} — ${verb} (${st.current.stage}) ${s}s`;
      const card = cards.get(st.current.job);
      if (card) {
        try { updateCard(cardsData(st.current.job)); }
        catch (e) { console.error("current-card update failed", e); }
      }
    } else {
      line.textContent = "";
      if (lastCurrent) refreshJobs();  // a job just finished -> pull results
    }
    lastCurrent = st.current && st.current.job;
    render(); // keeps the per-card "generating Ns…" ticker fresh
  } catch (e) { console.error(e); }
}

function cardsData(jobId) {
  return jobsData.find(j => j.id === jobId) || { id: jobId, family: "", label: "", thumbs: {} };
}

function refreshSoon() { setTimeout(refreshJobs, 400); setTimeout(refreshStatus, 400); }

setInterval(refreshStatus, 2000);
setInterval(refreshJobs, 6000);
refreshJobs();
refreshStatus();

/* ==== Layout tab (Phase 11 W5-D — the §4.8.9 visual layout editor) ======
   Live bridge: the BROWSER connects DIRECTLY to the game's LayoutBridge
   ws://127.0.0.1:8765 (90-* §5.7 frozen protocol) — server.py never
   proxies WS. Every edit is sent as its §5.7 message; the game replies
   tree + frame and we re-render. The edit session accumulates here as
   {screen: {element_id: {…overrides}}}, STARTING from the committed
   data/ui_layout.json so edits compose; Commit POSTs the full table and
   the server gates it behind tools/validate_data.py before writing.
   The wire discriminator rides under both `msg` and `type` so either
   reader convention works (the frozen table names messages, not keys). */

const LAY_SHEETS = ["panel", "button", "button_hover", "button_pressed",
  "button_focus", "field", "backdrop"];          // the 7 assignable (§4.8.9)
const LAY_ANCHORS = ["top", "bottom", "left", "right"];
const LAY = {
  ws: null, connected: false, connecting: false, loaded: false,
  screens: [], grid: { w: 60, h: 33 }, tile: 32,
  screen: null, tree: [], sel: null,
  session: {},              // {screen: {id: {…}}} — starts from committed
  committedText: null, drag: null,
};
const DESIGN_W = 1920, DESIGN_H = 1080;   // the locked design canvas (90-* §6)
const layEl = (id) => document.getElementById(id);
const layKind = (e) => String((e && e.kind) || "free");
const layLocked = (e) => !!(e && e.locked);
// an element's anchor: session override first, then the tree's own report
const layAnchor = (id) => {
  const ov = (LAY.session[LAY.screen] || {})[id];
  if (ov && ov.anchor) return ov.anchor;
  const el = LAY.tree.find(e => e.id === id);
  return (el && el.anchor) || null;
};
const layOvr = (id) => (LAY.session[LAY.screen] || {})[id] || null;

function layMsg(text, cls) {
  const el = layEl("lay-msg");
  if (!el) return;
  el.className = `status ${cls || ""}`;
  el.textContent = text || "";
}

function layChip(state, text) {
  const chip = layEl("lay-status"), hint = layEl("lay-hint");
  chip.className = `chip ${state === "connected" ? "idle"
    : state === "error" ? "warn" : state === "connecting" ? "busy" : ""}`;
  chip.textContent = `bridge: ${text}`;
  hint.hidden = state === "connected";
}

function laySend(name, payload) {
  if (!LAY.ws || LAY.ws.readyState !== 1) {
    layMsg("not connected — no edit sent", "error");
    return false;
  }
  const frame = Object.assign({ msg: name, type: name }, payload || {});
  LAY.ws.send(JSON.stringify(frame));
  return true;
}

// merge `patch` into the element's session override; a null value removes
// the key (the Revert semantics — never resurrect a dropped override)
function layPatch(id, patch) {
  const scr = (LAY.session[LAY.screen] = LAY.session[LAY.screen] || {});
  const ov = (scr[id] = scr[id] || {});
  for (const [k, v] of Object.entries(patch)) {
    if (v === null) delete ov[k];
    else ov[k] = v;
  }
  if (!Object.keys(ov).length) delete scr[id];
  layRenderSessionInfo();
}

function layoutOpen() {
  if (!LAY.loaded) {
    LAY.loaded = true;
    layoutWire();
    layoutLoadFile();
  }
  layRenderAll();
}

async function layoutLoadFile() {
  // raw fetch (not api()): the absent file answers 404 with a JSON shape
  let body = null;
  try {
    const r = await fetch("/api/layout/file");
    body = await r.json().catch(() => null);
  } catch (e) { /* server unreachable — degrade below */ }
  const ta = layEl("lay-file"), badge = layEl("lay-valid");
  if (!body || body.content == null) {
    LAY.committedText = null;
    ta.value = "(absent — the game applies code defaults; commit creates it)";
    badge.textContent = "validator: —";
  } else {
    LAY.committedText = body.content;
    ta.value = body.content;
    badge.textContent = "validator: "
      + (body.valid == null ? "—" : body.valid ? "pass" : "FAIL");
    badge.className = "badge " + (body.valid === false ? "pbad"
      : body.valid ? "pok" : "");
    try {
      LAY.session = JSON.parse(body.content);   // session starts committed
      if (typeof LAY.session !== "object" || !LAY.session) LAY.session = {};
    } catch (e) {
      LAY.session = {};
      layMsg("committed ui_layout.json does not parse — session starts empty",
        "error");
    }
  }
  layRenderSessionInfo();
}

function layoutWire() {
  layEl("lay-connect").addEventListener("click", layoutToggle);
  layEl("lay-url").addEventListener("keydown", (e) => {
    if (e.key === "Enter") layoutToggle();
  });
  layEl("lay-commit-btn").addEventListener("click", layoutCommit);
  layEl("lay-revert").addEventListener("click", () => {
    if (!LAY.sel) { layMsg("no element selected", "error"); return; }
    const scr = LAY.session[LAY.screen] || {};
    delete scr[LAY.sel];
    if (LAY.session[LAY.screen] && !Object.keys(LAY.session[LAY.screen]).length)
      delete LAY.session[LAY.screen];
    laySend("revert", { screen: LAY.screen, id: LAY.sel });
    layRenderSessionInfo();
    layMsg(`reverted ${LAY.sel} (code default)`, "done");
  });
  layEl("lay-reset").addEventListener("click", () => {
    if (!LAY.screen) return;
    delete LAY.session[LAY.screen];
    laySend("reset_screen", { screen: LAY.screen });
    layRenderSessionInfo();
    layMsg(`reset screen ${LAY.screen}`, "done");
  });
  // canvas pointer interactions (selection, drag-move, SE resize)
  const canvas = layEl("lay-canvas");
  canvas.addEventListener("mousemove", layDragMove);
  window.addEventListener("mouseup", layDragEnd);
}

function layoutToggle() {
  const btn = layEl("lay-connect");
  if (LAY.ws) {                       // any state → deliberate disconnect
    const was = LAY.connected;
    try { LAY.ws.close(); } catch (e) { /* already gone */ }
    LAY.ws = null;
    LAY.connected = false;
    btn.textContent = "Connect";
    layChip("disconnected", "disconnected");
    layMsg(was ? "disconnected" : "", "");
    return;
  }
  const url = layEl("lay-url").value.trim() || "ws://127.0.0.1:8765";
  layChip("connecting", "connecting…");
  let ws;
  try {
    ws = new WebSocket(url);
  } catch (e) {
    layChip("error", "bad url");
    layMsg(`connect failed: ${e.message}`, "error");
    return;
  }
  LAY.ws = ws;
  LAY.connecting = true;
  btn.textContent = "Disconnect";
  ws.onopen = () => {
    LAY.connected = true; LAY.connecting = false;
    layChip("connected", "connected");
    layMsg("bridge connected — waiting for hello…", "done");
    laySend("get_tree", {});
  };
  ws.onmessage = (ev) => { try { layoutMsg(JSON.parse(ev.data)); } catch (e) { } };
  ws.onerror = () => {
    layChip("error", "error");
    layMsg("websocket error — is the game running with --layout-bridge?", "error");
  };
  ws.onclose = () => {
    LAY.ws = null; LAY.connected = false; LAY.connecting = false;
    btn.textContent = "Connect";
    layChip("disconnected", "disconnected");
  };
}

function layoutMsg(m) {
  const name = m.msg || m.type;
  switch (name) {
    case "hello":
      LAY.screens = Array.isArray(m.screens) ? m.screens : [];
      if (m.grid) LAY.grid = m.grid;
      if (m.tile) LAY.tile = m.tile;
      if (!LAY.screen || !LAY.screens.includes(LAY.screen))
        LAY.screen = LAY.screens[0] || null;
      laySend("get_tree", {});
      layMsg(`hello — ${LAY.screens.length} screen(s)`, "done");
      break;
    case "screen_changed":
      if (m.screen && m.screen !== LAY.screen) {
        LAY.screen = m.screen;
        LAY.sel = null;
        laySend("get_tree", {});
      }
      break;
    case "tree":
      if (m.screen) LAY.screen = m.screen;
      LAY.tree = Array.isArray(m.elements) ? m.elements : [];
      if (LAY.sel && !LAY.tree.some(e => e.id === LAY.sel)) LAY.sel = null;
      layRenderAll();
      break;
    case "frame":
      if (m.png_b64) {
        const img = layEl("lay-frame");
        img.src = "data:image/png;base64," + m.png_b64;
        img.hidden = false;
        layEl("lay-canvas-note").hidden = true;
      }
      break;
    case "error":
      layMsg(`bridge error ${m.code || ""}: ${m.msg || m.message || "?"}`, "error");
      break;
    default:
      break;  // unknown message — ignore (forward compatibility)
  }
}

/* ---- rendering ------------------------------------------------------- */

function layRenderAll() {
  layRenderScreens();
  layRenderTree();
  layRenderBoxes();
  layRenderInspector();
  layRenderSessionInfo();
}

function layRenderScreens() {
  const host = layEl("lay-screens");
  host.textContent = "";
  if (!LAY.screens.length) {
    const s = document.createElement("span");
    s.className = "lbl";
    s.textContent = LAY.connected ? "no screens registered" : "connect for the screen list";
    host.appendChild(s);
    return;
  }
  for (const s of LAY.screens) {
    const b = document.createElement("button");
    b.className = "lay-screen-btn small" + (s === LAY.screen ? " active" : "");
    b.textContent = s;
    b.addEventListener("click", () => {
      if (LAY.screen === s) return;
      LAY.screen = s;
      LAY.sel = null;
      LAY.tree = [];
      laySend("get_tree", {});
      layRenderAll();
    });
    host.appendChild(b);
  }
}

function laySiblings(id) {
  // flat tree → same-parent siblings (hierarchical dotted ids)
  const dot = id.lastIndexOf(".");
  const parent = dot < 0 ? "" : id.slice(0, dot);
  return LAY.tree.filter(e => {
    const eid = e.id || "";
    const d = eid.lastIndexOf(".");
    return (d < 0 ? "" : eid.slice(0, d)) === parent;
  });
}

function layRenderTree() {
  const host = layEl("lay-tree");
  host.textContent = "";
  layEl("lay-els-count").textContent = LAY.tree.length
    ? `(${LAY.tree.length})` : "";
  layEl("lay-screen-name").textContent = LAY.screen
    ? `screen: ${LAY.screen}` : "no screen";
  if (!LAY.tree.length) {
    const s = document.createElement("span");
    s.className = "lbl";
    s.textContent = LAY.connected ? "no tree for this screen"
      : "connect + pick a screen";
    host.appendChild(s);
    return;
  }
  for (const e of LAY.tree) {
    const row = document.createElement("div");
    row.className = "lay-el" + (e.id === LAY.sel ? " active" : "");
    const id = document.createElement("span");
    id.className = "lay-el-id";
    id.textContent = e.id;
    id.title = `${e.id} — ${layKind(e)}${e.role ? ` · ${e.role}` : ""}`;
    row.appendChild(id);
    const ovr = layOvr(e.id);
    if (ovr) {
      const dot = document.createElement("span");
      dot.className = "lay-ovr";
      dot.title = "has a session override";
      dot.textContent = "●";
      row.appendChild(dot);
    }
    if (e.sheet) {
      const tag = document.createElement("span");
      tag.className = "lay-sheet-tag";
      tag.textContent = e.sheet;
      row.appendChild(tag);
    }
    const kind = document.createElement("span");
    kind.className = "lay-kind";
    kind.textContent = layKind(e);
    row.appendChild(kind);
    if (layLocked(e)) {
      const lock = document.createElement("span");
      lock.className = "lay-lock";
      lock.title = "data-pinned order (§4.8.9 locked order) — reorder ignored";
      lock.textContent = "🔒";
      row.appendChild(lock);
    }
    if ((e.id || "").includes(".")) {   // container children: order buttons
      for (const [lbl, delta] of [["▲", -1], ["▼", 1]]) {
        const b = document.createElement("button");
        b.textContent = lbl;
        b.disabled = layLocked(e) || !LAY.connected;
        b.title = `reorder ${e.id} (${delta > 0 ? "later" : "earlier"} sibling)`;
        b.addEventListener("click", (ev) => {
          ev.stopPropagation();
          const sib = laySiblings(e.id);
          const idx = Math.max(0, sib.findIndex(x => x.id === e.id));
          const order = Math.max(0, Math.min(sib.length - 1, idx + delta));
          if (order === idx) return;
          layPatch(e.id, { order });
          laySend("reorder", { screen: LAY.screen, id: e.id, order });
        });
        row.appendChild(b);
      }
    }
    row.addEventListener("click", () => {
      LAY.sel = e.id;
      layRenderTree();
      layRenderBoxes();
      layRenderInspector();
    });
    host.appendChild(row);
  }
}

function layBoxPos(r) {
  // tile rect → % of the 1920×1080 design canvas
  return {
    left: (r.x * LAY.tile / DESIGN_W) * 100,
    top: (r.y * LAY.tile / DESIGN_H) * 100,
    width: (r.w * LAY.tile / DESIGN_W) * 100,
    height: (r.h * LAY.tile / DESIGN_H) * 100,
  };
}

function layRect(e) {
  const r = e && e.rect_tiles;
  return r && [r.x, r.y, r.w, r.h].every(v => typeof v === "number")
    ? { x: r.x, y: r.y, w: r.w, h: r.h } : null;
}

function layRenderBoxes() {
  const host = layEl("lay-boxes");
  host.textContent = "";
  const note = layEl("lay-canvas-note");
  note.hidden = !!LAY.tree.length;
  note.textContent = LAY.connected
    ? (LAY.screen ? "no tree for this screen" : "pick a screen")
    : "no frame — connect the bridge and pick a screen";
  for (const e of LAY.tree) {
    const r = layRect(e);
    if (!r) continue;
    const kind = layKind(e);
    const box = document.createElement("div");
    box.className = "lay-box" + (kind === "child" ? " child" : "")
      + (kind === "plain" ? " plain" : "")
      + (e.id === LAY.sel ? " active" : "");
    const p = layBoxPos(r);
    box.style.left = p.left + "%";
    box.style.top = p.top + "%";
    box.style.width = p.width + "%";
    box.style.height = p.height + "%";
    box.dataset.id = e.id;
    const tag = document.createElement("span");
    tag.className = "lay-box-tag";
    tag.textContent = e.id;
    box.appendChild(tag);
    const dragable = kind !== "child" && !layLocked(e) && LAY.connected;
    box.style.cursor = dragable ? "move" : "default";
    if (dragable || (kind === "child" && LAY.connected)) {
      const se = document.createElement("div");
      se.className = "lay-se";
      se.title = kind === "child" ? "resize (min_w/min_h)" : "resize";
      se.addEventListener("mousedown", (ev) => {
        ev.stopPropagation(); ev.preventDefault();
        LAY.drag = { mode: "resize", e: JSON.parse(JSON.stringify(e)),
                     r: layRect(e) };
        box.classList.add("dragging");
      });
      box.appendChild(se);
    }
    if (dragable) {
      box.addEventListener("mousedown", (ev) => {
        ev.preventDefault();
        const g = layPointerTiles(ev);
        LAY.drag = { mode: "move", e: JSON.parse(JSON.stringify(e)),
                     r: layRect(e),
                     off: { x: g.x - r.x, y: g.y - r.y } };
        box.classList.add("dragging");
      });
    }
    box.addEventListener("click", (ev) => {
      ev.stopPropagation();
      LAY.sel = e.id;
      layRenderTree();
      layRenderBoxes();
      layRenderInspector();
    });
    host.appendChild(box);
  }
}

function layPointerTiles(ev) {
  const c = layEl("lay-canvas").getBoundingClientRect();
  const gridW = LAY.grid.w || 60;
  return {
    x: Math.round((ev.clientX - c.left) / c.width * gridW),
    y: Math.round((ev.clientY - c.top) / c.height * (DESIGN_H / LAY.tile)),
  };
}

function layClampRect(r, gridW) {
  const gw = gridW || LAY.grid.w || 60;
  const w = Math.max(0, Math.min(r.w, gw - r.x));
  const h = Math.max(0, Math.min(r.h, 33 - r.y));
  return { x: Math.max(0, r.x), y: Math.max(0, r.y), w, h };
}

function layDragMove(ev) {
  if (!LAY.drag) return;
  const { mode, e, r, off } = LAY.drag;
  const kind = layKind(e);
  const anchor = layAnchor(e.id);
  const p = layPointerTiles(ev);
  const patchBox = (nr) => {
    const box = layEl("lay-boxes").querySelector(
      `.lay-box[data-id="${CSS.escape(e.id)}"]`);
    if (!box) return;
    const pos = layBoxPos(layClampRect(nr));
    box.style.left = pos.left + "%";
    box.style.top = pos.top + "%";
    box.style.width = pos.width + "%";
    box.style.height = pos.height + "%";
  };
  if (mode === "move") {
    // pointer target = grab point minus the grab offset inside the box
    const tx = off ? p.x - off.x : p.x;
    const ty = off ? p.y - off.y : p.y;
    if (kind === "anchored") {
      // anchored: along-edge drag only (§4.8.9) — top/bottom drag x,
      // left/right drag y; the edge span itself never moves
      if (!anchor || anchor === "top" || anchor === "bottom") {
        const nx = Math.max(0, Math.min(tx, 60 - r.w));
        if (nx === r.x) return;
        LAY.drag.r = Object.assign({}, r, { x: nx });
        patchBox(LAY.drag.r);
        laySend("move", { screen: LAY.screen, id: e.id, x: nx });
        layPatch(e.id, { x: nx });
      } else {
        const ny = Math.max(0, Math.min(ty, 33 - r.h));
        if (ny === r.y) return;
        LAY.drag.r = Object.assign({}, r, { y: ny });
        patchBox(LAY.drag.r);
        laySend("move", { screen: LAY.screen, id: e.id, y: ny });
        layPatch(e.id, { y: ny });
      }
    } else {
      // free/plain: both axes, quantized to tiles, clamped to the grid
      const nx = Math.max(0, Math.min(tx, 60 - r.w));
      const ny = Math.max(0, Math.min(ty, 33 - r.h));
      if (nx === r.x && ny === r.y) return;
      LAY.drag.r = Object.assign({}, r, { x: nx, y: ny });
      patchBox(LAY.drag.r);
      laySend("move", { screen: LAY.screen, id: e.id, x: nx, y: ny });
      layPatch(e.id, { x: nx, y: ny });
    }
  } else if (mode === "resize") {
    if (kind === "child") {
      // container child: SE handle drives custom_minimum_size
      const nw = Math.max(1, p.x - r.x);
      const nh = Math.max(1, p.y - r.y);
      if (nw === (LAY.drag.lastW || 0) && nh === (LAY.drag.lastH || 0)) return;
      LAY.drag.lastW = nw; LAY.drag.lastH = nh;
      laySend("resize", { screen: LAY.screen, id: e.id,
                          min_w: nw, min_h: nh });
      layPatch(e.id, { min_w: nw, min_h: nh });
    } else if (kind === "anchored") {
      // anchored: resize = the span from the anchored edge
      if (!anchor || anchor === "top") {
        const nh = Math.max(1, p.y - r.y);
        if (nh === r.h) return;
        LAY.drag.r = Object.assign({}, r, { h: nh });
        patchBox(LAY.drag.r);
        laySend("resize", { screen: LAY.screen, id: e.id, h: nh });
        layPatch(e.id, { h: nh });
      } else if (anchor === "bottom") {
        const nh = Math.max(1, r.y + r.h - p.y);
        const ny = r.y + r.h - nh;
        if (nh === r.h) return;
        LAY.drag.r = Object.assign({}, r, { y: ny, h: nh });
        patchBox(LAY.drag.r);
        laySend("resize", { screen: LAY.screen, id: e.id, h: nh });
        layPatch(e.id, { h: nh });
      } else if (anchor === "left") {
        const nw = Math.max(1, p.x - r.x);
        if (nw === r.w) return;
        LAY.drag.r = Object.assign({}, r, { w: nw });
        patchBox(LAY.drag.r);
        laySend("resize", { screen: LAY.screen, id: e.id, w: nw });
        layPatch(e.id, { w: nw });
      } else {  // right
        const nw = Math.max(1, r.x + r.w - p.x);
        const nx = r.x + r.w - nw;
        if (nw === r.w) return;
        LAY.drag.r = Object.assign({}, r, { x: nx, w: nw });
        patchBox(LAY.drag.r);
        laySend("resize", { screen: LAY.screen, id: e.id, w: nw });
        layPatch(e.id, { w: nw });
      }
    } else {  // free/plain: SE handle drives w/h
      const nw = Math.max(1, Math.min(p.x - r.x, 60 - r.x));
      const nh = Math.max(1, Math.min(p.y - r.y, 33 - r.y));
      if (nw === r.w && nh === r.h) return;
      LAY.drag.r = Object.assign({}, r, { w: nw, h: nh });
      patchBox(LAY.drag.r);
      laySend("resize", { screen: LAY.screen, id: e.id, w: nw, h: nh });
      layPatch(e.id, { w: nw, h: nh });
    }
  }
}

function layDragEnd() {
  if (!LAY.drag) return;
  const box = layEl("lay-boxes").querySelector(
    `.lay-box[data-id="${CSS.escape(LAY.drag.e.id)}"]`);
  if (box) box.classList.remove("dragging");
  LAY.drag = null;
}

/* ---- inspector -------------------------------------------------------- */

function layIntInput(label, value, onSet, title) {
  const row = document.createElement("div");
  row.className = "lay-row";
  const lab = document.createElement("label");
  lab.textContent = label;
  if (title) lab.title = title;
  const input = document.createElement("input");
  input.type = "number"; input.min = "0"; input.step = "1";
  input.value = value == null ? "" : value;
  input.placeholder = "—";
  input.addEventListener("change", () => {
    const raw = parseInt(input.value, 10);
    const v = Number.isFinite(raw) && raw >= 0 ? raw : null;
    input.value = v == null ? "" : v;
    onSet(v);
  });
  row.append(lab, input);
  return row;
}

function layRenderInspector() {
  const host = layEl("lay-insp");
  layEl("lay-sel-name").textContent = LAY.sel ? `selected: ${LAY.sel}` : "";
  // never stomp an input the user is typing in
  if (host.contains(document.activeElement)
      && document.activeElement.tagName !== "BUTTON") return;
  host.textContent = "";
  const e = LAY.tree.find(x => x.id === LAY.sel);
  if (!e) {
    const s = document.createElement("span");
    s.className = "lbl";
    s.textContent = "select an element";
    host.appendChild(s);
    return;
  }
  const kind = layKind(e);
  const r = layRect(e);
  const ovr = layOvr(e.id) || {};
  const anchor = layAnchor(e.id);
  const meta = document.createElement("div");
  meta.className = "lay-meta";
  meta.textContent = `id: ${e.id}\nkind: ${kind}${e.role ? ` · role: ${e.role}` : ""}`
    + (r ? `\nrect: ${r.x},${r.y} ${r.w}×${r.h} tiles (${r.w * 32}×${r.h * 32} px)` : "")
    + (layLocked(e) ? "\n🔒 data-pinned order — reorder ignored" : "");
  meta.style.whiteSpace = "pre-wrap";
  host.appendChild(meta);

  const section = (t) => {
    const d = document.createElement("div");
    d.className = "lay-sec";
    const lab = document.createElement("div");
    lab.className = "lay-pan-title";
    lab.textContent = t;
    d.appendChild(lab);
    host.appendChild(d);
    return d;
  };
  const dis = !LAY.connected;
  const editNote = document.createElement("div");
  editNote.className = "lay-meta";
  if (dis) editNote.textContent = "connect the bridge to edit live";
  host.appendChild(editNote);

  if (kind !== "plain") {   // plain: sheet n/a (§4.8.9)
    const sec = section("sheet (one of the 7 nine-patches)");
    const sel = document.createElement("select");
    sel.disabled = dis;
    const cur = ovr.sheet != null ? ovr.sheet : (e.sheet || "");
    for (const s of LAY_SHEETS) {
      const o = document.createElement("option");
      o.value = s; o.textContent = s;
      if (s === cur) o.selected = true;
      sel.appendChild(o);
    }
    if (!cur) {
      const o = document.createElement("option");
      o.value = ""; o.textContent = "(code default)"; o.selected = true;
      o.disabled = true;
      sel.insertBefore(o, sel.firstChild);
    }
    sel.addEventListener("change", () => {
      if (!sel.value) return;
      layPatch(e.id, { sheet: sel.value });
      laySend("assign_sheet", { screen: LAY.screen, id: e.id, sheet: sel.value });
    });
    sec.appendChild(sel);
  }

  const sec2 = section("override (tile integers)");
  if (kind === "free" || kind === "anchored") {
    // anchor dropdown — free may gain one; anchored may change it.
    // Anchors live in the committed file (no §5.7 message), so this
    // edits the session only: "applied at game restart".
    const row = document.createElement("div");
    row.className = "lay-row";
    const lab = document.createElement("label");
    lab.textContent = "anchor";
    lab.title = "edge anchor — committed only; applied at game restart "
      + "(anchor and y are mutually exclusive, §8.9 item 5)";
    const sel = document.createElement("select");
    for (const a of ["", ...LAY_ANCHORS]) {
      const o = document.createElement("option");
      o.value = a; o.textContent = a === "" ? "(none — free x/y)" : a;
      if ((anchor || "") === a) o.selected = true;
      sel.appendChild(o);
    }
    sel.addEventListener("change", () => {
      const v = sel.value || null;
      if (v) {
        const patch = { anchor: v, y: null };   // anchor ⇒ no y (§8.9 item 5)
        if (v === "left" || v === "right") patch.x = null;
        layPatch(e.id, patch);
      } else {
        layPatch(e.id, { anchor: null });
      }
      layRenderInspector();
    });
    row.append(lab, sel);
    sec2.appendChild(row);
    const alongX = !anchor || anchor === "top" || anchor === "bottom";
    if (alongX) {
      sec2.appendChild(layIntInput("x", (ovr.x != null ? ovr.x : r ? r.x : null),
        (v) => { if (v == null) return; layPatch(e.id, { x: v });
                 laySend("move", { screen: LAY.screen, id: e.id, x: v }); },
        "absolute tile column (free) / along-edge span (anchored top|bottom)"));
    } else {
      sec2.appendChild(layIntInput("y", (ovr.y != null ? ovr.y : r ? r.y : null),
        (v) => { if (v == null) return; layPatch(e.id, { y: v });
                 laySend("move", { screen: LAY.screen, id: e.id, y: v }); },
        "absolute tile row (free) / along-edge span (anchored left|right)"));
    }
    if (!anchor || anchor === "top" || anchor === "bottom") {
      sec2.appendChild(layIntInput("h", (ovr.h != null ? ovr.h : r ? r.h : null),
        (v) => { if (v == null) return; layPatch(e.id, { h: v });
                 laySend("resize", { screen: LAY.screen, id: e.id, h: v }); },
        "height in tiles (with a top|bottom anchor: the span from the edge)"));
    }
    if (!anchor || anchor === "left" || anchor === "right") {
      sec2.appendChild(layIntInput("w", (ovr.w != null ? ovr.w : r ? r.w : null),
        (v) => { if (v == null) return; layPatch(e.id, { w: v });
                 laySend("resize", { screen: LAY.screen, id: e.id, w: v }); },
        "width in tiles (with a left|right anchor: the span from the edge)"));
    }
  } else if (kind === "child") {
    sec2.appendChild(layIntInput("min_w", (ovr.min_w != null ? ovr.min_w : r ? r.w : null),
      (v) => { if (v == null) return; layPatch(e.id, { min_w: v });
               laySend("resize", { screen: LAY.screen, id: e.id, min_w: v }); },
      "custom_minimum_size width (tiles)"));
    sec2.appendChild(layIntInput("min_h", (ovr.min_h != null ? ovr.min_h : r ? r.h : null),
      (v) => { if (v == null) return; layPatch(e.id, { min_h: v });
               laySend("resize", { screen: LAY.screen, id: e.id, min_h: v }); },
      "custom_minimum_size height (tiles)"));
    sec2.appendChild(layIntInput("order", ovr.order != null ? ovr.order : null,
      (v) => { if (v == null) return; layPatch(e.id, { order: v });
               laySend("reorder", { screen: LAY.screen, id: e.id, order: v }); },
      "sibling index (ignored for data-pinned orders — 🔒)"));
  } else {  // plain — moves/resizes "as per kind" (§4.8.9): offer both
    sec2.appendChild(layIntInput("x", (ovr.x != null ? ovr.x : r ? r.x : null),
      (v) => { if (v == null) return; layPatch(e.id, { x: v });
               laySend("move", { screen: LAY.screen, id: e.id, x: v }); },
      "as per the element's underlying kind"));
    sec2.appendChild(layIntInput("y", (ovr.y != null ? ovr.y : r ? r.y : null),
      (v) => { if (v == null) return; layPatch(e.id, { y: v });
               laySend("move", { screen: LAY.screen, id: e.id, y: v }); },
      "as per the element's underlying kind"));
    sec2.appendChild(layIntInput("w", (ovr.w != null ? ovr.w : r ? r.w : null),
      (v) => { if (v == null) return; layPatch(e.id, { w: v });
               laySend("resize", { screen: LAY.screen, id: e.id, w: v }); },
      "as per the element's underlying kind"));
    sec2.appendChild(layIntInput("h", (ovr.h != null ? ovr.h : r ? r.h : null),
      (v) => { if (v == null) return; layPatch(e.id, { h: v });
               laySend("resize", { screen: LAY.screen, id: e.id, h: v }); },
      "as per the element's underlying kind"));
    sec2.appendChild(layIntInput("min_w", ovr.min_w != null ? ovr.min_w : null,
      (v) => { if (v == null) return; layPatch(e.id, { min_w: v });
               laySend("resize", { screen: LAY.screen, id: e.id, min_w: v }); }));
    sec2.appendChild(layIntInput("min_h", ovr.min_h != null ? ovr.min_h : null,
      (v) => { if (v == null) return; layPatch(e.id, { min_h: v });
               laySend("resize", { screen: LAY.screen, id: e.id, min_h: v }); }));
  }
  // min_w/min_h apply to ANY control (§4.23) — offer them where the kind
  // block above didn't already
  if (kind === "free" || kind === "anchored") {
    const sec3 = section("min size (any control)");
    sec3.appendChild(layIntInput("min_w", ovr.min_w != null ? ovr.min_w : null,
      (v) => { if (v == null) return; layPatch(e.id, { min_w: v });
               laySend("resize", { screen: LAY.screen, id: e.id, min_w: v }); }));
    sec3.appendChild(layIntInput("min_h", ovr.min_h != null ? ovr.min_h : null,
      (v) => { if (v == null) return; layPatch(e.id, { min_h: v });
               laySend("resize", { screen: LAY.screen, id: e.id, min_h: v }); }));
  }
  const ovrKeys = Object.keys(layOvr(e.id) || {});
  const state = document.createElement("div");
  state.className = "lay-meta";
  state.textContent = ovrKeys.length
    ? `session override: ${ovrKeys.join(", ")}` : "session override: none";
  host.appendChild(state);
}

function layRenderSessionInfo() {
  let screens = 0, els = 0;
  for (const [s, m] of Object.entries(LAY.session)) {
    if (m && typeof m === "object") { screens++; els += Object.keys(m).length; }
  }
  layEl("lay-session-info").textContent =
    `session: ${screens} screen(s), ${els} element override(s)`
    + (LAY.committedText == null ? " · committed file absent" : "");
}

/* ---- commit ----------------------------------------------------------- */

async function layoutCommit() {
  const btn = layEl("lay-commit-btn");
  const verdict = layEl("lay-verdict");
  btn.disabled = true;
  verdict.className = "status generating";
  verdict.textContent = "gating behind tools/validate_data.py… (~30 s)";
  try {
    const r = await fetch("/api/layout/commit", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ layout: LAY.session }),
    });
    const body = await r.json().catch(() => ({}));
    if (body.ok) {
      verdict.className = "status done";
      verdict.textContent = `commit ok — ${body.bytes} bytes written to `
        + `data/ui_layout.json (validator gate passed)`;
      layEl("lay-valid").textContent = "validator: pass";
      layEl("lay-valid").className = "badge pok";
      await layoutLoadFile();          // show the committed bytes
    } else {
      verdict.className = "status error";
      verdict.textContent = `commit REJECTED — ${body.error || r.statusText}`;
      layEl("lay-valid").textContent = "validator: FAIL";
      layEl("lay-valid").className = "badge pbad";
    }
  } catch (e) {
    verdict.className = "status error";
    verdict.textContent = `commit failed: ${e.message}`;
  } finally {
    btn.disabled = false;
  }
}
