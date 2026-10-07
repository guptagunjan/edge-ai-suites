<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Frontend Specification — `static/whep.js` and `static/app.js`

Plain ECMAScript modules loaded as classic scripts. No framework, no bundler, no
external content delivery network. Clauses marked MUST are asserted by
`acceptance/verify.sh`.

## 0. Module layout

The controller is generated as four modules, each within the line budget in
`BUILD.md` 1.3.

| Module | Sections implemented |
|---|---|
| `whep.js` | Part A — ICE discovery, offer and retry |
| `panels.js` | Part B §B1–B4 and §F — panel lifecycle, zone overlay, drawing |
| `telemetry.js` | Part B §B5–B6, §E and §G — polling, telemetry cards, gauges, compatibility notes |
| `app.js` | Part B §B0 and §B7 — bootstrap, control wiring, start and stop |

The markup MUST load them in the order `whep.js`, `panels.js`, `telemetry.js`,
`app.js`.

Modules MUST communicate through a single namespace object created by the first
module to load:

```js
window.Console = window.Console || {};
```

Each module attaches only what its peers need (for example
`Console.createPanel`, `Console.renderTelemetry`, `Console.currentZoneString`).
A module MUST NOT reach into another module's internals or rely on a bare
global.

## A. `whep.js` — WebRTC playback

### A.1 ICE-server discovery (required)

Before constructing the peer connection, issue `OPTIONS` against the WHEP URL and
parse the `Link` response headers for entries with `rel="ice-server"`:

```
Link: <turn:host:3478>; rel="ice-server"; username="..."; credential="..."
Link: <stun:host:3478>; rel="ice-server"
```

Build an `iceServers` array from the parsed URLs and credentials and pass it to
`new RTCPeerConnection({ iceServers })`.

A peer connection constructed with an empty `iceServers` list gathers only host
candidates, which are the container's internal addresses and are unreachable from
another machine. Signalling still succeeds, so metadata and utilisation continue
to update while the video element never renders and eventually reports an error.
Constructing the connection without performing this discovery is a defect.

When discovery yields nothing, proceed with an empty list and record the
condition in the panel status; do not abort.

### A.2 Session negotiation

1. `addTransceiver('video', {direction:'recvonly'})`, and likewise for audio.
2. Create an offer, set it as the local description, and wait for ICE gathering to
   complete or for a short timeout.
3. `POST` the SDP to the WHEP URL with `Content-Type: application/sdp`. A `404`
   means the pipeline has not published yet, not that signalling failed; the
   offer MUST be retried on a fixed interval (about 1.5 s) until the path
   appears or a timeout of about 30 s elapses, reporting `waiting for stream…`
   meanwhile. Without this, starting a panel reports
   `signalling rejected (404)` even though the pipeline is healthy, which is
   most visible in comparison mode where two pipelines start together.
4. Apply the answer as the remote description; retain the `Location` header as the
   resource URL, resolved against `document.baseURI` so that `PATCH` and `DELETE`
   address the console proxy rather than a path that does not exist on this
   origin.
5. Attach the first inbound track to the video element.
6. On teardown, `DELETE` the resource URL when one was returned, then close the
   connection.

### A.3 URL handling

The WHEP URL MUST be taken from the `whep_url` field returned by the start
response, which is a path relative to the console origin. The client MUST NOT
construct a media-server address, and MUST NOT assume a host or port. This keeps
signalling same-origin and free of mixed-content and cross-origin failures.

### A.4 State reporting

Report `connecting`, `live`, `stalled` and `error` from the connection state and
from track activity, and surface the state in the panel status line. An error MUST
identify whether negotiation or media failed, so that a stalled video is
distinguishable from a rejected offer.

## B. `app.js` — controller

### B.1 Paths

All requests MUST use paths relative to the document base (`api/...`,
`whep/...`). A root-absolute path such as `/api/...` breaks whenever the console
is reached through a path prefix, producing an unstyled page, empty selectors and
absent utilisation. Combined with the base-href injector in `LAYOUT.md`, relative
references are correct at any mount point.

### B.2 Initialisation

1. `GET api/config` — populate sources, devices and defaults. Mark devices the
   host does not provide as disabled.
2. `GET api/models` — populate both model selectors. When the catalogue is empty,
   disable the start control and state that no model is installed in the model
   store. Never substitute a default model name.
3. Restore the zone inputs from the configured default.
4. Start the polling timers in §B.7.

### B.3 Model selection and comparison

The second model selector is revealed by the comparison control. In comparison
mode the start action issues two start requests for the same source, one per
selected model or device, and appends two panels. The grid takes its comparison
class so that panels are laid out side by side.

Each panel is an independent stream with its own peer identifier; the client MUST
NOT reuse a peer identifier between panels.

The refresh control issues `GET api/models?refresh=1` and rebuilds both selectors,
preserving the current selection when it is still present.

### B.4 Zone definition

The zone is expressed as `x,y,w,h` in source pixels and may be set either through
the numeric inputs or by drawing on a panel.

When drawing is enabled, a drag on the overlay defines a rectangle. Screen
coordinates MUST be converted to source pixels using the intrinsic video
dimensions and the letterbox offsets implied by `object-fit: contain`:

```
scale   = min(elementWidth / videoWidth, elementHeight / videoHeight)
offsetX = (elementWidth  - videoWidth  * scale) / 2
offsetY = (elementHeight - videoHeight * scale) / 2
sourceX = (clientX - rect.left - offsetX) / scale
sourceY = (clientY - rect.top  - offsetY) / scale
```

Clamp to the frame, reject a degenerate rectangle, and write the result into the
numeric inputs. The active zone is drawn continuously in the overlay using the
inverse transform, so it remains correct as the panel is resized.

### B.5 Applying a zone

Applying issues `POST api/zone` with the peer identifier and the rectangle. The
zone takes effect immediately for subsequent analytics.

The client MUST NOT stop and restart a pipeline in order to change a zone, and
MUST NOT replace the panel or renegotiate the media session. The zone is an
analytic region evaluated by the console, not a pipeline parameter. Applying to
all streams issues one request per active stream.

### B.6 Lifecycle

Starting appends a panel, requests the stream, and begins playback using the
returned relative WHEP URL. Closing a panel stops its instance and tears down its
peer connection. Stopping all iterates the session table. Every panel removal MUST
release its peer connection; leaking connections exhausts the browser's limit
after repeated comparisons.

### B.7 Polling

| Endpoint | Interval | Effect |
|---|---|---|
| `api/events` | 1 s | Rebuild the telemetry strip: FPS, objects, maximum dwell, loiter count. A card carries the loiter class when the count is non-zero. |
| `api/metrics` | 2 s | Update the four gauges and their detail lines. |
| `api/health` | 10 s | Update the connection indicator. |

A failed poll MUST leave the last values in place and mark the indicator as
degraded; it MUST NOT clear the interface or halt the timers.

### B.8 Utilisation display

Each gauge shows a headline percentage and a detail line. The GPU detail line
lists the per-engine ratios reported by the backend and the memory in use against
the total. The CPU, NPU and memory gauges show their corresponding secondary
figures. A null value is rendered as `n/a`; a null MUST NOT be rendered as zero,
because a zero is indistinguishable from an idle device and conceals a
misconfigured metrics source.

### B.9 Prohibitions

- No framework, bundler or external content delivery network.
- No colour, spacing or font outside `DESIGN-TOKENS.md`.
- No element identifier outside `LAYOUT.md`.
- No reference to a specific detection model, in code, in a comment or in a
  placeholder. The catalogue is whatever the deployment provides.


---

## E. Empty-state placeholder

The placeholder MUST be hidden whenever at least one panel is mounted in the
grid. Visibility MUST be derived from the panels present in the DOM, not from
the map of registered sessions: a panel is mounted synchronously while its
start request is still in flight, so a session-count test leaves the
placeholder visible on top of a live stream.

## F. Zone controls

1. The start request MUST carry the zone currently shown in the controls, so
   the first evaluated frame uses it.
2. Each panel's apply control MUST be enabled once the panel is mounted, MUST
   be bound to a handler that posts to `/api/zone` for that panel, and MUST
   report progress and completion.
3. Applying a zone MUST re-render that panel's zone rectangle. Exactly one
   zone rectangle may be displayed per panel at any time; the transient
   drawing rectangle MUST be cleared when the drag ends.

## G. Model compatibility

Models reported as other than `ok` MUST be marked in the selector and MUST
raise a visible notice on the panel when started, carrying
`compatibility_detail`. The dashboard MUST NOT present an incompatible model
as a normal stream with zero counts.


## H. Zone input: rectangle and polygon

The left rail MUST offer the four rectangle fields and, in addition, a free
text field (`#roiPoly`) accepting a vertex list such as
`(120,100) (900,120) (860,600) (100,560)`.

- A non-empty, well-formed vertex list takes precedence over the rectangle
  fields; `currentZoneString()` returns whichever is in force.
- Completing a drag-to-draw box MUST clear the vertex field, so the two
  notations can never disagree about what is being applied.
- The overlay MUST render a polygon via `clip-path` sized to the rendered
  frame, and a plain rectangle otherwise. The drawn shape must be what the
  server evaluates, never an approximation of it.

## I. Applying a zone

`applyZone` MUST post **without** `peer_id`, so the zone reaches every live
stream, and MUST then re-render the overlay on all panels and report the
number affected ("Applied to N streams"). The per-panel control is enabled
when the panel is created.

## J. Per-panel loiter table

Each panel MUST present, beneath its video:

- a summary row: fps, objects, max dwell, loiter count;
- a table of the `objects` rows from `/api/events`, with the columns
  Object ID, Label, Status, Entry, Dwell, Dwell (s);
- a message in place of the table when no object is inside the zone.

Rows whose status is `Loitering` MUST be visually distinguished. The table
belongs to its own stream window rather than a shared strip, so that when
models are compared each model's objects are attributable at a glance.
