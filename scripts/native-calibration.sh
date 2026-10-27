#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Native calibration requires macOS with Xcode command line tools. No CPU fallback is used." >&2
  exit 1
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_binary="$(mktemp -t camera18-calibration)"
trap 'rm -f "$task_binary"' EXIT
xcrun swiftc -swift-version 5 -DCAMERA18_CALIBRATION -parse-as-library \
  "$task_root/modules/camera-engine/ios/CameraProfileRenderer.swift" \
  "$task_root/tools/native-calibration/main.swift" \
  -o "$task_binary" -framework CoreImage -framework Metal -framework ImageIO
"$task_binary" "$@"
