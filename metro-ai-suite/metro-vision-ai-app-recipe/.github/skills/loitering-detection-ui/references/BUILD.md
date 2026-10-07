<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Build Procedure

The agent generates the console, deploys it as an addon, and verifies it. No file
belonging to the application is created, edited or replaced at any stage.

## Phase 0 — Survey

1. Confirm the application is running: `docker compose ps` in the recipe root.
2. Confirm it is unmodified: `git status --porcelain`. Only `.env`, written by
   `install.sh`, may appear. Restore anything else before continuing.
3. Confirm the pipeline server exposes `detection-properties`
   (`PIPELINE.md` §1). If it does not, report the incompatibility and stop.
4. Discover the network name (`DEPLOY.md` §3) and the model store path used by the
   pipeline server service.
5. Determine device availability: a render node for GPU, an accelerator node for
   NPU.
6. Determine the Prometheus base URL, including any route prefix:

   ```bash
   docker inspect prometheus --format '{{json .Args}}'
   ```

   A deployment started with `--web.route-prefix=/prometheus` answers only
   under that prefix; querying the bare port returns 404 and every gauge reads
   `n/a`.
7. Note that Docker injects the host's proxy settings into the container and
   that their bypass list does not contain Docker service names. The scaffold
   neutralises the proxy and writes an explicit bypass list; without it every
   in-network call fails with 504 and no pipeline can be started.

## Phase 1 — Generate

### 1.1 Non-destructive rule

An existing deployment MUST NOT be removed in order to regenerate it. A
half-finished generation leaves the operator with no console at all, which is
worse than an outdated one.

- Do not delete `{{ADDON_DIR}}`, and do not stop or remove the `console`
  container, before the replacement has been generated and validated.
- Generation is resumable. Before writing a file, test whether it already
  exists and satisfies its budget below. If it does, leave it and move on.
- Swap only at the end: build the image, and only then recreate the container.

### 1.2 Plumbing is scaffolded, not generated

Run the scaffold once. It emits the container and compose plumbing, which
carries no appearance or behaviour, and refuses to overwrite an existing file:

```bash
scripts/scaffold.sh \
  --addon-dir {{ADDON_DIR}} --network {{APP_NETWORK}} --host-ip {{HOST_IP}} \
  --console-port {{CONSOLE_PORT}} \
  --model-store {{MODEL_ROOT}} --model-store-host {{MODEL_STORE_HOST}} \
  --devices {{DEVICES}} --zone {{DEFAULT_ZONE}} \
  --loiter-threshold {{LOITER_THRESHOLD_S}} \
  --topic-prefix {{DETECTIONS_TOPIC_PREFIX}} \
  --sources-json '{{SOURCES_JSON}}'
```

This produces `requirements.txt`, `entrypoint.sh`, `Dockerfile`,
`compose.console.yml` and `.env`. Do not hand-write these; the `.env` quoting in
particular is a documented trap.

### 1.3 Module manifest

The dashboard itself is generated from its specifications. It is divided into
modules with a **hard budget of 220 lines each**. The budget exists because a
single large file cannot be written reliably: a monolithic backend has been
truncated by the model output token limit mid-write, losing the whole file.

| File | Budget | Specification |
|---|---|---|
| `console/config.py` | 110 | `BACKEND-SPEC.md` §1 — environment, shared state, the Flask object |
| `console/catalog.py` | 210 | §2, §3, §13, §14 — discovery, preflight, sources, pipeline and instance selection |
| `console/analytics.py` | 200 | §5, §6, §11 — frame-time units, zone occupancy, dwell, snapshot |
| `console/ingest.py` | 150 | §5, §6.1 — MQTT subscription and reconciliation |
| `console/metrics.py` | 140 | §7 — utilisation |
| `console/api.py` | 150 | §4, §6.2, §8 — configuration, models, zone, events, metrics, health |
| `console/api_pipelines.py` | 140 | §8, §12 — pipeline start and stop, zone honoured at start |
| `console/whep_proxy.py` | 110 | §4 — WHEP proxy and readiness |
| `console/app.py` | 60 | entry point: import the modules, start ingestion, serve over TLS |
| `console/templates/index.html` | 200 | `LAYOUT.md` |
| `console/static/styles.css` | 210 | `DESIGN-TOKENS.md` — tokens, skeleton, header, rail |
| `console/static/panels.css` | 190 | `LAYOUT.md` — grid, panels, telemetry, overlay |
| `console/static/whep.js` | 190 | `FRONTEND-SPEC.md` part A |
| `console/static/panels.js` | 200 | part B §B1–B4, §F |
| `console/static/telemetry.js` | 170 | part B §B5–B6, §E, §G |
| `console/static/app.js` | 180 | part B §B0, §B7 |

Modules MUST NOT import the entry point. `python app.py` makes that module
`__main__`, so `from app import SESSIONS` would load a second, independent
session table. Shared state lives in `config.py`.

`index.html` MUST load the scripts in the order `whep.js`, `panels.js`,
`telemetry.js`, `app.js`. Modules communicate through a single `window.Console`
namespace object; no module may assume another's internals.

### 1.4 Write protocol

For any file whose content exceeds roughly 120 lines, write it in **ordered
sections of at most 120 lines**: create the file with the first section, then
append the remainder one section at a time. Each section must end at a
syntactic boundary — a complete function or rule — so that a failed or
truncated write damages only that section.

If a write fails, retry **that section only**. Never restart the file, and never
delete completed files in response to a failure.

After each file, validate it before continuing:

```bash
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" <file.py>
node --check <file.js>
```

Both are mandatory, and the gate repeats them. A single malformed regular
expression literal disables an entire controller module, and with it all
video, while every content check still passes; syntax must be proven rather
than assumed.

Import resolution must be proven as well. Run the backend once and confirm it
starts: a split backend can reference a name that used to be module-global,
which no syntax check reveals.

### 1.5 Rules

- Emit the design tokens verbatim. Do not introduce a colour, spacing value or
  font that does not appear in `DESIGN-TOKENS.md`.
- Emit every element identifier in `LAYOUT.md` §8. Do not rename or omit one.
- Reference assets and APIs relatively, and include the base-href injector.
- Do not name a detection model anywhere, including comments and placeholder
  text. The catalogue comes from discovery.
- Implement every MUST clause. They encode defects observed in the field and are
  asserted by the gate.
- Respect the budgets. A file over budget is a gate failure, because it is the
  condition under which generation has been observed to fail.

## Phase 2 — Deploy

Follow `DEPLOY.md` §5. Build, start, and confirm the container is running. The
application's containers must be untouched; do not restart, recreate or modify
them.

### Static checks before deployment

Run all three against the generated package; each MUST pass:

```
python3 -c "import ast,sys;[ast.parse(open(f).read(),f) for f in sys.argv[1:]]" console/*.py
python3 <skill>/scripts/namecheck.py console/
node --check console/static/<each>.js      # when node is available
```

`namecheck.py` resolves every global name read inside a function against the
names its module binds. This catches the failure mode that module splitting
introduces and that neither a syntax check nor an import check detects: a
name used only inside a route body whose defining import was left in another
module. Such a module imports cleanly and fails at runtime with a 500 the
first time that route is exercised.

Note its limit: it detects *undefined* names, not semantically damaged code.
An edit that turns `f(a, b, c)` into the tuple `(a, b, c)` leaves every name
defined and is invisible to it. Editing generated modules with blanket string
substitution is therefore unsafe; prefer targeted replacement of a full
statement, and always exercise the affected route afterwards.

## Phase 3 — Verify

```bash
acceptance/verify.sh https://<HOST_IP>:<CONSOLE_PORT> {{ADDON_DIR}}/console \
    --app-dir {{APP_DIR}} --live
```

Resolve every failure by correcting the generated file so that it satisfies its
specification. Do not weaken the gate, and do not modify an application file in
order to make a check pass.

A failure in section `[15]` means a module is missing or over budget. Split it
rather than raising the budget.

The live phase exercises each device the host provides, so a GPU or NPU
regression is detected rather than assumed absent.

## Phase 4 — Report

State the console URL, the number of models discovered, the devices exercised,
and the gate result. Confirm that the application's tracked files are clean and
that its own interface is still reachable.

## If the appearance or behaviour must change

Amend the specification and the gate in this skill once, then regenerate. Editing
a generated file alone causes the next deployment on another machine to differ,
which is the variance this skill exists to prevent.
