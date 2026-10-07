#!/usr/bin/env bash
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Acceptance gate for the generated Metro Vision AI Mission Console.
#
# The skill ships no application code; the console is generated on each
# invocation. This script is the mechanism that guarantees every deployment
# renders the same dashboard, behaves identically, reintroduces none of the
# defects recorded in DESIGN.md section 12, and leaves the target application
# unmodified.
#
# Usage:
#   acceptance/verify.sh <CONSOLE_URL> <CONSOLE_SRC_DIR> [--app-dir DIR] [--live]
#
#   CONSOLE_URL      https://<host>:<console-port>
#   CONSOLE_SRC_DIR  generated console source directory (contains app.py)
#   --app-dir DIR    application directory, for the non-modification assertion
#   --live           additionally run a start / events / zone / stop smoke test
#
# Exits zero only when every assertion passes.

set -u

CONSOLE="${1:?usage: verify.sh <CONSOLE_URL> <CONSOLE_SRC_DIR> [--app-dir DIR] [--live]}"
shift
SRC="${1:?usage: verify.sh <CONSOLE_URL> <CONSOLE_SRC_DIR> [--app-dir DIR] [--live]}"
shift || true

LIVE=0
APP_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --live)    LIVE=1 ;;
    --app-dir) shift; APP_DIR="${1:-}" ;;
  esac
  shift || true
done

CONSOLE="${CONSOLE%/}"
CURL=_curl
_curl(){ command curl -sk --noproxy '*' --max-time 10 "$@"; }
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip(){ printf '  SKIP  %s\n' "$1"; }
have(){ printf '%s' "$1" | grep -q -- "$2"; }

echo "== Mission Console acceptance =="
echo "console=$CONSOLE  src=$SRC  app_dir=${APP_DIR:-<unset>}  live=$LIVE"

# The console is generated as modules (BUILD.md 1.3). Source contracts are
# asserted against the whole backend and the whole controller, not one file.
PYCAT="$(mktemp)"; JSCAT="$(mktemp)"; SERVEDJS="$(mktemp)"
trap 'rm -f "$PYCAT" "$JSCAT" "$SERVEDJS"' EXIT
cat "$SRC"/*.py            >"$PYCAT" 2>/dev/null || true
cat "$SRC"/static/*.js     >"$JSCAT" 2>/dev/null || true

# ------------------------------------------------- 0. skill loadability -----
echo "[0] skill front matter is loadable"
SKILL_MD="$(cd "$(dirname "$0")/.." && pwd)/SKILL.md"
if [ -f "$SKILL_MD" ]; then
  FM_NAME="$(sed -n '/^---$/,/^---$/p' "$SKILL_MD" | sed -n 's/^name:[[:space:]]*//p' | head -1)"
  if [ "$FM_NAME" = "loitering-detection-ui" ]; then
    ok "front-matter name is 'loitering-detection-ui'"
  else
    no "front-matter name is '$FM_NAME', expected 'loitering-detection-ui'"
  fi
  DESC_LEN="$(python3 - "$SKILL_MD" <<'PYIN'
import re,sys
s=open(sys.argv[1]).read()
fm=re.match(r"^---\n(.*?)\n---\n", s, re.S)
d=re.search(r"^description:\s*>-\n((?:  .*\n?)*)", fm.group(1), re.M)
print(len(" ".join(l.strip() for l in d.group(1).strip().splitlines())) if d else -1)
PYIN
)"
  if [ "$DESC_LEN" -gt 0 ] && [ "$DESC_LEN" -le 1024 ]; then
    ok "description is $DESC_LEN characters (loader limit 1024)"
  else
    no "description is $DESC_LEN characters; loader rejects skills over 1024"
  fi
else
  no "SKILL.md not found at $SKILL_MD"
fi

# ------------------------------------------------ 1. application untouched ---
echo "[1] the application is not modified"
if [ -n "$APP_DIR" ] && [ -d "$APP_DIR" ]; then
  if git -C "$APP_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    # '.env' is produced by the application's own install.sh (HOST_IP, SAMPLE_APP)
    # and is a prerequisite of running the application. It is therefore excluded.
    # Every other tracked file must be unmodified.
    DIRTY="$(git -C "$APP_DIR" status --porcelain -- . \
             | grep -v '^?? ' \
             | grep -v '[[:space:]]metro-ai-suite/metro-vision-ai-app-recipe/\.env$' \
             | grep -v '[[:space:]]\.env$' || true)"
    ENVMOD="$(git -C "$APP_DIR" status --porcelain -- . | grep -E '[[:space:]]\.env$' || true)"
    if [ -z "$DIRTY" ]; then
      ok "no tracked application file is modified"
      [ -n "$ENVMOD" ] && printf '        note: .env differs (install.sh output; expected)\n'
    else
      no "application files modified:
$(printf '%s' "$DIRTY" | sed 's/^/        /')"
    fi
    for f in src/dlstreamer-pipeline-server/config.json src/nginx/nginx.conf src/node-red/flows.json; do
      if [ -f "$APP_DIR/$f" ]; then
        if git -C "$APP_DIR" diff --quiet -- "$f" 2>/dev/null; then ok "unmodified: $f"; else no "MODIFIED: $f"; fi
      fi
    done
  else
    skip "application directory is not a git work tree"
  fi
else
  skip "no --app-dir supplied; non-modification not asserted"
fi

# the generated console must not live inside the application source tree
case "$(cd "$SRC" 2>/dev/null && pwd)" in
  */src/*) no "generated console is inside the application source tree" ;;
  *)       ok "generated console is outside the application source tree" ;;
esac

# ------------------------------------------------------------ 2. markup -----
echo "[2] served markup contract"
HTML="$(_curl "$CONSOLE/")"
[ -n "$HTML" ] || no "console did not answer at $CONSOLE/"
have "$HTML" 'document.createElement("base")' && ok "base-href injector present" || no "base-href injector missing"
have "$HTML" 'href="static/styles.css"' && ok "relative stylesheet reference" || no "stylesheet reference is not relative"
if have "$HTML" 'href="/static' || have "$HTML" 'src="/static'; then
  no "root-absolute static reference present"
else
  ok "no root-absolute static references"
fi
REQ_IDS="compareMode connState sourceSel rtspInput refreshModels modelSelA modelBWrap modelSelB deviceSel modelSrcHint drawZone roiX roiY roiW roiH applyZoneAll startBtn stopAllBtn grid emptyState telemetryStrip panelTpl loiterThr"
miss=""; for id in $REQ_IDS; do have "$HTML" "id=\"$id\"" || miss="$miss $id"; done
[ -z "$miss" ] && ok "all required element identifiers present" || no "missing identifiers:$miss"
gm=""; for k in cpu gpu npu mem; do have "$HTML" "data-key=\"$k\"" || gm="$gm $k"; done
[ -z "$gm" ] && ok "all four utilisation gauges present" || no "missing gauges:$gm"

# ----------------------------------------------------- 3. design tokens -----
echo "[3] design-token contract"
CSS="$(_curl "$CONSOLE/static/styles.css")"
CT="$(_curl -o /dev/null -w '%{content_type}' "$CONSOLE/static/styles.css")"
have "$CT" 'text/css' && ok "stylesheet served as text/css" || no "stylesheet content-type is $CT"
TOKENS='--bg: #0c1017|--panel: #151b26|--panel-2: #1b2432|--line: #24303f|--text: #e6edf5|--muted: #8ea0b5|--accent: #29c19c|--accent-2: #3d8bff|--warn: #f5a623|--danger: #ff5c6c|--rail-w: 320px|--foot-h: 84px|--head-h: 56px'
tmiss=""
IFS='|'; for t in $TOKENS; do have "$CSS" "$t" || tmiss="$tmiss [$t]"; done; unset IFS
[ -z "$tmiss" ] && ok "all locked design tokens present and unchanged" || no "token mismatch:$tmiss"
have "$CSS" 'grid-template-columns: var(--rail-w) 1fr' && ok "rail and stage layout locked" || no "layout grid does not follow the token"

# ------------------------------------------------------------- 4. WebRTC ----
echo "[4] WebRTC ICE-discovery contract"
WJ="$(_curl "$CONSOLE/static/whep.js")"
have "$WJ" 'OPTIONS'    && ok "issues OPTIONS to discover ICE servers" || no "no ICE discovery; video will not play cross-machine"
have "$WJ" 'ice-server' && ok "parses rel=ice-server Link entries"     || no "does not parse ice-server Link entries"
have "$WJ" 'iceServers' && ok "supplies iceServers to the peer connection" || no "iceServers not supplied to RTCPeerConnection"

# ------------------------------------------------------ 5. frontend paths ---
echo "[5] frontend path contract"
for m in app.js panels.js telemetry.js; do _curl "$CONSOLE/static/$m" >>"$SERVEDJS"; done
AJ="$(cat "$SERVEDJS")"
if have "$AJ" 'fetch("/api' || have "$AJ" "fetch('/api"; then
  no "root-absolute API request present"
else
  ok "no root-absolute API requests"
fi
have "$AJ" 'api/config' && ok "uses relative API paths" || no "relative API paths not found"
have "$AJ" 'api/zone'   && ok "zone applied through api/zone" || no "zone endpoint not used"
if have "$AJ" 'pipelines/reapply'; then no "zone change restarts the pipeline"; else ok "zone change does not restart the pipeline"; fi

# ------------------------------------------------------------ 6. backend ----
echo "[6] backend contract ($SRC/*.py)"
if [ -s "$PYCAT" ]; then
  AP="$(cat "$PYCAT")"
  have "$AP" 'subscribe("#")'                    && ok "MQTT subscribes with a wildcard and filters by prefix" || no "MQTT subscription will not match the flat topic"
  have "$AP" 'metadata'                          && ok "reads detections from nested metadata"                 || no "does not read metadata.objects"
  have "$AP" 'qmmd_gpu_engine_utilization_ratio' && ok "GPU utilisation from the engine series"                || no "GPU utilisation uses a series that reports zero"
  have "$AP" 'ccs'                               && ok "GPU headline is the compute engine"                    || no "GPU headline is not the compute engine"
  have "$AP" 'model-instance-id'                 && ok "supplies a model-instance identity per request"        || no "no model-instance identity; GPU/NPU break after a model change"
  have "$AP" 'version.lower()'                   && ok "selects the pipeline by version (device lives there)"   || no "selects pipeline by name; every device would use one template"
  have "$AP" '1e9'                               && ok "frame timestamps normalised from nanoseconds"           || no "timestamps not normalised; dwell will be astronomically wrong"
  have "$AP" 'DEVICES'                           && ok "device availability supplied by the deployment"         || no "device availability probed locally; GPU/NPU always absent"
  have "$AP" 'zone_entry_ts'                     && ok "dwell measured against zone occupancy"                 || no "dwell not measured against zone occupancy"
  have "$AP" 'ZONE_VACANT_GRACE_S'               && ok "zone vacancy grace period present"                     || no "no vacancy grace; dwell resets on brief occlusion"
  have "$AP" 'TRACK_TTL_S'                       && ok "track retention governed by a time-to-live"            || no "no track time-to-live; dwell truncated"
  have "$AP" 'Link'                              && ok "WHEP proxy forwards Link headers"                      || no "WHEP proxy does not forward Link headers"
  have "$AP" 'ssl_context'                       && ok "console terminates its own TLS"                        || no "console does not terminate TLS; WebRTC requires a secure origin"
  bad=""
  for f in "$SRC"/*.py; do
    python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$f" 2>/dev/null || bad="$bad $(basename "$f")"
  done
  [ -z "$bad" ] && ok "every backend module parses" || no "syntax error in:$bad"
else
  no "no backend module found at $SRC"
fi

# ------------------------------------------- 7. no hardcoded model names ----
echo "[7] model-agnostic contract"
HITS="$(grep -rEil 'yolo|resnet|mobilenet|ssd[-_]|pedestrian-and-vehicle' "$SRC" 2>/dev/null || true)"
[ -z "$HITS" ] && ok "no detection-model name appears in the generated console" || no "hardcoded model name in:
$(printf '%s' "$HITS" | sed 's/^/        /')"

# ---------------------------------------------------------- 8. API shape ----
echo "[8] API contract"
CFG="$(_curl "$CONSOLE/api/config")"
have "$CFG" '"sources"' && have "$CFG" '"devices"' && ok "/api/config returns sources and devices" || no "/api/config shape is wrong"
MJS="$(_curl "$CONSOLE/api/models")"
have "$MJS" '"models"' && ok "/api/models responds" || no "/api/models failed"
NMODELS="$(printf '%s' "$MJS" | grep -o '"id"' | wc -l | tr -d ' ')"
[ "${NMODELS:-0}" -ge 1 ] && ok "$NMODELS model(s) discovered from the model store" || no "no model discovered"
MET="$(_curl "$CONSOLE/api/metrics")"
have "$MET" '"cpu"' && have "$MET" '"gpu"' && have "$MET" '"npu"' && have "$MET" '"mem"' && ok "/api/metrics reports every device" || no "/api/metrics shape is wrong"
have "$MET" '"engines"' && ok "/api/metrics exposes the GPU engine breakdown" || no "/api/metrics omits the GPU engine breakdown"
EVC="$(_curl -o /dev/null -w '%{http_code}' "$CONSOLE/api/events")"
[ "$EVC" = 200 ] && ok "/api/events answers" || no "/api/events returned $EVC"

# ------------------------------------------- [15] generation-robustness ----
# Monolithic generation has failed in the field: a single large backend was
# truncated mid-write by the model output token limit, and a large controller
# never landed at all. The module split and the line budgets in BUILD.md 1.3
# exist to keep every write small enough to succeed, so they are enforced.
echo "[15] module layout and line budgets"

_budget() { # _budget <relative-path> <max-lines>
  f="$SRC/$1"; max="$2"
  if [ ! -f "$f" ]; then no "missing module $1"; return; fi
  n="$(grep -c "" "$f" 2>/dev/null || echo 0)"
  if [ "$n" -le "$max" ]; then ok "$1 ($n lines, budget $max)"
  else no "$1 is $n lines, over its $max-line budget - split it (BUILD.md 1.3)"; fi
}

_budget config.py                110
_budget catalog.py               210
_budget analytics.py             200
_budget ingest.py                150
_budget metrics.py               140
_budget api.py                   150
_budget api_pipelines.py         140
_budget whep_proxy.py            110
_budget app.py                    60
_budget templates/index.html     200
_budget static/styles.css        210
_budget static/panels.css        190
_budget static/whep.js           190
_budget static/panels.js         200
_budget static/telemetry.js      170
_budget static/app.js            180

# No generated file may exceed the hard ceiling, whatever its name.
OVER="$(find "$SRC" -type f \( -name '*.py' -o -name '*.js' -o -name '*.css' -o -name '*.html' \) \
        -exec sh -c 'n=$(grep -c "" "$1"); [ "$n" -gt 220 ] && echo "$1 ($n)"' _ {} \; 2>/dev/null || true)"
[ -z "$OVER" ] && ok "no generated file exceeds the 220-line ceiling" \
  || no "over the hard ceiling:
$(printf '%s' "$OVER" | sed 's/^/        /')"

# The controller is split, so the markup must load the modules in order and the
# namespace must be shared rather than assumed.
if [ -f "$SRC/templates/index.html" ]; then
  H="$(cat "$SRC/templates/index.html")"
  miss=""
  for m in whep.js panels.js telemetry.js app.js; do
    printf '%s' "$H" | grep -q "static/$m" || miss="$miss $m"
  done
  [ -z "$miss" ] && ok "markup loads every controller module" || no "markup omits:$miss"
  ORDER="$(printf '%s' "$H" | grep -o 'static/\(whep\|panels\|telemetry\|app\)\.js' | sed 's|static/||' | paste -sd, -)"
  [ "$ORDER" = "whep.js,panels.js,telemetry.js,app.js" ] \
    && ok "controller modules load in the required order" \
    || no "module load order is '$ORDER', expected whep.js,panels.js,telemetry.js,app.js"
fi
if command -v node >/dev/null 2>&1; then
  jsbad=""
  for f in "$SRC"/static/*.js; do
    node --check "$f" >/dev/null 2>&1 || jsbad="$jsbad $(basename "$f")"
  done
  [ -z "$jsbad" ] && ok "every controller module parses" || no "JavaScript syntax error in:$jsbad"
else
  printf '  SKIP  %s\n' "node unavailable; JavaScript syntax not checked"
fi

grep -q 'window.Console' "$JSCAT" \
  && ok "controller modules share the Console namespace" \
  || no "no shared namespace; modules assume each other's internals"

# --------------------------------------------------------- 9. live smoke ----

# ---------------------------------------------------------------- [9b] regression contracts
echo "[9b] regression contracts in generated source"
APP="$PYCAT"; WJS="$SRC/static/whep.js"; AJS="$JSCAT"

# WHEP session resource: without this route the browser resolves the media
# server's Location against this origin and signalling fails with 404.
grep -Eq '/whep/<peer_id>/<path:session>|/whep/<peer_id>/<session>' "$APP" \
  && ok "whep session-resource route present" \
  || no "missing /whep/<peer_id>/<session> route (ICE trickle and teardown 404)"
grep -q 'whep/%s/%s' "$APP" \
  && ok "Location rewrite preserves the session identifier" \
  || no "Location rewrite drops the session identifier"
grep -q 'api/stream/ready' "$APP" \
  && ok "stream readiness endpoint present" \
  || no "missing readiness endpoint"

# Offer retry: pipelines publish a moment after launch.
grep -Eq '404' "$WJS" && grep -Eiq 'retry|postOffer' "$WJS" \
  && ok "client retries signalling while the path is published" \
  || no "client does not retry a 404 offer (reports rejected signalling)"
grep -q 'baseURI' "$WJS" \
  && ok "session resource resolved against the document base" \
  || no "session resource not resolved against document base"

# Dwell time base must be locked per stream.
grep -q 'time_key' "$APP" \
  && ok "frame time base locked per stream" \
  || no "time base not locked (mixing PTS and epoch yields negative dwell)"

# Utilisation must not be bound to a single exporter.
grep -q '_prom_first' "$APP" && grep -q 'cpu_usage_percentage' "$APP" \
  && ok "utilisation uses candidate expression lists" \
  || no "utilisation bound to one exporter (gauges read n/a elsewhere)"
grep -q 'mem_used_percent' "$APP" \
  && ok "system memory candidates present" \
  || no "system memory candidates missing"

# Session reconciliation and health reporting.
grep -q '_reconcile_sessions' "$APP" \
  && ok "sessions reconciled against pipeline state" \
  || no "no reconciliation (stopped pipelines linger as frozen panels)"
grep -q 'detection_state' "$APP" && grep -q 'detection_state' "$AJS" \
  && ok "stream health reported and rendered" \
  || no "detection_state not reported/rendered"


# ------------------------------------------------ [9c] regression contracts
echo "[9c] regression contracts (frame time, zone, preflight, empty state)"
APP="$PYCAT"
AJS="$JSCAT"

grep -q "_normalise_frame_time(value, key)\|_normalise_frame_time(cand_val, cand_key)" "$APP" \
  && ok "frame time normalised by key, not magnitude" \
  || no "frame time still uses a magnitude heuristic (inflates dwell 1000x)"

grep -q "v / 1e9" "$APP" \
  && ok "nanosecond keys converted with /1e9" \
  || no "nanosecond conversion missing"

! grep -q "v / 1e6" "$APP" \
  && ok "no microsecond magnitude branch" \
  || no "microsecond magnitude branch present - dwell will be 1000x too large"

grep -q 'body.get("zone")' "$APP" \
  && ok "start honours the requested zone" \
  || no "start ignores the requested zone (always uses the default)"

grep -q "_model_compatibility" "$APP" && grep -q "dynamic-spatial" "$APP" \
  && ok "model compatibility preflight present" \
  || no "model compatibility preflight missing"

grep -q "_ir_input_shape" "$APP" \
  && ok "IR input shape introspection present" \
  || no "IR input shape introspection missing"

grep -q 'querySelectorAll(".panel").length' "$AJS" \
  && ok "empty state derived from mounted panels" \
  || no "empty state derived from session map - placeholder overlaps live video"

grep -q 'zone: currentZoneString()' "$AJS" \
  && ok "start request carries the operator zone" \
  || no "start request omits the zone"

grep -q "applyBtn.disabled = false" "$AJS" \
  && ok "per-panel apply control enabled" \
  || no "per-panel apply control not enabled"

grep -q "compatibility_detail" "$AJS" \
  && ok "incompatible models surfaced in the interface" \
  || no "incompatible models not surfaced"


if [ "$LIVE" = 1 ]; then
  echo "[9] live smoke"
  MID="$(printf '%s' "$MJS" | python3 -c "import sys,json;print(json.load(sys.stdin)['models'][0]['id'])" 2>/dev/null)"
  SID="$(printf '%s' "$CFG" | python3 -c "import sys,json;print(json.load(sys.stdin)['sources'][0]['id'])" 2>/dev/null)"
  DEVS="$(printf '%s' "$CFG" | python3 -c "import sys,json;print(' '.join(d['id'] for d in json.load(sys.stdin)['devices'] if d.get('available')))" 2>/dev/null)"
  [ -n "$DEVS" ] || DEVS="CPU"
  echo "      model=$MID source=$SID devices=$DEVS"
  for DEV in $DEVS; do
    body="{\"source\":\"$SID\",\"model\":\"$MID\",\"device\":\"$DEV\"}"
    RESP="$(_curl -X POST -H 'Content-Type: application/json' -d "$body" "$CONSOLE/api/pipelines/start")"
    PEER="$(printf '%s' "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('peer_id',''))" 2>/dev/null)"
    if [ -z "$PEER" ]; then
      no "$DEV start failed: $(printf '%s' "$RESP" | head -c 200)"
      continue
    fi
    ok "$DEV pipeline started"
    sleep 14
    EV="$(_curl "$CONSOLE/api/events")"
    STATS="$(printf '%s' "$EV" | python3 -c "
import sys,json
for s in json.load(sys.stdin)['streams']:
    if s['peer_id']=='$PEER':
        print('%s %s %s %s'%(s['fps'],s['object_count'],s['max_dwell_s'],s['frame_time_source'])); break
else: print('0 0 0 none')" 2>/dev/null)"
    set -- $STATS
    FPS="${1:-0}"; OBJ="${2:-0}"; DW="${3:-0}"; TSRC="${4:-none}"
    echo "      $DEV: fps=$FPS objects=$OBJ max_dwell=${DW}s time=$TSRC"
    awk "BEGIN{exit !($FPS > 0)}" && ok "$DEV is producing frames ($FPS fps)" || no "$DEV produced no telemetry"
    [ "$TSRC" = "frame" ] && ok "$DEV dwell measured on frame time" || no "$DEV fell back to wall-clock time"
    awk "BEGIN{exit !($DW >= 0 && $DW < 86400)}" && ok "$DEV dwell is plausible (${DW}s)" || no "$DEV dwell implausible (${DW}s) - unit error"
    ZR="$(_curl -X POST -H 'Content-Type: application/json' \
          -d "{\"peer_id\":\"$PEER\",\"zone\":\"0,0,4096,4096\"}" "$CONSOLE/api/zone")"
    have "$ZR" '"zone"' && ok "$DEV zone applied without restart" || no "$DEV zone change failed"
    _curl -X POST -H 'Content-Type: application/json' -d "{\"peer_id\":\"$PEER\"}" "$CONSOLE/api/pipelines/stop" >/dev/null
    ok "$DEV stopped"
    sleep 3
  done

  # ------------------------------------------------------------ [10] utilisation
  echo "[10] utilisation is populated"
  MET="$(_curl "$CONSOLE/api/metrics")"
  for FIELD in cpu.percent mem.percent mem.used_bytes; do
    V="$(printf '%s' "$MET" | python3 -c "
import sys,json
d=json.load(sys.stdin)
a,b='$FIELD'.split('.')
v=d.get(a,{}).get(b)
print('null' if v is None else v)" 2>/dev/null)"
    [ "$V" != "null" ] && [ -n "$V" ] \
      && ok "$FIELD = $V" \
      || no "$FIELD is null (gauge renders n/a)"
  done

  # ------------------------------------------------------- [11] comparison mode
  echo "[11] comparison mode (two concurrent pipelines)"
  NMODELS="$(printf '%s' "$MJS" | python3 -c "import sys,json;print(len(json.load(sys.stdin)['models']))" 2>/dev/null || echo 0)"
  M2="$(printf '%s' "$MJS" | python3 -c "
import sys,json
m=json.load(sys.stdin)['models']
print(m[1]['id'] if len(m)>1 else m[0]['id'])" 2>/dev/null)"
  bodyA="{\"source\":\"$SID\",\"model\":\"$MID\",\"device\":\"CPU\"}"
  bodyB="{\"source\":\"$SID\",\"model\":\"$M2\",\"device\":\"CPU\"}"
  RA="$(_curl -X POST -H 'Content-Type: application/json' -d "$bodyA" "$CONSOLE/api/pipelines/start")"
  RB="$(_curl -X POST -H 'Content-Type: application/json' -d "$bodyB" "$CONSOLE/api/pipelines/start")"
  PA="$(printf '%s' "$RA" | python3 -c "import sys,json;print(json.load(sys.stdin).get('peer_id',''))" 2>/dev/null)"
  PB="$(printf '%s' "$RB" | python3 -c "import sys,json;print(json.load(sys.stdin).get('peer_id',''))" 2>/dev/null)"
  if [ -n "$PA" ] && [ -n "$PB" ] && [ "$PA" != "$PB" ]; then
    ok "two concurrent sessions with distinct peer identifiers"
  else
    no "comparison mode failed to start two distinct sessions"
  fi

  # readiness and the session route must both answer, and never 404
  RDY="$(_curl "$CONSOLE/api/stream/ready/$PA")"
  have "$RDY" '"ready"' && ok "readiness endpoint answers" || no "readiness endpoint missing"
  SC="$(_curl -o /dev/null -w '%{http_code}' -X OPTIONS "$CONSOLE/whep/$PA")"
  [ "$SC" = "204" ] || [ "$SC" = "200" ] && ok "WHEP OPTIONS -> $SC" || no "WHEP OPTIONS -> $SC"
  SC2="$(_curl -o /dev/null -w '%{http_code}' -X PATCH -H 'Content-Type: application/trickle-ice-sdpfrag' \
        --data-binary 'a=x' "$CONSOLE/whep/$PA/probe-session")"
  [ "$SC2" != "404" ] \
    && ok "WHEP session route served (status $SC2, not 404)" \
    || no "WHEP session route returns 404 - ICE trickle and teardown fail"

  sleep 16
  EV2="$(_curl "$CONSOLE/api/events")"
  printf '%s' "$EV2" | python3 -c "
import sys,json
d=json.load(sys.stdin)
bad=[s for s in d['streams'] if s['max_dwell_s']<0 or s['avg_dwell_s']<0]
print('NEGATIVE' if bad else 'CLEAN')
n=len(d['streams']); print(n)
" > /tmp/_ev2 2>/dev/null
  DSTATE="$(head -1 /tmp/_ev2)"; NSTREAMS="$(tail -1 /tmp/_ev2)"
  [ "$DSTATE" = "CLEAN" ] \
    && ok "no negative dwell values (time base consistent)" \
    || no "negative dwell present - PTS and epoch mixed"
  [ "${NSTREAMS:-0}" -ge 2 ] \
    && ok "both panels reporting telemetry ($NSTREAMS streams)" \
    || no "expected 2 concurrent streams, saw ${NSTREAMS:-0}"

  
  # --------------------------------------------- [13] zone honoured at start
  echo "[13] zone honoured at start"
  ZR="$(_curl -X POST -H 'Content-Type: application/json' \
      -d '{"source":"'"$SID"'","model":"'"$MID"'","device":"CPU","zone":"211,107,613,409"}' \
      "$CONSOLE/api/pipelines/start")"
  PZ="$(printf '%s' "$ZR" | python3 -c "import sys,json;print(json.load(sys.stdin).get('peer_id',''))" 2>/dev/null)"
  if [ -n "$PZ" ]; then
    sleep 12
    ZCHK="$(_curl "$CONSOLE/api/events" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for s in d['streams']:
    if s['peer_id']=='$PZ':
        z=s['zone']
        print('MATCH' if (z['x']==211 and z['y']==107 and z['w']==613 and z['h']==409) else 'MISMATCH')
        break
else: print('MISSING')
" 2>/dev/null)"
    [ "$ZCHK" = "MATCH" ] \
      && ok "requested zone is in effect on the running stream" \
      || no "requested zone not applied at start ($ZCHK)"

    # dwell must advance in seconds, not milliseconds
    D1="$(_curl "$CONSOLE/api/events" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(next((s['max_dwell_s'] for s in d['streams'] if s['peer_id']=='$PZ'),0))" 2>/dev/null)"
    sleep 10
    D2="$(_curl "$CONSOLE/api/events" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(next((s['max_dwell_s'] for s in d['streams'] if s['peer_id']=='$PZ'),0))" 2>/dev/null)"
    python3 -c "
import sys
d1,d2=float('$D1' or 0),float('$D2' or 0)
delta=d2-d1
# 10 s of wall time must advance dwell by roughly 10 s, never by thousands
sys.exit(0 if (0 <= delta <= 60) else 1)
" \
      && ok "dwell advances in seconds (delta ${D1} -> ${D2})" \
      || no "dwell advances at the wrong scale (${D1} -> ${D2}) - unit error"

    _curl -X POST -H 'Content-Type: application/json' -d "{\"peer_id\":\"$PZ\"}" "$CONSOLE/api/pipelines/stop" >/dev/null
    sleep 2
  else
    no "could not start a stream for the zone check"
  fi

  # ------------------------------------------ [14] model compatibility report
  echo "[14] model compatibility preflight"
  _curl "$CONSOLE/api/models" | python3 -c "
import sys,json
ms=json.load(sys.stdin).get('models',[])
if not ms: print('NOMODELS'); raise SystemExit
missing=[m for m in ms if m.get('compatibility') is None]
print('MISSING' if missing else 'PRESENT')
" > /tmp/_compat 2>/dev/null
  CMP="$(cat /tmp/_compat 2>/dev/null)"
  [ "$CMP" = "PRESENT" ] \
    && ok "every discovered model reports a compatibility verdict" \
    || no "compatibility verdict absent from /api/models ($CMP)"


  # ------------------------------------------- [18] polygon zone, applied to all
  echo "[18] polygon zone applied to every live stream"
  PZ='(120,100) (900,120) (860,600) (100,560)'
  RZ="$(_curl -X POST -H 'Content-Type: application/json' \
        -d "{\"zone\":\"$PZ\"}" "$CONSOLE/api/zone")"
  echo "$RZ" > /tmp/_zone
  NPTS="$(python3 -c "
import json;d=json.load(open('/tmp/_zone'));p=(d.get('zone') or {}).get('points') or [];print(len(p))" 2>/dev/null || echo 0)"
  NUPD="$(python3 -c "
import json;print(json.load(open('/tmp/_zone')).get('count',0))" 2>/dev/null || echo 0)"
  [ "$NPTS" = "4" ] \
    && ok "polygon accepted and retained as 4 vertices" \
    || no "polygon not retained (points=$NPTS)"
  [ "$NUPD" -ge 2 ] 2>/dev/null \
    && ok "zone applied to all $NUPD live streams" \
    || no "zone reached $NUPD stream(s); comparison would be uneven"

  sleep 6
  _curl "$CONSOLE/api/events" > /tmp/_ev2
  ALLP="$(python3 -c "
import json
st=json.load(open('/tmp/_ev2'))['streams']
print('YES' if st and all(len(((s.get('zone') or {}).get('points') or []))==4 for s in st) else 'NO')" 2>/dev/null || echo NO)"
  [ "$ALLP" = "YES" ] \
    && ok "every stream reports the polygon in force" \
    || no "at least one stream is not on the new zone"

  # rectangle notation must still be honoured
  RR="$(_curl -X POST -H 'Content-Type: application/json' \
        -d '{"zone":"0,200,300,400"}' "$CONSOLE/api/zone")"
  echo "$RR" | grep -q '"count"' \
    && ok "rectangle notation still accepted" \
    || no "rectangle notation rejected"

  # ------------------------------------------- [19] per-object loiter table
  echo "[19] per-object loiter table"
  sleep 8
  _curl "$CONSOLE/api/events" > /tmp/_ev3
  python3 - <<'PY' > /tmp/_rows 2>/dev/null
import json
st = json.load(open('/tmp/_ev3'))['streams']
need = {"id", "label", "status", "entry_time", "dwell_hms", "dwell_s"}
tot, bad, neg = 0, [], 0
for s in st:
    rows = s.get("objects")
    if rows is None:
        bad.append("missing objects on %s" % s.get("peer_id"))
        continue
    for r in rows:
        tot += 1
        miss = need - set(r)
        if miss:
            bad.append("row missing %s" % sorted(miss))
        d = r.get("dwell_s")
        if not isinstance(d, (int, float)) or d < 0 or d > 86400:
            neg += 1
print("TOTAL=%d BAD=%s NEG=%d" % (tot, bad[:2], neg))
PY
  R="$(cat /tmp/_rows)"
  echo "$R" | grep -q "BAD=\[\]" \
    && ok "loiter rows carry the full column set ($R)" \
    || no "loiter row schema incomplete ($R)"
  echo "$R" | grep -q "NEG=0" \
    && ok "every row dwell is plausible" \
    || no "implausible dwell in loiter table ($R)"

  # ------------------------------------------- [12] reconciliation after stop
  echo "[12] stale-session reconciliation"
  for P in "$PA" "$PB"; do
    _curl -X POST -H 'Content-Type: application/json' -d "{\"peer_id\":\"$P\"}" "$CONSOLE/api/pipelines/stop" >/dev/null
  done
  sleep 4
  LEFT="$(_curl "$CONSOLE/api/events" | python3 -c "import sys,json;print(len(json.load(sys.stdin)['streams']))" 2>/dev/null || echo -1)"
  [ "$LEFT" = "0" ] \
    && ok "no stale sessions remain after stop" \
    || no "$LEFT stale session(s) remain - panels would show frozen readings"

fi


# ------------------------------------------------ [16] static name resolution
echo "[16] undefined-name analysis of the generated package"
NC="$(dirname "$0")/../scripts/namecheck.py"
if [ -f "$NC" ] && [ -d "$SRC" ]; then
  if python3 "$NC" "$SRC" >/tmp/_nc 2>&1; then
    ok "namecheck: no unresolved global name"
  else
    no "namecheck reported unresolved names: $(head -3 /tmp/_nc | tr '\n' ' ')"
  fi
else
  skip "namecheck.py or console source not available"
fi

# ------------------------------------------------ [17] zone + table contracts
echo "[17] zone notation and loiter-table source contracts"
_src_has() {
  if grep -rqF "$2" "$SRC" 2>/dev/null; then ok "$1"; else no "$1"; fi
}
_src_has "polygon containment implemented (ray casting)" "_point_in_zone"
_src_has "zone object carries a vertex list"             '"points"'
_src_has "loiter rows expose a dwell in seconds"         '"dwell_s"'
_src_has "loiter rows expose a formatted dwell"          '"dwell_hms"'
_src_has "loiter rows expose an entry time"              '"entry_time"'
_src_has "stale rows are withheld from the table"        "TABLE_STALE_S"
_src_has "zone applies to every live stream"             '"updated"'
_src_has "front end offers a polygon field"              "roiPoly"
_src_has "front end renders a per-panel table"           "renderPanelAnalytics"
_src_has "apply posts without a peer identifier"         'apiPost("api/zone", { zone: zone })'

echo "== result: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
