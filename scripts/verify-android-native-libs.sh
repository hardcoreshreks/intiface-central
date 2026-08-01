#!/usr/bin/env bash
#
# Verifies that Android release artifacts carry a complete set of native
# libraries for every ABI they advertise.
#
# Android infers supported ABIs from which lib/<abi>/ directories exist, so a
# partially populated one is worse than none at all: the platform installs that
# ABI and then dies on UnsatisfiedLinkError. Both intiface-central#262 (no Rust
# library at all) and #256 (x86_64 populated only by transitive AARs) were this
# failure, so check every library the app cannot start without.

set -euo pipefail

REQUIRED_LIBS=("librust_lib_intiface_central.so" "libapp.so" "libflutter.so")
ABIS=("armeabi-v7a" "arm64-v8a" "x86_64")

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
    for lib in "${REQUIRED_LIBS[@]}"; do
      if grep -qx "${prefix}lib/${abi}/${lib}" <<<"$contents"; then
        echo "ok: $archive contains ${abi}/${lib}"
      else
        echo "FAIL: $archive is missing ${prefix}lib/${abi}/${lib}" >&2
        failed=1
      fi
    done
  done

  # Any ABI directory outside the supported set is advertised support the app
  # cannot honour, which is what broke ChromeOS installs in #256.
  local unexpected
  unexpected="$(sed -n "s|^${prefix}lib/\([^/]*\)/.*|\1|p" <<<"$contents" \
    | sort -u \
    | grep -vxF "$(printf '%s\n' "${ABIS[@]}")" || true)"

  if [ -n "$unexpected" ]; then
    echo "FAIL: $archive advertises unsupported ABIs: $(tr '\n' ' ' <<<"$unexpected")" >&2
    failed=1
  fi
}

verify "$APK" ""
verify "$AAB" "base/"

exit "$failed"
