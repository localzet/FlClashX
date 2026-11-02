#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vconnect_dir="${VCONNECT_DIR:-${project_dir}/../vconnect}"
output_dir="${project_dir}/android/app/src/main/jniLibs/arm64-v8a"

if [[ ! -f "${vconnect_dir}/relay/go.mod" ]]; then
  echo "VConnect relay source not found at ${vconnect_dir}" >&2
  exit 1
fi

mkdir -p "${output_dir}"
cd "${vconnect_dir}/relay"
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
  -trimpath \
  -ldflags="-s -w" \
  -o "${output_dir}/libusernetrelay.so" \
  .

echo "Built ${output_dir}/libusernetrelay.so"
