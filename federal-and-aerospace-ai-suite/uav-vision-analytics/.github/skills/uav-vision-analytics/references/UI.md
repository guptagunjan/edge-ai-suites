<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Web UI Reference — UAV Vision Analytics

## Overview

`uav-mission-ui` is a single lightweight Flask + ffmpeg container that gives a
browser-based "Mission Console" for the stack — no VLC/QGroundControl
required to see annotated video, and no shell access required to see system
load. It must work **unmodified** in both deployment modes (`pymavlink` and
`uavsdk`); only environment variables should differ between the two compose
files — never branch on `{{DEPLOYMENT_MODE}}` inside Python/HTML.

Features (all backed by REST APIs already exposed by DLSPS / Metrics Manager
— this container adds no new inference or metrics logic, it only aggregates
and relays):

- **Pipeline Control** — list pipelines registered in DLSPS `config.json`,
  start/stop any of them on demand, any time (independent of arm state), with
  several running concurrently (each in its own "stream panel").
- **Live in-browser video preview** — MJPEG relay of the RTSP output via an
  `ffmpeg` subprocess, works in a plain `<img>` tag in any browser. The raw
  RTSP URL is also shown so VLC/QGC can be used instead/as well.
- **System Utilization panel** — live CPU / GPU / NPU / MEM gauges + secondary
  stats (frequency, power, temperature) polled every 2 s from Metrics Manager.
- **Mission Control** — "Start Mission" / "End Mission" buttons arm/disarm the
  vehicle (MAVLink command in pymavlink mode, companion-bridge REST call in
  uavsdk mode). This is optional/independent of Pipeline Control: it only
  matters if you also want to exercise the *separate* automated
  `pipeline_manager.py` arm/disarm pipeline lifecycle (see `TELEMETRY.md`)
  from the browser instead of QGroundControl.

## Files to Generate

```
{{STACK_DIR}}/ui/
├── Dockerfile
├── requirements.txt
├── app.py
└── templates/
    └── index.html
```

All four files are generated fresh, from the contracts below, on every
invocation. None contain `{{VAR}}` placeholders themselves — behavior differs
across deployment modes purely via the environment variables the compose
service injects (see below), so the same generated code works for both
`pymavlink` and `uavsdk` stacks without edits.

---

## Environment Variables

All read by `app.py` at startup (e.g. `os environ.get(...)`) and set via the
compose service's `environment:` block — this is the **only** thing that
differs between the two deployment modes.

| Variable | pymavlink default | uavsdk default | Purpose |
|----------|-------------------|-----------------|---------|
| `DEPLOY_MODE` | `standalone` | `sdk` | Selects MAVLink-direct vs. companion-bridge REST arm/disarm |
| `PIPELINE_SERVER_URL` | `http://dlstreamer-pipeline-server:8081` | same | DLSPS REST base URL (container network) |
| `METRICS_URL` | `http://metrics-manager:9090` | `http://metrics-manager:9090` (SDK-owned — see note below) | Metrics Manager REST base URL (container network) |
| `RTSP_HOST_INTERNAL` | `dlstreamer-pipeline-server` | same | Host `ffmpeg` uses to pull RTSP for the MJPEG relay (container network) |
| `RTSP_PORT_INTERNAL` | `8555` | same | — |
| `RTSP_PORT_EXTERNAL` | `8555` | same | Used only to build the browser-facing `rtsp://` URL string |
| `HOST_IP` | `${HOST_IP}` | `${HOST_IP}` | Used only to build the browser-facing `rtsp://` URL string |
| `MODEL_PATH` | `/home/pipeline-server/resources/models/yolov8n-visdrone/best_openvino_model/best.xml` | same | Passed as `detection-properties.model` when starting a pipeline |
| `MAVLINK_ARM_CONN` | `udpout:mavlink-router:14550` | n/a (sdk mode doesn't use this) | pymavlink connection string used only by the arm/disarm button |
| `COMPANION_BRIDGE_URL` | n/a | `http://px4-gazebo:8080` | uavsdk mode arm/disarm REST target (`POST /action/arm`, `POST /action/disarm`) |
| `UI_PORT` | `8090` | `8090` | Flask listen port |

**Metrics Manager ownership differs by mode** — this affects only *which*
`metrics-manager` the UI's `METRICS_URL` points at, never the UI's own code:

- **pymavlink mode**: this app generates and owns its own `metrics-manager`
  service (see `references/DEPLOY.md`) — always present.
- **uavsdk mode**: this app never generates a `metrics-manager` of its own.
  `METRICS_URL` points at the **`uav-mission-compute-sdk`**'s
  `metrics-manager` (hostname `metrics-manager`, reached over the external
  `infra` network — see `references/DEPLOY.md`), which is only present if
  that stack was started with the `observability` profile. If it is
  unreachable, `/api/metrics` must return `null` for every field (never a
  500) so the UI's System Utilization panel degrades to "unavailable"
  instead of crashing the whole page.

---

## REST API Contract (implement exactly these routes)

`templates/index.html` (client-side JS, polling) is the only consumer, but
the contract below is what makes the two files interoperate correctly —
implement it exactly so the UI has something to render.

| Route | Method | Request body | Response | Behavior |
|-------|--------|--------------|----------|----------|
| `/` | GET | — | HTML | Renders `index.html` |
| `/api/pipelines` | GET | — | `["name1", "name2", ...]` | Proxy `GET {PIPELINE_SERVER_URL}/pipelines`, return sorted list of names (**read `p["version"]`, not `p["name"]`** - every entry's `"name"` is the fixed literal `"user_defined_pipelines"`; the real, launchable pipeline identifier is in `"version"`) |
| `/api/pipelines/status` | GET | — | passthrough JSON | Proxy `GET {PIPELINE_SERVER_URL}/pipelines/status` |
| `/api/pipelines/start` | POST | `{"name": str, "device"?: str}` | `{"status":"started","session_id","instance_id","rtsp_url","preview_url"}` | See "Starting a Pipeline" below |
| `/api/pipelines/stop` | POST | `{"session_id": str}` | `{"status":"stopped"}` | `DELETE {PIPELINE_SERVER_URL}/pipelines/{instance_id}` for that session, then drop it from the in-memory session map |
| `/api/sessions` | GET | — | `{session_id: {name, instance_id, device, frame_path, rtsp_url, preview_url}}` | All currently active sessions — used to restore stream panels after a page refresh |
| `/api/stream/mjpeg` | GET | query `?path=<frame_path>` | `multipart/x-mixed-replace` MJPEG stream | See "MJPEG Relay" below |
| `/api/mission/start` | POST | — | `{"status":"armed"}` | Arm — see "Mission Control" below |
| `/api/mission/stop` | POST | — | `{"status":"disarmed"}` | Disarm — see "Mission Control" below |
| `/api/metrics` | GET | — | `{"cpu":{"percent":...},"gpu":{"percent":...},"npu":{"percent":...},"mem":{"percent":...}}` | Proxy + reshape `GET {METRICS_URL}/api/v1/metrics/latest` - see "Metrics Manager Response Shape" below, it is NOT already keyed by `cpu`/`gpu`/`mem` |

### Metrics Manager Response Shape — implementation requirement

**Verified against a live `intel/metrics-manager:2026.2.0-rc2` container.**
`GET {METRICS_URL}/api/v1/metrics/latest` does **not** return
`{"cpu": {...}, "mem": {...}}` directly. It returns:

```json
{
  "metrics": {
    "cpu_usage_idle{cpu=cpu-total,host=...}": {
      "name": "cpu_usage_idle", "tags": {...},
      "fields": {"value": 68.07}, "timestamp": 1788756259000000000
    },
    "mem_used_percent{host=...}": {
      "name": "mem_used_percent", "fields": {"value": 36.1}, ...
    },
    "gpu_engine_usage_usage{engine=bcs,gpu_id=0,...}": {
      "name": "gpu_engine_usage_usage", "fields": {"value": 1.2}, ...
    },
    "gpu_engine_usage_usage{engine=rcs,gpu_id=0,...}": { "...": "one entry per GPU engine (bcs/ccs/rcs/vcs/vecs)" },
    "npu_utilization{host=...}": {
      "name": "npu_utilization", "fields": {"value": 0.0}, ...
    }
  }
}
```

It is a **flat dict keyed by `"<metric_name>{tag=val,...}"`**, not grouped by
subsystem. `/api/metrics` must reshape it:

1. Iterate `resp.json()["metrics"].values()`, matching each entry's `"name"`
   field (ignore the tag suffix in the outer key - it varies per host/engine).
2. `cpu.percent = 100 - <cpu_usage_idle value where tags.cpu == "cpu-total">`
   (Metrics Manager reports idle %, not usage % directly).
3. `mem.percent = <mem_used_percent value>` (already a usage percentage).
4. `gpu.percent = average of every gpu_engine_usage_usage value` (there is
   one entry per GPU engine — bcs/ccs/rcs/vcs/vecs — not a single GPU
   number; average them for a single gauge, or expose all five if the UI
   needs per-engine detail).
5. `npu.percent = <npu_utilization value>`.
6. If a metric name is absent from the response (e.g. no NPU present on the
   host, or Metrics Manager hasn't completed its first poll yet), return
   `null` for that field rather than raising — the completion criteria only
   require `cpu.percent`/`mem.percent` to be non-null.

### Starting a Pipeline — implementation requirements

1. Generate a `session_id` — an 8-hex-char random suffix (e.g.
   `secrets.token_hex(4)`), so **multiple concurrent panels running the same
   pipeline name never collide** on the RTSP mount point.
2. Build `frame_path = f"{name}_{session_id}"`.
3. `POST {PIPELINE_SERVER_URL}/pipelines/user_defined_pipelines/{name}` with:
   ```json
   {
     "destination": {
       "metadata": {"type": "file", "path": "/tmp/results.jsonl", "format": "json-lines"},
       "frame": {"type": "rtsp", "path": "<frame_path>"}
     },
     "parameters": {
       "detection-properties": {"model": "<MODEL_PATH>", "device": "<device or pipeline default>"}
     }
   }
   ```
4. The response body is the raw integer `instance_id` — store it.
5. Store the session in an in-memory dict (module-level, no DB needed):
   `sessions[session_id] = {"name", "instance_id", "device", "frame_path", "rtsp_url", "preview_url"}`.
6. `rtsp_url = f"rtsp://{HOST_IP}:{RTSP_PORT_EXTERNAL}/{frame_path}"` (for
   VLC/QGC/`ffplay`), `preview_url = f"/api/stream/mjpeg?path={frame_path}"`
   (for the in-browser `<img>`).

### MJPEG Relay — implementation requirements

`GET /api/stream/mjpeg?path=<frame_path>` must:

1. Spawn `ffmpeg -i rtsp://{RTSP_HOST_INTERNAL}:{RTSP_PORT_INTERNAL}/<path> -f mjpeg -q:v 5 -r 10 pipe:1` (or
   equivalent) as a subprocess with `stdout=PIPE`.
2. Stream its stdout as a Flask `Response` with
   `mimetype="multipart/x-mixed-replace; boundary=frame"`, wrapping each JPEG
   frame in the multipart boundary format.
3. **Retry on startup race:** right after `/api/pipelines/start` returns, the
   RTSP mount point can take 1–2 seconds to begin serving media. Wrap the
   initial `ffmpeg` connection attempt in a bounded retry loop — e.g. up to
   10 attempts, ~1.2 s apart — before giving up. Without this, the `<img>`
   preview permanently shows a broken image if the browser requests the
   stream before the mount is ready.
4. Terminate the `ffmpeg` subprocess cleanly when the client disconnects
   (generator `finally:` block calling `.terminate()`/`.kill()`) to avoid
   leaking zombie processes as panels are opened/closed repeatedly.

### Mission Control — implementation requirements

- `DEPLOY_MODE=standalone` (pymavlink): use `pymavlink` to connect to
  `MAVLINK_ARM_CONN` and send `MAV_CMD_COMPONENT_ARM_DISARM` with param1
  `1` (arm) / `0` (disarm).
- `DEPLOY_MODE=sdk` (uavsdk): `POST {COMPANION_BRIDGE_URL}/action/arm` or
  `/action/disarm`.
- Branch on the `DEPLOY_MODE` env var at request time — never hardcode one
  mode.

---

## `Dockerfile` Requirements

- Base on a slim Python image (e.g. `python:3.11-slim`).
- `apt-get install -y ffmpeg` (required by the MJPEG relay — the image
  build fails at runtime with a cryptic `FileNotFoundError` for `ffmpeg` if
  this is forgotten).
- `pip install` at minimum: `flask`, `requests`, `pymavlink` (pymavlink mode
  only needs it, but installing it unconditionally keeps the image identical
  across modes), `psutil` is **not** needed here — metrics are fetched from
  the separate `metrics-manager` service, not read locally.
- `EXPOSE 8090` (or `${UI_PORT}`).
- `CMD ["python3", "app.py"]` (Flask app binds `0.0.0.0:$UI_PORT`).

---

## docker-compose Service Fragment

**This fragment is written only into the newly generated
`{{STACK_DIR}}/docker-compose-{{MODE}}.yml`.** Never add `uav-mission-ui` to
this skill's own reference/example compose files
(`docker-compose-pymavlink.yml` / `docker-compose-uavsdk.yml` checked into
this app's real repo) — those are the actual shipped application and must
never hardcode an optional, skill-only service.

The fragment **differs by deployment mode** — do not reuse the pymavlink
fragment for uavsdk mode with only the environment block swapped; the
network and which services exist are also different:

### pymavlink mode

Add both `uav-mission-ui` and this app's own `metrics-manager` (pymavlink
mode owns and generates its own — this stack is fully self-contained, see
`references/DEPLOY.md`) alongside the existing `dlstreamer-pipeline-server`
service:

```yaml
  metrics-manager:
    image: intel/metrics-manager:2026.2.0-rc1
    container_name: metrics-manager
    privileged: true
    pid: host
    devices:
      - /dev/dri            # Intel GPU — card0 + renderD128 required for qmassa
    volumes:
      - /sys:/sys:ro
    restart: unless-stopped
    networks:
      - app_network
    ports:
      - "9090:9090"

  uav-mission-ui:
    build: ./ui
    image: {{STACK_NAME}}-mission-ui
    container_name: uav-mission-ui
    environment:
      - http_proxy=${http_proxy}
      - https_proxy=${https_proxy}
      - no_proxy=${no_proxy},${HOST_IP},dlstreamer-pipeline-server,metrics-manager,mavlink-router,broker,px4
      - NO_PROXY=${no_proxy},${HOST_IP},dlstreamer-pipeline-server,metrics-manager,mavlink-router,broker,px4
      - DEPLOY_MODE=standalone
      - PIPELINE_SERVER_URL=http://dlstreamer-pipeline-server:8081
      - METRICS_URL=http://metrics-manager:9090
      - RTSP_HOST_INTERNAL=dlstreamer-pipeline-server
      - RTSP_PORT_INTERNAL=8555
      - RTSP_PORT_EXTERNAL=8555
      - HOST_IP=${HOST_IP}
      - MAVLINK_ARM_CONN=udpout:mavlink-router:14550
    ports:
      - "8090:8090"
    networks:
      - app_network
    depends_on:
      - dlstreamer-pipeline-server
      - metrics-manager
    restart: on-failure:5
```

### uavsdk mode

Add **only** `uav-mission-ui` alongside the existing
`dlstreamer-pipeline-server` service. **Never add a `metrics-manager` (or
`mqtt-broker`/`mediamtx`/`px4-gazebo`/`companion-bridge`/`camera-bridge`)
service here** — those belong to, and must already be running as part of,
the separate `uav-mission-compute-sdk` stack; this app only ever attaches to
it as a client (see `references/DEPLOY.md` for the prerequisite steps,
including setting `HOST_IP=0.0.0.0` in that stack's own `.env` before it is
started).

**Two different, and correctly different, network-reachability mechanisms
are required here — do not conflate them:**

1. `dlstreamer-pipeline-server` and `uav-mission-ui` are both on this stack's
   own `app_network` (bridge) and reach each other by container name
   directly — no SDK involvement needed for that hop.
2. To reach services that live in the **other** (`uav-mission-compute-sdk`)
   compose project, there are two sub-cases, confirmed against that stack's
   own `docs/user-guide/ports.md`:
   - `companion-bridge`'s REST API (port `8080`) **is** host-published,
     `HOST_IP`-controlled (same mechanism as MQTT `1884`/RTSP `8554` used by
     `dlstreamer-pipeline-server`, see `references/DEPLOY.md`) — reach it via
     `http://host.docker.internal:8080`, same pattern as pymavlink mode. Do
     **not** guess a container hostname (e.g. `px4-gazebo`) for it — it is a
     *different* container (`companion-bridge`) and is not on this stack's
     network anyway.
   - `metrics-manager`'s REST API (port `9090`) is documented as
     **"container-internal only"** with **no host-published port under any
     `HOST_IP` setting** — the *only* way to reach it is for `uav-mission-ui`
     to join the SDK's own Docker network as a second network, and address
     it by container name (`metrics-manager`). This is not a workaround; it
     is the only mechanism the SDK offers for this one service.

```yaml
  uav-mission-ui:
    build: ./ui
    image: {{STACK_NAME}}-mission-ui
    container_name: uav-mission-ui
    environment:
      - http_proxy=${http_proxy}
      - https_proxy=${https_proxy}
      - no_proxy=${no_proxy},${HOST_IP},host.docker.internal,dlstreamer-pipeline-server,metrics-manager
      - NO_PROXY=${no_proxy},${HOST_IP},host.docker.internal,dlstreamer-pipeline-server,metrics-manager
      - DEPLOY_MODE=sdk
      - PIPELINE_SERVER_URL=http://dlstreamer-pipeline-server:8081
      - RTSP_HOST_INTERNAL=dlstreamer-pipeline-server
      - RTSP_PORT_INTERNAL=8555
      - RTSP_PORT_EXTERNAL=8555
      - COMPANION_BRIDGE_URL=http://host.docker.internal:8080
      - METRICS_URL=http://metrics-manager:9090
      - HOST_IP=${HOST_IP}
    ports:
      - "8090:8090"
    networks:
      - app_network
      - sdk_network
    depends_on:
      - dlstreamer-pipeline-server
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: on-failure:5

networks:
  app_network:
    driver: bridge
  sdk_network:
    # {{SDK_COMPOSE_PROJECT_NAME}} is the uav-mission-compute-sdk directory's
    # basename (Compose's default project name) unless it was started with
    # `-p <name>`/`COMPOSE_PROJECT_NAME` — confirm with
    # `docker network ls | grep uav-mission-compute-sdk` before generating
    # this value, do not assume it.
    name: {{SDK_COMPOSE_PROJECT_NAME}}_default
    external: true
```

Note `depends_on` here lists only `dlstreamer-pipeline-server` — there is no
local `metrics-manager` service to depend on; if the SDK stack is not up yet,
or was started without granting `sdk_network` access, `/api/metrics` must
handle the resulting connection error gracefully (return `null` fields) per
the "Metrics Manager Response Shape" note above, not crash the container.

**Gotcha — `no_proxy`/`NO_PROXY` must list every container hostname the UI
talks to, including `dlstreamer-pipeline-server` itself** (Python's
`requests` does not match bare Docker Compose service names against CIDR/
domain-suffix `no_proxy` entries like `.internal` or `10.*` — each hostname
must be listed literally), otherwise requests are routed through a corporate
proxy and fail with `504 Gateway Timeout` from every `/api/*` route, not the
`502` this doc previously said — confirmed by reproducing this exact failure
during validation.

---

## Gotcha: Rebuild Required After Editing `ui/app.py` or `ui/templates/*`

Unlike `config.json` and the `gvapython`/`scripts/*.py` files (which are
bind-mounted into `dlstreamer-pipeline-server` and take effect on container
restart), `ui/app.py` and `ui/templates/index.html` are `COPY`'d into the
`uav-mission-ui` image at **build** time. A plain file edit has **no effect**
on the running container — you must rebuild and recreate it:

```bash
docker compose -f {{COMPOSE_FILE}} build uav-mission-ui
docker compose -f {{COMPOSE_FILE}} up -d --no-deps uav-mission-ui
```

---

## Verification (Completion Criteria)

1. `curl -s -o /dev/null -w '%{http_code}' http://localhost:8090/` → `200`.
2. `curl -s http://localhost:8090/api/pipelines` → JSON array of registered
   pipeline names (matches `configs/config-{{PIPELINE_PREFIX}}.json`).
3. `curl -s http://localhost:8090/api/metrics` → JSON with non-null
   `cpu.percent` and `mem.percent`, **provided `metrics-manager` is
   reachable** (always true in pymavlink mode; true in uavsdk mode only if
   the SDK stack was started with its `observability` profile — if not,
   all fields must be `null` with a `200` response, never a `500`).
4. `curl -s -X POST http://localhost:8090/api/pipelines/start -H "Content-Type: application/json" -d '{"name": "<pipeline_name>"}'`
   → `{"status": "started", "session_id", "instance_id", "rtsp_url", "preview_url"}`.
5. `curl -s http://localhost:8090/api/sessions` → the session started in
   step 4 is present.
6. `ffplay "$(curl -s http://localhost:8090/api/sessions | python3 -c "import json,sys;print(list(json.load(sys.stdin).values())[0]['rtsp_url'])")"`
   (or open the `preview_url` path via the browser `<img>` tag).
7. `curl -s -X POST http://localhost:8090/api/pipelines/stop -H "Content-Type: application/json" -d '{"session_id": "<from step 4>"}'`
   → `{"status": "stopped", ...}`, and the instance no longer appears in
   `GET http://localhost:8081/pipelines/status` as `RUNNING`.
8. Starting the same pipeline `name` twice concurrently (two different
   `session_id`s) succeeds without an RTSP mount-point collision — confirms
   the `frame_path = f"{name}_{session_id}"` scheme was implemented.
