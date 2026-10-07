<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Backend Specification — `console/app.py`

A single Flask application. It performs no inference and hosts no media. Every
clause marked MUST is asserted by `acceptance/verify.sh`.

## 0. Module layout

The backend is generated as six modules, each within the line budget in
`BUILD.md` 1.3. A single file is not permitted: a monolithic backend has been
truncated mid-write by the model output token limit, losing the whole file.

| Module | Sections implemented |
|---|---|
| `app.py` | §1 environment and configuration, Flask application, blueprint registration, TLS entrypoint |
| `catalog.py` | §2 discovery, §3 sources and pipeline selection, §13 preflight, §14 identifier uniqueness |
| `analytics.py` | §5 ingestion helpers, §6 dwell and zone, §11 frame-time units |
| `ingest.py` | §5 MQTT subscription, §6.1 reconciliation |
| `metrics.py` | §7 utilisation |
| `api.py` | §4 routes and WHEP proxy, §6.2 health, §8 endpoints, §12 zone at start |

Shared mutable state (the session table and its lock) is owned by `app.py` and
imported by the other modules. No module may import another in a cycle.

## 1. Configuration

Read from the environment, with the defaults shown.

Device availability MUST be taken from `DEVICES`. The console container does not
have the accelerator device nodes mapped, so probing its own filesystem reports
GPU and NPU as absent on every host. The deployment determines availability on
the host and passes it in; a local probe is retained only as a fallback.

| Variable | Default | Purpose |
|---|---|---|
| `PIPELINE_SERVER_URL` | `http://dlstreamer-pipeline-server:8080` | Pipeline control |
| `MQTT_HOST` / `MQTT_PORT` | `broker` / `1883` | Detection metadata |
| `PROMETHEUS_URL` | `http://prometheus:9090/prometheus` | Utilisation, optional |
| `MEDIAMTX_URL` | `http://mediamtx-server:8889` | WHEP signalling origin |
| `MODEL_ROOT` | `/home/pipeline-server/models` | Model store, mounted read-only |
| `SOURCES_JSON` | deployment sources | Source catalogue |
| `DETECTIONS_TOPIC_PREFIX` | `object_tracking` | MQTT topic prefix |
| `DEFAULT_ZONE` | `0,200,300,400` | Zone `x,y,w,h` in source pixels |
| `LOITER_THRESHOLD_S` | `5.0` | Dwell at which loitering is reported |
| `ZONE_VACANT_GRACE_S` | `3.0` | Continuous vacancy before zone entry is cleared |
| `TRACK_TTL_S` | `30.0` | Retention of an unseen track |
| `DEVICES` | probe | Comma-separated devices present on the HOST, e.g. `CPU,GPU,NPU` |
| `UI_PORT` | `9443` | HTTPS listen port |
| `TLS_CERT` / `TLS_KEY` | `/app/certs/console.crt` / `.key` | Certificate paths |

The application MUST start when Prometheus, MediaMTX or the broker are
unreachable, reporting degraded values rather than failing.

## 2. Transport

The application MUST serve HTTPS directly, using the certificate at `TLS_CERT`
and `TLS_KEY`, which `entrypoint.sh` generates as a self-signed certificate when
absent. A secure origin is required because browsers restrict
`RTCPeerConnection` to secure contexts.

The application MUST NOT depend on any reverse proxy. It MUST nonetheless remain
correct when mounted under a path prefix, which is satisfied by the relative
references and base-href injector defined in `LAYOUT.md`.

## 3. Endpoints

| Method and path | Behaviour |
|---|---|
| `GET /` | Renders `index.html` |
| `GET /api/config` | Sources, devices with availability, default zone, loiter threshold, topic prefix |
| `GET /api/models[?refresh=1]` | `{"models":[...],"discovered":true}` from the model store (`PIPELINE.md` §6) |
| `GET /api/pipelines` | Pipelines and instance status from the pipeline server |
| `POST /api/pipelines/start` | Starts one panel; returns `instance_id`, `peer_id`, `whep_url`, `topic` |
| `POST /api/pipelines/stop` | Stops one instance |
| `POST /api/zone` | Updates the analytic zone for a stream; applies immediately |
| `GET /api/events` | Per-stream FPS, dwell, loiter and object counts |
| `GET /api/metrics` | Per-device utilisation |
| `GET /api/health` | Liveness and dependency reachability |
| `OPTIONS,GET,POST,PATCH,DELETE /whep/<peer_id>` | WHEP signalling proxy (§4) |
| `OPTIONS,GET,POST,PATCH,DELETE /whep/<peer_id>/<session>` | WHEP session resource proxy (§4) |
| `GET /api/stream/ready/<peer_id>` | Reports whether the media server serves the path yet (§4.1) |

There MUST NOT be a pipeline-restart endpoint for zone changes. The zone is
evaluated in software and applies without touching the pipeline.

### 3.1 Start

Construct the request per `PIPELINE.md` §2. Generate a unique `peer_id` per panel.
Derive `model-instance-id` from the model path and device as required by
`PIPELINE.md` §2.1; this MUST be present on every request. Record the stream in a
session table keyed by `peer_id`, holding the instance identifier, topic, model,
device and the zone in force.

`whep_url` returned to the client MUST be the console's own proxy path
(`whep/<peer_id>`), relative, never the MediaMTX address.

## 4. WHEP proxy

Proxy `/whep/<peer_id>` to `{MEDIAMTX_URL}/<peer_id>/whep`, preserving method,
body and content type.

The proxy MUST forward the upstream `Link` response headers verbatim, and MUST
expose them by setting `Access-Control-Expose-Headers: Link, Location`. Those
headers carry the ICE server list, without which the browser gathers only host
candidates and video never starts from a remote machine.

`OPTIONS` MUST be proxied rather than answered locally, because the ICE server
list is discovered by that method.

### 4.1 Session resource (required)

On a successful offer the media server answers with a `Location` header naming
the session resource used for ICE trickle (`PATCH`) and teardown (`DELETE`),
typically `/<peer_id>/whep/<session>`. That path does not exist on the console
origin, so a client that resolves it against the page requests a route the
console does not serve and receives **404**, which the panel reports as a
rejected signalling exchange.

The console MUST therefore:

1. Expose a second route, `/whep/<peer_id>/<session>`, proxying to
   `{MEDIAMTX_URL}/<peer_id>/whep/<session>`.
2. Rewrite `Location` onto that route, **preserving the session identifier** —
   take the segment following `/whep/` and emit `whep/<peer_id>/<session>`.
   Rewriting to `whep/<peer_id>` discards the session and every subsequent
   request fails.

### 4.2 Readiness

A pipeline needs a short interval after launch before it publishes, and the
media server answers 404 for a path that does not yet exist. `GET
/api/stream/ready/<peer_id>` MUST issue `OPTIONS` upstream and report
`{"ready": <bool>, "status": <int>}` so the client can distinguish "not
published yet" from a genuine failure.

## 5. Metadata ingestion

Subscribe with a wildcard and filter in the client by prefix. The topic published
by the deployment contains no path separator, so a hierarchical wildcard does not
match it; subscribing to `<prefix>_#` receives nothing. Subscribe to `#` and
accept topics beginning with `<DETECTIONS_TOPIC_PREFIX>`.

Detections are nested. Read the object list from `metadata.objects` when present
and from a top-level `objects` otherwise; an implementation that reads only the
top level receives nothing in the deployment's operating mode.

Each object contributes a track identifier and a bounding box. Detections carry
pixel coordinates directly on the object as `x`, `y`, `w`, `h`; read those first
and accept a normalised box under `detection.bounding_box` as a fallback,
converting with the frame dimensions carried in the metadata.

### 5.1 Frame time

Dwell MUST be measured on frame time, not arrival time. Take the first available
of `metadata.timestamp`, `metadata.time` or a top-level `timestamp`, and
normalise: values above `1e12` are nanoseconds, above `1e9` are microseconds or
milliseconds by magnitude, otherwise seconds. Fall back to wall-clock only when no
timestamp is present, and record that fact in the stream state.

The time base MUST be locked per stream. `metadata.timestamp` is a presentation
timestamp measured from the start of the stream, whereas `metadata.time` is an
epoch value; both are nanoseconds and both occur in the feed. Selecting whichever
key happens to be present subtracts an epoch from a presentation timestamp
whenever the feed alternates, producing dwell figures near `-1.79e9` seconds. The
console MUST record the key observed for the first message of a stream, use only
that key thereafter, and reuse the previous reading when a message omits it.

## 6. Zone and dwell analytics

The zone is a rectangle in source pixels held per stream, initialised from
`DEFAULT_ZONE` and replaced by `POST /api/zone`. A detection is inside the zone
when the centre of its bounding box lies within the rectangle.

Maintain per stream:

- `zone_entry_ts` — set to the current frame time when occupancy transitions from
  zero to non-zero, and cleared only after the zone has been continuously vacant
  for `ZONE_VACANT_GRACE_S`. Brief vacancy MUST NOT reset it.
- `tracks` — for each identifier inside the zone, the first and last frame time
  observed. A track is evicted when unseen for `TRACK_TTL_S`. Eviction MUST NOT
  be tied to the reporting interval.
- `msg_times` — a bounded deque of arrival times used to derive FPS.

Derived values:

```
zone_dwell_s  = last_frame_ts - zone_entry_ts            (0 when vacant)
track_dwell_s = last_seen - first_seen                   (per track)
max_dwell_s   = max(zone_dwell_s, max(track_dwell_s))
avg_dwell_s   = mean(track_dwell_s) over tracks in the zone
loiter_count  = count of tracks with track_dwell_s >= LOITER_THRESHOLD_S
object_count  = tracks currently inside the zone
fps           = len(msg_times) / elapsed window
```

`max_dwell_s` is the figure presented as dwell time. Measuring dwell per track
alone under-reports, because the short-term tracker reassigns identifiers after a
brief occlusion and each reassignment restarts the measurement; zone occupancy
survives reassignment and matches the application's own dashboard.

`GET /api/events` returns, per stream: `peer_id`, `topic`, `model`, `device`,
`fps`, `max_dwell_s`, `avg_dwell_s`, `zone_dwell_s`, `loiter_count`,
`object_count`, `zone`, and `frame_time_source` (`frame` or `wallclock`).

### 6.1 Session reconciliation

`GET /api/events` MUST reconcile sessions against `GET /pipelines/status` before
answering, and MUST drop any session whose instance is no longer `RUNNING` or
`QUEUED`. A pipeline that reaches the end of its media, or aborts, stops
publishing; the session would otherwise persist and the panel would display a
frozen reading that is indistinguishable from a live stream of an idle scene.

### 6.2 Stream health

Each stream in the payload MUST carry `state` (the pipeline state) and
`detection_state`, where `detection_state` is `ok` when tracks are present,
`no-detections` when frames arrive but nothing is tracked, and `no-data` when no
frames arrive. Zeros alone do not distinguish a model that yields nothing from a
scene with no activity.

## 7. Utilisation

Query Prometheus and return per device. Every field is nullable; the endpoint MUST
return success even when Prometheus is unreachable.

Series names differ between the exporters that may be deployed (`qmmd`,
OpenTelemetry host metrics, telegraf). Only the GPU series are consistently
published under the `qmmd_` prefix; CPU, NPU and system-memory series are not.
Binding a field to a single expression therefore renders those gauges as `n/a` on
a host whose exporter uses different names.

Each field MUST therefore be defined as an **ordered list of candidate
expressions**, evaluated in order, the first returning a sample being used. At
minimum the candidates MUST cover, per field:

| Field | Candidates (in order) |
|---|---|
| `cpu.percent` | `avg(qmmd_cpu_utilization_ratio)*100`, `avg(cpu_usage_percentage)`, `100-avg(cpu_usage_idle)` |
| `cpu.freq_mhz` | `avg(qmmd_cpu_frequency_hertz)/1000000`, `avg(cpu_frequency_avg_frequency)/1000` |
| `gpu.freq_mhz` | `max(qmmd_gpu_actual_frequency_hertz)/1000000`, `max(gpu_frequency)` |
| `npu.percent` | `max(qmmd_npu_utilization_ratio)*100`, `avg(npu_utilization)` |
| `npu.mem_used_bytes` | `max(qmmd_npu_memory_used_bytes)`, `max(npu_memory_mb)*1000000` |
| `npu.power_w` | `max(qmmd_npu_power_watts)`, `max(npu_power)` |
| `mem.percent` | `avg(qmmd_memory_utilization_ratio)*100`, `avg(mem_used_percent)` |
| `mem.used_bytes` / `mem.total_bytes` | `max(qmmd_memory_used_bytes)` / `max(mem_used)`, `max(qmmd_memory_total_bytes)` / `max(mem_total)` |

Power counters occasionally emit an out-of-range sample. A power reading below
zero or above 2000 W is a counter artefact and MUST be reported as unavailable
rather than rendered as a plausible figure.

| Field | Source |
|---|---|
| `cpu.percent`, `cpu.freq_mhz` | CPU utilisation ratio and frequency series |
| `gpu.percent` | **maximum over devices of the compute-engine utilisation ratio**, scaled to a percentage |
| `gpu.engines` | per-engine ratios keyed by engine name, including render, compute, video and copy engines as published |
| `gpu.mem_used_bytes`, `gpu.mem_total_bytes`, `gpu.freq_mhz`, `gpu.power_w` | GPU memory, frequency and power series |
| `npu.percent`, `npu.mem_*`, `npu.power_w` | NPU series |
| `mem.percent`, `mem.used_bytes`, `mem.total_bytes` | System memory |

GPU utilisation MUST be taken from the compute-engine series. Averaging across all
engines dilutes the signal because most engines are idle during inference, and the
legacy aggregate series reports zero on supported builds; either error presents as
a GPU gauge that never leaves zero while inference is demonstrably running. Retain
the legacy series only as a fallback when the engine series is absent.

## 8. Discovery

Implement `PIPELINE.md` §6. Cache for approximately thirty seconds; `refresh=1`
forces a rescan. When the store yields nothing, return an empty list and an
explanatory field rather than an error, and let the interface report that no model
is installed. Do not substitute a hardcoded model.

## 9. Failure handling

- Upstream errors are returned as a JSON `error` field with the upstream status.
- No endpoint returns a server error for an unreachable optional dependency.
- All outbound calls carry a timeout; none blocks a request indefinitely.
- MQTT reconnects with backoff, and `/api/health` reports the connection state.


---

## 11. Frame time units (supersedes any magnitude heuristic)

Dwell is derived from frame time, so an incorrect unit scales every dwell
figure. Units MUST be resolved from the **key**, never from the magnitude of
the value.

| Key | Unit | Conversion |
|---|---|---|
| `metadata.timestamp` | GStreamer PTS, nanoseconds | `v / 1e9` |
| `metadata.time` | epoch, nanoseconds | `v / 1e9` |
| `timestamp` (top level) | epoch seconds | `v` |

A magnitude heuristic is **forbidden**. A presentation timestamp for a short
clip (19.6 s = 1.96e10 ns) falls in the same numeric range as a microsecond
value, and classifying it as microseconds inflates reported dwell by 1000x
(observed: `19619.62 s` for a true `19.62 s`).

The resolved key MUST be locked on the first message of a stream. If a later
message omits the locked key, the implementation MUST hold the previous frame
time rather than fall back to a different key on another time base.

## 12. Zone at pipeline start

`POST /api/pipelines/start` MUST accept an optional `zone` field (`"x,y,w,h"`)
and use it as the initial zone for that stream. When absent or malformed the
configured default applies.

The server MUST NOT unconditionally assign the default zone at start;
doing so causes every stream to evaluate dwell against the default rectangle
regardless of operator input, while the interface displays the requested zone.

## 13. Model compatibility preflight

`GET /api/models` MUST report, for every discovered IR:

| Field | Meaning |
|---|---|
| `compatibility` | `ok` \| `dynamic-spatial` \| `unknown` |
| `input_shape` | input dims as a list, `-1` for dynamic |
| `compatibility_detail` | remediation text when not `ok` |

Classification is by reading the first `Parameter` layer of the IR XML. If any
spatial dimension (index 2 or 3) is dynamic, the model is `dynamic-spatial`:
the GPU and NPU plugins reject such an IR, and on CPU the pipeline decodes at
full frame rate while producing **no detections**. Reporting this is required
so the condition is not mistaken for a dashboard fault.

Classification MUST be generic IR introspection. No model family may be
named or special-cased.

## 14. Model identifier uniqueness

Two IRs in sibling directories may share a file name (for example an original
export and a prepared variant). The generated identifier MUST therefore be
qualified with the containing directory when that directory differs from the
model file name, so one model cannot silently displace another during
deduplication.


## 15. Zone notation: rectangle or polygon

`_parse_zone` MUST accept both notations, in source-image pixels:

| Notation  | Example                                   |
|-----------|-------------------------------------------|
| rectangle | `100,300,400,500`                          |
| polygon   | `(120,100) (900,120) (860,600) (100,560)`  |

Parentheses, commas and whitespace are interchangeable separators; the parser
MUST read the numeric sequence and branch on its length (4 = rectangle,
>= 6 and even = polygon).

The returned object MUST always carry `x`, `y`, `w`, `h` — the axis-aligned
bounding box — so that every existing consumer keeps working, plus `points`
(the vertex list, or `null` for a rectangle).

Containment MUST use ray casting when `points` is present and a bounds test
otherwise. A rectangle is therefore a special case of a polygon, not a
separate code path.

Rationale: the application's Node-RED flow stores each region as four
vertices (`vertex1`..`vertex4`, each `{x, y}`) and evaluates containment by
intersection-over-region. Accepting vertices keeps the console's zone
notation expressible in the same terms as the application's own, so a region
can be moved between the two without being reshaped.

## 16. Zone changes apply to every live stream

`POST /api/zone` MUST apply the zone to **all** live streams when the request
body omits `peer_id`, and MUST return `{"zone", "updated", "count"}`.

When two models are being compared the comparison is only meaningful if both
are judged against the same region, so the interface MUST NOT offer a way to
leave one panel on a stale zone.

On application the server MUST clear `zone_entry_ts`, `zone_vacant_since`
and the track table for each affected stream, so dwell is measured against
the new region from that moment rather than inheriting entry times earned
under the previous one.

## 17. Per-object loiter table

Each entry of `/api/events` `streams[]` MUST carry `objects`: one row per
tracked object currently inside the zone, ordered by descending dwell.

| Field        | Meaning                                              |
|--------------|------------------------------------------------------|
| `id`         | tracker identifier                                    |
| `label`      | class label (see below)                               |
| `status`     | `Loitering` once dwell >= `LOITER_THRESHOLD_S`, else `Present` |
| `entry_time` | wall-clock time the object entered the zone, `HH:MM:SS` |
| `dwell_hms`  | dwell formatted `HH:MM:SS`                            |
| `dwell_s`    | dwell in seconds                                      |

These mirror the columns of the application's own loiter table
(`ID`, `Type`, `Status`, `Entry Time`, `Dwell Time`, `Dwell Time Seconds`),
so the two views can be read against each other without translation.

Rows MUST be withheld once their track has not been refreshed within
`TABLE_STALE_S` (default 10 s). This mirrors `stale_track_timeout_s` in the
application's Node-RED flow: without it a track that disappears is carried
forward indefinitely and the table shows stale rows.

Label resolution MUST try, in order: `label`, `roi_type`, `type`, `class`,
`class_name`; then the same keys inside `detection`; then `detection.label_id`
rendered as `class <n>`; then `region <n>`. Some pipelines publish geometry
only — `detection` containing just `bounding_box` — in which case no class
name exists to display and the fallback is correct behaviour, not a defect.
Attach a model-proc carrying a label list to obtain true class names.
