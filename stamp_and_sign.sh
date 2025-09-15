# SPDX-License-Identifier: Apache-2.0
#!/usr/bin/env sh
set -eu
DIR="${1:-.}"; cd "$DIR"

: "${AWS_REGION:=$(aws configure get region 2>/dev/null || echo ap-northeast-1)}"
: "${KMS_SIGN_KEY_ID:=alias/evidence-hub-sign}"

[ -f MANIFEST.sha256 ] || { echo "MANIFEST.sha256 がありません。先に make_manifest.sh を実行してください" >&2; exit 1; }

KEY_META_JSON="$(aws kms describe-key --region "$AWS_REGION" --key-id "$KMS_SIGN_KEY_ID")"
KEY_ARN="$(echo "$KEY_META_JSON" | jq -r '.KeyMetadata.Arn')"
CALLER_JSON="$(aws sts get-caller-identity)"
ACCOUNT_ID="$(echo "$CALLER_JSON" | jq -r '.Account')"
SIGNER_ARN="$(echo "$CALLER_JSON" | jq -r '.Arn')"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MANIFEST_HASH="$(shasum -a 256 MANIFEST.sha256 | awk '{print $1}')"

cat > STAMP.json <<JSON
{"ts":"$TS","region":"$AWS_REGION","kms_key_arn":"$KEY_ARN",
 "aws_account":"$ACCOUNT_ID","signer_arn":"$SIGNER_ARN",
 "manifest_sha256":"$MANIFEST_HASH",
 "bundle_spec":"cat MANIFEST.sha256 + STAMP.json (UTF-8) in this order"}
JSON

cat MANIFEST.sha256 STAMP.json > MANIFEST_STAMP.bundle

SIG_B64="$(aws kms sign --region "$AWS_REGION" --key-id "$KMS_SIGN_KEY_ID" \
  --message-type RAW --signing-algorithm RSASSA_PSS_SHA_256 \
  --message fileb://MANIFEST_STAMP.bundle --query Signature --output text)"
printf '%s\n' "$SIG_B64" > MANIFEST_STAMP.bundle.sig.b64
base64 -D -i MANIFEST_STAMP.bundle.sig.b64 -o MANIFEST_STAMP.bundle.sig

aws kms get-public-key --region "$AWS_REGION" --key-id "$KMS_SIGN_KEY_ID" \
  --query PublicKey --output text | base64 -D -o /tmp/kpub.der
openssl pkey -pubin -inform DER -in /tmp/kpub.der -out KMS_PUBLIC_KEY.pem
rm -f /tmp/kpub.der

echo "STAMP.json / MANIFEST_STAMP.bundle(.sig/.b64) / KMS_PUBLIC_KEY.pem created."
