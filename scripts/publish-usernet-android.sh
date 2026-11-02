#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo 'Usage: publish-usernet-android.sh stable VERSION BUILD APK [NOTES]' >&2
  exit 2
fi
channel="$1"
version="$2"
build="$3"
apk="$4"
notes="${5:-UserNet update}"

if [[ "$channel" != stable ]]; then
  echo 'Only the stable channel is supported.' >&2
  exit 2
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ||
      ! "$build" =~ ^[0-9]+$ || ! -f "$apk" ]]; then
  echo 'Invalid version, build number, or missing APK.' >&2
  exit 2
fi

remote_host="${USERNET_RELEASE_HOST:-}"
remote_dir="${USERNET_RELEASE_DIR:-}"
if [[ ! "$remote_host" =~ ^[A-Za-z0-9._@-]+$ ]]; then
  echo 'Set USERNET_RELEASE_HOST in the private deployment environment.' >&2
  exit 2
fi
if [[ ! "$remote_dir" =~ ^/[a-zA-Z0-9_./-]+$ || "$remote_dir" == / ]]; then
  echo 'Set USERNET_RELEASE_DIR to the updates server android directory.' >&2
  exit 2
fi

file_name="usernet-$channel-$version-$build.apk"
digest="$(sha256sum "$apk" | cut -d ' ' -f1)"
url="https://updates.userlay.com/android/$file_name"
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
jq -n --arg version "$version" --argjson build "$build" \
  --arg notes "$notes" --arg apkUrl "$url" --arg sha256 "$digest" \
  '{version:$version,build:$build,notes:$notes,apkUrl:$apkUrl,sha256:$sha256}' \
  > "$manifest"

ssh "$remote_host" "mkdir -p '$remote_dir' && test ! -e '$remote_dir/$file_name'"
scp "$apk" "$remote_host:$remote_dir/$file_name.uploading"
ssh "$remote_host" "mv '$remote_dir/$file_name.uploading' '$remote_dir/$file_name'"
ssh "$remote_host" "chmod 0644 '$remote_dir/$file_name'"
scp "$manifest" "$remote_host:$remote_dir/$channel.json.uploading"
ssh "$remote_host" "mv '$remote_dir/$channel.json.uploading' '$remote_dir/$channel.json'"
ssh "$remote_host" "chmod 0644 '$remote_dir/$channel.json'"
curl --fail --silent --show-error "https://updates.userlay.com/android/$channel.json" \
  | jq -e --arg sha256 "$digest" '.sha256 == $sha256' >/dev/null
echo "Published $url"
