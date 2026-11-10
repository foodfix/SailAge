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

/* ==== Layout tab (Phase 12 W3-E — the §4.8.9 v2 absolute-rect editor) ====
   Live bridge: the BROWSER connects DIRECTLY to the game's LayoutBridge
   ws://127.0.0.1:8765 (90-* §5.7, the Phase-12 protocol) — server.py
   never proxies WS. EVERY element drags/resizes as a rect: a drag sends
   `move {screen, id, x, y}`, a resize sends `resize {screen, id, w, h}`
   (tiles, parent-relative — a child's tiles address its registered
   parent's rect; top-level elements address the 60 × 34 canvas the
   `hello` reports); `assign_sheet` is unchanged. The Phase-11 kind
   split, the min-override dance, the sibling order and the edge dock
   are RETIRED game-side (answered `error`/`retired_field`) and the
   studio never sends them. Dynamic-list members are not editable rows:
   each list renders as ONE locked, hatched viewport block (the `lists`
   data is builder-owned; rows stack at base + i·row_h inside the
   viewport). The edit session accumulates here as the FULL v2 document
   {version: 2, screens: {<screen>: {elements, lists}}} — STARTING from
   the committed data/ui_layout.json so edits compose; Commit POSTs the
   whole document and the server gates it behind tools/validate_data.py
   before writing (10-* §4.23 bytes: sorted keys, 2-space indent,
   trailing newline).
   The wire discriminator rides under both `msg` and `type` so either
   reader convention works (the frozen table names messages, not keys). */

const LAY_SHEETS = ["panel", "button", "button_hover", "button_pressed",
  "button_focus", "field", "backdrop"];          // the 7 assignable (§4.8.9)
const LAY = {
  ws: null, connected: false, connecting: false, loaded: false,
  screens: [], grid: { w: 60, h: 34 }, tile: 32,
  screen: null, tree: [], sel: null,
  session: { version: 2, screens: {} },  // the FULL v2 doc — starts committed
  committed: null,                       // tab-open snapshot (revert target)
  committedText: null, drag: null,
};
const DESIGN_W = 1920, DESIGN_H = 1080;   // the locked design canvas (90-* §6)
const layEl = (id) => document.getElementById(id);
const layKind = (e) => String((e && e.kind) || "free");  // tree wording only
const layListOf = (e) => String((e && e.list) || "");    // non-empty = member
const layRect = (e) => {
  const r = e && e.rect_tiles;
  return r && [r.x, r.y, r.w, r.h].every(v => typeof v === "number")
    ? { x: r.x, y: r.y, w: r.w, h: r.h } : null;
};
const layParentRow = (e) =>
  (e && e.parent && LAY.tree.find(x => x.id === e.parent)) || null;

// The element's DATA-space rect — parent-relative tiles (the v2 file's
// address space, 10-* §4.23). The tree dump reports screen-root-relative
// rects, so a nested element's data x/y is its screen rect minus the
// registered parent row's.
function layDataRect(e) {
  const r = layRect(e);
  if (!r) return null;
  const p = layParentRow(e);
  const pr = p && layRect(p);
  if (!pr) return { x: r.x, y: r.y, w: r.w, h: r.h };  // root child: data == screen
  return { x: r.x - pr.x, y: r.y - pr.y, w: r.w, h: r.h };
}

// The screen-space clamp rect: the registered parent row's rect (rule 1),
// else the whole canvas (the grid `hello` reports — 60 × 34).
function layBounds(e) {
  const p = layParentRow(e);
  const pr = p && layRect(p);
  if (pr) return { x: pr.x, y: pr.y, w: Math.max(1, pr.w), h: Math.max(1, pr.h) };
  return { x: 0, y: 0, w: LAY.grid.w || 60, h: LAY.grid.h || 34 };
}

// The resize floors: the element's CONTENT minimum only, in tiles. The
// Phase-11 children-extent floor is RETIRED client-side (the 2026-11-10
// rule-2 amendment, the user-reported sandbox panel interiors): a parent
// shrink SUCCEEDS and the registered children clamp into the new rect —
// the game clamps them on the live edit, so the studio must not refuse
// the drag. `kids_tiles` stays in the tree payload as information only.
function layFloors(e) {
  const mt = (e && e.min_tiles) || {};
  return { w: Math.max(1, mt.w || 1),
           h: Math.max(1, mt.h || 1) };
}

const layScreenData = (screen) => ((LAY.session.screens || {})[screen]) || {};
const layElements = (screen) => layScreenData(screen).elements || {};
const layOvr = (screen, id) => layElements(screen)[id] || null;

// The effective data rect: the session row's fields win over the live
// tree's (edits compose over what is already committed).
function layCurrentData(e) {
  const d = layDataRect(e);
  if (!d) return null;
  const ov = layOvr(LAY.screen, e.id) || {};
  const pick = (k) => (ov[k] != null ? ov[k] : d[k]);
  return { x: pick("x"), y: pick("y"), w: pick("w"), h: pick("h") };
}

// The merged + clamped data rect for a typed patch: inside the parent's
// rect (rule 1), never below the floors (rule 2) — the client-side
// mirror of the game-side clamps.
function layClampedPatch(e, patch) {
  const merged = Object.assign({}, layCurrentData(e)
    || { x: 0, y: 0, w: 2, h: 2 });
  for (const [k, v] of Object.entries(patch)) if (v != null) merged[k] = v;
  const pr = layBounds(e);
  const f = layFloors(e);
  merged.w = Math.min(Math.max(f.w, merged.w), pr.w);
  merged.h = Math.min(Math.max(f.h, merged.h), pr.h);
  merged.x = Math.min(Math.max(0, merged.x), Math.max(0, pr.w - merged.w));
  merged.y = Math.min(Math.max(0, merged.y), Math.max(0, pr.h - merged.h));
  return merged;
}

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

// merge `patch` into the element's session row; a null value removes the
// key. A new row is seeded with the element's FULL current data rect —
// the v2 file stores complete {x, y, w, h} rows, so any edit commits a
// complete row (§8.9 item 3).
function layPatch(id, patch) {
  const scr = (LAY.session.screens = LAY.session.screens || {});
  const data = (scr[LAY.screen] = scr[LAY.screen] || {});
  const els = (data.elements = data.elements || {});
  const e = LAY.tree.find(x => x.id === id);
  if (!els[id] && e) {
    const seed = layDataRect(e);
    if (seed) els[id] = { x: seed.x, y: seed.y, w: seed.w, h: seed.h };
  }
  const ov = (els[id] = els[id] || {});
  for (const [k, v] of Object.entries(patch)) {
    if (v === null) delete ov[k];
    else ov[k] = v;
  }
  if (!Object.keys(ov).length) delete els[id];
  if (!Object.keys(data.elements).length
      && !Object.keys(data.lists || {}).length) delete scr[LAY.screen];
  layRenderSessionInfo();
}

// Session revert (the Phase-12 semantics): the element's session row goes
// back to the tab-open committed row — or disappears when THIS session
// created it. The v2 file has no code defaults underneath, so "revert"
// means the committed data rect, never a deleted row.
function layRestoreCommittedRow(screen, id) {
  const scr = (LAY.session.screens || {})[screen];
  if (!scr || !scr.elements) return;
  const committedEls = ((((LAY.committed || {}).screens || {})[screen])
    || {}).elements;
  if (committedEls && committedEls[id] != null)
    scr.elements[id] = JSON.parse(JSON.stringify(committedEls[id]));
  else delete scr.elements[id];
  if (!Object.keys(scr.elements).length
      && !Object.keys(scr.lists || {}).length)
    delete LAY.session.screens[screen];
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
    LAY.committed = null;
    LAY.session = { version: 2, screens: {} };
    ta.value = "(absent — commit creates the v2 file)";
    badge.textContent = "validator: —";
  } else {
    LAY.committedText = body.content;
    ta.value = body.content;
    badge.textContent = "validator: "
      + (body.valid == null ? "—" : body.valid ? "pass" : "FAIL");
    badge.className = "badge " + (body.valid === false ? "pbad"
      : body.valid ? "pok" : "");
    let parsed = null;
    try { parsed = JSON.parse(body.content); } catch (e) { parsed = null; }
    if (parsed && parsed.version === 2 && parsed.screens
        && typeof parsed.screens === "object") {
      LAY.session = parsed;                     // session starts committed
      LAY.committed = JSON.parse(body.content); // pristine revert snapshot
    } else {
      LAY.session = { version: 2, screens: {} };
      LAY.committed = null;
      layMsg("committed ui_layout.json is not v2 — session starts empty",
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
    const row = LAY.tree.find(x => x.id === LAY.sel);
    if (row && layListOf(row)) {
      layMsg("list member — the block is builder-owned, nothing to revert",
        "error");
      return;
    }
    layRestoreCommittedRow(LAY.screen, LAY.sel);
    laySend("revert", { screen: LAY.screen, id: LAY.sel });
    layRenderBoxes();
    layRenderInspector();
    layRenderSessionInfo();
    layMsg(`reverted ${LAY.sel} (the committed data rect)`, "done");
  });
  layEl("lay-reset").addEventListener("click", () => {
    if (!LAY.screen) return;
    for (const id of Object.keys(layElements(LAY.screen)))
      layRestoreCommittedRow(LAY.screen, id);
    laySend("reset_screen", { screen: LAY.screen });
    layRenderBoxes();
    layRenderInspector();
    layRenderSessionInfo();
    layMsg(`reset screen ${LAY.screen} (the committed data rects)`, "done");
  });
  // canvas pointer interactions (drag-move, SE resize of the one box)
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
      if (m.grid) LAY.grid = m.grid;      // 60 × 34 (the Phase-12 grid)
      if (m.tile) LAY.tile = m.tile;
      if (!LAY.screen || !LAY.screens.includes(LAY.screen))
        LAY.screen = LAY.screens[0] || null;
      laySend("get_tree", {});
      layMsg(`hello — ${LAY.screens.length} screen(s), grid `
        + `${LAY.grid.w}×${LAY.grid.h}`, "done");
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
  // The parent/child depth per row (the hierarchy shows as indentation):
  // each row carries its nearest registered ancestor (`parent`), so the
  // depth is the parent-chain length. The step cap keeps a pathological
  // dump bounded.
  const parentOf = {};
  for (const e of LAY.tree) parentOf[e.id] = e.parent || "";
  const depthOf = (id) => {
    let d = 0, p = parentOf[id];
    while (p && d < 32) { d += 1; p = parentOf[p]; }
    return d;
  };
  // HIERARCHICAL ORDER (kept from Phase 11): rows arrive in registration
  // order — render the forest instead, every parent immediately followed
  // by its descendants; orphans keep their registration position at the
  // end so no row is lost.
  const children = {};
  for (const e of LAY.tree) {
    const p = e.parent || "";
    (children[p] = children[p] || []).push(e);
  }
  const ordered = [];
  const visit = (pid) => {
    for (const e of (children[pid] || [])) {
      ordered.push(e);
      visit(e.id);
    }
  };
  visit("");
  const listed = new Set(ordered.map(x => x.id));
  for (const e of LAY.tree) {
    if (!listed.has(e.id)) ordered.push(e);
  }
  for (const e of ordered) {
    const depth = depthOf(e.id);
    const member = layListOf(e);
    const row = document.createElement("div");
    row.className = "lay-el" + (e.id === LAY.sel ? " active" : "")
      + (member ? " ismember" : "");
    row.style.paddingLeft = (6 + depth * 18) + "px";
    const id = document.createElement("span");
    id.className = "lay-el-id";
    id.textContent = (depth > 0 ? "└ " : "") + e.id;
    id.title = `${e.id} — ${layKind(e)}${e.role ? ` · ${e.role}` : ""}`
      + (member ? ` · list ${member}` : "")
      + (depth > 0 ? ` · depth ${depth}` : "");
    row.appendChild(id);
    const ovr = layOvr(LAY.screen, e.id);
    if (ovr) {
      const dot = document.createElement("span");
      dot.className = "lay-ovr";
      dot.title = "has a session edit";
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
    kind.textContent = member ? "list row" : layKind(e);
    row.appendChild(kind);
    if (member) {
      // a dynamic-row member: rendered as part of the list's locked
      // viewport block on the canvas — never a draggable row
      const tag = document.createElement("span");
      tag.className = "lay-list-tag";
      tag.title = `dynamic row of list ${member} — stacked by the block `
        + `(base + i·row_h), not editable`;
      tag.textContent = `⊆ ${member}`;
      row.appendChild(tag);
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

function unionRects(rects) {
  if (!rects.length) return null;
  const x0 = Math.min(...rects.map(r => r.x));
  const y0 = Math.min(...rects.map(r => r.y));
  const x1 = Math.max(...rects.map(r => r.x + r.w));
  const y1 = Math.max(...rects.map(r => r.y + r.h));
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

// Dynamic-list members are not editable rows: every list with member rows
// in the tree renders as ONE locked viewport block — hatched, labeled
// `<list> · row_h`, never draggable, never editable (the `lists` data is
// builder-owned; rows stack at base + i·row_h inside the viewport). The
// block rect comes from the session's committed lists data; without it
// the block degrades to the member rows' union extent.
function renderListBlocks(host) {
  const ids = [];
  for (const e of LAY.tree) {
    const l = layListOf(e);
    if (l && !ids.includes(l)) ids.push(l);
  }
  const selRow = LAY.sel && LAY.tree.find(x => x.id === LAY.sel);
  const selList = selRow ? layListOf(selRow) : "";
  for (const listId of ids) {
    const block = (layScreenData(LAY.screen).lists || {})[listId] || null;
    // The live member-union rect is the block's SCREEN-space position
    // (the committed viewport is parent-relative tiles — its host's
    // offset matters, the sandbox's ship-rows blocks rendered at the
    // canvas corner until 2026-11-10). The committed viewport is the
    // fallback for a block whose members are not mounted yet.
    let rect = unionRects(LAY.tree.filter(x => layListOf(x) === listId)
      .map(layRect).filter(Boolean));
    let label = listId;
    if (!rect && block && block.viewport) {
      const v = block.viewport;
      if ([v.x, v.y, v.w, v.h].every(n => typeof n === "number")) {
        rect = { x: v.x, y: v.y, w: v.w, h: v.h };
      }
    }
    if (block && block.row_h != null) label = `${listId} · row_h ${block.row_h}`;
    if (!rect) continue;
    const div = document.createElement("div");
    div.className = "lay-listblock" + (selList === listId ? " active" : "");
    const p = layBoxPos(rect);
    div.style.left = p.left + "%";
    div.style.top = p.top + "%";
    div.style.width = p.width + "%";
    div.style.height = p.height + "%";
    const tag = document.createElement("span");
    tag.className = "lay-listblock-tag";
    tag.textContent = `🔒 ${label} — locked viewport (builder-owned)`;
    div.appendChild(tag);
    host.appendChild(div);
  }
}

function layRenderBoxes() {
  const host = layEl("lay-boxes");
  host.textContent = "";
  const note = layEl("lay-canvas-note");
  renderListBlocks(host);
  // The simplified canvas model (kept from Phase 11): the element LIST is
  // the only selection surface, and the canvas renders ONLY the selected
  // element's box (plus the locked list blocks above).
  if (!LAY.sel) {
    note.hidden = !LAY.tree.length;
    note.textContent = LAY.connected && LAY.tree.length
      ? "pick an element in the list (left) to edit it"
      : (LAY.connected
        ? (LAY.screen ? "no tree for this screen" : "pick a screen")
        : "no frame — connect the bridge and pick a screen");
    return;
  }
  const e = LAY.tree.find(x => x.id === LAY.sel);
  if (!e) return;  // the selection vanished (rebuild) — tree receipt clears it
  if (layListOf(e)) return;  // a list member: the highlighted block IS it
  const r = layRect(e);
  if (!r) return;
  const box = document.createElement("div");
  box.className = "lay-box active";
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
  // Drag-move + SE resize for EVERY element alike (the Phase-12 rule:
  // one path for all) — a drag sends move {x, y}, a resize sends
  // resize {w, h}; clamps mirror the game client-side (the parent row's
  // rect + the min_tiles/kids_tiles floors).
  const dragable = LAY.connected;
  box.style.cursor = dragable ? "move" : "default";
  if (dragable) {
    const se = document.createElement("div");
    se.className = "lay-se";
    se.title = "resize (w/h tiles)";
    se.addEventListener("mousedown", (ev) => {
      ev.stopPropagation(); ev.preventDefault();
      const f = layFloors(e);
      LAY.drag = { mode: "resize", e: JSON.parse(JSON.stringify(e)),
                   r: layRect(e), floorW: f.w, floorH: f.h };
      box.classList.add("dragging");
    });
    box.appendChild(se);
    box.addEventListener("mousedown", (ev) => {
      ev.preventDefault();
      const g = layPointerTiles(ev);
      LAY.drag = { mode: "move", e: JSON.parse(JSON.stringify(e)),
                   r: layRect(e),
                   off: { x: g.x - r.x, y: g.y - r.y } };
      box.classList.add("dragging");
    });
  }
  host.appendChild(box);
}

function layPointerTiles(ev) {
  const c = layEl("lay-canvas").getBoundingClientRect();
  const gridW = LAY.grid.w || 60;
  return {
    x: Math.round((ev.clientX - c.left) / c.width * gridW),
    y: Math.round((ev.clientY - c.top) / c.height * (DESIGN_H / LAY.tile)),
  };
}

function layClampRect(r) {
  const gw = LAY.grid.w || 60, gh = LAY.grid.h || 34;
  const w = Math.max(0, Math.min(r.w, gw - r.x));
  const h = Math.max(0, Math.min(r.h, gh - r.y));
  return { x: Math.max(0, r.x), y: Math.max(0, r.y), w, h };
}

// screen-space rect → data-space (parent-relative) tiles
function layToData(e, r) {
  const p = layParentRow(e);
  const pr = p && layRect(p);
  if (!pr) return { x: r.x, y: r.y };
  return { x: r.x - pr.x, y: r.y - pr.y };
}

function layDragMove(ev) {
  if (!LAY.drag) return;
  const { mode, e, r, off } = LAY.drag;
  const p = layPointerTiles(ev);
  const bounds = layBounds(e);
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
    // pointer target = grab point minus the grab offset inside the box;
    // clamped INSIDE the parent row's rect (rule 1)
    const tx = off ? p.x - off.x : p.x;
    const ty = off ? p.y - off.y : p.y;
    const nx = Math.max(bounds.x, Math.min(tx, bounds.x + bounds.w - r.w));
    const ny = Math.max(bounds.y, Math.min(ty, bounds.y + bounds.h - r.h));
    if (nx === r.x && ny === r.y) return;
    LAY.drag.r = Object.assign({}, r, { x: nx, y: ny });
    patchBox(LAY.drag.r);
    const d = layToData(e, LAY.drag.r);
    laySend("move", { screen: LAY.screen, id: e.id, x: d.x, y: d.y });
    layPatch(e.id, { x: d.x, y: d.y });
  } else if (mode === "resize") {
    // the floor captured at mousedown (the content minimum — the amended
    // rule 2 lets the parent shrink freely; the game clamps the
    // registered children into the new rect on the live edit), clamped
    // inside the parent's edges
    const nw = Math.max(LAY.drag.floorW,
      Math.min(p.x - r.x, bounds.x + bounds.w - r.x));
    const nh = Math.max(LAY.drag.floorH,
      Math.min(p.y - r.y, bounds.y + bounds.h - r.y));
    if (nw === r.w && nh === r.h) return;
    LAY.drag.r = Object.assign({}, r, { w: nw, h: nh });
    patchBox(LAY.drag.r);
    layThrottledSend("resize", { screen: LAY.screen, id: e.id, w: nw, h: nh });
    layPatch(e.id, { w: nw, h: nh });
  }
}

/* The drag-send throttle (kept from Phase 11): one WS message per tile
 * change floods the bridge's tree+frame replies, and each reply
 * re-renders the box from the authoritative rect — mid-drag that fights
 * the optimistic box. Sends coalesce to one per 150 ms, and `layDragEnd`
 * flushes the trailing one so the last state always lands. */
let laySendTimer = null;
let layPendingSend = null;
function layThrottledSend(type, payload) {
  layPendingSend = { type, payload };
  if (laySendTimer != null) return;
  laySendTimer = setTimeout(() => {
    laySendTimer = null;
    if (!layPendingSend) return;
    laySend(layPendingSend.type, layPendingSend.payload);
    layPendingSend = null;
  }, 150);
}

function layDragEnd() {
  if (laySendTimer != null) { clearTimeout(laySendTimer); laySendTimer = null; }
  if (layPendingSend) {
    laySend(layPendingSend.type, layPendingSend.payload);
    layPendingSend = null;
  }
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
  const r = layRect(e);
  const d = layCurrentData(e);
  const member = layListOf(e);
  const meta = document.createElement("div");
  meta.className = "lay-meta";
  meta.textContent = `id: ${e.id}\nkind: ${layKind(e)}${e.role ? ` · role: ${e.role}` : ""}`
    + (e.parent ? `\nparent: ${e.parent}` : "")
    + (r ? `\nrect (screen): ${r.x},${r.y} ${r.w}×${r.h} tiles (${r.w * 32}×${r.h * 32} px)` : "")
    + (d ? `\nrect (data, parent-relative): ${d.x},${d.y} ${d.w}×${d.h} tiles` : "");
  meta.style.whiteSpace = "pre-wrap";
  host.appendChild(meta);

  if (member) {
    // a dynamic-row member: read-only — the block is builder-owned
    const note = document.createElement("div");
    note.className = "lay-meta";
    note.textContent = `⊆ dynamic row of list ${member} — rows stack at `
      + `base + i·row_h inside the block's viewport; the block is `
      + `builder-owned and not editable here.`;
    host.appendChild(note);
    return;
  }

  const section = (t) => {
    const d2 = document.createElement("div");
    d2.className = "lay-sec";
    const lab = document.createElement("div");
    lab.className = "lay-pan-title";
    lab.textContent = t;
    d2.appendChild(lab);
    host.appendChild(d2);
    return d2;
  };
  const dis = !LAY.connected;
  const editNote = document.createElement("div");
  editNote.className = "lay-meta";
  if (dis) editNote.textContent = "connect the bridge to edit live";
  host.appendChild(editNote);

  if (e.role !== "plain") {   // plain: sheet n/a (§4.8.9)
    const sec = section("sheet (one of the 7 nine-patches)");
    const sel = document.createElement("select");
    sel.disabled = dis;
    const ov = layOvr(LAY.screen, e.id) || {};
    const cur = ov.sheet != null ? ov.sheet : (e.sheet || "");
    for (const s of LAY_SHEETS) {
      const o = document.createElement("option");
      o.value = s; o.textContent = s;
      if (s === cur) o.selected = true;
      sel.appendChild(o);
    }
    if (!cur) {
      const o = document.createElement("option");
      o.value = ""; o.textContent = "(theme default)"; o.selected = true;
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

  const sec2 = section("rect (tiles — parent-relative)");
  sec2.appendChild(layIntInput("x", d ? d.x : null, (v) => {
    if (v == null) return;
    const m = layClampedPatch(e, { x: v });
    layPatch(e.id, { x: m.x, y: m.y });
    laySend("move", { screen: LAY.screen, id: e.id, x: m.x, y: m.y });
  }, "tile column inside the registered parent's rect (top-level: the canvas)"));
  sec2.appendChild(layIntInput("y", d ? d.y : null, (v) => {
    if (v == null) return;
    const m = layClampedPatch(e, { y: v });
    layPatch(e.id, { x: m.x, y: m.y });
    laySend("move", { screen: LAY.screen, id: e.id, x: m.x, y: m.y });
  }, "tile row inside the registered parent's rect (top-level: the canvas)"));
  sec2.appendChild(layIntInput("w", d ? d.w : null, (v) => {
    if (v == null) return;
    const m = layClampedPatch(e, { w: v });
    layPatch(e.id, { w: m.w, h: m.h });
    laySend("resize", { screen: LAY.screen, id: e.id, w: m.w, h: m.h });
  }, "width in tiles (never below the min_tiles/kids_tiles floors)"));
  sec2.appendChild(layIntInput("h", d ? d.h : null, (v) => {
    if (v == null) return;
    const m = layClampedPatch(e, { h: v });
    layPatch(e.id, { w: m.w, h: m.h });
    laySend("resize", { screen: LAY.screen, id: e.id, w: m.w, h: m.h });
  }, "height in tiles (never below the min_tiles/kids_tiles floors)"));

  const ovrKeys = Object.keys(layOvr(LAY.screen, e.id) || {});
  const state = document.createElement("div");
  state.className = "lay-meta";
  state.textContent = ovrKeys.length
    ? `session row: ${ovrKeys.join(", ")}` : "session row: none";
  host.appendChild(state);
}

function layRenderSessionInfo() {
  const screens = LAY.session.screens || {};
  let scr = 0, els = 0;
  for (const data of Object.values(screens)) {
    if (data && typeof data === "object") {
      scr++;
      els += Object.keys(data.elements || {}).length;
    }
  }
  layEl("lay-session-info").textContent =
    `session: ${scr} screen(s), ${els} element row(s)`
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
      body: JSON.stringify({ layout: LAY.session }),   // the FULL v2 doc
    });
    const body = await r.json().catch(() => ({}));
    if (body.ok) {
      verdict.className = "status done";
      verdict.textContent = `commit ok — ${body.bytes} bytes written to `
        + `data/ui_layout.json (validator gate passed)`;
      layEl("lay-valid").textContent = "validator: pass";
      layEl("lay-valid").className = "badge pok";
      // The both-locale guard reminder (80-* §4.8.9) — shown ONLY on a
      // successful commit: nothing changed on a rejection, so no suites
      // are owed. The set is concrete: the layout guards + the
      // port-screen behavior suites.
      const remind = layEl("lay-remind");
      remind.textContent = "⚠ layout committed — before playing on, run: "
        + "python3 tools/run_tests.py --only test_layout --jobs 4 + the "
        + "port-screen suites (market/port_hub/inn/tavern/palace/shipyard/"
        + "quests). The studio cannot run Godot — the committed file is "
        + "the suites' input (80-* §4.8.9 both-locale guard).";
      remind.hidden = false;
      await layoutLoadFile();          // show the committed bytes
    } else {
      verdict.className = "status error";
      verdict.textContent = `commit REJECTED — ${body.error || r.statusText}`;
      layEl("lay-valid").textContent = "validator: FAIL";
      layEl("lay-valid").className = "badge pbad";
      layEl("lay-remind").hidden = true;   // nothing changed — no suites owed
    }
  } catch (e) {
    verdict.className = "status error";
    verdict.textContent = `commit failed: ${e.message}`;
  } finally {
    btn.disabled = false;
  }
}

