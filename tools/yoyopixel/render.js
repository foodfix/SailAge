#!/usr/bin/env node
"use strict";
// ==================================================================
// render.js — the vendored YoYoPixel engine core as a node CLI.
//
// SECTION 1 below is the pixel-math script extracted from the upstream
// `engine-v3.html` (YoYoPixel, © 2026 SbName, MIT — see VENDORED.md
// and LICENSE). The math is verbatim; deviations are marked with
// `[SailAge]` comments and listed in render.md §Deviations.
//
// SECTION 2 (PNG encoder) and SECTION 3/4 (declaration renderer +
// CLI) are first-party SailAge code: zero npm dependencies, node
// builtins only (`zlib`, `fs`, `path`), no network access.
//
// Usage:  node render.js <declaration.json> [<declaration2.json> ...]
// Format: see render.md. Node is pinned to v24.16.0.
// ==================================================================

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

// ==================================================================
// SECTION 1 — VENDORED ENGINE CORE (extracted from engine-v3.html)
// ==================================================================

class PB {
  constructor(w,h){this.w=w;this.h=h;this.data=new Uint8ClampedArray(w*h*4)}
  set(x,y,r,g,b,a){x|=0;y|=0;if(x<0||x>=this.w||y<0||y>=this.h)return;const i=(y*this.w+x)<<2;this.data[i]=r;this.data[i+1]=g;this.data[i+2]=b;this.data[i+3]=a!==undefined?a:255}
  setC(x,y,c,a){this.set(x,y,c[0],c[1],c[2],a)}
  get(x,y){x|=0;y|=0;if(x<0||x>=this.w||y<0||y>=this.h)return null;const i=(y*this.w+x)<<2;if(this.data[i+3]===0)return null;return[this.data[i],this.data[i+1],this.data[i+2],this.data[i+3]]}
  has(x,y){x|=0;y|=0;return x>=0&&x<this.w&&y>=0&&y<this.h&&this.data[((y*this.w+x)<<2)+3]>0}
  blend(x,y,c,sA){x|=0;y|=0;if(x<0||x>=this.w||y<0||y>=this.h)return;const i=(y*this.w+x)<<2;const dA=this.data[i+3]/255,s=(sA!==undefined?sA:255)/255,oA=s+dA*(1-s);if(oA===0)return;this.data[i]=((c[0]*s+this.data[i]*dA*(1-s))/oA)|0;this.data[i+1]=((c[1]*s+this.data[i+1]*dA*(1-s))/oA)|0;this.data[i+2]=((c[2]*s+this.data[i+2]*dA*(1-s))/oA)|0;this.data[i+3]=(oA*255)|0}
}
function blit(s,d,dx,dy){for(let y=0;y<s.h;y++)for(let x=0;x<s.w;x++){const c=s.get(x,y);if(!c)continue;d.set(dx+x,dy+y,c[0],c[1],c[2],c[3])}}
function blitA(s,d,dx,dy,o){o=o||{};if(o.shadow)for(let y=0;y<s.h;y++)for(let x=0;x<s.w;x++){if(!s.has(x,y))continue;d.blend(dx+x+(o.so||[1,2])[0],dy+y+(o.so||[1,2])[1],[0,0,0],((o.sa||.18)*255)|0)};for(let y=0;y<s.h;y++)for(let x=0;x<s.w;x++){const c=s.get(x,y);if(!c)continue;d.set(dx+x,dy+y,c[0],c[1],c[2],c[3])}}
function H(x,y){let n=((x|0)*374761393+(y|0)*668265263+1013904223)|0;n=(((n>>13)^n)*1274126177)|0;return(((n>>16)^n)>>>0)/4294967296}
function hx(s){return[parseInt(s.slice(1,3),16),parseInt(s.slice(3,5),16),parseInt(s.slice(5,7),16)]}
function nz(c,x,y,r){const n=(H(x*7,y*13)-.5)*r;return c.map(v=>Math.max(0,Math.min(255,(v+n)|0)))}
function pk(a,x,y){return[...a[Math.floor(H(x,y)*a.length)%a.length]]}
function inE(x,y,cx,cy,rx,ry){const dx=(x-cx)/rx,dy=(y-cy)/ry;return dx*dx+dy*dy<=1}
function inRR(x,y,x1,y1,x2,y2,r){if(x<x1||x>=x2||y<y1||y>=y2)return false;for(const[cx,cy]of[[x1+r,y1+r],[x2-r,y1+r],[x1+r,y2-r],[x2-r,y2-r]]){if((x<x1+r||x>=x2-r)&&(y<y1+r||y>=y2-r)){const dx2=x-cx,dy2=y-cy;if(dx2*dx2+dy2*dy2>r*r)return false}}return true}

// ================================================================
//  V3 CORE: Hue-Shift Shading
// ================================================================

// Replace dk/lt with hue-aware shade function
// amount: -1 (full shadow) to +1 (full highlight)
// warmth: how much to shift hue (>0 = warm highlights, <0 = cool highlights)
function shade(c, amount, warmth) {
  warmth = warmth !== undefined ? warmth : 0.5;
  const r = c[0], g = c[1], b = c[2];
  if (amount > 0) {
    // Highlight: shift toward warm (add yellow/white)
    return [
      Math.min(255, (r + (255-r) * amount + warmth * amount * 15) | 0),
      Math.min(255, (g + (255-g) * amount + warmth * amount * 8) | 0),
      Math.min(255, (b + (255-b) * amount - warmth * amount * 10) | 0),
    ];
  } else {
    // Shadow: shift toward cool (add blue/purple)
    const a = -amount;
    return [
      Math.max(0, (r * (1-a) - warmth * a * 8) | 0),
      Math.max(0, (g * (1-a) - warmth * a * 15) | 0),
      Math.max(0, (b * (1-a) + warmth * a * 12) | 0),
    ];
  }
}

// Simple dk/lt still available for backwards compat
function dk(c,a){return shade(c,-a,0.5)}
function lt(c,a){return shade(c,a,0.5)}

// ================================================================
//  V3 CORE: Adaptive Outline
// ================================================================
function adaptiveOutlineColor(c) {
  // Saturated dark version: increase saturation, decrease brightness, slight cool shift
  const avg = (c[0]+c[1]+c[2])/3;
  return [
    Math.max(0, (c[0]*0.35 + (c[0]-avg)*0.15 - 5) | 0),
    Math.max(0, (c[1]*0.30 + (c[1]-avg)*0.15 - 8) | 0),
    Math.max(0, (c[2]*0.40 + (c[2]-avg)*0.15) | 0),
  ];
}

// ================================================================
//  V3 CORE: Per-Material Shading Strategies
// ================================================================
const MAT_SHADERS = {
  wood: {
    shade: (c, nx, ny, zoneW, zoneH) => {
      // Directional: top-left bright, bottom-right dark
      const l = (0.5-nx)*0.22 + (0.5-ny)*0.15;
      return shade(c, l, 0.6); // warm wood
    }
  },
  wood_dark: {
    shade: (c, nx, ny) => {
      const l = (0.5-nx)*0.25 + (0.5-ny)*0.18;
      return shade(c, l, 0.5);
    }
  },
  glass: {
    shade: (c, nx, ny, zw, zh, alpha) => {
      // Round cylinder: bright center-left, dark edges
      const center = Math.abs(nx-0.35)*1.5;
      const l = 0.25 - center*0.4 - ny*0.15;
      return shade(c, l, 0.2); // cool glass
    },
    alpha: 200,
    specular: {nx: 0.25, ny: 0.2, r: 0.15, intensity: 0.5}
  },
  liquid: {
    shade: (c, nx, ny) => {
      // Horizontal gradient, surface line highlight
      const surfLine = ny < 0.15 ? 0.3 : 0;
      const l = 0.1 - ny*0.25 + surfLine;
      return shade(c, l, 0.3);
    }
  },
  metal: {
    shade: (c, nx, ny) => {
      // Sharp specular band
      const spec = Math.exp(-((nx-0.3)**2)*30) * 0.4;
      const l = (0.5-ny)*0.2 + spec;
      return shade(c, l, 0.15); // cool metal
    }
  },
  gold: {
    shade: (c, nx, ny) => {
      const spec = Math.exp(-((nx-0.35)**2)*25) * 0.35;
      const l = (0.5-ny)*0.18 + spec;
      return shade(c, l, 0.7); // warm gold
    }
  },
  cloth: {
    shade: (c, nx, ny) => {
      // Soft directional with fold hint
      const fold = Math.sin(nx*8+ny*4)*0.08;
      const l = (0.5-nx)*0.15 + (0.5-ny)*0.12 + fold;
      return shade(c, l, 0.4);
    }
  },
  leather: {
    shade: (c, nx, ny) => {
      const l = (0.5-nx)*0.2 + (0.5-ny)*0.15;
      return shade(c, l, 0.55);
    }
  },
  ceramic: {
    shade: (c, nx, ny) => {
      const roundness = 1 - Math.sqrt((nx-0.4)**2 + (ny-0.4)**2)*1.2;
      return shade(c, roundness*0.25, 0.3);
    }
  },
  gem: {
    shade: (c, nx, ny) => {
      const facet = Math.sin(nx*6)*Math.cos(ny*6)*0.3;
      const spec = (nx<0.3&&ny<0.3) ? 0.4 : 0;
      return shade(c, facet+spec, 0.1);
    }
  },
  paper: {
    shade: (c, nx, ny) => shade(c, (0.5-ny)*0.08, 0.2)
  },
  flat: {
    shade: (c) => c  // no shading
  },
  cork: {
    shade: (c, nx, ny) => shade(c, (0.4-ny)*0.15, 0.5)
  },
  plant: {
    shade: (c, nx, ny) => {
      const l = (0.5-nx)*0.18 + (0.5-ny)*0.2;
      return shade(c, l, 0.4);
    }
  },
  fire: {
    shade: (c, nx, ny) => shade(c, (0.5-ny)*0.5, 0.8) // very warm, brighter on top
  }
};

// ================================================================
//  V3 CORE: Sprite Template Renderer
// ================================================================
function renderSprite(template, colors, scale) {
  scale = scale || 1;
  const w = template.grid[0].length * scale;
  const h = template.grid.length * scale;
  const pb = new PB(w, h);

  // Pass 1: Fill base colors + per-material shading
  const zones = {}; // track bounding box per material zone
  // Pre-scan for zone bounds
  for (let gy = 0; gy < template.grid.length; gy++) {
    const row = template.grid[gy];
    for (let gx = 0; gx < row.length; gx++) {
      const ch = row[gx];
      if (ch === '.' || !template.materials[ch]) continue;
      if (!zones[ch]) zones[ch] = {x1:gx,y1:gy,x2:gx,y2:gy};
      zones[ch].x1 = Math.min(zones[ch].x1, gx);
      zones[ch].y1 = Math.min(zones[ch].y1, gy);
      zones[ch].x2 = Math.max(zones[ch].x2, gx);
      zones[ch].y2 = Math.max(zones[ch].y2, gy);
    }
  }

  for (let gy = 0; gy < template.grid.length; gy++) {
    const row = template.grid[gy];
    for (let gx = 0; gx < row.length; gx++) {
      const ch = row[gx];
      if (ch === '.') continue;
      const mat = template.materials[ch];
      if (!mat) continue;

      const baseColor = colors[ch] || [128,128,128];
      const shader = MAT_SHADERS[mat.type || mat] || MAT_SHADERS.flat;

      // Normalized position within zone
      const z = zones[ch];
      const zw = z.x2 - z.x1 + 1, zh = z.y2 - z.y1 + 1;
      const nx = zw > 1 ? (gx - z.x1) / (zw - 1) : 0.5;
      const ny = zh > 1 ? (gy - z.y1) / (zh - 1) : 0.5;

      // Apply per-material shading
      let c = shader.shade([...baseColor], nx, ny, zw, zh);

      // Per-pixel noise (very subtle)
      c = nz(c, gx*7, gy*13, 5);

      const alpha = shader.alpha || (mat.alpha) || 255;

      // Fill scaled pixels
      for (let sy = 0; sy < scale; sy++)
        for (let sx = 0; sx < scale; sx++)
          pb.setC(gx*scale+sx, gy*scale+sy, c, alpha);
    }
  }

  // Pass 2: Specular highlights
  // [SailAge] iterate material keys in sorted order instead of
  // `for (const ch in template.materials)` (insertion order). Sorted
  // order keeps output bytes identical regardless of JSON key order
  // (determinism requirement); it can only reorder the specular pass
  // when two specular zones overlap.
  for (const ch of Object.keys(template.materials).sort()) {
    const mat = template.materials[ch];
    const shader = MAT_SHADERS[mat.type || mat] || MAT_SHADERS.flat;
    if (!shader.specular) continue;
    const z = zones[ch]; if (!z) continue;
    const sp = shader.specular;
    const spx = (z.x1 + (z.x2-z.x1) * sp.nx) * scale;
    const spy = (z.y1 + (z.y2-z.y1) * sp.ny) * scale;
    const spr = Math.max(1, sp.r * Math.max(z.x2-z.x1, z.y2-z.y1) * scale);
    for (let y = Math.floor(spy-spr); y <= Math.ceil(spy+spr); y++)
      for (let x = Math.floor(spx-spr); x <= Math.ceil(spx+spr); x++) {
        const c = pb.get(x,y); if (!c) continue;
        const d = Math.sqrt((x-spx)**2+(y-spy)**2);
        if (d > spr) continue;
        const intensity = (1-d/spr)**2 * sp.intensity;
        pb.setC(x, y, shade(c, intensity, 0));
      }
  }

  // Pass 3: Adaptive outline
  const snap = new Uint8ClampedArray(pb.data);
  for (let y = 0; y < pb.h; y++) for (let x = 0; x < pb.w; x++) {
    if (!pb.has(x,y)) continue;
    let isEdge = false;
    for (const [ex,ey] of [[-1,0],[1,0],[0,-1],[0,1]])
      if (!pb.has(x+ex,y+ey)) { isEdge = true; break; }
    if (isEdge) {
      const i = (y*pb.w+x)<<2;
      const c = [snap[i],snap[i+1],snap[i+2]];
      const oc = adaptiveOutlineColor(c);
      pb.data[i]=oc[0]; pb.data[i+1]=oc[1]; pb.data[i+2]=oc[2];
    }
  }

  return pb;
}

// Not extracted from upstream: the browser-only canvas writer `render()`,
// the V2 comparison helpers (`oldDk`/`oldLt`/`oldPP`/`oldSprite`), the demo
// palette `C`, the demo templates `SPRITES`, and the demo scene builders.
// The canvas writer is replaced by the PNG encoder below; demo content is
// not engine math (declarations carry their own grids/colors).

// ==================================================================
// SECTION 2 — PNG ENCODER (first-party; node stdlib zlib only).
// ~50-line encoder: signature + IHDR + [PLTE + tRNS] + IDAT + IEND,
// filter type 0 per scanline, CRC32 per chunk (Adler-32 lives inside
// the zlib stream from deflateSync).
// ==================================================================

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, "ascii");
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

function encodePNG(pb, colorType) {
  const w = pb.w, h = pb.h;
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;          // bit depth
  ihdr[9] = colorType;  // 3 = indexed (palette), 6 = truecolor RGBA
  // ihdr[10..12] = compression 0, filter 0, interlace 0 (alloc zeroed)

  const stride = colorType === 6 ? w * 4 : w;
  const raw = Buffer.alloc((stride + 1) * h);
  let p = 0;

  let plte = null, trns = null;
  if (colorType === 6) {
    for (let y = 0; y < h; y++) {
      raw[p++] = 0; // filter type 0 (None)
      for (let x = 0; x < w; x++) {
        const i = (y * w + x) << 2;
        raw[p++] = pb.data[i]; raw[p++] = pb.data[i + 1];
        raw[p++] = pb.data[i + 2]; raw[p++] = pb.data[i + 3];
      }
    }
  } else {
    // Indexed: palette = distinct RGBA tuples in first-appearance order;
    // per-entry alpha rides in a tRNS chunk (omitted when all opaque).
    const indexOf = new Map();
    const pal = [];
    for (let y = 0; y < h; y++) {
      raw[p++] = 0;
      for (let x = 0; x < w; x++) {
        const i = (y * w + x) << 2;
        const key = pb.data[i] + "," + pb.data[i + 1] + "," + pb.data[i + 2] + "," + pb.data[i + 3];
        let idx = indexOf.get(key);
        if (idx === undefined) {
          if (pal.length >= 256) throw new Error("more than 256 distinct colors; use \"png\": \"rgba\"");
          idx = pal.length;
          pal.push([pb.data[i], pb.data[i + 1], pb.data[i + 2], pb.data[i + 3]]);
          indexOf.set(key, idx);
        }
        raw[p++] = idx;
      }
    }
    plte = Buffer.alloc(pal.length * 3);
    trns = Buffer.alloc(pal.length);
    let anyAlpha = false;
    for (let n = 0; n < pal.length; n++) {
      plte[n * 3] = pal[n][0]; plte[n * 3 + 1] = pal[n][1]; plte[n * 3 + 2] = pal[n][2];
      trns[n] = pal[n][3];
      if (pal[n][3] !== 255) anyAlpha = true;
    }
    if (!anyAlpha) trns = null;
  }

  const idat = zlib.deflateSync(raw, { level: 9 });
  const parts = [
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), // PNG signature
    pngChunk("IHDR", ihdr),
  ];
  if (plte) parts.push(pngChunk("PLTE", plte));
  if (trns) parts.push(pngChunk("tRNS", trns));
  parts.push(pngChunk("IDAT", idat), pngChunk("IEND", Buffer.alloc(0)));
  return Buffer.concat(parts);
}

// ==================================================================
// SECTION 3 — DECLARATION RENDERER (first-party).
// Format documented in render.md:
//   style A "string-map": flat grid rows + palette dict (chrome/arrow/marks)
//   style B "template":   engine grid + materials (+ colors, scale)
// ==================================================================

function parseHexColor(s, what) {
  if (typeof s !== "string" || !/^#[0-9a-fA-F]{6}$/.test(s))
    throw new Error(what + ": expected \"#rrggbb\", got " + JSON.stringify(s));
  return hx(s);
}

function asGrid(key, v) {
  if (!Array.isArray(v) || v.length === 0)
    throw new Error(key + ": must be a non-empty array of strings");
  const w = v[0].length;
  for (let i = 0; i < v.length; i++) {
    const row = v[i];
    if (typeof row !== "string" || row.length !== w)
      throw new Error(key + "[" + i + "]: every row must be a string of the same length");
  }
  return v;
}

function checkDims(decl, w, h) {
  if (decl.width !== undefined && decl.width !== w)
    throw new Error("width " + decl.width + " does not match rendered width " + w);
  if (decl.height !== undefined && decl.height !== h)
    throw new Error("height " + decl.height + " does not match rendered height " + h);
}

function asObject(decl, key) {
  const v = decl[key];
  if (v === undefined) return {};
  if (v === null || typeof v !== "object" || Array.isArray(v))
    throw new Error(key + ": must be a JSON object");
  return v;
}

function renderStringMap(decl, id) {
  const rows = asGrid("rows", decl.rows);
  const w = rows[0].length, h = rows.length;
  checkDims(decl, w, h);
  const palette = decl.palette;
  if (palette === null || typeof palette !== "object" || Array.isArray(palette) || palette === undefined)
    throw new Error("palette: required JSON object mapping chars to \"#rrggbb\" or \"transparent\"");
  const pb = new PB(w, h);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const ch = rows[y][x];
      const spec = palette[ch];
      if (spec === undefined) {
        if (ch === ".") continue; // '.' defaults to transparent
        throw new Error("row " + y + " col " + x + ": char " + JSON.stringify(ch) + " missing from palette");
      }
      if (spec === "transparent") continue;
      const c = parseHexColor(spec, "palette[" + JSON.stringify(ch) + "]");
      pb.set(x, y, c[0], c[1], c[2], 255);
    }
  }
  return pb;
}

function renderTemplate(decl, id) {
  const grid = asGrid("grid", decl.grid);
  const materials = decl.materials;
  if (materials === null || typeof materials !== "object" || Array.isArray(materials) || materials === undefined)
    throw new Error("materials: required JSON object mapping chars to a material name or {\"type\", \"alpha\"}");
  for (const ch of Object.keys(materials)) {
    const m = materials[ch];
    if (typeof m !== "string" && (m === null || typeof m !== "object"))
      throw new Error("materials[" + JSON.stringify(ch) + "]: must be a material name string or an object");
  }
  let scale = decl.scale === undefined ? 1 : decl.scale;
  if (!Number.isInteger(scale) || scale < 1 || scale > 64)
    throw new Error("scale: must be an integer in 1..64, got " + JSON.stringify(decl.scale));
  const colors = asObject(decl, "colors");
  const parsed = {};
  for (const ch of Object.keys(colors))
    parsed[ch] = parseHexColor(colors[ch], "colors[" + JSON.stringify(ch) + "]");
  const w = grid[0].length * scale, h = grid.length * scale;
  checkDims(decl, w, h);
  // Rendered by the vendored engine core (hue-shift shading, per-material
  // shaders, specular pass, adaptive outline). Unknown material names fall
  // back to `flat` exactly as upstream; missing colors default to #808080.
  const pb = renderSprite({ grid: grid, materials: materials }, parsed, scale);
  if (decl.background !== undefined) {
    // [SailAge] `background` fills fully-transparent pixels after the
    // render (upstream demos pre-fill the canvas before blitting; the
    // visible result for a single sprite is the same).
    const bg = parseHexColor(decl.background, "background");
    for (let y = 0; y < pb.h; y++)
      for (let x = 0; x < pb.w; x++)
        if (!pb.has(x, y)) pb.set(x, y, bg[0], bg[1], bg[2], 255);
  }
  return pb;
}

function renderDeclaration(decl) {
  if (decl === null || typeof decl !== "object" || Array.isArray(decl))
    throw new Error("declaration must be a JSON object");
  const id = decl.id;
  if (typeof id !== "string" || id === "") throw new Error("id: required non-empty string");
  const file = decl.file;
  if (typeof file !== "string" || file === "") throw new Error(id + ": file: required non-empty output path string");

  let mode = decl.mode;
  if (mode === undefined) mode = decl.rows !== undefined ? "string-map" : (decl.grid !== undefined ? "template" : undefined);
  if (mode === undefined) throw new Error(id + ": mode: required (\"string-map\" or \"template\"), or provide \"rows\"/\"grid\"");
  if (mode !== "string-map" && mode !== "template")
    throw new Error(id + ": mode: must be \"string-map\" or \"template\", got " + JSON.stringify(mode));

  let colorType;
  if (decl.png === undefined) colorType = mode === "template" ? 6 : 3;
  else if (decl.png === "indexed") colorType = 3;
  else if (decl.png === "rgba") colorType = 6;
  else throw new Error(id + ": png: must be \"indexed\" or \"rgba\", got " + JSON.stringify(decl.png));

  const pb = mode === "string-map" ? renderStringMap(decl, id) : renderTemplate(decl, id);
  const pngMode = decl.png === undefined ? (colorType === 6 ? "rgba" : "indexed") : decl.png;
  return { id: id, file: file, bytes: encodePNG(pb, colorType), w: pb.w, h: pb.h, pngMode: pngMode };
}

// ==================================================================
// SECTION 4 — CLI
// ==================================================================

function main(argv) {
  if (argv.length === 0) {
    process.stderr.write("usage: node render.js <declaration.json> [<declaration2.json> ...]\n" +
      "  each JSON file holds one sprite declaration, an array of them, or {\"sprites\": [...]}\n" +
      "  format: see render.md; output paths in \"file\" resolve against the current directory\n");
    return 2;
  }
  for (const arg of argv) {
    let text, json;
    try {
      text = fs.readFileSync(arg, "utf8");
    } catch (e) {
      process.stderr.write("render.js: " + arg + ": cannot read file: " + e.message + "\n");
      return 2;
    }
    try {
      json = JSON.parse(text);
    } catch (e) {
      process.stderr.write("render.js: " + arg + ": invalid JSON: " + e.message + "\n");
      return 2;
    }
    const decls = Array.isArray(json) ? json
      : (json !== null && typeof json === "object" && Array.isArray(json.sprites)) ? json.sprites
      : [json];
    if (decls.length === 0) {
      process.stderr.write("render.js: " + arg + ": no sprite declarations found\n");
      return 2;
    }
    for (const decl of decls) {
      let out;
      try {
        out = renderDeclaration(decl);
      } catch (e) {
        const label = decl && typeof decl.id === "string" ? decl.id : "?";
        process.stderr.write("render.js: " + arg + ": sprite " + JSON.stringify(label) + ": " + e.message + "\n");
        return 2;
      }
      const dest = path.resolve(out.file);
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.writeFileSync(dest, out.bytes);
      process.stdout.write("rendered " + out.id + " -> " + out.file + " (" + out.w + "x" + out.h + ", " + out.pngMode + ")\n");
    }
  }
  return 0;
}

process.exitCode = main(process.argv.slice(2));
