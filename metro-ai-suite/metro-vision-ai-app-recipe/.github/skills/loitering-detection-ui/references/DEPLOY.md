<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Deployment

The console is deployed as a self-contained addon. **No file belonging to the
application is created, edited or replaced.**

## 1. Prerequisite

The application must already be running from its released configuration:

```bash
cd <recipe-root>
./install.sh <app-name> <HOST_IP>
docker compose up -d
docker compose ps           # pipeline server, mediamtx, coturn, broker, nginx healthy
```

Confirm the application is unmodified before proceeding:

```bash
git status --porcelain      # only .env, which install.sh writes, may appear
```

If any application file is modified, restore it (`git checkout -- <path>`) before
deploying. The console does not require any such change.

## 2. Addon directory

All generated artefacts live in one directory outside the application tree:

```
{{ADDON_DIR}}/
├── compose.console.yml
├── .env
└── console/{Dockerfile,requirements.txt,entrypoint.sh,app.py,templates/,static/}
```

Removing this directory and the console container removes the addon completely.

## 3. Network discovery

The console joins the application's existing Docker network as an external
network. Discover its name rather than assuming it:

```bash
docker network ls --format '{{.Name}}' | grep app_network
```

The name is the compose project name followed by `_app_network`. Record it as
`APP_NETWORK` in the addon `.env`.

## 4. Compose file

```yaml
services:
  console:
    build: ./console
    image: metro-mission-console:latest
    container_name: mission-console
    restart: unless-stopped
    ports:
      - "${CONSOLE_PORT}:${CONSOLE_PORT}"
    environment:
      - http_proxy=${http_proxy}
      - https_proxy=${https_proxy}
      - no_proxy=${no_proxy},${HOST_IP},dlstreamer-pipeline-server,broker,prometheus,mediamtx-server
      - NO_PROXY=${no_proxy},${HOST_IP},dlstreamer-pipeline-server,broker,prometheus,mediamtx-server
      - PIPELINE_SERVER_URL=http://dlstreamer-pipeline-server:8080
      - PROMETHEUS_URL=http://prometheus:9090/prometheus
      - MEDIAMTX_URL=http://mediamtx-server:8889
      - MQTT_HOST=broker
      - MQTT_PORT=1883
      - MODEL_ROOT=/home/pipeline-server/models
      - DETECTIONS_TOPIC_PREFIX=${DETECTIONS_TOPIC_PREFIX}
      - LOITER_THRESHOLD_S=${LOITER_THRESHOLD_S}
      - DEFAULT_ZONE=${DEFAULT_ZONE}
      - SOURCES_JSON=${SOURCES_JSON}
      - DEVICES=${DEVICES}
      - UI_PORT=${CONSOLE_PORT}
    volumes:
      - "${MODEL_STORE}:/home/pipeline-server/models:ro"
    networks:
      - app_network

networks:
  app_network:
    external: true
    name: ${APP_NETWORK}
```

Requirements:

- The model store MUST be mounted at the same path the pipeline server uses, so
  that discovered paths are valid in a start request without translation.
- The mount MUST be read-only.
- Every container hostname MUST appear literally in `no_proxy` and `NO_PROXY`.
- The service MUST NOT declare `depends_on` against the application's services;
  they belong to a different compose project.
- `DEVICES` MUST be determined on the host at deployment time, for example
  `CPU` plus `GPU` when `/dev/dri` exists and `NPU` when `/dev/accel` exists, and
  recorded in the addon `.env`. The console cannot determine this itself because
  it does not map the device nodes.

## 5. Bring-up

```bash
cd {{ADDON_DIR}}
docker compose -f compose.console.yml build console
docker compose -f compose.console.yml up -d console
docker compose -f compose.console.yml ps
```

The console is then reachable at `https://<HOST_IP>:<CONSOLE_PORT>/` (default
port `9443`), which serves the document titled `Mission Console`.

The console is **not** published under a path on the application's reverse proxy.
Because the skill makes no modification to `nginx.conf`, the application's proxy
has no `/console/` route; requesting `https://<HOST_IP>/console/` is matched by the
proxy's default `location /` and returns the application's own landing page
(`Metro Vision AI App - Loitering Detection`). Observing that page is the expected
result of using the wrong URL, not a deployment fault. Confirm the endpoint with:

```
curl -ks https://<HOST_IP>:<CONSOLE_PORT>/ | grep -o '<title>.*</title>'
# <title>Mission Console</title>
```

The
certificate is self-signed and generated at first start; browsers prompt once.
Supply a certificate by placing `console.crt` and `console.key` in
`{{ADDON_DIR}}/console/certs/` before building.

The application's own entry point is unaffected and remains on port 443.

## 6. Verification

```bash
{{SKILL_DIR}}/acceptance/verify.sh https://<HOST_IP>:<CONSOLE_PORT> {{ADDON_DIR}}/console --live
```

The gate additionally asserts that the application's tracked files are clean, so
a deployment that modified the application fails regardless of whether the
dashboard works.

## 7. Removal

```bash
cd {{ADDON_DIR}} && docker compose -f compose.console.yml down
rm -rf {{ADDON_DIR}}
```

Nothing remains. No application file was changed, so no restoration is required.

## 8. Adding a model for comparison

Comparison operates between any two models the deployment provides. To add one,
place its OpenVINO intermediate representation in the model store and refresh the
catalogue:

```bash
DEST=<model-store>/<vendor>/<model-name>/<PRECISION>
mkdir -p "$DEST"
cp /path/to/model.xml /path/to/model.bin "$DEST/"
# optional: a model-proc document alongside, named after the model
```

Then use the refresh control in the interface, or
`curl -k https://<HOST_IP>:<CONSOLE_PORT>/api/models?refresh=1`.

The console does not require the model to be of any particular family. A
model-proc document is used when present and omitted when absent, because modern
intermediate representations describe their output in `rt_info`.

`scripts/add-model.sh` performs the copy and the refresh for an arbitrary model.


---

## 7. Preparing a model for accelerator use

An OpenVINO IR exported with dynamic spatial dimensions (input shape
`?,3,?,?`) cannot be used on the GPU or NPU, and yields no detections on the
CPU. The console reports such a model as `dynamic-spatial` in
`GET /api/models`.

To make it usable, reshape it to a fixed input size:

```bash
.github/skills/loitering-detection-ui/scripts/prepare-model.sh \
    <model-store>/<model>/<model>.xml 640 640
```

This writes `<model>_static/` beside the original and copies any model-proc
sidecar. Re-scan the model store from the console to pick it up; both variants
remain listed and are distinguished by their containing directory.

Where the source checkpoint is available, exporting with a fixed input size is
preferable to reshaping. Pin the exporter version known to work with your
target devices: some exporter releases emit detection heads containing
operations the GPU and NPU plugins do not support, irrespective of input shape.

Verified on this stack after preparation: CPU 22.4 fps, GPU 29.8 fps,
NPU 30.0 fps, with no inference errors logged by the pipeline server.
