#!/usr/bin/env bash
#
# Verifies that Android release artifacts actually contain the Rust native
# library for every shipped ABI. See intiface-central#262: a build ordering bug
# silently produced an APK with no librust_lib_intiface_central.so, which
# crashed on startup.

set -euo pipefail

LIB_NAME="librust_lib_intiface_central.so"
ABIS=("armeabi-v7a" "arm64-v8a")

APK="build/app/outputs/flutter-apk/app-release.apk"
AAB="build/app/outputs/bundle/release/app-release.aab"

failed=0

verify() {
  local archive="$1"
  local prefix="$2"

  if [ ! -f "$archive" ]; then
    echo "Missing artifact: $archive" >&2
    failed=1
    return
  fi

  local contents
  contents="$(unzip -Z1 "$archive")"

  for abi in "${ABIS[@]}"; do
    if grep -qx "${prefix}lib/${abi}/${LIB_NAME}" <<<"$contents"; then
      echo "ok: $archive contains ${abi}/${LIB_NAME}"
    else
      echo "FAIL: $archive is missing ${prefix}lib/${abi}/${LIB_NAME}" >&2
      failed=1
    fi
  done
}

verify "$APK" ""
verify "$AAB" "base/"

exit "$failed"
