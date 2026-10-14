#!/bin/bash
set -euo pipefail
umask 077
COPILOT_SIGNING_DIR="$HOME/Library/Application Support/InterviewCopilot/Signing"
COPILOT_CERTIFICATE="$COPILOT_SIGNING_DIR/identity.pem"
COPILOT_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [ "${1:-}" = "--setup" ]; then
    if [ -f "$COPILOT_CERTIFICATE" ]; then
        printf '%s\n' "Сертификат уже создан: $COPILOT_CERTIFICATE"
        exit 0
    fi
    mkdir -p "$COPILOT_SIGNING_DIR"
    COPILOT_SIGNING_TEMP="$(mktemp -d "$COPILOT_SIGNING_DIR/setup.XXXXXX")"
    trap 'rm -rf "$COPILOT_SIGNING_TEMP"' EXIT
    cat > "$COPILOT_SIGNING_TEMP/certificate.conf" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = Whislet Local Signing
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
    /usr/bin/openssl genrsa -out "$COPILOT_SIGNING_TEMP/private.pem" 3072 \
        2> "$COPILOT_SIGNING_TEMP/openssl.log"
    /usr/bin/openssl req -new -x509 -sha256 -days 3650 \
        -config "$COPILOT_SIGNING_TEMP/certificate.conf" -key "$COPILOT_SIGNING_TEMP/private.pem" \
        -out "$COPILOT_SIGNING_TEMP/identity.pem" 2> "$COPILOT_SIGNING_TEMP/openssl.log"
    /usr/bin/security import "$COPILOT_SIGNING_TEMP/private.pem" \
        -k "$COPILOT_KEYCHAIN" -f openssl -t priv -x -T /usr/bin/codesign
    /usr/bin/security import "$COPILOT_SIGNING_TEMP/identity.pem" \
        -k "$COPILOT_KEYCHAIN" -t cert
    cp "$COPILOT_SIGNING_TEMP/identity.pem" "$COPILOT_CERTIFICATE"
    printf '%s\n' "Локальный сертификат создан; закрытый ключ хранится в Keychain."
    exit 0
fi

if [ "$#" -ne 1 ] || [ ! -d "$1/Contents" ]; then
    printf '%s\n' "Использование: bash scripts/sign-app.sh <приложение.app> или --setup" >&2
    exit 1
fi
if [ ! -f "$COPILOT_CERTIFICATE" ]; then
    /usr/bin/codesign --force --sign - --timestamp=none --identifier local.interviewcopilot "$1"
    /usr/bin/codesign --verify --deep --strict "$1"
    printf '%s\n' "Применена ad-hoc подпись. Для постоянных разрешений: bash scripts/sign-app.sh --setup"
    exit 0
fi
COPILOT_IDENTITY="$(/usr/bin/openssl x509 -in "$COPILOT_CERTIFICATE" -noout -fingerprint -sha1 | sed 's/.*=//;s/://g')"
if [[ ! "$COPILOT_IDENTITY" =~ ^[0-9A-F]{40}$ ]]; then
    printf '%s\n' "Не удалось прочитать сертификат подписи" >&2
    exit 1
fi
COPILOT_REQUIREMENT="identifier \"local.interviewcopilot\" and certificate leaf = H\"$COPILOT_IDENTITY\""
/usr/bin/codesign --force --sign "$COPILOT_IDENTITY" --keychain "$COPILOT_KEYCHAIN" \
    --timestamp=none --identifier local.interviewcopilot \
    --requirements "=designated => $COPILOT_REQUIREMENT" "$1"
/usr/bin/codesign --verify --deep --strict --test-requirement "=$COPILOT_REQUIREMENT" "$1"
