#!/usr/bin/env bash
set -euo pipefail

# Arguments:
#   $1 = Prompt label (e.g., "Client Common Name")
#   $2 = Pre-filled editable value (e.g., "vpn.")
#   $3 = Optional example hint shown in the prompt label (e.g., "vpn.jim.cronqvist")
prompt_editable() {
  local prompt_text="$1"
  local default_val="$2"
  local example_text="${3:-}"
  local input_val
  local full_prompt="$prompt_text"

  if [[ -n "$example_text" ]]; then
    full_prompt="${prompt_text} (e.g., ${example_text})"
  fi

  if (( BASH_VERSINFO[0] >= 4 )); then
    read -e -i "$default_val" -rp "${full_prompt}: " input_val
  else
    read -rp "${full_prompt} [${default_val}]: " input_val
  fi

  printf '%s' "${input_val:-$default_val}"
}

CA_CN=$(prompt_editable "CA Common Name" "client-vpn-ca")
SERVER_CN=$(prompt_editable "Server Common Name" "server")
CLIENT_CN=$(prompt_editable "Client Common Name" "vpn." "vpn.jim.cronqvist")
PKI_DIR=$(prompt_editable "Output directory" "${PWD}/pki")

# Guard against accidentally pressing Enter on "vpn." without typing a username
if [[ -z "$CLIENT_CN" || "$CLIENT_CN" == "vpn." ]]; then
  echo "Error: Please complete the Client Common Name (e.g., vpn.jim.cronqvist)."
  exit 1
fi

if [[ -d "$PKI_DIR" ]]; then
  read -rp "Directory '$PKI_DIR' already exists and will be overwritten. Continue? (y/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  rm -rf "$PKI_DIR"
fi

echo ""
echo "Generating PKI in: $PKI_DIR"
echo "  CA CN:     $CA_CN"
echo "  Server CN: $SERVER_CN"
echo "  Client CN: $CLIENT_CN"
echo ""

mkdir -p "$PKI_DIR"

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${PKI_DIR}:/work/output" \
  -e EASYRSA_PKI="/tmp/pki" \
  -e CA_CN="$CA_CN" \
  -e SERVER_CN="$SERVER_CN" \
  -e CLIENT_CN="$CLIENT_CN" \
  kylemanna/openvpn bash -c '
    easyrsa --batch init-pki && \
    easyrsa --batch --req-cn="$CA_CN" build-ca nopass && \
    easyrsa --batch build-server-full "$SERVER_CN" nopass && \
    easyrsa --batch build-client-full "$CLIENT_CN" nopass && \
    cp -rp /tmp/pki/. /work/output/
  '

echo ""
echo "Done! Generated files:"
echo "  ACM Certificate body:        ${PKI_DIR}/issued/${SERVER_CN}.crt"
echo "  ACM Certificate private key: ${PKI_DIR}/private/${SERVER_CN}.key"
echo "  ACM Certificate chain:       ${PKI_DIR}/ca.crt"
echo "  Client .ovpn <cert>:         ${PKI_DIR}/issued/${CLIENT_CN}.crt"
echo "  Client .ovpn <key>:          ${PKI_DIR}/private/${CLIENT_CN}.key"
