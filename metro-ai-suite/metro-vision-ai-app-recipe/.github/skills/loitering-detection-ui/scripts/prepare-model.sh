#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# prepare-model.sh - make an OpenVINO IR usable on CPU, GPU and NPU.
#
# An IR exported with fully dynamic spatial dimensions (input shape "?,3,?,?")
# is rejected by the NPU ("upper bounds are not specified") and by the GPU VA
# surface path, and raises per-frame shape-merge errors on CPU, so the pipeline
# decodes at full frame rate while producing no detections.
#
# This script reshapes such an IR to a fixed input size and writes a new IR
# alongside the original. It is model-agnostic: it inspects and rewrites the
# IR only, and does not reference any particular model family.
#
# Usage:
#   ./prepare-model.sh <model.xml> [WIDTH] [HEIGHT] [BATCH]
#
# Defaults: WIDTH=640 HEIGHT=640 BATCH=1
#
# Output: <dir>/<name>_static/<name>.xml (+ .bin)
#
# Requires: python3 with openvino (pip install openvino)
#
# Note on re-export: when the source checkpoint is available, exporting with a
# fixed input size is preferable to reshaping. Consult the exporting
# framework's documentation for its fixed-input-size option, and pin the
# exporter version known to work with your target devices -- some exporter
# releases emit detection heads containing operations that the GPU and NPU
# plugins do not support, regardless of input shape.

set -euo pipefail

XML="${1:-}"
WIDTH="${2:-640}"
HEIGHT="${3:-640}"
BATCH="${4:-1}"

if [[ -z "$XML" || ! -f "$XML" ]]; then
  echo "usage: $0 <model.xml> [WIDTH] [HEIGHT] [BATCH]" >&2
  exit 2
fi

BIN="${XML%.xml}.bin"
if [[ ! -f "$BIN" ]]; then
  echo "error: companion weights not found: $BIN" >&2
  exit 2
fi

DIR="$(cd "$(dirname "$XML")" && pwd)"
NAME="$(basename "${XML%.xml}")"
OUT_DIR="${DIR}/${NAME}_static"

python3 - "$XML" "$OUT_DIR" "$NAME" "$BATCH" "$WIDTH" "$HEIGHT" <<'PY'
import sys, os

xml, out_dir, name, batch, width, height = sys.argv[1:7]
batch, width, height = int(batch), int(width), int(height)

try:
    import openvino as ov
except ImportError:
    sys.exit("error: openvino is not installed. Run: pip install openvino")

core = ov.Core()
model = core.read_model(xml)

inputs = model.inputs
if not inputs:
    sys.exit("error: model exposes no inputs")

shape = inputs[0].get_partial_shape()
print("input shape before: %s" % shape)

if shape.rank.is_dynamic or len(shape) < 4:
    sys.exit("error: expected a 4D input (N,C,H,W); got rank %s" % shape.rank)

if all(shape[i].is_static for i in (2, 3)):
    print("spatial dimensions are already static; no reshape required")
    sys.exit(0)

channels = shape[1].get_length() if shape[1].is_static else 3
target = ov.PartialShape([batch, channels, height, width])
model.reshape({inputs[0]: target})
print("input shape after:  %s" % model.inputs[0].get_partial_shape())

os.makedirs(out_dir, exist_ok=True)
out_xml = os.path.join(out_dir, name + ".xml")
ov.save_model(model, out_xml, compress_to_fp16=False)
print("written: %s" % out_xml)
PY

# Carry over the model-proc sidecar, if the original had one, so the reshaped
# IR is discovered with identical post-processing.
if [[ -f "${DIR}/${NAME}.json" && -d "$OUT_DIR" ]]; then
  cp -f "${DIR}/${NAME}.json" "${OUT_DIR}/${NAME}.json"
  echo "copied model-proc: ${OUT_DIR}/${NAME}.json"
fi

echo
echo "Re-scan the model store from the console (the refresh control beside the"
echo "model selector) to pick up the prepared model."
