<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Pipeline Interface

This document defines how the console drives the deployed DL Streamer Pipeline
Server. **No change is made to the application's pipeline configuration.**

## 1. Released capability

Each device pipeline in the released `config.json` declares a
`detection-properties` parameter bound to the `gvadetect` element:

```json
"parameters": { "type": "object", "properties": {
  "detection-properties": { "element": { "name": "detection", "format": "element-properties" } } } }
```

`element-properties` permits any property of that element to be supplied per
request. The console uses `model`, `model_proc`, `device` and
`model-instance-id`. Nothing further is required, and `config.json` MUST NOT be
edited.

Verify before generating:

```bash
python3 -c "import json;c=json.load(open('src/dlstreamer-pipeline-server/config.json'));\
print([p['name'] for p in c['config']['pipelines']])"
grep -c detection-properties src/dlstreamer-pipeline-server/config.json   # expect one per pipeline
```

If `detection-properties` is absent, the deployment is not supported by this
skill. Report the incompatibility; do not modify the file.

## 2. Start request

```
POST {PIPELINE_SERVER_URL}/pipelines/{pipeline_name}/{version}
```

```json
{
  "source": { "uri": "<source uri>", "type": "uri" },
  "destination": {
    "metadata": { "type": "mqtt", "host": "broker", "port": 1883,
                  "topic": "<DETECTIONS_TOPIC_PREFIX>_<peer_id_suffix>" },
    "frame":    { "type": "webrtc", "peer-id": "<peer_id>" }
  },
  "parameters": {
    "detection-properties": {
      "model": "<discovered .xml path, container-absolute>",
      "model_proc": "<discovered .json path, omitted when absent>",
      "device": "CPU | GPU | NPU",
      "model-instance-id": "console-<hash(model,device)>"
    }
  }
}
```

Requirements:

- The device is carried by the pipeline **version**, not the name. `GET /pipelines`
  reports entries such as `{"name":"user_defined_pipelines","version":"object_tracking_cpu"}`.
  Select by matching the version against the device (see §2.2). Matching on the
  name alone never selects a device and silently falls through to whichever entry
  is first, sending every request to a single template — the documented cause of
  GPU and NPU appearing broken while the pipeline server reports errors against
  another device's instance identifier.
- `peer_id` MUST be unique per panel so that comparison mode does not collide in
  MediaMTX.
- `model` and `model_proc` MUST be paths as seen **inside the pipeline server
  container**. The console mounts the same store at the same path so that
  discovered paths are valid without translation.
- `model_proc` MUST be omitted when no sibling document exists. Modern
  intermediate representations carry output metadata in `rt_info`, and supplying
  an empty value causes a load failure.

### 2.2 Selecting the pipeline (required)

```
GET {PIPELINE_SERVER_URL}/pipelines  ->  [{name, version, ...}, ...]
```

Choose the entry whose `version` ends with `_<device>` (case-insensitive), falling
back to a substring match. Issue the start request against
`/pipelines/{name}/{version}`. Never assume the ordering of the returned list, and
never hardcode a pipeline name.

If the server is unreachable, report that distinctly from "no pipeline for this
device"; the two failures have different remedies.

### 2.1 Model instance identity (required)

`model-instance-id` MUST be derived from the model path and device, for example
the first twelve hexadecimal characters of a digest of `f"{model}|{device}"`,
prefixed with `console-`.

The released pipelines pin a fixed identifier per device. DL Streamer caches a
loaded network against that identifier. Reusing it with a different model binds
the request to the previously loaded network; the pipeline reports incorrect
results or fails to start. This is the cause of GPU and NPU pipelines failing
after a model change while CPU appears unaffected.

Supplying a derived identifier makes every model and device combination its own
instance, and makes repeated selection of the same combination reuse its cached
network. The rule is model-agnostic.

## 3. Stop request

```
DELETE {PIPELINE_SERVER_URL}/pipelines/{instance_id}
```

## 4. Status

`GET {PIPELINE_SERVER_URL}/pipelines/status` reports instance state and average
frames per second. The console reads FPS from the metadata message rate and uses
this endpoint for lifecycle state.

## 5. Zone

The loitering zone is **not** a pipeline parameter. `gvaattachroi` fixes the
inference region at construction time; the console evaluates the zone in software
from detection coordinates, as the application's own flow does. Changing the zone
does not restart the pipeline. See `BACKEND-SPEC.md`.

## 6. Model discovery

The catalogue is discovered, never declared. Scan `MODEL_ROOT` for every `*.xml`
with a sibling `*.bin`:

- identifier: model directory name with precision suffix, lower-cased
- label: model name with precision in parentheses
- `model`: absolute path to the `.xml` as mounted in the pipeline server
- `model_proc`: sibling or parent `.json` whose stem matches the model name, else absent

Deduplicate by identifier, sort by label for deterministic ordering, and cache
briefly. `GET /api/models?refresh=1` forces a rescan.

No model name appears in this skill or in generated output. Any model added to the
store is offered for selection and for comparison after a refresh.

## 7. Device availability

Offer only devices the host provides: `CPU` always; `GPU` when a render node is
present; `NPU` when an accelerator node is present. Report unavailable devices as
disabled rather than omitting them, so the operator can see why a comparison is
unavailable.
