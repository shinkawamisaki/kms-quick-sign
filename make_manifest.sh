# SPDX-License-Identifier: Apache-2.0
#!/usr/bin/env sh
set -eu
DIR="${1:-.}"; cd "$DIR"
TMP="$(mktemp)"
find -s . -type f \
  ! -name 'MANIFEST.sha256' \
  ! -name 'MANIFEST.sha256.sig' \
  ! -name 'MANIFEST.sha256.sig.b64' \
  ! -name 'KMS_PUBLIC_KEY.pem' \
  ! -name 'STAMP.json' \
  ! -name 'MANIFEST_STAMP.bundle' \
  ! -name 'MANIFEST_STAMP.bundle.sig' \
  ! -name 'MANIFEST_STAMP.bundle.sig.b64' \
  ! -name '.DS_Store' -print0 > "$TMP"
: > MANIFEST.sha256
[ -s "$TMP" ] && xargs -0 shasum -a 256 < "$TMP" > MANIFEST.sha256
rm -f "$TMP"; echo "MANIFEST.sha256 created."
