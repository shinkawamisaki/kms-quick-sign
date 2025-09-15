## これは何に効く？（使用用途と効果）

> 提出する ZIP やフォルダに 「何を(WHAT) / 誰が(WHO) / いつ(WHEN)」 を1コマンドで刻印。
納品後の“改ざん疑義”や“言った言わない” を未然に潰します。
> 

- **WHAT**: `MANIFEST.sha256`（内容のハッシュ台帳）
- **WHO/WHEN**: `STAMP.json`（署名者ARN・KMS鍵ARN・UTC時刻）
- **SIGN**: `MANIFEST.sha256 + STAMP.json` を**束ねて** KMS（`RSASSA_PSS_SHA_256`）で署名
- **VERIFY**: 受領側は **1コマンド**で「内容一致 / 署名有効 / STAMP整合」を検証

**こんな場面で使う**

- **監査提出物**：設定エクスポート/ログ一式を `MANIFEST+署名+STAMP` で固め、**提出時点の完全性**を主張。
- **客先納品**：仕様書/ソース/レポートに**改ざん検知＋承認者記録**を同梱。差分混入を抑止。
- **SaaS構成のスナップショット保全**：再提出時に“いつ/誰が更新したか”が明確。
- **インシデント証跡**：調査ログの**チェーン・オブ・カストディ**を簡易に確保（必要なら S3 Object Lock）。

**読者の即効メリット**

- **揉めない**：提出後の差し替え/無権限編集を**検知**
- **説明が簡単**：`WHAT/WHO/WHEN` を**ひとかたまりで署名**→監査での説明が楽
- **相手の環境を選ばない**：受領側は **OpenSSLだけ**でも検証可（`KMS_PUBLIC_KEY.pem` 同梱）



## ⚠️ 対象外（このツールが解決しないこと）

- **暗号化（秘匿性）は対象外**：これは**完全性（改ざん検知）**の仕組み。暗号化は別レイヤー（例：SSE-KMS）。
- **アクセス制御/削除防止は対象外**：IAM/権限/WORM(Object Lock) は別設計。
- **真正な時刻証明は対象外**：`STAMP.json` の時刻は署名対象だが、時刻ソース保証は CloudTrail/TSA で補完。
- **鍵ガバナンスは前提**：KMS 鍵の最小権限・削除防止・ローテが崩れると保証も崩れる。
- **意味的正しさは保証しない**：バイト列一致のみ。ウイルス検査/妥当性は別。



## ✅ 前提（macOS / zsh）

- macOS 13/14/15、シェルは zsh
- 利用コマンド: `aws`, `jq`, `openssl`, `shasum`, `base64`
（未導入なら `brew install awscli jq openssl`）



## **🧩 初回だけ：KMS 署名キーを作る（あるなら不要）**

```
AWS_REGION=ap-northeast-1
KEY_ID=$(aws kms create-key \
  --region "$AWS_REGION" \
  --description "Evidence signing key" \
  --key-usage SIGN_VERIFY --key-spec RSA_2048 \
  --query KeyMetadata.KeyId --output text)
aws kms create-alias --region "$AWS_REGION" \
  --alias-name alias/evidence-hub-sign --target-key-id "$KEY_ID"
```

## 🚀 クイックスタート（**カレント直下にシェルを置く**。検証対象は下の test/ など）

> 署名キーは alias/evidence-hub-sign を想定。リージョンは ap-northeast-1（適宜変更）。
ここではスクリプトは カレント直下 に作り、ターゲットディレクトリを引数で渡します。
> 

### 1) MANIFEST 生成用スクリプト作成（WHAT）

```
cat > make_manifest.sh <<'SH'
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
SH
chmod +x make_manifest.sh
```

### **2) STAMP 作成＋BUNDLE 署名**用スクリプト作成**（WHO/WHEN を束ねて KMS 署名）**

```
cat > stamp_and_sign.sh <<'SH'
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
SH
chmod +x stamp_and_sign.sh
```

### **3) 受領側 検証**用スクリプト作成**（内容→STAMP 整合→署名）**

```
cat > verify_bundle.sh <<'SH'
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
SH
chmod +x verify_bundle.sh
```

### **▶ 実行（ターゲットだけ渡す。この3行で完了）**

署名したいファイルをスクリプト直下のフォルダに格納

```
./make_manifest.sh **<フォルダ名>**
KMS_SIGN_KEY_ID=alias/evidence-hub-sign AWS_REGION=ap-northeast-1 ./stamp_and_sign.sh **<フォルダ名>**
./verify_bundle.sh **<フォルダ名>**
```
<img width="605" height="99" alt="スクリーンショット 2025-09-15 15 13 14" src="https://github.com/user-attachments/assets/7d896ff7-8afc-41f1-b231-2418ce881baa" />
<img width="566" height="242" alt="スクリーンショット 2025-09-15 15 13 56" src="https://github.com/user-attachments/assets/19cf4d60-d6c1-4e7b-a963-ebb231723bff" />

---

## **📦 生成物（成果物一覧）**

| **ファイル** | **役割** |
| --- | --- |
| MANIFEST.sha256 | 内容ハッシュ台帳（WHAT） |
| STAMP.json | 署名者ARN / KMS鍵ARN / UTC時刻 / 当時のMANIFESTハッシュ（WHO/WHEN） |
| MANIFEST_STAMP.bundle | MANIFEST.sha256 + STAMP.json の連結（署名対象） |
| MANIFEST_STAMP.bundle.sig(.b64) | KMS署名（RSASSA_PSS_SHA_256） |
| KMS_PUBLIC_KEY.pem | KMS公開鍵（DER→PEM）。OpenSSLでのオフライン検証に使用 |

---
## **🤔 なぜ「束ねて署名」？**

- **ハッシュだけ**＝中身の指紋（WHAT）
- **署名だけ**＝鍵の所有者（WHO）
- **時刻だけ**＝承認時点（WHEN）
    
    → **WHAT/WHO/WHEN をひとかたまりにして署名**することで、
    
    「**この内容を、この人が、この時刻に承認**」を**一体で**主張できます。
    



## **🔒 さらに堅くするなら（任意）**

- **S3 Versioning + Object Lock (Governance)** で保管のすり替え抑止
- **CloudTrail** で Sign/Verify 操作のイベント時刻を外部証跡として残す
- **RFC3161 TSA** を併用すれば暗号学的な時刻証明も付与可能



## **❓FAQ**

**Q. 受領側に AWS が無くても検証できる？**

A. KMS_PUBLIC_KEY.pem があれば **OpenSSL だけ**で検証可能です。

**Q. 改行や順番で誤検知しない？**

A. macOS の find -s で**並び順固定**、-print0 | xargs -0 で**ファイル名安全**。改行は **LF固定** 推奨。

## License
Code: Apache-2.0 © 2025 新川
Docs (this README/Qiita post): CC BY 4.0 推奨（本文転載時は出典明記）

> 本ツールは完全性（改ざん検知）の提供のみで、法的助言ではありません。無保証・自己責任でご利用ください。
