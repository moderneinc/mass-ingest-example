#!/bin/bash
set -euo pipefail

# Azure Batch processor task: loads publish.sh credentials from Key Vault with the pool identity, then runs publish.sh (see README).

KEY_VAULT_API_VERSION="7.4"
KEY_VAULT_RESOURCE="https://vault.azure.net"

info() { printf 'task: %s\n' "$1"; }
die() { printf 'task: %s\n' "$1" >&2; exit 1; }

imds_token() {
  local url="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$1"
  if [ -n "${AZURE_CLIENT_ID:-}" ]; then
    url="${url}&client_id=${AZURE_CLIENT_ID}"
  fi
  curl -sS -f -H 'Metadata: true' "$url" | jq -r '.access_token // empty'
}

# load_secret SECRET_NAME ENV_VAR
load_secret() {
  local secret_name=$1 var_name=$2 body_file http_code
  if [ -n "${!var_name:-}" ]; then
    info "$var_name already set, not reading $secret_name from Key Vault"
    return
  fi
  body_file=$(mktemp)
  http_code=$(curl -sS -o "$body_file" -w '%{http_code}' \
    -H "Authorization: Bearer $KEY_VAULT_TOKEN" \
    "${KEY_VAULT_URI%/}/secrets/${secret_name}?api-version=${KEY_VAULT_API_VERSION}")
  case "$http_code" in
    200)
      export "$var_name=$(jq -r '.value' "$body_file")"
      info "Loaded $var_name from Key Vault secret $secret_name"
      ;;
    404)
      info "Key Vault secret $secret_name not found, $var_name left unset"
      ;;
    401|403)
      die "Access denied reading Key Vault secret $secret_name (HTTP $http_code). Grant the pool identity secret read access (access policy Get, or the 'Key Vault Secrets User' role): $(cat "$body_file")"
      ;;
    *)
      die "Reading Key Vault secret $secret_name failed (HTTP $http_code): $(cat "$body_file")"
      ;;
  esac
  rm -f "$body_file"
}

main() {
  if [ -z "${KEY_VAULT_URI:-}" ]; then
    info "KEY_VAULT_URI is not set, expecting credentials in the environment"
  else
    KEY_VAULT_TOKEN=$(imds_token "$KEY_VAULT_RESOURCE") || die "Could not get a Key Vault token from IMDS for identity ${AZURE_CLIENT_ID:-<default>}"
    [ -n "$KEY_VAULT_TOKEN" ] || die "IMDS returned an empty Key Vault token"
    load_secret moderne-token    MODERNE_TOKEN
    load_secret git-credentials  GIT_CREDENTIALS
    load_secret ssh-private-key  GIT_SSH_CREDENTIALS
    load_secret publish-user     PUBLISH_USER
    load_secret publish-password PUBLISH_PASSWORD
    load_secret publish-token    PUBLISH_TOKEN
  fi

  exec /app/publish.sh "$@"
}

main "$@"
