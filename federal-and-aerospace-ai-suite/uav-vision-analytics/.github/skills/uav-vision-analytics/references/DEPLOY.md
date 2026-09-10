<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Deployment Reference — UAV Vision Analytics

## Docker Compose Service Map

### pymavlink mode (`docker-compose-pymavlink.yml`)

| Service | Image | Ports | Role |
|---------|-------|-------|------|
| `dlstreamer-pipeline-server` | `${DLSTREAMER_PIPELINE_SERVER_IMAGE}`-pymavlink (built inline with `pip install pymavlink`) | `8081`, `8555` | AI inference + RTSP output |
| `broker` | `eclipse-mosquitto:2.0.22` | `1883` | MQTT broker for detection metadata |
| `px4` | `px4io/px4-sitl:latest` | — | PX4 SITL flight controller simulator (requires `10040_sihsim_quadx.post` volume mount) |
| `mavlink-router` | custom build | — | Routes MAVLink :14550 → :14541 |
| `metrics-manager` | `intel/metrics-manager:2026.1.0-*` | `9090` | CPU/GPU/NPU/power metrics collection — **always generated, independent of `{{INCLUDE_UI}}`** |
| `uav-mission-ui` | built from `./ui` (optional, `{{INCLUDE_UI}}`) | `8090` | Web Mission Console — pipeline control, live preview, system metrics (see `references/UI.md`). **This service block is only ever written into the freshly generated `{{STACK_DIR}}`'s compose file — never edit this app's own real `docker-compose-*.yml` in-place to add it.** |

### px4 Service (pymavlink mode)

The `px4` service MUST mount the airframe configuration file that tells PX4 which
MAVLink target to use. Without this mount PX4 SITL sends to its default
endpoint (within the container) and mavlink-router never receives packets,
causing the pipeline manager to block forever on `Waiting for heartbeat`.

```
{{STACK_DIR}}/10040_sihsim_quadx.post:
mavlink start -u 14541 -t $(getent hosts mavlink-router | awk '{print $1}')
```

Docker Compose fragment:
```yaml
  px4:
    image: px4io/px4-sitl:latest
    hostname: px4-sitl
    container_name: px4
    volumes:
      - ./10040_sihsim_quadx.post:/opt/px4/etc/init.d-posix/airframes/10040_sihsim_quadx.post
    stdin_open: true
    tty: true
    networks:
      - app_network
    depends_on:
      - mavlink-router
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

---

### UAVSDK mode (`docker-compose-uavsdk.yml`)

| Service | Image | Ports | Role |
|---------|-------|-------|------|
| `dlstreamer-pipeline-server` | `${DLSTREAMER_PIPELINE_SERVER_IMAGE}` | `8081`, `8555` | AI inference + RTSP output |
| `uav-mission-ui` | built from `./ui` (optional, `{{INCLUDE_UI}}`) | `8090` | Web Mission Console (`DEPLOY_MODE=sdk`, see `references/UI.md`). The UI app itself is identical code to pymavlink mode — only the compose service's env vars/networks differ. |

**This app deploys ONLY these two services in uavsdk mode — never a
`broker`/`mosquitto`, `metrics-manager`, `px4`, `companion-bridge`,
`camera-bridge`, `mediamtx`, or `mavlink-router` service.** All of that
infrastructure is owned by, and started separately by, the
**`uav-mission-compute-sdk`** repo (real container names, confirmed via
`docker ps`: `px4-gazebo`, `companion-bridge`, `camera-bridge`,
`mqtt-broker`, `mediamtx`, plus `metrics-manager`/`influxdb`/`grafana` if
the `observability` profile was enabled). This app's uavsdk-mode services
attach to that already-running stack as clients; they never stand up a
duplicate/competing copy of any SDK-owned service.

**Prerequisites:**
1. **Before starting `uav-mission-compute-sdk`**, set
   `HOST_IP=0.0.0.0` in that repo's `.env` (its `docker-compose.yml` binds
   MQTT/RTSP/REST ports as `${HOST_IP:-127.0.0.1}:<port>:<port>` — left at
   the `127.0.0.1` default, they are **not** reachable from sibling
   containers via `host.docker.internal`, only from the Docker host itself).
   The SDK's own get-started guide already documents this step
   (`sed -i 's|^HOST_IP=.*|HOST_IP=0.0.0.0|' .env`) — apply it as part of
   this skill's generation flow, do not skip it or assume it was already
   done.
2. Then start it, e.g. `make up-sim-camera` (includes the `observability`
   profile, i.e. `metrics-manager`, by default; `-lean` variants omit it, in
   which case the UI's System Utilization panel must degrade gracefully,
   see `references/UI.md`).
3. Confirm the SDK's Compose network name (needed for step 4 below,
   `metrics-manager` access only): `docker network ls | grep
   uav-mission-compute-sdk` — the default is `<dirname>_default` where
   `<dirname>` is that repo's checkout directory name (Compose's default
   project-name derivation), **not necessarily**
   `uav-mission-compute-sdk_default` — confirm, don't assume.

### uavsdk network attachment (`docker-compose-uavsdk.yml`)

**Two different, deliberately different mechanisms — do not conflate them
into a single "join the SDK's network for everything" approach (that was
tried and reverted; it duplicates the SDK's own documented port-publishing
design and is unnecessary/fragile for anything except `metrics-manager`):**

1. **`dlstreamer-pipeline-server`** stays on this stack's own `app_network`
   and reaches the SDK's MQTT broker and RTSP camera source via
   `host.docker.internal` — this works precisely because prerequisite #1
   above (`HOST_IP=0.0.0.0`) makes those host-published ports reachable
   from any container, not just the Docker host:
   ```yaml
   environment:
     - MQTT_HOST=host.docker.internal   # -> mqtt-broker, host-published :1884
     - MQTT_PORT=1884
   # config.json's RTSP source similarly uses host.docker.internal:8554 (mediamtx)
   extra_hosts:
     - "host.docker.internal:host-gateway"
   ```
2. **`uav-mission-ui`** needs both mechanisms, for different upstream
   services:
   - `companion-bridge`'s REST API (arm/disarm, port `8080`) is *also*
     host-published/`HOST_IP`-controlled → reach it via
     `http://host.docker.internal:8080`, same pattern as above. (Do not
     guess a container hostname for it, e.g. `px4-gazebo` — it is a
     separate container, `companion-bridge`, and is not on this stack's
     `app_network` regardless.)
   - `metrics-manager`'s REST API (port `9090`) is documented by the SDK
     itself (`uav-mission-compute-sdk/docs/user-guide/ports.md`) as
     **"container-internal only"**, with no host-published port under any
     `HOST_IP` setting. The *only* way to reach it is for `uav-mission-ui`
     to also join the SDK's Docker network as a **second** network and
     address it by container name. This is the one legitimate case for
     network-joining in uavsdk mode — see the full compose fragment in
     `references/UI.md`.

---

## SDK Simulation Gotchas (uavsdk mode)

- **The UI container needs `no_proxy`/`NO_PROXY` runtime env vars covering
  every internal hostname it talks to** (`dlstreamer-pipeline-server`,
  `metrics-manager`, `host.docker.internal`), not just build-time `ARG`s in
  the Dockerfile. On a host with a corporate `http_proxy`/`https_proxy`
  set, Python's `requests` library honors env-var proxies for *every*
  outbound call — including calls to sibling containers on the same Docker
  network — and CIDR/domain-suffix `no_proxy` patterns (e.g. `10.*`,
  `.internal`) do **not** match bare Docker Compose service names; each
  hostname must be listed literally. Without this, every
  `/api/pipelines*`/`/api/mission/*`/`/api/metrics` call from the UI fails
  with `504 Gateway Timeout` (confirmed by reproducing this exact failure
  during validation) — it looks like a networking/DNS bug but is actually
  the corporate proxy intercepting an intra-Docker-network call.
- **PX4 SITL in this simulation auto-disarms after ~10s of no active
  RC/GCS/offboard input.** `camera-bridge` only pushes frames to MediaMTX
  RTSP **while armed** (by design, to avoid idle RTSP connections) — so
  RTSP sources go dark ~10s after every `POST /action/arm`, independent of
  anything this app does. For a live demo or automated verification, arm
  periodically (e.g. every 5-8s) via `POST
  http://host.docker.internal:8080/action/arm` for as long as you need the
  camera feed alive — a real mission script (e.g.
  `uav-mission-compute-sdk/sample-apps/mission-simulation`) would send
  continuous setpoints/heartbeats and never hit this timeout. Also note PX4
  SITL can reject `arm()` with `COMMAND_DENIED` if its flight-mode/preflight
  state isn't ready (e.g. currently in `LAND` mode, EKF/GPS not settled) —
  this is normal simulator behavior, retry after a few seconds, it is not a
  bug in this app or the SDK.
- **`dlstreamer-pipeline-server` (the vendored `intel/dlstreamer-pipeline-server`
  image) can crash (`Too many open files` / segfault)** if its `rtspsrc`
  reconnection logic retries rapidly against a source that is repeatedly
  flapping between available/404 (e.g. because the UAV is being armed and
  disarmed in quick succession rather than held armed for the session).
  This is a bug inside the vendored image's reconnection/fd-cleanup logic,
  not something to work around in `app.py`/pipeline config. Mitigations:
  (1) hold the UAV armed for the duration of the pipeline session instead
  of flapping arm state, (2) only call `/api/pipelines/start` while
  confirmed armed (`GET http://host.docker.internal:8080/health` →
  `"armed": true`), (3) set generous `ulimits: nofile: {soft: 65536, hard:
  65536}` on the service as headroom, and (4) the compose file's
  `restart_policy: on-failure` already recovers the container
  automatically if it does crash.

---

## mavlink-router Self-Containment (pymavlink mode)

The pymavlink stack MUST be fully self-contained and buildable without any
sibling repository being checked out. Never set the `mavlink-router` service's
build `context` to a path outside `{{STACK_DIR}}` (for example, do NOT
reference `../../uav-mission-compute-sdk/infra/px4-sim/mavlink-router`) —
that path will not exist for a standalone `{{STACK_DIR}}` and `docker compose
up` fails with `unable to prepare context: path ... not found`.

Always copy both files into the generated stack and build from the local
directory:

```
{{STACK_DIR}}/mavlink-router/
├── Dockerfile     # builds mavlink-router from source (ubuntu:24.04 base)
└── main.conf      # routing config (may be stack-specific, see TELEMETRY.md)
```

```yaml
mavlink-router:
  build:
    context: ./mavlink-router
    dockerfile: Dockerfile
    args:
      http_proxy:  ${http_proxy:-}
      https_proxy: ${https_proxy:-}
      no_proxy:    ${no_proxy:-localhost,127.0.0.0/8}
      NO_PROXY:    ${NO_PROXY:-localhost,127.0.0.0/8}
  container_name: mavlink-router
  restart: unless-stopped
  volumes:
    - ./mavlink-router/main.conf:/etc/mavlink-router/main.conf
  networks:
    - app_network
```

The `Dockerfile` source (clones and builds `mavlink-router` from GitHub) can
be copied from any existing pymavlink stack's `mavlink-router/Dockerfile` in
this repo, or reused as-is:

```dockerfile
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG http_proxy
ARG https_proxy
ARG no_proxy
ENV http_proxy=${http_proxy} https_proxy=${https_proxy} no_proxy=${no_proxy}

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates build-essential pkg-config \
    libssl-dev meson ninja-build python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/mavlink-router/mavlink-router.git /src \
    && cd /src \
    && git submodule update --init --recursive \
    && meson setup build . -Dsystemdsystemunitdir=/usr/lib/systemd/system \
    && ninja -C build \
    && ninja -C build install \
    && rm -rf /src

ENV http_proxy= https_proxy= no_proxy=

COPY main.conf /etc/mavlink-router/main.conf

CMD ["mavlink-routerd", "-c", "/etc/mavlink-router/main.conf"]
```

The `main.conf` bind-mounted at runtime overrides the one baked in at build
time, so stack-specific routing (e.g. broadcast vs. point-to-point UDP
endpoints, see `references/TELEMETRY.md`) always takes effect.

---

## DLSPS Docker Compose Fragment

```yaml
dlstreamer-pipeline-server:
  build:
    context: .
    dockerfile_inline: |
      FROM ${DLSTREAMER_PIPELINE_SERVER_IMAGE}
      RUN pip install --no-cache-dir pymavlink    # pymavlink mode only
  image: ${DLSTREAMER_PIPELINE_SERVER_IMAGE}-pymavlink
  container_name: dlstreamer-pipeline-server
  environment:
    - http_proxy=${http_proxy}
    - https_proxy=${https_proxy}
    - no_proxy=${no_proxy},${HOST_IP}
    - NO_PROXY=${no_proxy},${HOST_IP}
    - ENABLE_RTSP=true
    - RTSP_PORT=8555
    - RUN_MODE=EVA
    - EMIT_SOURCE_AND_DESTINATION=true
    - REST_SERVER_PORT=8081
    - SERVICE_NAME=dlstreamer-pipeline-server
    - MQTT_HOST=broker
    - MQTT_PORT=1883
    - APPEND_PIPELINE_NAME_TO_PUBLISHER_TOPIC=true
    - ZE_ENABLE_ALT_DRIVERS=libze_intel_npu.so
  volumes:
    - dlstreamer-pipeline-server-pipeline-root:/var/cache/pipeline_root:uid=1999,gid=1999
    - "./resources:/home/pipeline-server/resources"
    - "./configs/config-pymavlink.json:/home/pipeline-server/config.json"
    - "./gvapython/telemetry-overlay-pymavlink.py:/home/pipeline-server/gvapython/telemetry-overlay-pymavlink.py"
    - "./scripts/mavlink_pipeline_manager.py:/home/pipeline-server/scripts/pipeline_manager.py"
    - "/run/udev:/run/udev:ro"
    - "/dev:/dev"
    - "/tmp:/tmp"
  group_add:
    - "44"    # video
    - "109"   # render (adjust per host: stat -c %g /dev/dri/render*)
    - "110"
    - "990"
    - "992"
    - "993"
    - "994"
    - "996"
  device_cgroup_rules:
    - "c 189:* rmw"
    - "c 209:* rmw"
    - "a 189:* rwm"
  devices:
    - "/dev:/dev"
  ports:
    - '8081:8081'
    - "8555:8555"
  networks:
    - app_network
  extra_hosts:
    - "host.docker.internal:host-gateway"
```

**For UAVSDK mode** mount the UAVSDK overlay and manager instead:
```yaml
    - "./gvapython/telemetry-overlay-uavsdk.py:/home/pipeline-server/gvapython/telemetry-overlay-uavsdk.py"
    - "./scripts/uavsdk_pipeline_manager.py:/home/pipeline-server/scripts/pipeline_manager.py"
```
And set `UAV_ID` env var (default `uav-1`).

---

## .env Variables

```bash
# Host network
HOST_IP=192.168.1.x           # LAN IP — NOT 127.0.0.1; used for RTSP URLs

# DL Streamer image
DLSTREAMER_PIPELINE_SERVER_IMAGE=intel/dlstreamer-pipeline-server:2026.1.0-ubuntu24

# Proxy
# http_proxy=
# https_proxy=
# no_proxy=localhost,127.0.0.0/8
```

---

## Makefile Targets

```makefile
.PHONY: init model pymav-up pymav-down uavsdk-up uavsdk-down start-rtsp

init:        ## Create .env from .env.example and auto-detect GPU/NPU device paths
model:       ## Download and export YOLOv8n-VisDrone to OpenVINO FP16
pymav-up:    ## Start pymavlink stack (docker-compose-pymavlink.yml)
pymav-down:  ## Stop pymavlink stack
uavsdk-up:   ## Start UAVSDK stack (requires uav-mission-compute-sdk running first)
uavsdk-down: ## Stop UAVSDK stack
start-rtsp:  ## Launch pipeline_manager.py --sink rtsp inside container
```

Full Makefile is in `uav-vision-analytics/Makefile`.

---

## Network Architecture

### pymavlink

```
PX4 SITL ──MAVLink──▶ mavlink-router (:14550 server → :14541 broadcast)
                                           │
                           DLSPS ◀─UDP :14541─┘
                             │
                        ┌────┤
                        │    └──▶ RTSP :8555 → QGC / ffplay rtsp://...
                        │
                    MQTT :1883 ──▶ Mosquitto broker
```

### UAVSDK

```
uav-mission-compute-sdk:
  PX4+Gazebo → companion-bridge → MQTT broker (:1884)
                               → RTSP server (:8554) [camera streams]

DLSPS container:
  MQTT subscriber → on ARMED → POST pipelines
  rtspsrc ← RTSP (:8554) [nadir/forward/rear]
  appsink → RTSP output :8555
```

---

## Device Group IDs

The `group_add` list must include the numeric GIDs for `/dev/dri` (GPU) and
`/dev/accel` (NPU). Check on the host:

```bash
stat -c %g /dev/dri/render*
stat -c %g /dev/accel/accel*
```

Update the `group_add` list in the compose file accordingly.

---

## Volumes

```yaml
volumes:
  dlstreamer-pipeline-server-pipeline-root:
    driver: local
    driver_opts:
      type: tmpfs
      device: tmpfs
```

The pipeline root is a tmpfs (in-memory) volume, reset on every container
recreation. Always use `docker compose up -d --force-recreate` (not `restart`)
when changing `config.json` — plain `restart` keeps the stale tmpfs.
