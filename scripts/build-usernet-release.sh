#!/usr/bin/env bash
set -euo pipefail

release_channel="${1:-stable}"
if [[ "$release_channel" != stable ]]; then
  echo 'Usage: build-usernet-release.sh stable' >&2
  exit 2
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_bin="${USERNET_FLUTTER_BIN:-flutter}"
signing_dir="${USERNET_SIGNING_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/usernet}"
password_file="$signing_dir/signing.password"
keystore_file="$signing_dir/usernet-release.p12"
if [[ ! -s "$password_file" || ! -s "$keystore_file" ]]; then
  echo 'Release signing key or password is missing.' >&2
  exit 1
fi

export USERNET_KEYSTORE_FILE="$keystore_file"
export USERNET_SIGNING_PASSWORD="$(<"$password_file")"
export USERNET_SIGNING_ALIAS=usernet
cd "$repo_dir"
"$flutter_bin" build apk --release

version="$(sed -n 's/^version: //p' pubspec.yaml | head -1)"
output_dir="$repo_dir/build/usernet-releases"
mkdir -p "$output_dir"
output="$output_dir/usernet-$release_channel-${version//+/-}.apk"
cp "$repo_dir/build/app/outputs/flutter-apk/app-release.apk" "$output"

apksigner_bin="${USERNET_APKSIGNER_BIN:-$HOME/Android/Sdk/build-tools/36.0.0/apksigner}"
"$apksigner_bin" verify --verbose "$output" >/dev/null
if [[ "$release_channel" == stable ]]; then
  bash "$repo_dir/scripts/check-usernet-public-apk.sh" "$output"
fi
sha256sum "$output"
echo "Release APK: $output"
