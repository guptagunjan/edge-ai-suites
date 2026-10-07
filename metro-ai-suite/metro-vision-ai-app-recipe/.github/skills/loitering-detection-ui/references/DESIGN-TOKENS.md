<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# DESIGN TOKENS — the "same dashboard on every machine" contract

This skill ships **no UI code**. It ships this **locked design system**. When the
agent generates the stylesheet it MUST emit exactly these token values and the
structural rules below. This is what makes the dashboard look identical on every
machine even though the CSS is generated fresh each time.

> Consistency model: we do **not** guarantee byte-identical files. We guarantee
> an identical *rendered dashboard* by (1) locking every visual value here, (2)
> locking the DOM structure in `LAYOUT.md`, and (3) gating completion on
> `acceptance/verify.sh`, which fails the build if any token or structural rule
> is missing or wrong. Do not "restyle to taste" — that is exactly the drift
> this contract prevents.

## 1. Root tokens (emit VERBATIM as the stylesheet `:root` block)

```css
:root {
  --bg: #0c1017;
  --panel: #151b26;
  --panel-2: #1b2432;
  --line: #24303f;
  --text: #e6edf5;
  --muted: #8ea0b5;
  --accent: #29c19c;
  --accent-2: #3d8bff;
  --warn: #f5a623;
  --danger: #ff5c6c;
  --rail-w: 320px;
  --foot-h: 84px;
  --head-h: 56px;
  font-size: 14px;
}
```

Every color/dimension used anywhere in the stylesheet MUST reference one of these
tokens (or a value derived from them). No hard-coded hex colors outside `:root`.
`acceptance/verify.sh` greps the served CSS for each `--name: value;` pair above
and fails if any is missing or altered.

## 2. Typography & base

- Font stack: `"Segoe UI", Roboto, system-ui, -apple-system, sans-serif`.
- `* { box-sizing: border-box; }`; `html, body { margin:0; height:100%; }`.
- `body`: `background var(--bg)`, `color var(--text)`, flex column, `height 100vh`,
  `overflow hidden`.
- Numeric readouts (gauges, telemetry values) use
  `font-variant-numeric: tabular-nums;` so figures don't jitter as they update.

## 3. Layout skeleton (emit these rules; classes are the DOM contract)

```
body            → flex column: [.topbar] [.layout grows] [.telemetry]
.topbar         → height var(--head-h); space-between; bg var(--panel); bottom border var(--line)
.layout         → grid; grid-template-columns: var(--rail-w) 1fr; min-height:0
.rail           → bg var(--panel); right border var(--line); padding 14px; overflow-y auto;
                  flex column; gap 12px
.stage          → position relative; overflow hidden; bg #090c12
.telemetry      → height var(--foot-h); bg var(--panel); top border var(--line)
```

- **Left rail width is exactly `--rail-w` (320px).** Right pane is `1fr`.
- **Bottom telemetry bar height is exactly `--foot-h` (84px).**
- **Header height is exactly `--head-h` (56px).**

## 4. Component rules (visual contract — reproduce faithfully)

**Cards** (`.card`): bg `--panel-2`, 1px `--line` border, `border-radius:10px`,
`padding:12px`. Card titles (`.card h2`): `.78rem`, uppercase,
`letter-spacing:.8px`, color `--muted`, flex row with space-between (so the
model card's ⟳ button sits at the right).

**Form controls** (`select`, `input[type=text|number]`): bg `#0f1520`, text
`--text`, 1px `--line` border, `border-radius:7px`, `padding:8px`,
`font-size:.88rem`; focus border `--accent-2`.

**Buttons**
- `.btn` base: no border, `border-radius:8px`, `padding:11px 10px`, `font-weight:600`.
- `.btn-primary` (Start): bg `--accent`, color `#06231c`; hover `brightness(1.08)`.
- `.btn-ghost` (Stop all / apply-all): transparent, `--muted` text, 1px `--line`.
- `.mini-btn` (⟳ re-scan): 24×22px, transparent, 1px `--line`; hover turns `--accent`;
  add a `.spin` modifier animating `spin .8s linear infinite` (`@keyframes spin { to { transform: rotate(360deg); } }`).
- `.p-apply` (per-panel Apply zone): bg `--accent-2`, color `#04122b`, small.

**Utilization gauges** (`.util .gauge`): CSS grid
`grid-template-columns: 42px 1fr 46px`, `align-items:center`, `gap:3px 8px`. Row =
`[.g-label] [.bar] [.g-val]`, plus a full-width sub-line `.g-sub`
(`grid-column: 1 / -1`, `.68rem`, `--muted`, right-aligned, `tabular-nums`,
`min-height:.8em`). `.bar`: 8px tall, bg `#0f1520`, `border-radius:999px`,
`overflow:hidden`; its `> i`: height 100%, width set by JS,
`background: linear-gradient(90deg, var(--accent), var(--accent-2))`,
`transition: width .4s ease`.

**Video grid** (`.grid`): `display:grid`, `gap:14px`, `padding:14px`,
`grid-auto-rows:1fr`, `grid-template-columns: repeat(auto-fit, minmax(360px, 1fr))`,
`overflow-y:auto`. Compare modifier `.grid.compare`:
`grid-template-columns: repeat(2, 1fr)`.

**Panel** (`.panel`): bg `--panel`, 1px `--line`, `border-radius:10px`,
`overflow:hidden`, flex column, `min-height:220px`. Head (`.panel-head`) bg
`--panel-2`, space-between. Video wrap (`.video-wrap`): `position:relative`,
`flex:1`, bg `#000`. `video`: absolutely filled, `object-fit: contain`, bg `#000`.

**ROI overlay** (inside `.video-wrap`): `.roi-overlay` absolutely covers the video,
`pointer-events:none`; add `.draw` modifier → `pointer-events:auto; cursor:crosshair`.
`.roi-current` (applied zone): 2px solid `--accent`, bg `rgba(41,193,156,.12)`,
`display:none` until positioned, with a `::after` "zone" label. `.roi-draw`
(rubber-band while dragging): 2px dashed `--accent-2`, bg `rgba(61,139,255,.14)`.

**Panel status** (`.p-status`): `.74rem`, `--muted`; `.live` modifier → `--accent`;
`.error` modifier → `--danger`.

**Telemetry strip** (`.strip`): flex row, `gap:12px`, `overflow-x:auto`,
`padding:10px 14px`. Cards (`.tele-card`): min-width 200px, bg `--panel-2`, 1px
`--line`, `border-radius:9px`. Metrics row (`.tele-metrics`) = flex of `.m` blocks,
each `<b>` value `1rem tabular-nums` over a `<span>` `.66rem` uppercase `--muted`
label. Loiter emphasis: `.tele-card.loiter` border `--warn`; its loiter value
`--warn`.

**Connection pill** (`.conn`): `.8rem`, pill (`border-radius:999px`), 1px `--line`.
`.conn-ok` text `--accent`; `.conn-bad` text + border `--danger`.

## 5. Why these exact values

They are the validated palette/spacing from the reference deployment. Reproducing
them — rather than inventing new ones per machine — is the entire reason the UAV
"different feel on each machine" problem does not recur here. If a future change
to the look is wanted, change it **here once**; every regenerated stack then
inherits it.
