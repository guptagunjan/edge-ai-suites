<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Example: PX4 SITL Simulation with Web Mission Console UI

Build a full end-to-end UAV object detection and telemetry overlay stack in
`./uav-ui-stack/` using the uav-vision-analytics skill, including the
browser-based Mission Console.

**Scenario:** Simulate a UAV flight using PX4 SITL. Detect aerial objects in a
looped Gazebo simulation video using YOLOv8n-VisDrone on CPU. Instead of using
`ffplay`/VLC/QGroundControl to view the annotated stream, provide a web UI
where an operator can pick a pipeline from a dropdown, start/stop it, see the
live annotated video directly in the browser, watch CPU/GPU/NPU/memory
utilization update in real time, and arm/disarm the simulated vehicle with a
button instead of opening QGroundControl.

**Requirements:**
- Deployment mode: `pymavlink` (self-contained with PX4 SITL)
- Video source: `file` (gazebo.avi, looped)
- Inference device: `CPU`
- Model: `yolov8n-visdrone` (default)
- Output directory: `./uav-ui-stack/`
- Include web Mission Console UI: `yes`

Produce everything from the base pymavlink stack (see
`01-pymavlink-sim-all-devices.md`) **plus**:
- `ui/Dockerfile`, `ui/requirements.txt`, `ui/app.py`, `ui/templates/index.html`
  — generated from scratch by implementing the full specification in
  `references/UI.md` (routes, env vars, request/response shapes, required
  behavior).
- `uav-mission-ui` and `metrics-manager` services added to
  `docker-compose-pymavlink.yml`, with `uav-mission-ui` depending on both
  `dlstreamer-pipeline-server` and `metrics-manager`
- Port `8090` exposed for the Mission Console, `9090` for Metrics Manager

Verify against all completion criteria, including the UI-specific criteria in
`references/UI.md` (index page returns `200`, `/api/pipelines` matches DLSPS,
`/api/metrics` returns non-null CPU/MEM percentages, a pipeline started via
`/api/pipelines/start` shows up as `RUNNING` in DLSPS, and starting the same pipeline
twice concurrently under different sessions does not collide).
