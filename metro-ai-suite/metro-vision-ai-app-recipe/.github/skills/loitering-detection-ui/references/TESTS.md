<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Verification

## The gate

`acceptance/verify.sh` is the completion criterion. A deployment is not complete
until it exits zero.

```bash
acceptance/verify.sh https://<HOST_IP>:<CONSOLE_PORT> {{ADDON_DIR}}/console \
    --app-dir {{APP_DIR}} --live
```

| Group | Asserts |
|---|---|
| 1 Application untouched | No tracked application file is modified; the pipeline, proxy and flow configurations are clean; the generated console is outside the application source tree |
| 2 Markup | Base-href injector, relative asset references, every required element identifier, all four gauges |
| 3 Design tokens | Every locked token present and unchanged; the rail and stage grid follows the token; the stylesheet is served as `text/css` |
| 4 WebRTC | `OPTIONS` ICE discovery, `rel=ice-server` parsing, `iceServers` supplied to the peer connection |
| 5 Frontend paths | No root-absolute API request; the zone is applied through `api/zone` and never by restarting a pipeline |
| 6 Backend | Prefix-filtered MQTT subscription, nested metadata read, compute-engine GPU series, model-instance identity, zone-occupancy dwell with grace period and track time-to-live, `Link` header forwarding, own TLS, parses |
| 7 Model agnosticism | No detection-model name appears anywhere in the generated console |
| 8 API | `/api/config`, `/api/models` with at least one discovered model, `/api/metrics` with the GPU engine breakdown, `/api/events` |
| 9 Live | Start, telemetry, zone change without restart, and stop, on every available device |

Do not weaken an assertion to make a deployment pass, and do not modify an
application file to satisfy one.

## Extending the gate

When a visible element or a behaviour is added, extend the specification and the
gate together. An assertion that is not present is a property that will drift on
the next machine.

## Optional regression suite

A `pytest` suite may be generated alongside the console for continuous use. It
covers the same properties at a finer granularity.

| Module | Covers |
|---|---|
| `test_app_untouched.py` | The application repository is clean; no pipeline, proxy or flow file differs from the release |
| `test_discovery.py` | Only models present in the store are offered; an `.xml` without a sibling `.bin` is ignored; `refresh=1` observes an addition; no model name is hardcoded |
| `test_pipeline_request.py` | `model-instance-id` is derived and differs across model and device combinations; `model_proc` is omitted when absent |
| `test_zone.py` | A zone change alters analytics without a new instance identifier; a degenerate rectangle is rejected |
| `test_dwell.py` | Dwell uses the frame timestamp; zone dwell survives a tracker identifier change; the vacancy grace period is honoured; a track is retained for its time-to-live |
| `test_metrics.py` | Per-device shape; GPU headline follows the compute engine; a null is reported as null rather than zero; an absent Prometheus yields success with null fields |
| `test_whep_proxy.py` | `OPTIONS` is proxied and `Link` headers are forwarded and exposed |
| `test_devices.py` | Only available devices are offered; a start succeeds on each |

Run with `pytest -q tests/console/`. The suite supplements the gate; it does not
replace it.
