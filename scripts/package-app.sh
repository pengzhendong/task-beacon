#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
output_dir="${1:-${root_dir}/dist}"
app_dir="${output_dir}/TaskBeacon.app"
version="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${root_dir}/Resources/Info.plist")}"
build_number="${BUILD_NUMBER:-1}"
signing_identity="${CODE_SIGN_IDENTITY:--}"

cd "${root_dir}"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"

mkdir -p "${app_dir}/Contents/MacOS"
mkdir -p "${app_dir}/Contents/Helpers"
mkdir -p "${app_dir}/Contents/Resources/bin"
mkdir -p "${app_dir}/Contents/Frameworks"
cp "${binary_dir}/TaskBeaconMenu" "${app_dir}/Contents/MacOS/TaskBeaconMenu"
cp "${binary_dir}/taskbeacond" "${app_dir}/Contents/Helpers/taskbeacond"
cp "${binary_dir}/taskbeacon" "${app_dir}/Contents/Resources/bin/taskbeacon"
cp "${binary_dir}/taskbeacon-mcp" "${app_dir}/Contents/Resources/bin/taskbeacon-mcp"
cp "${root_dir}/Resources/Info.plist" "${app_dir}/Contents/Info.plist"
cp "${root_dir}/Resources/TaskBeacon.icns" "${app_dir}/Contents/Resources/TaskBeacon.icns"
cp "${root_dir}/Resources/TaskBeaconStatus.png" "${app_dir}/Contents/Resources/TaskBeaconStatus.png"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version}" "${app_dir}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${build_number}" "${app_dir}/Contents/Info.plist"

sparkle_framework="$(find "${root_dir}/.build/artifacts" -type d -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' -print -quit)"
if [[ -z "${sparkle_framework}" ]]; then
  echo "Sparkle.framework was not found in SwiftPM artifacts" >&2
  exit 1
fi
ditto "${sparkle_framework}" "${app_dir}/Contents/Frameworks/Sparkle.framework"

sign_args=(--force --sign "${signing_identity}")
if [[ "${signing_identity}" != "-" ]]; then
  sign_args+=(--options runtime --timestamp)
fi
# Executables stored under Resources are not discovered by codesign --deep.
# Sign our three helpers explicitly, then the nested framework and app bundle.
for helper in \
  "${app_dir}/Contents/Helpers/taskbeacond" \
  "${app_dir}/Contents/Resources/bin/taskbeacon" \
  "${app_dir}/Contents/Resources/bin/taskbeacon-mcp"; do
  codesign "${sign_args[@]}" "$helper"
done
codesign "${sign_args[@]}" --deep "${app_dir}/Contents/Frameworks/Sparkle.framework"
codesign "${sign_args[@]}" "${app_dir}"
echo "Created ${app_dir}"
