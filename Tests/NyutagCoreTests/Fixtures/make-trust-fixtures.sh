#!/bin/sh
# Перегенерация DER-фикстур для TransportTests (нужен системный openssl; запуск из этой папки).
# Ключи одноразовые и нигде не хранятся: тестам нужны только сертификаты.
# Корни 36500 дней; листья 397 дней: Apple отвергает лист дольше 398 дней и у своего якоря. Протухание обходится датой проверки (verifyDate) в тестах. Публичная цепочка public-chain-*.der снимается отдельно (см. TransportTests).
set -eu
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

ca() { # имя, CN
  openssl ecparam -name prime256v1 -genkey -noout -out "$T/$1.key"
  openssl req -x509 -new -key "$T/$1.key" -sha256 -days 36500 -subj "/CN=$2/O=Nyutag Test" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$T/$1.pem"
  openssl x509 -in "$T/$1.pem" -outform DER -out "$1.der"
}
leaf() { # CA, имя файла, хост
  openssl ecparam -name prime256v1 -genkey -noout -out "$T/$2.key"
  openssl req -new -key "$T/$2.key" -subj "/CN=$3" -out "$T/$2.csr"
  printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\n" "$3" > "$T/$2.ext"
  openssl x509 -req -in "$T/$2.csr" -CA "$T/$1.pem" -CAkey "$T/$1.key" -CAcreateserial -sha256 -days 397 \
    -extfile "$T/$2.ext" -outform DER -out "$2.der"
}

ca test-ca "Nyutag Test CA"
ca other-ca "Other Test CA"
leaf test-ca leaf-good core.test.nyutag
leaf other-ca leaf-foreign-root core.test.nyutag
leaf test-ca leaf-other-host elsewhere.test.nyutag
