#!/usr/bin/env bash
set -euo pipefail

apk="${1:-}"
if [[ -z "$apk" || ! -f "$apk" ]]; then
  echo 'Usage: check-usernet-public-apk.sh APK' >&2
  exit 2
fi

android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -n "${USERNET_AAPT_BIN:-}" ]]; then
  aapt_bin="$USERNET_AAPT_BIN"
elif [[ -n "$android_sdk" ]]; then
  aapt_bin="$android_sdk/build-tools/36.0.0/aapt"
else
  echo 'Set USERNET_AAPT_BIN or ANDROID_HOME to inspect the APK.' >&2
  exit 2
fi
package_name="$("$aapt_bin" dump badging "$apk" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)"
if [[ "$package_name" != com.userlay.usernet ]]; then
  echo 'Refusing to publish an APK with the wrong application ID.' >&2
  exit 1
fi

if unzip -p "$apk" lib/arm64-v8a/libapp.so | strings | \
    grep -Eq 'eyJhbGciOi|-----BEGIN PRIVATE KEY-----'; then
  echo 'Refusing to publish an APK containing private key material.' >&2
  exit 1
fi

echo 'Public APK package and marker checks passed.'
