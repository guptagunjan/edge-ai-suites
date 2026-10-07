<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# LAYOUT — the DOM contract

The generated `index.html` MUST produce this structure. Element **IDs and class
names are a contract**: `app.js` binds to them and `acceptance/verify.sh` asserts
they are present in the served page. Reproduce the structure exactly; wording of
static copy may vary slightly but the regions and controls must all exist.

## 0. Sub-path-agnostic `<base href>` (MANDATORY — first thing in `<head>`)

The console is served under a reverse-proxy prefix (e.g. `/console/`). If assets
and API calls use root-absolute paths (`/static/...`, `/api/...`) the browser
requests them at the site root and gets the wrong content → **unstyled page,
empty dropdowns, no metrics**. Prevent this two ways, both required:

1. Inject a `<base>` element pointing at the page's own directory, BEFORE the
   stylesheet link:
   ```html
   <script>
     (function () {
       var pth = location.pathname;
       if (pth.charAt(pth.length - 1) !== "/") pth = pth.slice(0, pth.lastIndexOf("/") + 1);
       var b = document.createElement("base");
       b.href = pth;
       document.head.appendChild(b);
     })();
   </script>
   ```
2. Reference the stylesheet and scripts with **relative** paths
   (`static/styles.css`, `static/whep.js`, `static/app.js`) and make every
   `fetch()` in `app.js` use a **relative** API path (`api/config`, not `/api/config`).

`verify.sh` fails if the served HTML contains `href="/static` or `src="/static`
or if `app.js` contains `fetch("/api` (root-absolute).

## 1. Overall skeleton

```
<body>
  <header class="topbar"> … </header>
  <main class="layout">
    <aside class="rail"> …left controls… </aside>
    <section class="stage">
      <div id="grid" class="grid"></div>
      <div id="emptyState" class="empty"> …hint… </div>
    </section>
  </main>
  <footer class="telemetry">
    <div id="telemetryStrip" class="strip"> …per-stream cards… </div>
  </footer>
  <template id="panelTpl"> …one video panel… </template>
  <script src="static/whep.js"></script>
  <script src="static/app.js"></script>
</body>
```

## 2. Header (`.topbar`)

- `.brand`: a `.dot` (glowing accent circle) + `.title` "VMS · Loitering
  Detection" + `.subtitle` "Mission Console".
- `.topbar-right`:
  - `.compare-toggle` label wrapping `#compareMode` checkbox + text
    "Model compare (side-by-side)".
  - `#connState` `.conn.conn-ok` pill, initial text "DLSPS: connecting…".

## 3. Left rail (`.rail`) — required cards, in this order

1. **Source** card (`<h2>Source</h2>`):
   - `.field` label "Camera / stream" wrapping `<select id="sourceSel">`.
   - `.field` label "…or RTSP URL" wrapping `<input id="rtspInput" type="text">`.
2. **Model** card (`<h2>Model <button id="refreshModels" class="mini-btn">⟳</button></h2>`):
   - `.field` "Primary model" → `<select id="modelSelA">`.
   - `.field id="modelBWrap" hidden` "Compare model" → `<select id="modelSelB">`.
   - `.field` "Device" → `<select id="deviceSel">`.
   - `<p class="hint" id="modelSrcHint">` describing auto-discovery.
3. **Zone (ROI)** card (`<h2>Zone (ROI)</h2>`):
   - `.draw-toggle` label wrapping `#drawZone` checkbox + "✏ Draw zone on video".
   - `.roi-grid` with four number inputs `#roiX #roiY #roiW #roiH`
     (defaults 0 / 200 / 300 / 400).
   - `<button id="applyZoneAll" class="btn btn-ghost btn-sm">` "Apply zone to live streams".
   - `<p class="hint">` mentioning the loiter threshold via `<span id="loiterThr">`.
4. **Actions** row (`.actions`): `<button id="startBtn" class="btn btn-primary">▶ Start stream</button>`
   and `<button id="stopAllBtn" class="btn btn-ghost">■ Stop all</button>`.
5. **System Utilization** card (`.util`, `<h2>System Utilization</h2>`): four gauges,
   one per `data-key` in `cpu`, `gpu`, `npu`, `mem`. Each gauge:
   ```html
   <div class="gauge" data-key="cpu">
     <span class="g-label">CPU</span>
     <div class="bar"><i></i></div>
     <span class="g-val">–</span>
     <span class="g-sub"></span>
   </div>
   ```
   Labels: CPU / GPU / NPU / MEM.

## 4. Right stage (`.stage`)

- `#grid.grid` — panels are appended here; gets `.compare` class in compare mode.
- `#emptyState.empty` — shown when no streams; hidden once a panel exists.

## 5. Bottom telemetry (`.telemetry`)

- `#telemetryStrip.strip` — one `.tele-card` per active stream, rebuilt each poll.

## 6. Panel template (`#panelTpl`) — cloned per stream

```html
<template id="panelTpl">
  <div class="panel">
    <div class="panel-head">
      <span class="p-title"></span>
      <span class="p-actions">
        <button class="p-apply" hidden>Apply zone</button>
        <button class="p-close">✕</button>
      </span>
    </div>
    <div class="video-wrap">
      <video autoplay playsinline muted></video>
      <div class="roi-overlay">
        <div class="roi-current"></div>
        <div class="roi-draw"></div>
      </div>
    </div>
    <div class="p-status">connecting…</div>
  </div>
</template>
```

## 7. Telemetry card shape (built in JS per stream)

```html
<div class="tele-card"><!-- add " loiter" to class when loiter_count>0 -->
  <span class="t-title">{model_label} · {device}</span>
  <div class="tele-metrics">
    <div class="m"><b>{fps}</b><span>fps</span></div>
    <div class="m"><b>{objects}</b><span>objects</span></div>
    <div class="m"><b>{max_dwell_s}s</b><span>max dwell</span></div>
    <div class="m loiter"><b>{loiter_count}</b><span>loiter</span></div>
  </div>
</div>
```

## 8. Required IDs checklist (verify.sh asserts all present)

`compareMode, connState, sourceSel, rtspInput, refreshModels, modelSelA,
modelBWrap, modelSelB, deviceSel, modelSrcHint, drawZone, roiX, roiY, roiW, roiH,
applyZoneAll, startBtn, stopAllBtn, grid, emptyState, telemetryStrip, panelTpl,
loiterThr` — plus four `.gauge[data-key]` of `cpu/gpu/npu/mem`.
