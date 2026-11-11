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
      ? "Accept + rebuild" : "Accept"}</button>
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
    render();
  });
});

function visible(job) {
  if (filter === "flagged") return job.flagged;
  if (filter === "ingame") return !!(job.ingest && job.ingest.state === "in-game");
  if (filter === "all") return true;
  if (filter === "icons") return job.family === "icons";
  if (filter === "glyphs") return job.family === "glyphs";
  if (filter === "coast") return job.family === "coast";
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
      `coast ${data.counts.coast || 0}`
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
