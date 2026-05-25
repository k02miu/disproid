#!/usr/bin/env bash
#
# Disproid Helper 用の自己署名コード署名証明書を login キーチェーンに作成する（冪等）。
#
# これで署名 ID が再ビルド後も固定され、macOS の「画面収録」許可が維持される
# （ad-hoc 署名だと再ビルドのたびに別アプリ扱いになり許可がリセットされる）。
#
# 一度だけ実行すればよい。証明書は自己署名のため Gatekeeper の「開発元未確認」警告は残る
# （配布時は Apple Developer ID 署名＋公証が別途必要）。
#
set -euo pipefail

CERT_NAME="Disproid Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
PW="disproid"

if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "証明書 '$CERT_NAME' は既に存在します。"
    exit 0
fi

TMP="$(mktemp -d)"
cat > "$TMP/c.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$CERT_NAME
[v3]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/k.pem" -out "$TMP/c.pem" -config "$TMP/c.cnf" >/dev/null 2>&1
# macOS の security が読める legacy 形式の PKCS12
openssl pkcs12 -export -legacy -inkey "$TMP/k.pem" -in "$TMP/c.pem" \
    -out "$TMP/c.p12" -passout "pass:$PW" -name "$CERT_NAME" >/dev/null 2>&1
# codesign が鍵を非対話で使えるよう -A -T を付けてインポート
security import "$TMP/c.p12" -k "$KEYCHAIN" -P "$PW" -A -T /usr/bin/codesign
rm -rf "$TMP"

echo "証明書 '$CERT_NAME' を作成しました（自己署名・未trust。codesign では使用可能）。"
