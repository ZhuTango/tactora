#!/bin/bash
# Local use only: --prepare does not change Keychain or trust settings.
set -euo pipefail
umask 077
signing_dir="$HOME/Library/Application Support/Light Tools Signing"
mkdir -p "$signing_dir"
chmod 700 "$signing_dir"
case "${1:-}" in
  --prepare)
    if [[ -f "$signing_dir/identity.sha1" ]]; then
      echo 'A signing identity is already configured; it will not be replaced.'
      exit 0
    fi
    if [[ ! -f "$signing_dir/identity.p12" ]]; then
      cat > "$signing_dir/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = name
x509_extensions = extensions
prompt = no
[name]
CN = Light Tools Local Development
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
      openssl rand -hex 32 > "$signing_dir/import-password"
      openssl req -new -x509 -newkey rsa:3072 -nodes -days 3650 \
        -config "$signing_dir/certificate.cnf" -keyout "$signing_dir/private.key" \
        -out "$signing_dir/certificate.pem" 2> "$signing_dir/generation.log"
      openssl pkcs12 -export -inkey "$signing_dir/private.key" -in "$signing_dir/certificate.pem" \
        -out "$signing_dir/identity.p12" -passout "file:$signing_dir/import-password"
      rm "$signing_dir/private.key"
    fi
    openssl x509 -in "$signing_dir/certificate.pem" -noout -subject -dates -fingerprint -sha256
    echo 'Prepared only. --install imports into the login keychain and trusts this certificate for code signing only.'
    ;;
  --install)
    if [[ -f "$signing_dir/identity.sha1" ]]; then
      fingerprint=$(cat "$signing_dir/identity.sha1")
      security find-identity -v -p codesigning | grep -F "$fingerprint" >/dev/null || {
        echo 'Configured identity is missing or invalid; restore it rather than generating a new identity.' >&2
        exit 1
      }
      echo 'Stable signing identity already installed.'
      exit 0
    fi
    [[ -f "$signing_dir/identity.p12" ]] || { echo 'Run --prepare first.' >&2; exit 1; }
    login_keychain="$HOME/Library/Keychains/login.keychain-db"
    security import "$signing_dir/identity.p12" -k "$login_keychain" \
      -P "$(cat "$signing_dir/import-password")" -T /usr/bin/codesign
    # User-domain trust, restricted to code signing, never SSL or system-wide trust.
    security add-trusted-cert -r trustRoot -p codeSign -k "$login_keychain" "$signing_dir/certificate.pem"
    fingerprint=$(openssl x509 -in "$signing_dir/certificate.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
    security find-identity -v -p codesigning "$login_keychain" | grep -F "$fingerprint" >/dev/null
    printf '%s\n' "$fingerprint" > "$signing_dir/identity.sha1"
    rm "$signing_dir/identity.p12" "$signing_dir/import-password"
    echo 'Stable local identity installed. Future builds reuse it; do not regenerate it.'
    ;;
  *) echo 'Usage: setup-local-signing.sh --prepare | --install' >&2; exit 2 ;;
esac
