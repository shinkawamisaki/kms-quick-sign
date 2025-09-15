# SPDX-License-Identifier: Apache-2.0
#!/usr/bin/env sh
set -eu
DIR="${1:-.}"; cd "$DIR"

: "${AWS_REGION:=$(aws configure get region 2>/dev/null || echo ap-northeast-1)}"
: "${KMS_SIGN_KEY_ID:=alias/evidence-hub-sign}"

# 内容検証
shasum -a 256 -c MANIFEST.sha256

# STAMP と MANIFEST の整合
STAMP_HASH="$(jq -r '.manifest_sha256' STAMP.json)"
CUR_HASH="$(shasum -a 256 MANIFEST.sha256 | awk '{print $1}')"
[ "$STAMP_HASH" = "$CUR_HASH" ] || { echo "STAMP/manifest mismatch"; exit 2; }

# 署名検証（KMS）
cat MANIFEST.sha256 STAMP.json > MANIFEST_STAMP.bundle
VALID="$(aws kms verify --region "$AWS_REGION" --key-id "$KMS_SIGN_KEY_ID" \
  --message-type RAW --signing-algorithm RSASSA_PSS_SHA_256 \
  --message fileb://MANIFEST_STAMP.bundle \
  --signature fileb://MANIFEST_STAMP.bundle.sig \
  --query SignatureValid --output text)"
[ "$VALID" = "True" ] || { echo "Invalid KMS signature"; exit 3; }

echo "Verified: content OK / stamp OK / signature OK"
