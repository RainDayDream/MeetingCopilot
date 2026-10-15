#!/bin/bash
# 在登录钥匙串中创建一个本地自签名“代码签名”证书，供 build.sh 使用。
# 作用：让每次构建的签名身份保持不变，macOS 才不会反复要求重新授权。证书只存在你本机。
set -euo pipefail
NAME="MeetingCopilot Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then echo "证书已存在"; exit 0; fi
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/c.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/k.pem" -out "$D/c.pem" -days 3650 -config "$D/c.cnf" 2>/dev/null
PW=$(openssl rand -hex 8)
openssl pkcs12 -export -inkey "$D/k.pem" -in "$D/c.pem" -out "$D/c.p12" -passout "pass:$PW" -legacy
security import "$D/c.p12" -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
echo "已创建证书：$NAME"
