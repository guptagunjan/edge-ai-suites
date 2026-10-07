<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Runtime Reference

Operational reference for a deployed console. The authoritative definitions are
in `BACKEND-SPEC.md` and `FRONTEND-SPEC.md`.

## Access

```
https://<HOST_IP>:<CONSOLE_PORT>/
```

The console serves its own TLS with a self-signed certificate generated at first
start. The application's own interface remains on its usual port and is not
affected.

## Generated files

```
{{ADDON_DIR}}/
├── compose.console.yml
├── .env
└── console/{Dockerfile,entrypoint.sh,requirements.txt,app.py,templates/,static/}
```

None of these is an application file. Removing the directory and the container
removes the addon entirely.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `PIPELINE_SERVER_URL` | `http://dlstreamer-pipeline-server:8080` | Pipeline control |
| `MEDIAMTX_URL` | `http://mediamtx-server:8889` | WHEP signalling origin |
| `MQTT_HOST` / `MQTT_PORT` | `broker` / `1883` | Detection metadata |
| `PROMETHEUS_URL` | `http://prometheus:9090/prometheus` | Utilisation, optional |
| `MODEL_ROOT` | `/home/pipeline-server/models` | Model store, read-only |
| `SOURCES_JSON` | deployment sources | Source catalogue |
| `DETECTIONS_TOPIC_PREFIX` | `object_tracking` | MQTT topic prefix |
| `DEFAULT_ZONE` | `0,200,300,400` | Zone `x,y,w,h` in source pixels |
| `LOITER_THRESHOLD_S` | `5.0` | Dwell at which loitering is reported |
| `ZONE_VACANT_GRACE_S` | `3.0` | Vacancy before the zone entry is cleared |
| `TRACK_TTL_S` | `30.0` | Retention of an unseen track |
| `UI_PORT` | `9443` | HTTPS listen port |

## Endpoints

| Path | Method | Body | Result |
|---|---|---|---|
| `/api/config` | GET | — | Sources, devices with availability, defaults |
| `/api/models` | GET | `?refresh=1` | Discovered models; never a hardcoded list |
| `/api/pipelines` | GET | — | Pipelines and instance status |
| `/api/pipelines/start` | POST | `{source, model, device}` | `{peer_id, instance_id, whep_url, topic}` |
| `/api/pipelines/stop` | POST | `{peer_id}` | `{status:"stopped"}` |
| `/api/zone` | POST | `{peer_id, zone}` | `{peer_id, zone}`; applies immediately |
| `/api/events` | GET | — | Per stream: FPS, dwell, loiter and object counts |
| `/api/metrics` | GET | — | Per device utilisation including GPU engines |
| `/api/health` | GET | — | Dependency reachability |
| `/whep/<peer_id>` | OPTIONS/POST/DELETE | SDP | WHEP proxy to MediaMTX |

There is no endpoint that restarts a pipeline to change a zone. The zone is an
analytic region evaluated by the console.

## Pipeline request

The console supplies the released `detection-properties` parameter:

```json
"parameters": { "detection-properties": {
  "model": "<discovered path>", "model_proc": "<when present>",
  "device": "CPU|GPU|NPU", "model-instance-id": "console-<hash>" } }
```

`model-instance-id` is derived from the model path and device. Omitting it, or
reusing the identifier pinned by the released configuration, binds the request to
a previously loaded network and is the usual cause of a GPU or NPU pipeline
failing after a model change.

## Zone behaviour

- The zone is `x,y,w,h` in source pixels, set numerically or by drawing on a panel.
- Drawing converts screen coordinates using the intrinsic video size and the
  letterbox offsets implied by `object-fit: contain`.
- Applying is immediate; the video is not interrupted.

## Dwell reporting

Dwell is measured on the frame timestamp carried in the metadata and against zone
occupancy, so it survives tracker identifier reassignment and agrees with the
value shown by the application's own dashboard. The figure presented is the
greater of the zone dwell and the longest per-track dwell.

## Diagnostics

| Symptom | Check |
|---|---|
| Empty model selector | Is the model store mounted, and does it contain an `.xml` with a sibling `.bin`? |
| Video never starts, telemetry updates | ICE discovery; confirm the WHEP `OPTIONS` response carries `Link` headers and that Coturn is reachable |
| GPU gauge reads zero under load | Confirm the compute-engine series is present in Prometheus |
| Dwell lower than the application dashboard | Confirm a frame timestamp is present; `/api/events` reports `frame_time_source` |
| GPU or NPU fails after a model change | Confirm a derived `model-instance-id` is supplied on every request |
| All API calls time out | Confirm every container hostname appears literally in `no_proxy` and `NO_PROXY` |
