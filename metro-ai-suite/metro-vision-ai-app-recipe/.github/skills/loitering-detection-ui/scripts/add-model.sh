#!/usr/bin/env bash
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Install an arbitrary OpenVINO model into a deployment's model store so that the
# Mission Console discovers it and offers it for selection and comparison.
#
# The console is model-agnostic. This script neither knows nor assumes a model
# family: supply any intermediate representation and it becomes selectable.
#
# Usage:
#   add-model.sh --xml <model.xml> --store <model-store-dir> [--name NAME]
#                [--precision FP16|FP32|INT8] [--vendor VENDOR]
#                [--proc <model-proc.json>] [--console-url URL]
#
# The .bin file is taken from alongside the .xml. A model-proc document is copied
# only when supplied; modern intermediate representations describe their output in
# rt_info and do not require one.

set -euo pipefail

XML=""; STORE=""; NAME=""; PREC=""; VENDOR="custom"; PROC=""; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --xml)         shift; XML="${1:-}" ;;
    --store)       shift; STORE="${1:-}" ;;
    --name)        shift; NAME="${1:-}" ;;
    --precision)   shift; PREC="${1:-}" ;;
    --vendor)      shift; VENDOR="${1:-}" ;;
    --proc)        shift; PROC="${1:-}" ;;
    --console-url) shift; URL="${1:-}" ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift || true
done

[ -n "$XML" ]   || { echo "--xml is required" >&2; exit 2; }
[ -n "$STORE" ] || { echo "--store is required" >&2; exit 2; }
[ -f "$XML" ]   || { echo "not found: $XML" >&2; exit 1; }

BIN="${XML%.xml}.bin"
[ -f "$BIN" ] || { echo "sibling .bin not found: $BIN" >&2; exit 1; }

[ -n "$NAME" ] || NAME="$(basename "${XML%.xml}")"
if [ -z "$PREC" ]; then
  PREC="$(basename "$(dirname "$XML")")"
  case "$PREC" in FP16|FP32|INT8|FP16-INT8) ;; *) PREC="FP16" ;; esac
fi

DEST="$STORE/$VENDOR/$NAME/$PREC"
mkdir -p "$DEST"
cp -f "$XML" "$BIN" "$DEST/"
echo "installed: $DEST/$(basename "$XML")"

if [ -n "$PROC" ]; then
  [ -f "$PROC" ] || { echo "not found: $PROC" >&2; exit 1; }
  cp -f "$PROC" "$STORE/$VENDOR/$NAME/$NAME.json"
  echo "installed model-proc: $STORE/$VENDOR/$NAME/$NAME.json"
else
  echo "no model-proc supplied; output layout will be read from rt_info"
fi

if [ -n "$URL" ]; then
  echo "refreshing the console catalogue"
  curl -sk --noproxy '*' "${URL%/}/api/models?refresh=1" \
    | grep -o '"label":"[^"]*"' | sed 's/^/  /' || true
else
  echo "use the refresh control in the console, or call /api/models?refresh=1"
fi
