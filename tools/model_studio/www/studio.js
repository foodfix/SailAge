/* SailAge Model Studio frontend — vanilla JS, no frameworks. */
"use strict";

const $ = (sel, el) => (el || document).querySelector(sel);
const grid = $("#grid");
const cards = new Map();          // job_id -> {root, els, data}
let jobsData = [];
let filter = "all";
let lastCurrent = null;

const CAPTIONS = {
  hull: { draft: "draft (read-only)", raw: "raw gen", snapped: "snapped 64" },
  icon: { draft: "draft (read-only)", raw: "raw gen", snapped: "snapped 64" },
  terrain: { draft: "draft sheet", raw: "raw sheet", snapped: "sheet (no snap)" },
};

async function api(path, opts) {
  const r = await fetch(path, opts);
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || r.statusText);
  return body;
}

function thumbURL(job, kind) {
  const t = job.thumbs[kind];
  if (!t) return null;
  return `/thumb/${kind}/${job.id}.png?v=${t.v}`;
}

function bandBadge(job) {
  if (!job.band) return '<span class="badge">band —</span>';
  if (job.band.in_band === true) return '<span class="badge ok">band OK</span>';
  if (job.band.in_band === false) {
    const px = job.band.long_axis_px != null ? ` ${job.band.long_axis_px}px` : "";
    return `<span class="badge over">OVER${px}</span>`;
  }
  return '<span class="badge">band ?</span>';
}

function pennantBadge(job) {
  if (job.family !== "hull") return "";
  if (job.pennant_ok === true) return '<span class="badge pok">pennant ✓</span>';
  if (job.pennant_ok === false) return '<span class="badge pbad">pennant ✗</span>';
  return '<span class="badge">pennant ?</span>';
}

function statusHTML(job, current, queue) {
  const el = job => {
    if (current && current.job === job.id) {
      const s = Math.max(0, Math.round(Date.now() / 1000 - current.started_epoch));
      return { cls: "generating", text: `generating ${s}s… (${current.stage})` };
    }
    const qi = queue.indexOf(job.id);
    if (qi >= 0) return { cls: "queued", text: `queued (#${qi + 1})` };
    if (job.status_source === "studio" || job.error) {
      const m = job.metrics || {};
      const extra = [];
      if (job.seconds != null) extra.push(`${job.seconds}s`);
      if (job.seed != null) extra.push(`seed ${job.seed}`);
      if (m.band) extra.push(`${m.band.long_axis_px}px ∈ [${m.band.band.join(",")}]? ${m.band.in_band ? "yes" : "NO"}`);
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
  if (m.bbox) bits.push(`bbox [${m.bbox.join(",")}]`);
  if (m.pennant_red_px != null) bits.push(`red ${m.pennant_red_px}px`);
  return bits.join(" · ");
}

function buildCard(job) {
  const root = document.createElement("div");
  root.className = "card";
  root.dataset.job = job.id;
  const head = document.createElement("div");
  head.className = "card-head";
  head.innerHTML = `
    <span class="jid">${job.id}</span>
    <span class="lbl">${job.label}</span>
    ${job.mirror_of ? `<span class="badge mirror" title="mirror-derived at ingestion (doc f6c00bb)">⇄ mirror of ${job.mirror_of}</span>` : ""}
    ${bandBadge(job)}
    ${pennantBadge(job)}
    <span class="badge acc" style="display:none">★ accepted</span>`;
  const thumbs = document.createElement("div");
  thumbs.className = "thumbs";
  const mk = (kind, cap) => {
    const d = document.createElement("div");
    d.className = "thumb";
    d.innerHTML = `<img alt="${kind}"><div class="cap">${cap}</div>`;
    const img = $("img", d);
    img.addEventListener("error", () => { d.classList.add("missing"); });
    d.dataset.kind = kind;
    thumbs.appendChild(d);
    if (kind !== "snapped") {
      const ar = document.createElement("span");
      ar.className = "arrow"; ar.textContent = "→";
      thumbs.appendChild(ar);
    }
  };
  mk("draft", "draft (read-only)");
  mk("raw", "raw gen");
  mk("snapped", "snapped 64");
  const ta = document.createElement("textarea");
  ta.rows = 3;
  ta.spellcheck = false;
  ta.addEventListener("change", () => {
    ta.dataset.dirty = "1";
    savePrompt(job.id, ta.value);
  });
  const controls = document.createElement("div");
  controls.className = "controls";
  controls.innerHTML = `
    <input class="seed" placeholder="random" inputmode="numeric">
    <button class="reroll">Re-roll</button>
    <button class="accept small">Accept</button>
    <span class="spacer"></span>`;
  const status = document.createElement("div");
  status.className = "status";
  const metrics = document.createElement("div");
  metrics.className = "metrics";
  root.append(head, thumbs, ta, controls, status, metrics);

  $(".reroll", controls).addEventListener("click", () => reroll(job.id, ta));
  $(".accept", controls).addEventListener("click", () => accept(job.id));
  grid.appendChild(root);
  return { root, els: {
    ta, status, metrics, seed: $(".seed", controls),
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
  if (filter === "all") return true;
  return job.family === filter;
}

function render() {
  const seen = new Set();
  for (const job of jobsData) {
    if (!visible(job)) continue;
    seen.add(job.id);
    if (!cards.has(job.id)) cards.set(job.id, buildCard(job));
    updateCard(job);
  }
  for (const [id, card] of cards) {
    if (!seen.has(id)) { card.root.remove(); cards.delete(id); }
  }
}

function updateCard(job) {
  const card = cards.get(job.id);
  if (!card) return;
  const { root, els } = card;
  const current = window._status && window._status.current;
  const queue = (window._status && window._status.queue) || [];
  root.classList.toggle("flagged", !!job.flagged);
  root.classList.toggle("accepted", !!job.accepted);
  root.classList.toggle("running", !!(current && current.job === job.id));
  // badges: simplest correct refresh — rebuild head minus textarea impact
  const keep = els.head.querySelector(".jid").textContent;
  els.head.innerHTML = `
    <span class="jid">${keep}</span>
    <span class="lbl">${job.label}</span>
    ${job.mirror_of ? `<span class="badge mirror">⇄ mirror of ${job.mirror_of}</span>` : ""}
    ${bandBadge(job)}
    ${pennantBadge(job)}
    <span class="badge acc" style="${job.accepted ? "" : "display:none"}"
      title="${job.accepted ? "accepted " + job.accepted.at + " (" + job.accepted.source + ")" : ""}">★ accepted</span>`;
  // thumbs + captions (mirror note when serving the flipped base dir)
  const caps = CAPTIONS[job.family] || CAPTIONS.hull;
  for (const kind of ["draft", "raw", "snapped"]) {
    const d = root.querySelector(`.thumb[data-kind="${kind}"]`);
    const t = job.thumbs[kind];
    const url = thumbURL(job, kind);
    $(".cap", d).textContent =
      caps[kind] + (t && t.mirrored ? ` (⇄ ${t.mirrored})` : "");
    if (url) {
      d.classList.remove("missing");
      const img = $("img", d);
      const want = url;
      if (img.dataset.src !== want) {
        img.dataset.src = want;
        img.src = want;
      }
    } else {
      d.classList.add("missing");
    }
  }
  // prompt (never stomp user edits; never blank)
  const ta = els.ta;
  if (document.activeElement !== ta && ta.dataset.dirty !== "1"
      && ta.value !== job.prompt) ta.value = job.prompt || "";
  ta.placeholder = job.prompt ? "" : "prompt unavailable — type here";
  ta.title = job.custom_prompt ? "persisted studio prompt" : "canonical driver prompt";
  const st = statusHTML(job, current, queue);
  els.status.className = `status ${st.cls}`;
  els.status.textContent = st.html;
  els.metrics.textContent = metricsLine(job);
  els.seed.placeholder = job.canonical_seed != null
    ? `random (canon ${job.canonical_seed})` : "random";
}

async function refreshJobs() {
  try {
    const data = await api("/api/jobs");
    jobsData = data.jobs;
    $("#counts-chip").textContent =
      `ships ${data.counts.hull} · icons ${data.counts.icon} · terrain ${data.counts.terrain} — flagged ${data.flagged.length}`;
    $("#flagged-n").textContent = data.flagged.length;
    $("#flagged-n2").textContent = data.flagged.length;
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
      line.textContent = `${st.current.job} — ${st.current.stage} ${s}s · seed ${st.current.seed}`;
      const card = cards.get(st.current.job);
      if (card) updateCard(cardsData(st.current.job));
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
