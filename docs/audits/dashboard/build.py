#!/usr/bin/env python3
"""Builds docs/audits/dashboard/index.html from the structured audit data.

The page must work from file:// with no network access, so every data set is embedded.
Run: python3 docs/audits/dashboard/build.py
"""
import json
import os
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
AUDIT = HERE.parent
ROOT = AUDIT.parent.parent

findings = json.loads((AUDIT / "findings.json").read_text())
bench = json.loads((AUDIT / "benchmarks" / "results.json").read_text())
inventory = json.loads((AUDIT / "benchmarks" / "code-inventory.json").read_text())

AREAS = {
    "engine": "engine",
    "app": "app/macos/Dalnok",
    "cli": "tools/dalnok-cli",
    "scanner": "tools/dalnok-scan",
    "tests": "tests/engine",
}
CODE_EXT = {".cpp", ".hpp", ".h", ".mm", ".swift"}


def area_files(rel):
    out = []
    base = ROOT / rel
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in (".build", "third_party", "fixtures", ".git")]
        for name in filenames:
            p = Path(dirpath) / name
            if "/third_party/" in str(p):
                continue
            if p.suffix in CODE_EXT:
                try:
                    lines = sum(1 for _ in p.open(encoding="utf-8", errors="ignore"))
                except OSError:
                    lines = 0
                out.append({"path": str(p.relative_to(ROOT)), "lines": lines})
    return sorted(out, key=lambda x: -x["lines"])


for key, rel in AREAS.items():
    inventory["areas"][key]["files"] = area_files(rel)

AREA_INFO = [
    {
        "id": "engine",
        "name": "Engine core",
        "health": "strained",
        "role": "Owns the project model, undo, transport, recording, MIDI, routing, launcher and offline rendering.",
        "depends": ["DalnokDSP", "platform/macos", "fx", "import"],
        "findings": ["A-03", "A-04", "A-06", "A-22"],
        "notes": "One class, 117 methods, 2,526 lines. Correct but at the point where every new feature widens the same surface.",
    },
    {
        "id": "app",
        "name": "AppKit front end",
        "health": "fair",
        "role": "Custom-drawn arrangement, headers, mixer, piano roll, device panel, settings, both themes.",
        "depends": ["C API only"],
        "findings": ["A-05", "A-08", "A-17", "A-18"],
        "notes": "Good view ownership and no model mirror; refresh is whole-model and blocks the drag path.",
    },
    {
        "id": "tests",
        "name": "Engine tests",
        "health": "good",
        "role": "188 tests in 57 suites through the C API, with generated fixtures and numeric tolerances.",
        "depends": ["C API"],
        "findings": ["A-10", "A-18"],
        "notes": "Strong on behaviour and determinism; no fuzzing, no UI performance gate.",
    },
    {
        "id": "cli",
        "name": "Headless CLI",
        "health": "good",
        "role": "Smoke tests, rendering, import, recording, benchmarks and the new audit measurements.",
        "depends": ["C API"],
        "findings": ["A-19"],
        "notes": "The only place a performance regression can currently be measured reproducibly.",
    },
    {
        "id": "scanner",
        "name": "Plug-in scanner",
        "health": "good",
        "role": "Validates one plug-in per process with a timeout and caches the result.",
        "depends": ["VST3/CLAP headers"],
        "findings": ["A-01"],
        "notes": "The containment pattern the app itself still lacks.",
    },
]

ROADMAP = [
    {
        "phase": "Phase 0 — Stop the bleeding",
        "goal": "Bound data loss before anything else changes.",
        "items": [
            {"order": 1, "id": "A-02", "title": "Autosave and project crash recovery", "effort": "M", "depends": []},
            {"order": 2, "id": "A-23", "title": "Regenerate the capability matrix from tests", "effort": "S", "depends": []},
            {"order": 3, "id": "A-01a", "title": "Snapshot before plug-in initialisation", "effort": "S", "depends": ["A-02"]},
            {"order": 4, "id": "A-01", "title": "Out-of-process plug-in hosting", "effort": "XL", "depends": ["A-02", "A-01a"]},
        ],
    },
    {
        "phase": "Phase 1 — Make the model scale",
        "goal": "Remove whole-model work from interactive paths.",
        "items": [
            {"order": 5, "id": "A-04a", "title": "Linear compile: bucket clips by track", "effort": "S", "depends": []},
            {"order": 6, "id": "A-03a", "title": "Parameter edits skip the model copy", "effort": "M", "depends": []},
            {"order": 7, "id": "A-07", "title": "Share plug-in state as immutable blobs", "effort": "S", "depends": ["A-03a"]},
            {"order": 8, "id": "A-05a", "title": "Skip refresh for parameter-only revisions", "effort": "S", "depends": ["A-03a"]},
            {"order": 9, "id": "A-05", "title": "Change sets and incremental UI refresh", "effort": "L", "depends": ["A-05a", "A-15"]},
            {"order": 10, "id": "A-04", "title": "Incremental snapshot compilation", "effort": "M", "depends": ["A-04a"]},
            {"order": 11, "id": "A-03", "title": "Structurally shared undo model", "effort": "L", "depends": ["A-03a", "A-07"]},
        ],
    },
    {
        "phase": "Phase 2 — Reliability hardening",
        "goal": "Make failures observable and containable.",
        "items": [
            {"order": 12, "id": "A-08", "title": "Async plug-in activation with progress and cancel", "effort": "L", "depends": ["A-01a"]},
            {"order": 13, "id": "A-10", "title": "Fuzzing, property tests, local sanitizer pass", "effort": "M", "depends": []},
            {"order": 14, "id": "A-14", "title": "Handoff health metrics and test", "effort": "S", "depends": []},
            {"order": 15, "id": "A-16", "title": "Project schema and migration chain", "effort": "M", "depends": ["A-10"]},
            {"order": 16, "id": "A-18", "title": "Deterministic self-test harness", "effort": "M", "depends": []},
        ],
    },
    {
        "phase": "Phase 3 — Structural clarity",
        "goal": "Make one feature touch one place.",
        "items": [
            {"order": 17, "id": "A-06", "title": "Extract engine services from the god object", "effort": "L", "depends": ["A-04"]},
            {"order": 18, "id": "A-15", "title": "Generate or bulk-load C API model DTOs", "effort": "L", "depends": ["A-05", "A-06"]},
            {"order": 19, "id": "A-19", "title": "Split build targets and add a compile cache", "effort": "M", "depends": ["A-06"]},
            {"order": 20, "id": "A-17", "title": "Inject theme values, allow live switching", "effort": "M", "depends": []},
        ],
    },
    {
        "phase": "Phase 4 — Media and DSP headroom",
        "goal": "Long sessions and measurable audio headroom.",
        "items": [
            {"order": 21, "id": "A-09", "title": "Disk streaming with guaranteed residency", "effort": "XL", "depends": ["A-04"]},
            {"order": 22, "id": "A-11", "title": "Skip silent tracks per block", "effort": "M", "depends": ["A-04"]},
            {"order": 23, "id": "A-12", "title": "Denormal and FP-environment guard", "effort": "S", "depends": []},
            {"order": 24, "id": "A-13", "title": "SIMD for copy, fades, ramp and meters", "effort": "M", "depends": ["A-11"]},
        ],
    },
    {
        "phase": "Phase 5 — Optional cleanup",
        "goal": "Small consistency work, done alongside real changes.",
        "items": [
            {"order": 25, "id": "A-20", "title": "Central policy header for real-time constants", "effort": "S", "depends": []},
            {"order": 26, "id": "A-21", "title": "Error classes in the C API", "effort": "S", "depends": []},
            {"order": 27, "id": "A-22", "title": "Decide the undo rule for view-only state", "effort": "S", "depends": []},
        ],
    },
]

TEMPLATE = r'''<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dalnok — Engineering Audit 2026-11</title>
<style>
:root{
  --bg:#0c1014; --panel:#141a21; --panel2:#1a222b; --text:#e8eef6; --muted:#94a3b3;
  --line:#25313c; --accent:#4fd1c5; --accent2:#8ab4f8; --p0:#ff6b6b; --p1:#ffa94d; --p2:#4dabf7; --p3:#9aa7b4;
  --good:#51cf66; --warn:#ffd43b; --shadow:0 10px 30px rgba(0,0,0,.35);
}
[data-theme="light"]{
  --bg:#f3f6f9; --panel:#ffffff; --panel2:#eef3f8; --text:#101820; --muted:#56626e;
  --line:#d7e0e8; --accent:#0f8f84; --accent2:#2258a8; --p0:#c92a2a; --p1:#b35c00; --p2:#1668b3; --p3:#5c6773;
  --good:#2b8a3e; --warn:#9c6f00; --shadow:0 8px 22px rgba(20,40,60,.10);
}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{background:var(--bg);color:var(--text);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,system-ui,sans-serif}
a{color:var(--accent2)}
.skip{position:absolute;left:-9999px;top:0;background:var(--accent);color:#04110f;padding:8px 12px;z-index:99}
.skip:focus{left:8px;top:8px}
.topbar{position:sticky;top:0;z-index:30;display:flex;flex-wrap:wrap;gap:12px;align-items:center;
  padding:12px clamp(14px,3vw,32px);background:color-mix(in srgb,var(--bg) 88%,transparent);
  backdrop-filter:blur(8px);border-bottom:1px solid var(--line)}
.brand{font-weight:700;letter-spacing:.2px;font-size:16px}
.brand span{color:var(--accent)}
.rev{font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted)}
.spacer{flex:1}
.search{display:flex;align-items:center;gap:8px;background:var(--panel);border:1px solid var(--line);
  border-radius:8px;padding:6px 10px;min-width:min(320px,60vw)}
.search input{background:none;border:0;color:var(--text);outline:none;width:100%;font:inherit;font-size:14px}
.btn{background:var(--panel);border:1px solid var(--line);color:var(--text);border-radius:8px;
  padding:7px 11px;font:inherit;font-size:13px;cursor:pointer}
.btn:hover{border-color:var(--accent)}
.btn:focus-visible, .tab:focus-visible, .chip:focus-visible, .card:focus-visible, tr[tabindex]:focus-visible,
  circle.matrix-dot:focus-visible, .road-item:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.tabs{display:flex;gap:4px;overflow-x:auto;padding:10px clamp(14px,3vw,32px) 0;border-bottom:1px solid var(--line)}
.tab{background:none;border:0;border-bottom:2px solid transparent;color:var(--muted);padding:9px 12px;
  font:inherit;font-size:14px;cursor:pointer;white-space:nowrap}
.tab[aria-selected="true"]{color:var(--text);border-bottom-color:var(--accent)}
main{max-width:1280px;margin:0 auto;padding:24px clamp(14px,3vw,32px) 80px}
.panel[hidden]{display:none}
h1{font-size:clamp(22px,2.6vw,30px);margin:4px 0 6px}
h2{font-size:20px;margin:30px 0 12px}
h3{font-size:15px;margin:0 0 8px;letter-spacing:.2px;text-transform:uppercase;color:var(--muted)}
p{margin:0 0 12px}
.lead{color:var(--muted);max-width:80ch}
.grid{display:grid;gap:14px}
.g2{grid-template-columns:repeat(2,minmax(0,1fr))}
.g3{grid-template-columns:repeat(3,minmax(0,1fr))}
.g4{grid-template-columns:repeat(4,minmax(0,1fr))}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px;box-shadow:var(--shadow)}
.card.click{cursor:pointer}
.card.click:hover{border-color:var(--accent)}
.kpi{font:600 clamp(22px,2.4vw,30px)/1.1 ui-monospace,SFMono-Regular,Menlo,monospace}
.kpi.small{font-size:18px}
.muted{color:var(--muted)}
.tiny{font-size:12px}
.pill{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11.5px;font-weight:700;letter-spacing:.3px}
.pill.P0{background:color-mix(in srgb,var(--p0) 18%,transparent);color:var(--p0);border:1px solid color-mix(in srgb,var(--p0) 45%,transparent)}
.pill.P1{background:color-mix(in srgb,var(--p1) 18%,transparent);color:var(--p1);border:1px solid color-mix(in srgb,var(--p1) 45%,transparent)}
.pill.P2{background:color-mix(in srgb,var(--p2) 18%,transparent);color:var(--p2);border:1px solid color-mix(in srgb,var(--p2) 45%,transparent)}
.pill.P3{background:color-mix(in srgb,var(--p3) 18%,transparent);color:var(--p3);border:1px solid color-mix(in srgb,var(--p3) 45%,transparent)}
.pill.effort{background:var(--panel2);color:var(--muted);border:1px solid var(--line)}
.tag{display:inline-block;padding:2px 7px;border-radius:6px;background:var(--panel2);border:1px solid var(--line);
  font-size:11.5px;color:var(--muted);margin:2px 4px 2px 0}
table{width:100%;border-collapse:collapse;font-size:13.5px}
th,td{text-align:left;padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:11.5px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);font-weight:600;position:sticky;top:0;background:var(--panel)}
tbody tr:hover{background:var(--panel2)}
tr[data-id]{cursor:pointer}
.num{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-variant-numeric:tabular-nums}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
.chips{display:flex;gap:6px;flex-wrap:wrap}
.chip{background:var(--panel);border:1px solid var(--line);border-radius:999px;padding:5px 11px;font:inherit;
  font-size:12.5px;color:var(--muted);cursor:pointer}
.chip[aria-pressed="true"]{color:var(--text);border-color:var(--accent);background:color-mix(in srgb,var(--accent) 14%,transparent)}
select{background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:8px;padding:6px 9px;font:inherit;font-size:13px}
.filters{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px;margin:12px 0}
label.f{display:flex;flex-direction:column;gap:5px;font-size:11.5px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted)}
.count{color:var(--muted);font-size:13px}
dialog{border:1px solid var(--line);border-radius:14px;background:var(--panel);color:var(--text);
  padding:0;max-width:820px;width:calc(100vw - 32px);max-height:88vh;box-shadow:var(--shadow)}
dialog::backdrop{background:rgba(0,0,0,.55)}
.dlg-head{display:flex;gap:12px;align-items:flex-start;padding:18px 20px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--panel)}
.dlg-body{padding:18px 20px 24px;overflow:auto;max-height:calc(88vh - 74px)}
.dlg-title{margin:0;font-size:18px}
.close{margin-left:auto;background:none;border:1px solid var(--line);color:var(--muted);border-radius:8px;
  width:32px;height:32px;font-size:16px;cursor:pointer}
.section{margin-top:18px}
.section h4{margin:0 0 6px;font-size:12px;text-transform:uppercase;letter-spacing:.6px;color:var(--muted)}
ul{margin:0 0 10px;padding-left:20px}
li{margin:3px 0}
code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px;background:var(--panel2);padding:1px 5px;border-radius:4px}
pre{background:var(--panel2);border:1px solid var(--line);border-radius:8px;padding:10px;overflow:auto;font-size:12px}
.bar{height:6px;border-radius:3px;background:var(--panel2);overflow:hidden;margin-top:4px}
.bar>span{display:block;height:100%;background:var(--accent)}
.chart{width:100%;height:auto;overflow:visible}
.chart text{fill:var(--muted);font-size:11px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.chart .axis{stroke:var(--line);stroke-width:1}
.chart .grid{stroke:var(--line);stroke-width:1;stroke-dasharray:3 4;opacity:.6}
.chart .b1{fill:var(--accent)}
.chart .b2{fill:color-mix(in srgb,var(--accent) 34%,transparent)}
.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--muted);margin-top:6px}
.sw{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:5px;vertical-align:middle}
.diagram{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:10px;overflow:auto}
.node{fill:var(--panel2);stroke:var(--line);stroke-width:1.2}
.node.ok{stroke:var(--good)}
.node.warn{stroke:var(--warn)}
.edge{stroke:var(--muted);stroke-width:1.2;fill:none;marker-end:url(#arrow)}
.edge-label{fill:var(--muted);font-size:10.5px}
.arch{display:grid;gap:14px;grid-template-columns:1fr 1fr}
.arch-col h3{display:flex;gap:8px;align-items:center;text-transform:none;font-size:14px;color:var(--text)}
.arch-item{border:1px solid var(--line);border-radius:9px;padding:9px 11px;margin:7px 0;background:var(--panel2);font-size:13px}
.arch-item b{display:block;font-size:13.5px}
.arch-item.keep{border-left:4px solid var(--good)}
.arch-item.move{border-left:4px solid var(--warn)}
.arch-item.new{border-left:4px solid var(--accent2)}
.road{display:grid;gap:16px}
.phase{border:1px solid var(--line);border-radius:12px;background:var(--panel);padding:14px 16px}
.phase h3{text-transform:none;color:var(--text);font-size:15px;margin-bottom:2px}
.road-item{display:grid;grid-template-columns:26px 1fr auto;gap:10px;align-items:start;padding:9px 0;border-top:1px solid var(--line)}
.road-item:first-of-type{border-top:0}
.road-item .title{font-size:14px}
.road-item.done .title{text-decoration:line-through;color:var(--muted)}
.blocked{color:var(--warn);font-size:11.5px}
.area-list{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px}
.area{border:1px solid var(--line);border-radius:10px;padding:12px;background:var(--panel2);cursor:pointer;text-align:left;color:var(--text);font:inherit}
.area[aria-pressed="true"]{border-color:var(--accent);box-shadow:inset 0 0 0 1px var(--accent)}
.health{font-size:11px;text-transform:uppercase;letter-spacing:.5px}
.health.good{color:var(--good)} .health.fair{color:var(--warn)} .health.strained{color:var(--p0)}
.matrix-wrap{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:8px}
.matrix-dot{cursor:pointer}
.note{border-left:3px solid var(--warn);background:color-mix(in srgb,var(--warn) 8%,transparent);padding:10px 12px;border-radius:6px;font-size:13.5px}
.kv{display:grid;grid-template-columns:180px 1fr;gap:6px 14px;font-size:13.5px}
.kv dt{color:var(--muted)}
.kv dd{margin:0}
.tooltip{position:fixed;pointer-events:none;background:var(--panel);border:1px solid var(--line);border-radius:8px;
  padding:6px 9px;font-size:12px;box-shadow:var(--shadow);opacity:0;transition:opacity .12s;z-index:50}
.tooltip.on{opacity:1}
@media (max-width: 980px){
  .g4{grid-template-columns:repeat(2,minmax(0,1fr))}
  .g3{grid-template-columns:1fr}
  .arch{grid-template-columns:1fr}
}
@media (max-width: 620px){
  .g2,.g4{grid-template-columns:1fr}
  .kv{grid-template-columns:1fr}
  main{padding-bottom:60px}
}
@media (prefers-reduced-motion: reduce){*{transition:none!important;animation:none!important}}
</style>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="topbar">
  <div>
    <div class="brand">Dalnok <span>engineering audit</span></div>
    <div class="rev">rev b15410a · 0.1.0 · 2026-11-18</div>
  </div>
  <div class="spacer"></div>
  <div class="search" role="search">
    <span aria-hidden="true">⌕</span>
    <input id="q" type="search" placeholder="Search findings  ( / )" aria-label="Search findings">
  </div>
  <button class="btn" id="export" type="button">Export findings</button>
  <button class="btn" id="theme" type="button" aria-label="Switch colour theme">Light / dark</button>
</header>

<nav class="tabs" role="tablist" aria-label="Audit sections">
  <button class="tab" role="tab" id="tab-overview" aria-controls="overview" aria-selected="true" data-tab="overview">Overview</button>
  <button class="tab" role="tab" id="tab-codebase" aria-controls="codebase" aria-selected="false" data-tab="codebase" tabindex="-1">Codebase</button>
  <button class="tab" role="tab" id="tab-performance" aria-controls="performance" aria-selected="false" data-tab="performance" tabindex="-1">Performance</button>
  <button class="tab" role="tab" id="tab-findings" aria-controls="findings" aria-selected="false" data-tab="findings" tabindex="-1">Findings</button>
  <button class="tab" role="tab" id="tab-roadmap" aria-controls="roadmap" aria-selected="false" data-tab="roadmap" tabindex="-1">Roadmap</button>
  <button class="tab" role="tab" id="tab-matrix" aria-controls="matrix" aria-selected="false" data-tab="matrix" tabindex="-1">Impact / effort</button>
  <button class="tab" role="tab" id="tab-architecture" aria-controls="architecture" aria-selected="false" data-tab="architecture" tabindex="-1">Architecture</button>
  <button class="tab" role="tab" id="tab-method" aria-controls="method" aria-selected="false" data-tab="method" tabindex="-1">Method</button>
</nav>

<main id="main">
  <section class="panel" id="overview" role="tabpanel" aria-labelledby="tab-overview" tabindex="-1"></section>
  <section class="panel" id="codebase" role="tabpanel" aria-labelledby="tab-codebase" tabindex="-1" hidden></section>
  <section class="panel" id="performance" role="tabpanel" aria-labelledby="tab-performance" tabindex="-1" hidden></section>
  <section class="panel" id="findings" role="tabpanel" aria-labelledby="tab-findings" tabindex="-1" hidden></section>
  <section class="panel" id="roadmap" role="tabpanel" aria-labelledby="tab-roadmap" tabindex="-1" hidden></section>
  <section class="panel" id="matrix" role="tabpanel" aria-labelledby="tab-matrix" tabindex="-1" hidden></section>
  <section class="panel" id="architecture" role="tabpanel" aria-labelledby="tab-architecture" tabindex="-1" hidden></section>
  <section class="panel" id="method" role="tabpanel" aria-labelledby="tab-method" tabindex="-1" hidden></section>
</main>

<dialog id="detail" aria-labelledby="dlg-title">
  <div class="dlg-head">
    <div>
      <div class="row" id="dlg-tags"></div>
      <h2 class="dlg-title" id="dlg-title">Finding</h2>
    </div>
    <button class="close" id="dlg-close" type="button" aria-label="Close">✕</button>
  </div>
  <div class="dlg-body" id="dlg-body"></div>
</dialog>
<div class="tooltip" id="tip" role="status" aria-live="polite"></div>

<script type="application/json" id="data-findings">__FINDINGS__</script>
<script type="application/json" id="data-bench">__BENCH__</script>
<script type="application/json" id="data-inventory">__INVENTORY__</script>
<script type="application/json" id="data-areas">__AREAS__</script>
<script type="application/json" id="data-roadmap">__ROADMAP__</script>
<script>
(function(){
  "use strict";
  const A = JSON.parse(document.getElementById('data-findings').textContent);
  const B = JSON.parse(document.getElementById('data-bench').textContent);
  const INV = JSON.parse(document.getElementById('data-inventory').textContent);
  const AREAS = JSON.parse(document.getElementById('data-areas').textContent);
  const ROAD = JSON.parse(document.getElementById('data-roadmap').textContent);
  const F = A.findings;
  const $ = (s, r) => (r || document).querySelector(s);
  const $$ = (s, r) => Array.prototype.slice.call((r || document).querySelectorAll(s));
  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const PR = {P0:0, P1:1, P2:2, P3:3};
  const EFF = {S:1, M:2, L:3, XL:4};
  const state = {tab: 'overview', q: '', pr: new Set(), cat: 'all', sub: 'all', sort: 'priority',
                 metric: 'value', area: 'engine', showAll: false};
  const store = {
    get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }
  };

  const byId = id => F.find(f => f.id === id);
  const pct = (a, b) => b ? Math.round(a / b * 100) : 0;

  /* ---------- theme ---------- */
  const savedTheme = store.get('dalnok.audit.theme', null);
  if (savedTheme) document.documentElement.setAttribute('data-theme', savedTheme);
  $('#theme').addEventListener('click', () => {
    const next = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    store.set('dalnok.audit.theme', next);
  });

  /* ---------- tabs ---------- */
  const TABS = ['overview','codebase','performance','findings','roadmap','matrix','architecture','method'];
  function showTab(name, focusPanel) {
    if (TABS.indexOf(name) < 0) name = 'overview';
    state.tab = name;
    TABS.forEach(t => {
      const tab = $('#tab-' + t), panel = document.getElementById(t);
      const on = t === name;
      tab.setAttribute('aria-selected', on ? 'true' : 'false');
      tab.tabIndex = on ? 0 : -1;
      panel.hidden = !on;
    });
    if (focusPanel) document.getElementById(name).focus({preventScroll: true});
    window.scrollTo(0, 0);
    renderPanel(name);
  }
  $$('.tab').forEach(tab => {
    tab.addEventListener('click', () => showTab(tab.dataset.tab));
    tab.addEventListener('keydown', e => {
      const i = TABS.indexOf(tab.dataset.tab);
      if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
        e.preventDefault();
        const n = (i + (e.key === 'ArrowRight' ? 1 : TABS.length - 1)) % TABS.length;
        const next = $('#tab-' + TABS[n]);
        next.focus(); showTab(TABS[n]);
      }
    });
  });

  /* ---------- overview ---------- */
  function priorityCount(p) { return F.filter(f => f.priority === p).length; }
  function renderOverview() {
    const t = B.engineScaling.runs;
    const top = F.slice().sort((a, b) => PR[a.priority] - PR[b.priority] || b.impact.value - a.impact.value).slice(0, 10);
    $('#overview').innerHTML = `
      <h1>Dalnok 0.1.0 — independent engineering audit</h1>
      <p class="lead">A C++20 real-time engine behind a plain C API, with a native AppKit front end.
      The audio path is fast and the real-time contract is enforced by the compiler. The risks are
      failure containment, whole-model work per interaction, and growth assumptions that have not been
      paid for yet. ${F.length} findings, prioritised and evidenced.</p>

      <div class="grid g4" style="margin-top:18px">
        <div class="card"><div class="muted tiny">Findings</div><div class="kpi">${F.length}</div>
          <div class="tiny muted">${priorityCount('P0')} critical · ${priorityCount('P1')} high · ${priorityCount('P2')} medium · ${priorityCount('P3')} low</div></div>
        <div class="card"><div class="muted tiny">Engine tests (audit baseline)</div><div class="kpi">${B.tests.engineTests}</div>
          <div class="tiny muted">${B.tests.engineSuites} suites · ${B.tests.wallSeconds}s wall · all passing</div></div>
        <div class="card"><div class="muted tiny">Live path, 64 tracks</div><div class="kpi">${t[1].avgUs}<span class="tiny"> µs</span></div>
          <div class="tiny muted">${t[1].loadPercent}% of a 10.67 ms block · 512-frame blocks</div></div>
        <div class="card"><div class="muted tiny">Full model read, 4,096 clips (audit baseline)</div><div class="kpi">15.9<span class="tiny"> ms</span></div>
          <div class="tiny muted">a 60 Hz frame is 16.7 ms</div></div>
      </div>

      <h2>Assessment</h2>
      <div class="grid g3">
        <div class="card"><h3>Strengths</h3><ul class="tiny" style="font-size:13px">
          <li>Compile-time real-time safety: <code>[[clang::nonblocking]]</code> with <code>-Werror=function-effects</code> and a negative test.</li>
          <li>Engine-owned model, revision counter, no UI mirror, all edits undoable and scriptable.</li>
          <li>Immutable render snapshots through one atomic slot; atomics for continuous parameters.</li>
          <li>Generated fixtures and numeric-tolerance tests; durable, atomic project writes.</li>
        </ul></div>
        <div class="card"><h3>Principal risks</h3><ul class="tiny" style="font-size:13px">
          <li>In-process third-party plug-ins can crash or hang the app; recovery snapshots mitigate data loss.</li>
          <li>Structural edits still retain whole-model undo snapshots and rebuild the render snapshot.</li>
          <li>Structural revisions still trigger a full UI model read; parameter-only refresh has a fast path.</li>
          <li>Media is fully decoded into RAM; no streaming, no long-session test.</li>
        </ul></div>
        <div class="card"><h3>Most valuable next moves</h3><ul class="tiny" style="font-size:13px">
          <li>Out-of-process plug-in hosting and further recovery validation.</li>
          <li>Incremental snapshot compilation.</li>
          <li>Change sets so the UI touches only what moved.</li>
          <li>Disk streaming before the session size grows further.</li>
        </ul></div>
      </div>

      <h2>Technical debt distribution</h2>
      <p class="lead tiny">A judgement based on severity and effort, not a measured quantity.</p>
      <div class="grid" style="gap:10px;margin-top:8px">
        <div class="card"><div class="row"><b style="min-width:230px">Reliability and containment</b><span class="muted tiny">30%</span></div><div class="bar"><span style="width:30%;background:var(--p0)"></span></div></div>
        <div class="card"><div class="row"><b style="min-width:230px">Model and sync scalability</b><span class="muted tiny">30%</span></div><div class="bar"><span style="width:30%;background:var(--p1)"></span></div></div>
        <div class="card"><div class="row"><b style="min-width:230px">Architecture and module shape</b><span class="muted tiny">20%</span></div><div class="bar"><span style="width:20%;background:var(--p1)"></span></div></div>
        <div class="card"><div class="row"><b style="min-width:230px">Media and memory</b><span class="muted tiny">10%</span></div><div class="bar"><span style="width:10%;background:var(--p2)"></span></div></div>
        <div class="card"><div class="row"><b style="min-width:230px">Tooling and documentation</b><span class="muted tiny">10%</span></div><div class="bar"><span style="width:10%;background:var(--p3)"></span></div></div>
      </div>

      <h2>Ten most important improvements</h2>
      <div class="card" style="padding:6px 16px">
        <table><tbody>
        ${top.map((f, i) => `<tr data-id="${f.id}" tabindex="0" role="button" aria-label="Open ${esc(f.id)}">
          <td class="num" style="width:28px;color:var(--muted)">${i + 1}</td>
          <td style="width:64px"><span class="pill ${f.priority}">${f.priority}</span></td>
          <td><b>${esc(f.title)}</b><div class="tiny muted">${esc(f.summary)}</div></td>
          <td class="num tiny" style="width:52px">${esc(f.effort)}</td></tr>`).join('')}
        </tbody></table>
      </div>
      <p class="tiny muted" style="margin-top:10px">Audit scope: engine, C API, macOS front end, tests, tools, build and CI at rev b15410a.
      Not measured: timeline scroll/zoom frame time, cold launch, third-party plug-in cost, multi-hour soak.
      Measurement-only code: two <code>dalnok-cli</code> subcommands. No product behaviour changed.</p>`;
    bindRows($('#overview'));
  }

  /* ---------- codebase explorer ---------- */
  function renderCodebase() {
    const area = state.area;
    const info = AREAS.find(a => a.id === area);
    const inv = INV.areas[area] || {loc: 0, code_files: 0, languages: {}, files: []};
    const largest = INV.largest_files.slice(0, 12);
    const totalLoc = Object.values(INV.areas).reduce((s, a) => s + a.loc, 0);
    const langColors = {'C++': 'var(--accent)', 'Swift': 'var(--accent2)', 'C/C++ header': 'var(--warn)', 'Objective-C++': 'var(--p1)'};
    $('#codebase').innerHTML = `
      <h1>Codebase explorer</h1>
      <p class="lead">${totalLoc.toLocaleString()} lines of first-party code across ${Object.values(INV.areas).reduce((s,a)=>s+a.code_files,0)} files.
      Dependencies point one way: the front end only ever sees the C API.</p>

      <div class="area-list" style="margin:16px 0">
        ${AREAS.map(a => `<button class="area" data-area="${a.id}" aria-pressed="${a.id === area}">
          <div class="row" style="justify-content:space-between"><b>${esc(a.name)}</b>
          <span class="health ${a.health}">${a.health}</span></div>
          <div class="tiny muted" style="margin-top:5px">${INV.areas[a.id].loc.toLocaleString()} LOC · ${INV.areas[a.id].code_files} files</div>
        </button>`).join('')}
      </div>

      <div class="grid g2">
        <div class="card">
          <h3>${esc(info.name)}</h3>
          <p style="font-size:13.5px">${esc(info.role)}</p>
          <dl class="kv tiny">
            <dt>Depends on</dt><dd>${info.depends.map(d => `<span class="tag">${esc(d)}</span>`).join('')}</dd>
            <dt>Related findings</dt><dd>${info.findings.map(id => {
              const f = byId(id);
              return f ? `<button class="chip" data-open="${id}">${id} · ${esc(f.priority)}</button>` : `<span class="tag">${id}</span>`;
            }).join(' ')}</dd>
            <dt>Assessment</dt><dd>${esc(info.notes)}</dd>
          </dl>
        </div>
        <div class="card">
          <h3>Largest files in this area</h3>
          <table><tbody>${(inv.files || []).slice(0, 9).map(f => `<tr>
            <td class="num tiny">${f.lines.toLocaleString()}</td>
            <td class="tiny"><code>${esc(f.path)}</code></td></tr>`).join('')}</tbody></table>
        </div>
      </div>

      <h2>Dependency direction</h2>
      <div class="diagram">
        <svg class="chart" viewBox="0 0 900 300" role="img" aria-label="Module dependency diagram: UI and tools enter through the C API into the engine, which depends on DSP, platform code, built-in effects and importers; the scanner loads plug-ins in its own process.">
          <defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
            <path d="M 0 0 L 10 5 L 0 10 z" fill="var(--muted)"></path></marker></defs>
          <rect class="node" x="20" y="20" width="190" height="52" rx="8"></rect>
          <text x="115" y="42" text-anchor="middle" fill="var(--text)" font-size="13">AppKit UI</text>
          <text x="115" y="60" text-anchor="middle" class="edge-label">35 Swift files · 19,913 LOC</text>
          <rect class="node" x="20" y="96" width="190" height="46" rx="8"></rect>
          <text x="115" y="117" text-anchor="middle" fill="var(--text)" font-size="13">dalnok-cli</text>
          <text x="115" y="132" text-anchor="middle" class="edge-label">benchmarks, imports</text>
          <rect class="node" x="20" y="166" width="190" height="46" rx="8"></rect>
          <text x="115" y="187" text-anchor="middle" fill="var(--text)" font-size="13">tests/engine</text>
          <text x="115" y="202" text-anchor="middle" class="edge-label">188 tests</text>

          <rect class="node" x="330" y="86" width="170" height="120" rx="10" style="stroke:var(--accent)"></rect>
          <text x="415" y="112" text-anchor="middle" fill="var(--text)" font-size="14">C API</text>
          <text x="415" y="132" text-anchor="middle" class="edge-label">211 functions</text>
          <text x="415" y="148" text-anchor="middle" class="edge-label">stable ABI</text>
          <text x="415" y="164" text-anchor="middle" class="edge-label">DALNOK_API_VERSION</text>
          <text x="415" y="184" text-anchor="middle" class="edge-label">the only boundary</text>

          <rect class="node" x="620" y="60" width="250" height="180" rx="10"></rect>
          <text x="745" y="86" text-anchor="middle" fill="var(--text)" font-size="14">Engine (C++20)</text>
          <text x="745" y="108" text-anchor="middle" class="edge-label">model · undo · transport</text>
          <text x="745" y="126" text-anchor="middle" class="edge-label">recording · MIDI · routing</text>
          <text x="745" y="144" text-anchor="middle" class="edge-label">render compile · offline render</text>
          <text x="745" y="168" text-anchor="middle" class="edge-label">2,526 lines · 117 methods</text>
          <text x="745" y="188" text-anchor="middle" class="edge-label" style="fill:var(--p1)">god object (A-06)</text>

          <path class="edge" d="M 210 46 C 260 46, 280 110, 328 120"></path>
          <path class="edge" d="M 210 119 L 326 130"></path>
          <path class="edge" d="M 210 189 C 260 189, 280 158, 328 146"></path>
          <path class="edge" d="M 502 146 L 616 146"></path>
          <text x="558" y="138" text-anchor="middle" class="edge-label">in-process</text>

          <rect class="node" x="620" y="258" width="120" height="34" rx="7"></rect>
          <text x="680" y="280" text-anchor="middle" class="edge-label">DalnokDSP (stretch)</text>
          <rect class="node" x="752" y="258" width="118" height="34" rx="7"></rect>
          <text x="811" y="280" text-anchor="middle" class="edge-label">platform/macOS</text>
          <rect class="node" x="20" y="258" width="190" height="34" rx="7" style="stroke:var(--good)"></rect>
          <text x="115" y="280" text-anchor="middle" class="edge-label">dalnok-scan (isolated)</text>
          <path class="edge" d="M 680 258 L 700 246"></path>
          <path class="edge" d="M 811 258 L 800 246"></path>
          <path class="edge" d="M 210 275 L 286 275" style="stroke:var(--good);marker-end:none;stroke-dasharray:4 4"></path>
          <text x="246" y="268" text-anchor="middle" class="edge-label" style="fill:var(--good)">same idea</text>
        </svg>
      </div>

      <h2>Language distribution</h2>
      <div class="card">
        ${Object.entries(INV.languages).sort((a,b)=>b[1]-a[1]).map(([k,v]) => `
          <div style="margin:9px 0"><div class="row"><b class="tiny" style="min-width:150px">${esc(k)}</b>
          <span class="muted tiny num">${v.toLocaleString()} lines</span></div>
          <div class="bar"><span style="width:${pct(v, totalLoc)}%;background:${langColors[k] || 'var(--p3)'}"></span></div></div>`).join('')}
        <p class="tiny muted" style="margin-top:12px">Third-party code (VST3 SDK, CLAP, pugixml, Signalsmith) is excluded from all counts.</p>
      </div>`;
    $$('.area', $('#codebase')).forEach(b => b.addEventListener('click', () => { state.area = b.dataset.area; renderCodebase(); }));
    $$('[data-open]').forEach(b => b.addEventListener('click', () => openDetail(b.dataset.open)));
  }

  /* ---------- performance ---------- */
  function barChart(rows, labelKey, valKey, unit, maxOverride) {
    const W = 640, H = 240, padL = 56, padB = 34, padT = 12;
    const max = maxOverride || Math.max.apply(null, rows.map(r => r[valKey])) * 1.15;
    const bw = (W - padL - 16) / rows.length;
    const y = v => H - padB - (v / max) * (H - padB - padT);
    return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Bar chart">
      ${[0, .25, .5, .75, 1].map(f => `<line class="grid" x1="${padL}" x2="${W - 10}" y1="${y(max*f)}" y2="${y(max*f)}"></line>
        <text x="${padL - 8}" y="${y(max*f) + 4}" text-anchor="end">${Math.round(max*f)}</text>`).join('')}
      <line class="axis" x1="${padL}" x2="${W - 10}" y1="${H - padB}" y2="${H - padB}"></line>
      ${rows.map((r, i) => {
        const x = padL + i * bw + bw * .18, w = bw * .64;
        return `<rect class="b1" x="${x}" y="${y(r[valKey])}" width="${w}" height="${H - padB - y(r[valKey])}" rx="3"><title>${esc(r[labelKey])}: ${r[valKey]} ${unit}</title></rect>
          <text x="${x + w/2}" y="${H - padB + 16}" text-anchor="middle">${esc(r[labelKey])}</text>
          <text x="${x + w/2}" y="${y(r[valKey]) - 5}" text-anchor="middle">${r[valKey]}</text>`;
      }).join('')}
      <text x="${padL}" y="${H - 4}">${esc(unit)}</text>
    </svg>`;
  }
  function groupedChart(rows) {
    const W = 660, H = 260, padL = 56, padB = 36, padT = 14;
    const max = Math.max.apply(null, rows.map(r => r.avgUs)) * 1.5;
    const bw = (W - padL - 16) / rows.length;
    const y = v => H - padB - (v / max) * (H - padB - padT);
    return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Average and worst block cost by track count">
      ${[0, .25, .5, .75, 1].map(f => `<line class="grid" x1="${padL}" x2="${W - 10}" y1="${y(max*f)}" y2="${y(max*f)}"></line>
        <text x="${padL - 8}" y="${y(max*f)+4}" text-anchor="end">${Math.round(max*f)}</text>`).join('')}
      <line class="axis" x1="${padL}" x2="${W - 10}" y1="${H - padB}" y2="${H - padB}"></line>
      ${rows.map((r, i) => {
        const x = padL + i * bw + bw * .12, w = bw * .3;
        return `<rect class="b1" x="${x}" y="${y(r.avgUs)}" width="${w}" height="${H - padB - y(r.avgUs)}" rx="2"><title>${r.tracks} tracks: average ${r.avgUs} µs</title></rect>
          <rect class="b2" x="${x + w + 4}" y="${y(r.worstUs)}" width="${w}" height="${H - padB - y(r.worstUs)}" rx="2"><title>${r.tracks} tracks: worst ${r.worstUs} µs</title></rect>
          <text x="${x + w + 2}" y="${H - padB + 16}" text-anchor="middle">${r.tracks}</text>
          <text x="${x + w + 2}" y="${y(r.worstUs) - 4}" text-anchor="middle">${r.avgUs}/${r.worstUs}</text>`;
      }).join('')}
      <text x="${padL}" y="${H - 4}">tracks · µs per 512-frame block</text>
    </svg>`;
  }
  function renderPerformance() {
    const ms = B.modelScaling.runs;
    const pe = B.projectEdit.runs;
    const nm = B.notMeasured;
    $('#performance').innerHTML = `
      <h1>Performance</h1>
      <p class="lead">Every number here was measured on this machine with the commands in
      <code>benchmarks/method.md</code>. Nothing is projected except where a target is labelled as one.</p>
      <div class="card" style="margin:12px 0"><div class="row tiny">
        <span><b>${esc(B.environment.machine)}</b></span><span class="muted">${esc(B.environment.os)}</span>
        <span class="muted">${esc(B.environment.toolchain)}</span><span class="muted">${B.environment.sampleRate / 1000} kHz · ${B.environment.internalBlock}-frame blocks</span>
      </div></div>

      <h2>Real-time path</h2>
      <div class="grid g2">
        <div class="card">${groupedChart(B.engineScaling.runs)}
          <div class="legend"><span><span class="sw" style="background:var(--accent)"></span>average</span>
          <span><span class="sw" style="background:color-mix(in srgb,var(--accent) 34%,transparent)"></span>worst</span>
          <span>budget ${B.engineScaling.budgetUsPerBlock} µs</span></div>
        </div>
        <div class="card"><h3>What it means</h3>
          <p style="font-size:13.5px">The audio path is linear in track count at about 2.2 µs per track per block.
          At 256 tracks it uses ${B.engineScaling.runs[2].loadPercent}% of the budget; at 512, ${B.engineScaling.runs[3].loadPercent}%.
          This is not a current bottleneck. Headroom work is A-11 (skip silent tracks) and A-13 (SIMD), both
          of which must be measured after landing.</p>
          <table><tbody>${B.engineScaling.runs.map(r => `<tr><td class="num">${r.tracks}</td>
            <td class="num">${r.avgUs} µs</td><td class="num">${r.worstUs} µs</td>
            <td class="num">${r.loadPercent}%</td><td class="num">${r.offlineRealtime}x</td></tr>`).join('')}</tbody></table>
          <p class="tiny muted">Repeat runs: 64-track average varied 0.4%; 256-track 6%. Worst-case is an upper envelope.</p>
        </div>
      </div>

      <h2>Where the model stops scaling</h2>
      <div class="grid g2">
        <div class="card">${barChart(ms, 'clips', 'modelReadMs', 'ms', 18)}
          <div class="legend"><span><span class="sw" style="background:var(--accent)"></span>one full model read (Session.refresh)</span></div>
          <p class="tiny muted">This runs on every revision change, including each mouse event of a fader drag.</p>
        </div>
        <div class="card">${barChart(ms, 'clips', 'structuralEditMs', 'ms', 1)}
          <div class="legend"><span><span class="sw" style="background:var(--accent)"></span>one structural edit (copy + recompile)</span></div>
          <p class="tiny muted">Growing linearly because compile() loops all clips once per track (A-04).</p>
        </div>
      </div>
      <div class="card" style="margin-top:14px">
        <table><thead><tr><th>Model</th><th>Build</th><th>Model read</th><th>Structural edit</th><th>Parameter edit</th><th>Undo</th></tr></thead>
        <tbody>${ms.map(r => `<tr><td>${r.tracks} × ${r.clipsPerTrack} <span class="muted tiny">(${r.clips} clips)</span></td>
          <td class="num">${r.buildMs} ms</td><td class="num">${r.modelReadMs} ms</td>
          <td class="num">${r.structuralEditMs} ms</td><td class="num">${r.parameterEditMs} ms</td>
          <td class="num">${r.undoMs} ms</td></tr>`).join('')}</tbody></table>
        <p class="tiny muted">p50 of 30 samples, release build. Building 4,096 clips one at a time took 1.27 s because each add recompiles.</p>
      </div>

      <h2>Real projects</h2>
      <div class="card">
        <table><thead><tr><th>Project</th><th>Tracks / clips</th><th>Read</th><th>Param edit</th><th>Structural</th><th>Undo</th><th>RSS after 200 edits</th></tr></thead>
        <tbody>${pe.map(r => `<tr><td>${esc(r.project)}</td><td class="num">${r.tracks} / ${r.clips}</td>
          <td class="num">${r.modelReadMs} ms</td><td class="num">${r.parameterEditMs} ms</td>
          <td class="num">${r.structuralEditMs} ms</td><td class="num">${r.undoMs} ms</td>
          <td class="num">${r.rssBeforeMB} → ${r.rssAfterMB} MB</td></tr>`).join('')}</tbody></table>
      </div>

      <h2>Memory, load and startup</h2>
      <div class="grid g3">
        <div class="card"><h3>Memory by project</h3>
          ${B.projectLoadAndMemory.runs.map(r => `<div style="margin:8px 0"><div class="row"><span class="tiny">${esc(r.project)}</span>
            <span class="muted tiny num" style="margin-left:auto">${r.maxRssMB} MB</span></div>
            <div class="bar"><span style="width:${pct(r.maxRssMB, 600)}%"></span></div></div>`).join('')}
          <p class="tiny muted">Media is fully decoded (A-09): 23 MB per stereo minute at 48 kHz.</p></div>
        <div class="card"><h3>Project load</h3>
          ${B.projectLoadAndMemory.runs.map(r => `<div class="row tiny" style="justify-content:space-between;padding:5px 0">
            <span>${esc(r.project)}</span><span class="num">${r.realSeconds} s</span></div>`).join('')}
          <p class="tiny muted">Includes decoding every file. A 64-track 30 s project renders at ${B.projectLoadAndMemory.render[0].realtimeMultiple}x realtime.</p></div>
        <div class="card"><h3>Launch to snapshot</h3>
          ${B.appSnapshots.runs.map(r => `<div class="row tiny" style="justify-content:space-between;padding:5px 0">
            <span>${esc(r.theme)}</span><span class="num">${r.ms.join(' / ')} ms</span></div>`).join('')}
          <p class="tiny muted">Process start to exit, no fixed wait. Both themes are comparable.</p></div>
      </div>

      <h2>Build</h2>
      <div class="grid g4">
        <div class="card"><div class="muted tiny">Clean debug</div><div class="kpi small">${B.build.cleanDebugSeconds} s</div></div>
        <div class="card"><div class="muted tiny">Clean release</div><div class="kpi small">${B.build.cleanReleaseSeconds} s</div></div>
        <div class="card"><div class="muted tiny">Incremental (CLI only)</div><div class="kpi small">${B.build.incrementalCliOnlySeconds} s</div></div>
        <div class="card"><div class="muted tiny">No-op</div><div class="kpi small">${B.build.noOpSeconds} s</div></div>
      </div>

      <h2>Not measured</h2>
      <div class="note"><b>Listed explicitly rather than estimated.</b>
        <ul class="tiny" style="margin-top:6px">${nm.map(n => `<li>${esc(n)}</li>`).join('')}</ul></div>`;
  }

  /* ---------- findings ---------- */
  function filtered() {
    const q = state.q.trim().toLowerCase();
    let out = F.filter(f => {
      if (state.pr.size && !state.pr.has(f.priority)) return false;
      if (state.cat !== 'all' && f.category !== state.cat) return false;
      if (state.sub !== 'all' && f.subsystem !== state.sub) return false;
      if (q) {
        const hay = [f.id, f.title, f.summary, f.category, f.subsystem, f.files.join(' '), f.recommendation].join(' ').toLowerCase();
        if (hay.indexOf(q) < 0) return false;
      }
      return true;
    });
    const cmp = {
      priority: (a, b) => PR[a.priority] - PR[b.priority] || a.id.localeCompare(b.id),
      id: (a, b) => a.id.localeCompare(b.id),
      effort: (a, b) => EFF[a.effort] - EFF[b.effort] || PR[a.priority] - PR[b.priority],
      impact: (a, b) => b.impact[state.metric] - a.impact[state.metric] || PR[a.priority] - PR[b.priority]
    };
    return out.sort(cmp[state.sort] || cmp.priority);
  }
  function renderFindings() {
    const rows = filtered();
    const cats = Array.from(new Set(F.map(f => f.category))).sort();
    const subs = Array.from(new Set(F.map(f => f.subsystem))).sort();
    $('#findings').innerHTML = `
      <h1>Findings</h1>
      <p class="lead">Filter, sort and open any finding. Every entry carries its own evidence, a proposed fix,
      alternatives, risks and acceptance criteria.</p>
      <div class="chips" style="margin-top:12px" role="group" aria-label="Filter by priority">
        ${['P0','P1','P2','P3'].map(p => `<button class="chip" data-pr="${p}" aria-pressed="${state.pr.has(p)}">
          ${p} · ${priorityCount(p)}</button>`).join('')}
        <button class="chip" data-clear="1" aria-pressed="false">Clear filters</button>
      </div>
      <div class="filters">
        <label class="f">Category
          <select id="f-cat"><option value="all">All categories</option>
          ${cats.map(c => `<option ${state.cat === c ? 'selected' : ''}>${esc(c)}</option>`).join('')}</select></label>
        <label class="f">Subsystem
          <select id="f-sub"><option value="all">All subsystems</option>
          ${subs.map(s => `<option ${state.sub === s ? 'selected' : ''}>${esc(s)}</option>`).join('')}</select></label>
        <label class="f">Sort
          <select id="f-sort">
            <option value="priority" ${state.sort === 'priority' ? 'selected' : ''}>Priority</option>
            <option value="impact" ${state.sort === 'impact' ? 'selected' : ''}>Impact (${state.metric})</option>
            <option value="effort" ${state.sort === 'effort' ? 'selected' : ''}>Effort</option>
            <option value="id" ${state.sort === 'id' ? 'selected' : ''}>ID</option>
          </select></label>
        <label class="f">Impact metric
          <select id="f-metric">
            ${['value','performance','maintenance','reliability'].map(m => `<option value="${m}" ${state.metric === m ? 'selected' : ''}>${m}</option>`).join('')}
          </select></label>
      </div>
      <div class="row" style="justify-content:space-between;margin:6px 0 8px">
        <span class="count">${rows.length} of ${F.length} findings</span>
        <span class="tiny muted">Select a row for evidence and the proposed implementation.</span>
      </div>
      <div class="card" style="overflow:auto;padding:0">
        <table>
          <thead><tr><th style="width:56px">ID</th><th style="width:58px">Priority</th><th>Finding</th>
            <th style="width:120px">Category</th><th style="width:52px">Effort</th><th style="width:64px">Impact</th></tr></thead>
          <tbody id="f-body">
          ${rows.map(f => `<tr data-id="${f.id}" tabindex="0" role="button" aria-label="Open ${esc(f.id)}: ${esc(f.title)}">
            <td class="num">${f.id}</td>
            <td><span class="pill ${f.priority}">${f.priority}</span></td>
            <td><b>${esc(f.title)}</b><div class="tiny muted">${esc(f.summary.slice(0, 150))}${f.summary.length > 150 ? '…' : ''}</div></td>
            <td class="tiny">${esc(f.category)}</td>
            <td class="num tiny">${esc(f.effort)}</td>
            <td class="num tiny">${f.impact[state.metric]}/5</td></tr>`).join('') || `<tr><td colspan="6" class="muted">No findings match these filters.</td></tr>`}
          </tbody>
        </table>
      </div>`;
    $$('[data-pr]', $('#findings')).forEach(b => b.addEventListener('click', () => {
      const p = b.dataset.pr;
      if (state.pr.has(p)) state.pr.delete(p); else state.pr.add(p);
      renderFindings();
    }));
    $('[data-clear]', $('#findings')).addEventListener('click', () => {
      state.pr.clear(); state.cat = 'all'; state.sub = 'all'; state.q = ''; $('#q').value = '';
      renderFindings();
    });
    $('#f-cat').addEventListener('change', e => { state.cat = e.target.value; renderFindings(); });
    $('#f-sub').addEventListener('change', e => { state.sub = e.target.value; renderFindings(); });
    $('#f-sort').addEventListener('change', e => { state.sort = e.target.value; renderFindings(); });
    $('#f-metric').addEventListener('change', e => { state.metric = e.target.value; renderFindings(); });
    bindRows($('#findings'));
  }
  function bindRows(root) {
    $$('tr[data-id]', root).forEach(tr => {
      tr.addEventListener('click', () => openDetail(tr.dataset.id));
      tr.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openDetail(tr.dataset.id); } });
    });
  }

  /* ---------- detail ---------- */
  const dlg = $('#detail');
  function impactRows(f) {
    return ['performance','maintenance','reliability','value'].map(k => `
      <div style="margin:6px 0"><div class="row tiny"><span style="min-width:110px">${k}</span>
      <span class="num">${f.impact[k]}/5</span></div>
      <div class="bar"><span style="width:${f.impact[k] * 20}%"></span></div></div>`).join('');
  }
  function openDetail(id, presetTitle) {
    const f = byId(id);
    if (!f) {
      $('#dlg-tags').innerHTML = '<span class="tag">Roadmap item</span>';
      $('#dlg-title').textContent = id + (presetTitle ? ' · ' + presetTitle : '');
      $('#dlg-body').innerHTML = '<p>This roadmap step is a sub-task of a finding and has no separate detail page.</p>' +
        '<p class="tiny muted">See the parent finding ' + esc(id.replace(/[a-z]$/, '')) +
        ' and <code>modernization-roadmap.md</code>.</p>';
      dlg.showModal();
      return;
    }
    const tags = ['<span class="pill ' + f.priority + '">' + f.priority + '</span>',
      '<span class="tag">' + esc(f.category) + '</span>',
      '<span class="tag">' + esc(f.subsystem) + '</span>',
      '<span class="tag">' + esc(f.effort) + ' effort</span>',
      '<span class="tag">' + esc(f.confidence) + ' confidence</span>'];
    if (f.measured) tags.push('<span class="tag" style="color:var(--good)">measured</span>');
    $('#dlg-tags').innerHTML = tags.join('');
    $('#dlg-title').textContent = f.id + ' · ' + f.title;
    const listOf = function (items) {
      return '<ul>' + items.map(function (x) { return '<li class="tiny">' + esc(x) + '</li>'; }).join('') + '</ul>';
    };
    const files = f.files.map(function (p) { return '<span class="tag"><code>' + esc(p) + '</code></span>'; }).join('');
    const deps = f.dependencies.length
      ? f.dependencies.map(function (d) { return '<span class="tag">' + esc(d) + '</span>'; }).join('')
      : 'None';
    const impacts = ['performance', 'maintenance', 'reliability', 'value'].map(function (k) {
      return '<div style="margin:6px 0"><div class="row tiny"><span style="min-width:110px">' + k + '</span>' +
        '<span class="num">' + f.impact[k] + '/5</span></div>' +
        '<div class="bar"><span style="width:' + (f.impact[k] * 20) + '%"></span></div></div>';
    }).join('');
    $('#dlg-body').innerHTML =
      '<p>' + esc(f.summary) + '</p>' +
      '<div class="section"><h4>Evidence</h4>' + listOf(f.evidence) + '</div>' +
      '<div class="section"><h4>Files</h4><div>' + files + '</div></div>' +
      '<div class="section"><h4>Recommended implementation</h4><p style="font-size:13.5px">' + esc(f.recommendation) + '</p></div>' +
      '<div class="section"><h4>Alternatives considered</h4>' + listOf(f.alternatives) + '</div>' +
      '<div class="section"><h4>Risks</h4><p class="tiny">' + esc(f.risk) + '</p></div>' +
      '<div class="section"><h4>Dependencies</h4><p class="tiny">' + deps + '</p></div>' +
      '<div class="section"><h4>Verification</h4>' + listOf(f.verification) + '</div>' +
      '<div class="section"><h4>Acceptance criteria</h4><p class="tiny">' + esc(f.acceptance) + '</p></div>' +
      '<div class="section"><h4>Impact (1-5, judged)</h4>' + impacts + '</div>' +
      '<div class="row" style="margin-top:18px"><button class="btn" id="copy-md" type="button">Copy as Markdown</button>' +
      '<button class="btn" id="copy-steps" type="button">Copy implementation steps</button></div>' +
      '<p class="tiny muted" style="margin-top:10px">Evidence is from rev b15410a. Impact scores are judgements with definitions in the Method tab.</p>';
    const md = ['## ' + f.id + ' - ' + f.title,
      '**' + f.priority + ' | ' + f.category + ' | ' + f.subsystem + ' | effort ' + f.effort + ' | confidence ' + f.confidence + '**',
      '', f.summary, '', '**Evidence**'];
    f.evidence.forEach(function (e) { md.push('- ' + e); });
    md.push('', '**Files:** ' + f.files.join(', '), '', '**Recommendation:** ' + f.recommendation,
      '', '**Alternatives:** ' + f.alternatives.join(' / '), '', '**Risks:** ' + f.risk, '', '**Verification**');
    f.verification.forEach(function (v) { md.push('- ' + v); });
    md.push('', '**Acceptance:** ' + f.acceptance);
    $('#copy-md').addEventListener('click', function () { copyText(md.join('\n'), $('#copy-md')); });
    $('#copy-steps').addEventListener('click', function () {
      copyText(f.id + ' ' + f.title + '\n\n' + f.recommendation + '\n\nVerification:\n' +
        f.verification.map(function (v) { return '- ' + v; }).join('\n') + '\n\nDone when: ' + f.acceptance,
        $('#copy-steps'));
    });
    dlg.showModal();
  }

  function copyText(text, btn) {
    const done = () => { if (btn) { const old = btn.textContent; btn.textContent = 'Copied'; setTimeout(() => btn.textContent = old, 1200); } };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, () => fallback(text, done));
    } else fallback(text, done);
  }
  function fallback(text, done) {
    const ta = document.createElement('textarea');
    ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.left = '-9999px';
    document.body.appendChild(ta); ta.select();
    try { document.execCommand('copy'); done(); } catch (e) {}
    document.body.removeChild(ta);
  }
  $('#dlg-close').addEventListener('click', () => dlg.close());
  dlg.addEventListener('click', e => { if (e.target === dlg) dlg.close(); });

  /* ---------- roadmap ---------- */
  const progress = store.get('dalnok.audit.progress', {});
  function isDone(id) { return !!progress[id]; }
  function renderRoadmap() {
    const doneCount = Object.keys(progress).filter(isDone).length;
    const total = ROAD.reduce((s, p) => s + p.items.length, 0);
    $('#roadmap').innerHTML = `
      <h1>Modernization roadmap</h1>
      <p class="lead">Ordered so that every phase leaves the suite green and no quick win waits on a
      multi-month programme. Progress is stored in this browser only (localStorage); nothing is sent anywhere.</p>
      <div class="card" style="margin:14px 0"><div class="row">
        <b>${doneCount} of ${total} steps marked done</b>
        <div class="bar" style="flex:1;min-width:140px"><span style="width:${pct(doneCount, total)}%"></span></div>
        <button class="btn" id="reset-progress" type="button">Reset progress</button>
      </div></div>
      <div class="road">
        ${ROAD.map(p => `<div class="phase"><h3>${esc(p.phase)}</h3>
          <p class="tiny muted" style="margin-bottom:4px">${esc(p.goal)}</p>
          ${p.items.map(it => {
            const f = byId(it.id);
            const blocked = it.depends.filter(d => !isDone(d));
            return `<div class="road-item ${isDone(it.id) ? 'done' : ''}">
              <input type="checkbox" id="chk-${it.id}" data-check="${it.id}" ${isDone(it.id) ? 'checked' : ''}
                aria-label="Mark ${esc(it.id)} done">
              <div class="title">
                <button class="chip" data-id="${it.id}" data-title="${esc(it.title)}" style="border:0;background:none;padding:0;color:var(--accent2);font-size:13.5px;text-align:left">${esc(it.id)} · ${esc(it.title)}</button>
                <div class="tiny muted">Step ${it.order}${it.depends.length ? ' · depends on ' + it.depends.join(', ') : ''}</div>
                ${blocked.length ? `<div class="blocked">waiting on ${blocked.map(d => esc(d)).join(', ')}</div>` : ''}
              </div>
              <div class="row"><span class="pill effort">${esc(it.effort)}</span>
                ${f ? `<span class="pill ${f.priority}">${f.priority}</span>` : ''}</div>
            </div>`;
          }).join('')}
        </div>`).join('')}
      </div>
      <p class="tiny muted" style="margin-top:14px">Full acceptance criteria and the dependency rules are in
      <code>modernization-roadmap.md</code>. Checking a box here does not change the repository.</p>`;
    $$('[data-check]').forEach(cb => cb.addEventListener('change', () => {
      progress[cb.dataset.check] = cb.checked;
      store.set('dalnok.audit.progress', progress);
      renderRoadmap();
    }));
    $$('[data-id]', $('#roadmap')).forEach(b => b.addEventListener('click', () => openDetail(b.dataset.id, b.dataset.title)));
    $('#reset-progress').addEventListener('click', () => {
      Object.keys(progress).forEach(k => delete progress[k]);
      store.set('dalnok.audit.progress', progress);
      renderRoadmap();
    });
  }

  /* ---------- matrix ---------- */
  function renderMatrix() {
    const W = 760, H = 420, padL = 70, padB = 56, padT = 22, padR = 26;
    const x = e => padL + ((EFF[e] - 1) / 3) * (W - padL - padR);
    const y = v => H - padB - (v / 5) * (H - padB - padT);
    const jitter = id => (id.charCodeAt(2) % 7) * 3 - 9;
    const dots = F.map(f => {
      const cx = x(f.effort) + jitter(f.id), cy = y(f.impact[state.metric]) + jitter(f.id + 'y');
      return `<circle class="matrix-dot" cx="${cx}" cy="${cy}" r="9" fill="${f.priority === 'P0' ? 'var(--p0)' : f.priority === 'P1' ? 'var(--p1)' : f.priority === 'P2' ? 'var(--p2)' : 'var(--p3)'}"
        data-id="${f.id}" tabindex="0" role="button" aria-label="${esc(f.id)}: ${esc(f.title)}, effort ${f.effort}, ${state.metric} ${f.impact[state.metric]} of 5"
        ><title>${esc(f.id)} · ${esc(f.title)} — effort ${f.effort}, ${state.metric} ${f.impact[state.metric]}/5</title></circle>
        <text x="${cx}" y="${cy + 3.5}" text-anchor="middle" style="font-size:9px;fill:var(--bg);pointer-events:none">${f.id.replace('A-', '')}</text>`;
    }).join('');
    $('#matrix').innerHTML = `
      <h1>Impact versus effort</h1>
      <p class="lead">Upper-left is where the quick wins are. Scores are judgements; the definitions are below
      and in <code>findings.json</code>, and every dot opens its finding.</p>
      <div class="row" style="margin:12px 0">
        <label class="f" style="max-width:260px">Impact metric
          <select id="m-metric">${['value','performance','maintenance','reliability'].map(m =>
            `<option value="${m}" ${state.metric === m ? 'selected' : ''}>${m}</option>`).join('')}</select></label>
        <div class="legend" style="margin-left:auto">
          ${['P0','P1','P2','P3'].map(p => `<span><span class="sw" style="background:var(--${p.toLowerCase()})"></span>${p}</span>`).join('')}
        </div>
      </div>
      <div class="matrix-wrap">
        <svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Scatter plot of findings by effort and impact">
          ${[1,2,3,4,5].map(v => `<line class="grid" x1="${padL}" x2="${W - padR}" y1="${y(v)}" y2="${y(v)}"></line>
            <text x="${padL - 10}" y="${y(v) + 4}" text-anchor="end">${v}</text>`).join('')}
          <line class="axis" x1="${padL}" x2="${W - padR}" y1="${H - padB}" y2="${H - padB}"></line>
          <line class="axis" x1="${padL}" x2="${padL}" y1="${padT}" y2="${H - padB}"></line>
          ${[['S',1],['M',2],['L',3],['XL',4]].map(([k, v]) => `<text x="${x(k)}" y="${H - padB + 20}" text-anchor="middle">${k}</text>`).join('')}
          <text x="${(padL + W) / 2}" y="${H - 12}" text-anchor="middle">effort →</text>
          <text x="16" y="${H / 2}" text-anchor="middle" transform="rotate(-90 16 ${H / 2})">${esc(state.metric)} impact →</text>
          ${dots}
        </svg>
      </div>
      <div class="grid g2" style="margin-top:14px">
        <div class="card"><h3>Scoring definitions</h3><dl class="kv tiny">
          <dt>Effort</dt><dd>S ≤ 1 day · M 2–5 days · L 2–4 weeks · XL &gt; 1 month</dd>
          <dt>Impact</dt><dd>1 negligible … 5 transformative, judged per metric</dd>
          <dt>Overall value</dt><dd>A judgement that weights user-visible reliability higher than polish; not an average</dd>
          <dt>Priority</dt><dd>P0 data loss or dangerous failure · P1 growth blocker · P2 worthwhile · P3 cleanup</dd>
        </dl></div>
        <div class="card"><h3>Quick wins (S/M, value ≥ 4)</h3>
          <ul class="tiny">${F.filter(f => (f.effort === 'S' || f.effort === 'M') && f.impact.value >= 4)
            .sort((a, b) => PR[a.priority] - PR[b.priority])
            .map(f => `<li><button class="chip" data-id="${f.id}" style="border:0;background:none;padding:0;color:var(--accent2)">${f.id}</button> ${esc(f.title)} <span class="muted">(${f.effort})</span></li>`).join('') || '<li class="muted">None.</li>'}</ul></div>
      </div>`;
    $('#m-metric').addEventListener('change', e => { state.metric = e.target.value; renderMatrix(); });
    $$('circle[data-id]', $('#matrix')).forEach(c => {
      c.addEventListener('click', () => openDetail(c.dataset.id));
      c.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openDetail(c.dataset.id); } });
    });
    $$('button[data-id]', $('#matrix')).forEach(b => b.addEventListener('click', () => openDetail(b.dataset.id)));
  }

  /* ---------- architecture ---------- */
  function renderArchitecture() {
    const keep = [
      ['Compiler-enforced real-time safety', 'DALNOK_NONBLOCKING with -Werror=function-effects and a negative test. Keep exactly as is.'],
      ['Immutable snapshots + atomic slot', 'Simple, wait-free, and already proven under edit churn.'],
      ['Engine-owned model + command catalog', 'One source of truth for UI, scripts, tests and future assistance.'],
      ['C ABI boundary', 'Unchanged: the front end still only sees dalnok.h.'],
      ['Atomic durable saves', 'mkstemp + fsync + rename + directory fsync.']
    ];
    const move = [
      ['Model copy per edit', 'Coalesce parameter edits; share clip vectors and plug-in state.'],
      ['Whole-snapshot compile', 'Linear bucketing now, per-track incremental compile next.'],
      ['Whole-model UI refresh', 'Publish change sets; keep full refresh as the correctness fallback.'],
      ['Engine god object', 'Extract Transport, Recording, PluginHost, RenderCompiler, UndoStack behind the facade.'],
      ['Plug-in initialisation on the UI thread', 'Async activation with progress, cancel and a watchdog.'],
      ['Global theme state', 'Inject theme values so a theme switch does not relaunch the app.']
    ];
    const add = [
      ['Autosave service', 'Periodic atomic snapshots into Application Support with bounded retention.'],
      ['Out-of-process plug-in supervisor', 'Reuse the scanner pattern; shared-memory audio transport.'],
      ['MediaSource / block cache', 'Stream long files with guaranteed residency on the audio thread.'],
      ['Change-set channel', 'Bounded per-revision summary of what moved.'],
      ['Parser fuzz targets', 'Project reader and importers under libFuzzer, nightly.'],
      ['Policy header for real-time constants', 'One place for block, fade, queue and undo limits.']
    ];
    $('#architecture').innerHTML = `
      <h1>Current and proposed architecture</h1>
      <p class="lead">The shape is right: UI → C API → engine → DSP/platform. The proposal keeps every
      boundary that works and moves work out of interactive paths. No rewrite.</p>
      <div class="arch" style="margin-top:16px">
        <div class="arch-col"><h3>Current</h3>
          <div class="arch-item keep"><b>AppKit UI</b>read-only views, full refresh on revision, theme globals</div>
          <div class="arch-item keep"><b>C API (211 functions)</b>stable ABI, hand-written marshalling</div>
          <div class="arch-item"><b>Engine (one class)</b>model + undo + transport + recording + MIDI + plugins + routing + launcher + offline render</div>
          <div class="arch-item"><b>RenderState</b>full recompile per structural edit, O(T×C)</div>
          <div class="arch-item"><b>In-process plug-ins</b>VST3 / AU / CLAP on the audio thread</div>
          <div class="arch-item"><b>Media</b>fully decoded in RAM</div>
        </div>
        <div class="arch-col"><h3>Proposed</h3>
          <div class="arch-item keep"><b>AppKit UI</b>same views, incremental refresh from change sets</div>
          <div class="arch-item keep"><b>C API</b>same ABI, generated or bulk-loaded DTOs</div>
          <div class="arch-item move"><b>Engine facade</b>model + undo + command dispatch only</div>
          <div class="arch-item new"><b>Transport · Recording · RenderCompiler · UndoStack</b>services behind the facade</div>
          <div class="arch-item new"><b>Plug-in supervisor process</b>crash containment, in-process fallback</div>
          <div class="arch-item new"><b>MediaSource</b>block cache with prefetch; peaks in memory</div>
          <div class="arch-item new"><b>Autosave service</b>bounded snapshots, recovery prompt</div>
        </div>
      </div>
      <h2>What changes and why</h2>
      <div class="grid g3">
        <div class="card"><h3>Keep unchanged</h3>
          ${keep.map(([t, d]) => `<div class="arch-item keep"><b>${esc(t)}</b><span class="tiny muted">${esc(d)}</span></div>`).join('')}</div>
        <div class="card"><h3>Reorganise</h3>
          ${move.map(([t, d]) => `<div class="arch-item move"><b>${esc(t)}</b><span class="tiny muted">${esc(d)}</span></div>`).join('')}</div>
        <div class="card"><h3>Add</h3>
          ${add.map(([t, d]) => `<div class="arch-item new"><b>${esc(t)}</b><span class="tiny muted">${esc(d)}</span></div>`).join('')}</div>
      </div>
      <h2>Real-time and background split</h2>
      <div class="card"><p style="font-size:13.5px;margin:0">
        The audio thread keeps its current contract: immutable snapshot in, samples out, no allocation, no locks, no I/O.
        Everything proposed here lives off it — autosave serialises on a worker, plug-in activation moves to a supervisor,
        media prefetch runs on a worker with guaranteed residency before the callback reads a block, and change sets are
        produced on the control thread. The one audio-thread change proposed is a conservative skip test (A-11), which is
        null-tested against the unskipped path.</p></div>`;
  }

  /* ---------- method ---------- */
  function renderMethod() {
    $('#method').innerHTML = `
      <h1>Audit methodology</h1>
      <p class="lead">What was read, run, and not run — so the conclusions can be weighted honestly.</p>
      <div class="grid g2" style="margin-top:14px">
        <div class="card"><h3>Source revision</h3><dl class="kv tiny">
          <dt>Commit</dt><dd><code>b15410a621f7ce25f6f73f2738f8108c47ea184f</code></dd>
          <dt>Branch</dt><dd><code>audit/2026-11-codebase</code> (from main)</dd>
          <dt>Product</dt><dd>Dalnok 0.1.0 preview (pre-alpha)</dd>
          <dt>Date</dt><dd>2026-11-18</dd>
        </dl></div>
        <div class="card"><h3>Environment</h3><dl class="kv tiny">
          <dt>Machine</dt><dd>${esc(B.environment.machine)}</dd>
          <dt>OS</dt><dd>${esc(B.environment.os)}</dd>
          <dt>Toolchain</dt><dd>${esc(B.environment.toolchain)}</dd>
          <dt>Build</dt><dd>${esc(B.environment.build)}</dd>
        </dl></div>
      </div>

      <h2>What ran</h2>
      <div class="card"><ul class="tiny" style="font-size:13px">
        <li><code>swift build</code> (debug and release), clean builds in a fresh scratch directory, no-op and incremental builds.</li>
        <li><code>swift test</code>: ${B.tests.engineTests} tests in ${B.tests.engineSuites} suites, ${B.tests.wallSeconds} s, all passing.</li>
        <li><code>dalnok-cli bench</code> at 8, 64, 256 and 512 tracks, with repeats at 64 and 256.</li>
        <li><code>dalnok-cli audit-scale</code> at 64, 1,024, 2,048 and 4,096 clips (added by this audit, C API only).</li>
        <li><code>dalnok-cli audit-bench</code> on generated band, 64-track and 256-track projects (added by this audit).</li>
        <li>Project load, render, RSS and both-theme snapshot timings; generated projects only, never owner material.</li>
      </ul></div>

      <h2>What did not run, and why</h2>
      <div class="card"><ul class="tiny" style="font-size:13px">
        <li>The GUI self-test: needs an interactive, focused GUI session. Check counts are quoted from CURRENT_STATE, not re-verified.</li>
        <li>Sanitizer runs: CI covers ASan and TSan; they were not repeated here.</li>
        <li>Plug-in hosting scripts and real third-party plug-ins: they build fixtures and load vendor code; not needed for these findings.</li>
        <li>Timeline scroll/zoom frame time: no instrumented harness existed, and driving a UI session was not reliable during the audit.</li>
        <li>Multi-hour soak and cold-start-without-snapshot: out of scope for the session.</li>
      </ul>
      <p class="tiny muted">Anything not measured is listed in the Performance tab and in <code>benchmarks/results.json</code>
      under <code>notMeasured</code>; it is never presented as a result.</p></div>

      <h2>Code changed by this audit</h2>
      <div class="card"><p class="tiny" style="font-size:13px;margin:0">
        Only <code>tools/dalnok-cli/main.swift</code> gained two measurement subcommands (<code>audit-bench</code>,
        <code>audit-scale</code>) that call the public C API. No engine or app behaviour changed, and both can be removed
        without touching the product. All other files in this branch are new files under <code>docs/audits/</code>
        plus the status/changelog notes.</p></div>

      <h2>Confidence</h2>
      <div class="card"><table><thead><tr><th>Confidence</th><th>Basis</th><th>Findings</th></tr></thead><tbody>
        <tr><td><span class="tag" style="color:var(--good)">high</span></td><td>Source plus direct measurement or a reproduced incident</td>
          <td class="tiny">${F.filter(f => f.confidence === 'high').map(f => f.id).join(', ')}</td></tr>
        <tr><td><span class="tag" style="color:var(--warn)">medium</span></td><td>Source plus reasoning; the fix needs a spike</td>
          <td class="tiny">${F.filter(f => f.confidence === 'medium').map(f => f.id).join(', ')}</td></tr>
        <tr><td><span class="tag">low</span></td><td>Hypothesis only</td>
          <td class="tiny">${F.filter(f => f.confidence === 'low').map(f => f.id).join(', ') || 'None'}</td></tr>
      </tbody></table></div>

      <h2>Reproduce</h2>
      <div class="card"><pre>swift build -c release
.build/release/dalnok-cli make-test-project /tmp/audit-band --preset band
.build/release/dalnok-cli bench --tracks 64 --seconds 20
.build/release/dalnok-cli audit-scale --tracks 128 --clips 32
.build/release/dalnok-cli audit-bench /tmp/audit-band/band.dalnok --edits 200
DALNOK_SNAPSHOT_DELAY=0 .build/release/Dalnok /tmp/audit-band/band.dalnok --snapshot /tmp/audit.png</pre>
      <p class="tiny muted">Full commands, raw output and caveats: <code>docs/audits/benchmarks/</code>.</p></div>

      <h2>Deliverables</h2>
      <div class="card"><ul class="tiny" style="font-size:13px">
        <li><code>docs/audits/codebase-audit-2026-11.md</code> — the report.</li>
        <li><code>docs/audits/findings.json</code> — machine-readable findings (the source of this page).</li>
        <li><code>docs/audits/modernization-roadmap.md</code> — ordered plan with acceptance criteria.</li>
        <li><code>docs/audits/benchmarks/</code> — method, results.json, raw output, code inventory.</li>
        <li><code>docs/audits/dashboard/index.html</code> — this page.</li>
      </ul></div>`;
  }

  /* ---------- panel dispatch ---------- */
  const rendered = {};
  function renderPanel(name) {
    if (name === 'overview') renderOverview();
    else if (name === 'codebase') renderCodebase();
    else if (name === 'performance') renderPerformance();
    else if (name === 'findings') renderFindings();
    else if (name === 'roadmap') renderRoadmap();
    else if (name === 'matrix') renderMatrix();
    else if (name === 'architecture') renderArchitecture();
    else if (name === 'method') renderMethod();
    rendered[name] = true;
  }

  /* ---------- search ---------- */
  $('#q').addEventListener('input', e => {
    state.q = e.target.value;
    if (state.tab !== 'findings') showTab('findings');
    else renderFindings();
  });
  $('#export').addEventListener('click', () => {
    const blob = new Blob([JSON.stringify(A, null, 2)], {type: 'application/json'});
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'dalnok-audit-findings.json';
    document.body.appendChild(a); a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 0);
  });

  /* ---------- keyboard ---------- */
  document.addEventListener('keydown', e => {
    if (e.key === '/' && document.activeElement !== $('#q') && !['INPUT','TEXTAREA','SELECT'].includes(document.activeElement.tagName)) {
      e.preventDefault(); $('#q').focus();
    }
    if (e.key === 'Escape' && dlg.open) dlg.close();
  });

  /* ---------- boot ---------- */
  const initial = (location.hash || '').slice(1);
  showTab(TABS.indexOf(initial) >= 0 ? initial : 'overview');
  setTimeout(function () { window.scrollTo(0, 0); }, 0);
})();
</script>
</body>
</html>
'''

html = TEMPLATE
for marker, payload in (
    ("__FINDINGS__", json.dumps(findings, ensure_ascii=False)),
    ("__BENCH__", json.dumps(bench, ensure_ascii=False)),
    ("__INVENTORY__", json.dumps(inventory, ensure_ascii=False)),
    ("__AREAS__", json.dumps(AREA_INFO, ensure_ascii=False)),
    ("__ROADMAP__", json.dumps(ROADMAP, ensure_ascii=False)),
):
    html = html.replace(marker, payload.replace("</", "<\\/"))

(AUDIT / "benchmarks" / "code-inventory.json").write_text(json.dumps(inventory, indent=2) + "\n", encoding="utf-8")
out = HERE / "index.html"
out.write_text(html, encoding="utf-8")
print(f"wrote {out} ({len(html):,} bytes)")
