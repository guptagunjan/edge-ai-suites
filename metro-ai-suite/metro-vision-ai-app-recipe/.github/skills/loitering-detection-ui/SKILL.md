---
name: loitering-detection-ui
description: >-
  Generate a browser-based Mission Console dashboard for a Metro Vision AI
  application (default: loitering-detection) and attach it to an already-running,
  unmodified deployment. The console provides a left control rail for source
  selection, auto-discovered detection models, inference device (CPU/GPU/NPU),
  loitering zone definition including draw-on-video, and system utilisation; a
  right pane with live annotated WebRTC video supporting side-by-side model
  comparison; and a bottom bar reporting per-stream FPS, dwell time and
  loiter/object counts. The skill contains no application code: it generates the
  console from locked specifications and verifies it against an acceptance
  suite, modifying no application file.
  USE FOR: adding an operator and model-comparison dashboard to a deployed
  metro-vision-ai-app-recipe application. DO NOT USE FOR: building the detection
  pipeline itself (see metro-ai-app-recipe), model training, or cloud-only
  deployments.
license: Apache-2.0
compatibility: >-
  Requires a running metro-vision-ai-app-recipe deployment providing DL Streamer
  Pipeline Server, MediaMTX, Coturn and an MQTT broker; Prometheus and
  metrics-manager are optional. Docker and Docker Compose v2 are required. The
  generated console is a single Flask container that terminates its own TLS on a
  dedicated published port, attaches to the deployment's existing Docker network,
  and mounts the model store read-only. It does not modify the application's
  compose files, pipeline configuration, reverse-proxy configuration, Grafana
  dashboards or Node-RED flows. Validated against
  intel/dlstreamer-pipeline-server:2026.2.0-ubuntu24.
---

<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Mission Console (UI) Skill — Metro Vision AI / Loitering Detection

## Purpose

This skill generates an operator dashboard ("Mission Console") and attaches it to
a running Metro Vision AI deployment. The dashboard adds interactive control and
model comparison to a stack whose stock interface (Grafana and Node-RED) is
read-only.

The skill contains no runtime source code. On invocation the agent generates the
console from the specifications under [`references/`](references/) and validates
the deployment with [`acceptance/verify.sh`](acceptance/verify.sh).

## Non-modification requirement

The target application is deployed from its released configuration and is left
byte-for-byte unchanged. The following files MUST NOT be created, edited or
replaced by this skill:

| Application file | Why it is not required |
|---|---|
| `src/dlstreamer-pipeline-server/config.json` | The released pipelines already declare a `detection-properties` parameter, which is sufficient to select model, device and model instance at request time (see `references/PIPELINE.md`). |
| `src/nginx/nginx.conf` | The console terminates its own TLS on a dedicated port and proxies WHEP itself; no reverse-proxy route is needed. |
| `compose-*.yml`, `docker-compose.yml` | The console is deployed from a separate compose file owned by the skill, which joins the application's existing network as an external network. |
| `src/node-red/flows.json`, Grafana dashboards | The console derives its own analytics from the MQTT metadata stream and does not alter existing dashboards or flows. |

All generated artefacts are written to a single new directory outside the
application's source tree and can be removed without trace. This requirement is
verified by the acceptance suite, which fails if the application's tracked files
are dirty.

## Architecture

```
Browser
  ├─ https://HOST:443/grafana/        existing application UI (untouched)
  └─ https://HOST:CONSOLE_PORT/       Mission Console (generated, own TLS)
                                        ├─ /api/*    control and telemetry
                                        └─ /whep/*   WebRTC signalling proxy

Mission Console (Flask, aggregation and relay only; performs no inference)
  ├─ DL Streamer Pipeline Server REST   start / stop / list pipeline instances
  ├─ MQTT broker                        detection metadata -> FPS, dwell, loiter
  ├─ Prometheus (optional)              CPU / GPU / NPU / memory utilisation
  ├─ MediaMTX                           WHEP signalling proxied to the browser
  └─ model store (read-only mount)      detection-model auto-discovery

DL Streamer Pipeline Server -- WHIP --> MediaMTX -- WHEP --> browser <video>
```

Media is relayed by the deployment's existing Coturn TURN server, so playback
works from a remote browser. No additional media server, broker or metrics
backend is introduced.

## Consistency model

The dashboard must render and behave identically on every machine. Because the
skill ships no code, consistency is enforced by locked contracts and a gate:

| Contract | File | Guarantees |
|---|---|---|
| Design tokens (palette, spacing, typography, dimensions) | `references/DESIGN-TOKENS.md` | identical appearance |
| DOM contract (element identifiers, structure, base href) | `references/LAYOUT.md` | identical structure and wiring |
| Behavioural contract (REST, MQTT, metrics, WebRTC, analytics) | `references/BACKEND-SPEC.md`, `references/FRONTEND-SPEC.md` | identical behaviour |
| Acceptance gate | `acceptance/verify.sh` | the above are asserted against the served artefact |

Generated files are not byte-identical between runs; the rendered dashboard and
its behaviour are. Every defect previously observed in the field is recorded as a
MUST clause in the specifications and asserted by the gate, so a regeneration
cannot reintroduce it.

## Invoking this skill

The skill is addressed by the `name` field of this file's front matter. The
identifier is lower-case and must match exactly:

```
/loitering-detection-ui deploy the console against the running loitering-detection stack
```

### Discovery root

Skills are discovered from `.github/skills/` **relative to the session root**.
The session must therefore be started at the repository directory that *contains*
`.github/`, not inside `.github/skills/` itself. Starting a session inside
`.github/skills/` causes the loader to search `.github/skills/.github/skills/`,
and the skill is reported only as an inherited entry or not at all.

| Session started at | Result |
| --- | --- |
| `<repo>/metro-ai-suite/metro-vision-ai-app-recipe` | Listed under **Project skills**; `/loitering-detection-ui` resolves |
| `<repo>/.../.github/skills` | Not resolvable from this root |

VS Code: open the directory containing `.github/` as a workspace folder.
Copilot CLI: `cd` to that directory before starting `copilot`, or pass
`--add-dir <directory>` to load its `.github/skills` as trusted configuration.

### Front-matter constraints

The loader rejects a skill whose `description` exceeds **1024 characters**,
reporting `Skill description must be at most 1024 characters`; the skill then does
not appear and the command is reported as unknown. Any edit to the `description`
field must preserve this limit. The constraint is asserted by
`acceptance/verify.sh`.

### Diagnosis

List the skills visible from the intended session root and inspect the load
report:

```
copilot skill list
```

A skill that fails validation is named under `The following skills failed to
load:` together with the reason. A skill that loads correctly appears under
`Project skills`.

The skill may also be engaged by description, for example "attach a mission
console to the loitering-detection deployment".

## Procedure

1. Read this file, then `DESIGN.md`, then the specifications under `references/`.
2. Confirm the target deployment is running and healthy. The console attaches to a
   live stack; it does not deploy the application.
3. Ask the questions below in a single message; accept `defaults` to proceed.
4. Validate the parameters in the table below before writing any file.
5. Generate the console into `{{ADDON_DIR}}` per `references/BUILD.md`.
6. Deploy it with the generated compose file per `references/DEPLOY.md`.
7. Run `acceptance/verify.sh` and resolve every failure before reporting success.

## Parameters

| Parameter | Purpose |
|---|---|
| `{{APP_DIR}}` | Directory of the deployed application, for example `.../metro-vision-ai-app-recipe/loitering-detection` |
| `{{ADDON_DIR}}` | Directory for generated artefacts (default `{{APP_DIR}}/../console-addon`) |
| `{{APP_NETWORK}}` | Existing Docker network of the deployment, discovered with `docker network ls` |
| `{{CONSOLE_PORT}}` | Published HTTPS port for the console (default `9443`) |
| `{{SOURCES}}` | Camera, RTSP or file catalogue published as `SOURCES_JSON` |
| `{{DEFAULT_ZONE}}` | Default loitering zone `x,y,w,h` in source pixels (default `0,200,300,400`) |
| `{{LOITER_THRESHOLD_S}}` | Dwell seconds at which a track is reported as loitering (default `5.0`) |
| `{{DETECTIONS_TOPIC_PREFIX}}` | MQTT metadata topic prefix (default `object_tracking`) |

Detection models are never supplied as a parameter. They are discovered at
runtime from the deployment's model store; see `references/PIPELINE.md`.

## Questions

1. Application directory [`./loitering-detection`]
2. Published console port [`9443`]
3. Video sources [the sources already present in the deployment]
4. Default loitering zone `x,y,w,h` [`0,200,300,400`]
5. Loiter dwell threshold in seconds [`5.0`]

## Parameter validation

| Parameter | Rule | Failure mode if violated |
|---|---|---|
| `APP_DIR` | Exists and contains `src/dlstreamer-pipeline-server/` | Wrong target; discovery yields nothing |
| `APP_NETWORK` | Present in `docker network ls` | Console cannot resolve service names |
| model store | Mounted read-only; discovery returns at least one model | Empty model selector |
| `CONSOLE_PORT` | Free on the host | Container fails to bind |
| `DEFAULT_ZONE` | Four integers, width and height greater than zero | Zone analytics rejects the region |
| `LOITER_THRESHOLD_S` | Float greater than zero | Loiter state never or always asserted |
| `DETECTIONS_TOPIC_PREFIX` | Matches `^[a-z0-9_]+$` | MQTT topic filter does not match |

## Execution constraints

- Do not modify any file belonging to the application. The constraint is absolute
  and is asserted by the acceptance gate.
- Generate strictly to the specifications. Do not introduce frameworks, external
  content delivery networks, additional colours, or endpoints beyond those
  specified. To change appearance or behaviour, amend the specification and the
  gate once, so that every future deployment inherits the change.
- Do not reference a specific detection model anywhere in generated code,
  configuration or documentation. The model catalogue is entirely determined by
  what the deployment provides.
- Reuse the deployment's MediaMTX and Coturn. Introducing a second media server
  double-binds the WebRTC ports.
- Supply a unique `model-instance-id` per model and device combination on every
  pipeline request. Reusing the released identifier with a different model leaves
  a stale instance bound to the previous network, which is the documented cause of
  GPU and NPU pipelines failing after a model change.
- Degrade rather than fail. If Prometheus is absent, `/api/metrics` returns null
  fields and the gauges display `n/a`; it must never return a server error.
- List every container hostname literally in `no_proxy` and `NO_PROXY`. The Python
  `requests` library does not match bare service names against CIDR or suffix
  entries, and every call would otherwise time out behind a corporate proxy.
- Bypass the host proxy for local checks in scripts (`--noproxy '*'`).

## Generated layout

```
{{ADDON_DIR}}/                       generated; contains no application file
├── compose.console.yml              console service; joins the app network as external
├── .env                             HOST_IP, ports, topic prefix, thresholds
└── console/
    ├── Dockerfile
    ├── requirements.txt
    ├── entrypoint.sh                issues the self-signed certificate
    ├── app.py                       per references/BACKEND-SPEC.md
    ├── templates/index.html         per references/LAYOUT.md
    └── static/{styles.css,whep.js,app.js}
```

## Completion criteria

The deployment is complete when `acceptance/verify.sh` exits zero, having
asserted each of the following.

1. The application's tracked files are unmodified and no application compose,
   pipeline, reverse-proxy, flow or dashboard file has been touched.
2. The served stylesheet contains every locked design token, and the served markup
   contains the base-href injector, relative asset references and every required
   element identifier.
3. No root-absolute asset or API reference appears in the generated markup or
   script.
4. `whep.js` performs ICE-server discovery and passes the parsed servers to the
   peer connection.
5. `app.py` filters the MQTT topic by prefix, reads detections from the nested
   metadata object, derives GPU utilisation from the compute-engine series, and
   evaluates the loitering zone in software.
6. The console container is running and healthy; the application's containers are
   unchanged and still running.
7. The console answers over HTTPS on its published port and serves the stylesheet
   as `text/css`; the application's own entry point is still reachable.
8. `/api/config` returns sources and devices; `/api/models` returns at least one
   discovered model; `/api/metrics` returns per-device figures including the GPU
   engine breakdown; `/api/events` returns successfully.
9. With `--live`: a pipeline starts and reaches `RUNNING` on each device the host
   provides; `/api/events` reports FPS and dwell for the corresponding stream;
   the loiter count increments once the threshold is exceeded; comparison mode
   yields two distinct peer identifiers; a zone change applies without restarting
   the pipeline; and stopping removes the instance.
