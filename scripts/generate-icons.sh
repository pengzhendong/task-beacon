#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
cd "$root_dir"
swift -module-cache-path "${TMPDIR:-/tmp}/taskbeacon-icon-module-cache" \
  scripts/export-icon.swift Assets/TaskBeacon.source.png Assets/TaskBeacon.png

scratch_dir="$(mktemp -d /tmp/taskbeacon-icons.XXXXXX)"
iconset_dir="$scratch_dir/TaskBeacon.iconset"
mkdir -p "$iconset_dir"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Assets/TaskBeacon.png \
    --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" Assets/TaskBeacon.png \
    --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o Resources/TaskBeacon.icns
echo "Created Resources/TaskBeacon.icns"
