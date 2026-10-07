#!/usr/bin/env bash
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Emit the container and compose plumbing for the console addon.
#
# This script deliberately does NOT emit any dashboard code. The backend
# modules, markup, stylesheet and controller are generated from the
# specifications in references/. Only deployment plumbing is templated here,
# because it carries no appearance or behaviour, and because hand-generating it
# has repeatedly failed on two counts:
#
#   * the .env JSON values lose their quoting (Docker Compose strips unescaped
#     double quotes from unquoted values, silently emptying SOURCES_JSON);
#   * every generated line is a chance for a truncated or rejected write.
#
# Usage:
#   scaffold.sh --addon-dir DIR --network NAME --host-ip IP [options]
#
# Options (defaults in brackets):
#   --console-port N        published TLS port                        [9443]
#   --model-store PATH      model root inside the pipeline server     [/home/pipeline-server/models]
#   --model-store-host PATH host path bound to the model root         [required]
#   --pipeline-url URL      pipeline server REST base                 [http://dlstreamer-pipeline-server:8080]
#   --broker HOST:PORT      MQTT broker                               [broker:1883]
#   --mediamtx URL          MediaMTX WHEP base                        [http://mediamtx-server:8889]
#   --prometheus URL        Prometheus base                           [http://prometheus:9090]
#   --devices CSV           target devices                            [CPU]
#   --zone X,Y,W,H          default zone rectangle                    [100,300,400,500]
#   --loiter-threshold S    dwell seconds before a loiter is counted  [3.0]
#   --vacancy-grace S       zone vacancy tolerated before dwell resets      [3.0]
#   --track-ttl S           track retention                                [30.0]
#   --topic-prefix P        detection topic prefix                    [object_tracking]
#   --sources-json JSON     source catalogue, a JSON array            [[]]
set -euo pipefail

ADDON_DIR=""; NETWORK=""; HOST_IP=""
CONSOLE_PORT=9443
MODEL_STORE=/home/pipeline-server/models
MODEL_STORE_HOST=""
PIPELINE_URL=http://dlstreamer-pipeline-server:8080
BROKER=broker:1883
MEDIAMTX=http://mediamtx-server:8889
PROMETHEUS=http://prometheus:9090
DEVICES=CPU
ZONE=100,300,400,500
LOITER=3.0
GRACE=3.0
TTL=30.0
TOPIC_PREFIX=object_tracking
SOURCES_JSON='[]'

while [ $# -gt 0 ]; do
  case "$1" in
    --addon-dir) ADDON_DIR=$2; shift 2;;
    --network) NETWORK=$2; shift 2;;
    --host-ip) HOST_IP=$2; shift 2;;
    --console-port) CONSOLE_PORT=$2; shift 2;;
    --model-store) MODEL_STORE=$2; shift 2;;
    --model-store-host) MODEL_STORE_HOST=$2; shift 2;;
    --pipeline-url) PIPELINE_URL=$2; shift 2;;
    --broker) BROKER=$2; shift 2;;
    --mediamtx) MEDIAMTX=$2; shift 2;;
    --prometheus) PROMETHEUS=$2; shift 2;;
    --devices) DEVICES=$2; shift 2;;
    --zone) ZONE=$2; shift 2;;
    --loiter-threshold) LOITER=$2; shift 2;;
    --vacancy-grace) GRACE=$2; shift 2;;
    --track-ttl) TTL=$2; shift 2;;
    --topic-prefix) TOPIC_PREFIX=$2; shift 2;;
    --sources-json) SOURCES_JSON=$2; shift 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

for v in ADDON_DIR NETWORK HOST_IP MODEL_STORE_HOST; do
  [ -n "${!v}" ] || { echo "--${v,,} is required" | tr '_' '-' >&2; exit 2; }
done

# Refuse to clobber a deployment. Plumbing is rewritten only when absent or
# when the caller has removed it deliberately.
mkdir -p "$ADDON_DIR/console/templates" "$ADDON_DIR/console/static" "$ADDON_DIR/console/certs"

w() { # w <path>  -- write stdin only if the file does not already exist
  if [ -e "$1" ]; then echo "  keep  $1"; cat >/dev/null; else cat >"$1"; echo "  write $1"; fi
}

w "$ADDON_DIR/console/requirements.txt" <<'EOF'
Flask==3.1.0
requests==2.32.3
paho-mqtt==2.1.0
EOF

w "$ADDON_DIR/console/entrypoint.sh" <<'EOF'
#!/bin/sh
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
set -e
CERT_DIR=${CERT_DIR:-/app/certs}
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/console.crt" ] || [ ! -f "$CERT_DIR/console.key" ]; then
    echo "issuing a self-signed certificate for the console"
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout "$CERT_DIR/console.key" -out "$CERT_DIR/console.crt" \
        -subj "/CN=${HOST_IP:-console}" \
        -addext "subjectAltName=IP:${HOST_IP:-127.0.0.1},DNS:localhost" 2>/dev/null
fi
exec python3 -u /app/app.py
EOF
chmod +x "$ADDON_DIR/console/entrypoint.sh" 2>/dev/null || true

w "$ADDON_DIR/console/Dockerfile" <<'EOF'
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY *.py /app/
COPY templates /app/templates
COPY static /app/static
COPY entrypoint.sh /app/entrypoint.sh
RUN mkdir -p /app/certs && chmod +x /app/entrypoint.sh

RUN useradd -r -u 10001 -m console && chown -R console:console /app
USER console

ENTRYPOINT ["/app/entrypoint.sh"]
EOF

w "$ADDON_DIR/compose.console.yml" <<'EOF'
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# The console addon. It joins the application's network as an external network
# and publishes its own TLS port, so no application file is modified.
services:
  console:
    build:
      context: ./console
      dockerfile: Dockerfile
    image: mission-console:latest
    container_name: mission-console
    restart: unless-stopped
    ports:
      - "${CONSOLE_PORT}:${CONSOLE_PORT}"
    environment:
      - UI_PORT=${CONSOLE_PORT}
      - HOST_IP=${HOST_IP}
      - PIPELINE_SERVER_URL=${PIPELINE_SERVER_URL}
      - MQTT_HOST=${MQTT_HOST}
      - MQTT_PORT=${MQTT_PORT}
      - MEDIAMTX_URL=${MEDIAMTX_URL}
      - PROMETHEUS_URL=${PROMETHEUS_URL}
      - MODEL_ROOT=${MODEL_ROOT}
      - DEVICES=${DEVICES}
      - DEFAULT_ZONE=${DEFAULT_ZONE}
      - LOITER_THRESHOLD_S=${LOITER_THRESHOLD_S}
      - ZONE_VACANT_GRACE_S=${ZONE_VACANT_GRACE_S}
      - TRACK_TTL_S=${TRACK_TTL_S}
      - DETECTIONS_TOPIC_PREFIX=${DETECTIONS_TOPIC_PREFIX}
      - SOURCES_JSON=${SOURCES_JSON}
      # The console talks only to services on this network. Docker injects the
      # host's proxy settings, whose bypass list does not contain Docker
      # service names, so every in-network call is sent to the proxy and fails
      # with 504. Neutralise it and bypass explicitly.
      - http_proxy=
      - https_proxy=
      - HTTP_PROXY=
      - HTTPS_PROXY=
      - no_proxy=${NO_PROXY_LIST}
      - NO_PROXY=${NO_PROXY_LIST}
    volumes:
      - ${MODEL_STORE_HOST}:${MODEL_ROOT}:ro
    networks:
      - app_network

networks:
  app_network:
    name: ${APP_NETWORK}
    external: true
EOF

# Hostnames of every service the console contacts, so the bypass list is
# correct regardless of how the deployment names them.
_host_of() { printf '%s' "$1" | sed -E 's#^[a-z]+://##; s#[:/].*$##'; }
NO_PROXY_LIST="localhost,127.0.0.1,::1"
for _u in "$PIPELINE_URL" "$MEDIAMTX" "$PROMETHEUS"; do
  _h="$(_host_of "$_u")"; [ -n "$_h" ] && NO_PROXY_LIST="$NO_PROXY_LIST,$_h"
done
_b="${BROKER%%:*}"; [ -n "$_b" ] && NO_PROXY_LIST="$NO_PROXY_LIST,$_b"
NO_PROXY_LIST="$NO_PROXY_LIST,$HOST_IP"

# .env -- JSON values are wrapped in SINGLE quotes. Docker Compose honours a
# leading and trailing quote and leaves the interior untouched; an unquoted
# value loses its double quotes, which silently empties the catalogue.
ENV_FILE="$ADDON_DIR/.env"
if [ -e "$ENV_FILE" ]; then
  echo "  keep  $ENV_FILE"
else
  cat >"$ENV_FILE" <<EOF
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
CONSOLE_PORT=$CONSOLE_PORT
HOST_IP=$HOST_IP
APP_NETWORK=$NETWORK
PIPELINE_SERVER_URL=$PIPELINE_URL
MQTT_HOST=${BROKER%%:*}
MQTT_PORT=${BROKER##*:}
MEDIAMTX_URL=$MEDIAMTX
PROMETHEUS_URL=$PROMETHEUS
MODEL_ROOT=$MODEL_STORE
MODEL_STORE_HOST=$MODEL_STORE_HOST
DEVICES=$DEVICES
DEFAULT_ZONE=$ZONE
LOITER_THRESHOLD_S=$LOITER
ZONE_VACANT_GRACE_S=$GRACE
TRACK_TTL_S=$TTL
DETECTIONS_TOPIC_PREFIX=$TOPIC_PREFIX
NO_PROXY_LIST=$NO_PROXY_LIST
SOURCES_JSON='$SOURCES_JSON'
EOF
  echo "  write $ENV_FILE"
fi

echo
echo "plumbing ready under $ADDON_DIR"
echo "model store: $MODEL_STORE_HOST -> $MODEL_STORE (read only)"
