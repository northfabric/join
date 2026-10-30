#!/bin/sh
# Mining Monitor: add this machine as a worker. Run it as root:   curl -fsSL <address of this script> | sudo sh
# It holds no secret. It asks for the join code from the dashboard, checks the machine, checks that Tailscale is connected (it never
# changes Tailscale), pins the server by its certificate fingerprint and runs the installer that the server hands to a valid code.
set -eu
S='https://100.71.159.41:9443'; FP='8492eb0516417214856a24381559f760727f453dda3b1088b1ec1b0d095180bd'
step='start'
say() { printf '==> %s\n' "$1"; }
fail() { printf 'FAILED at step %s: %s\n' "$step" "$1" >&2; exit 1; }
tmp="$(mktemp -d)"; chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

[ "$(id -u)" = 0 ] || fail 'run this as root: curl -fsSL <address> | sudo sh'
for c in curl openssl base64 sed tr; do command -v "$c" >/dev/null 2>&1 || fail "$c is needed and is not installed"; done
step='platform'; say 'Checking this machine'
case "$(uname -s)" in Linux) ;; *) fail 'this script is for Linux' ;; esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) fail "unsupported processor: $(uname -m) (x86_64 and 64-bit ARM only)" ;;
esac
[ "$(getconf LONG_BIT)" = 64 ] || fail 'this system is 32-bit: install a 64-bit system (for a Raspberry Pi, Raspberry Pi OS 64-bit)'
command -v systemctl >/dev/null 2>&1 || fail 'systemd is needed'
echo "    Linux $arch"

[ -r /dev/tty ] || fail 'no terminal to ask the join code on'
printf 'Join code (on the dashboard, like ABCDE-FGHIJ): ' > /dev/tty
read -r code < /dev/tty
code="$(printf '%s' "$code" | tr -d ' -' | tr '[:lower:]' '[:upper:]')"
[ -n "$code" ] || fail 'no join code'

step='tailscale'; say 'Tailscale'
command -v tailscale >/dev/null 2>&1 || fail 'Tailscale is not installed here. Install it (https://tailscale.com/download/linux), connect it, then run this command again. Nothing was changed.'
tailscale status >/dev/null 2>&1 || fail 'Tailscale is installed but not connected. Run: tailscale up   (then this command again). Nothing was changed.'

step='server'; say 'Reaching the server'
hostport="${S#https://}"
reached=0; i=0
while [ "$i" -lt 12 ] && [ "$reached" = 0 ]; do
  if printf '' | openssl s_client -connect "$hostport" 2>/dev/null | openssl x509 > "$tmp/cert.pem" 2>/dev/null && [ -s "$tmp/cert.pem" ]; then reached=1; else i=$((i + 1)); sleep 5; fi
done
[ "$reached" = 1 ] || fail "the server $S does not answer. Is this machine allowed to reach it over Tailscale?"
got="$(openssl x509 -in "$tmp/cert.pem" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"
[ "$got" = "$FP" ] || fail 'the certificate of the server is not the expected one. Nothing was sent.'
pin="$(openssl x509 -in "$tmp/cert.pem" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)"

step='installer'; say 'Fetching the installer'
umask 077
printf 'Authorization: Bearer %s\n' "$code" > "$tmp/code-header"
curl -fsS -k --pinnedpubkey "sha256//$pin" -H "@$tmp/code-header" -o "$tmp/installer.sh" "$S/api/enroll/bootstrap?os=linux&arch=$arch" \
  || fail 'the server refused the join code (wrong, used, expired or revoked), or the installer could not be fetched'
[ -s "$tmp/installer.sh" ] || fail 'the installer came back empty'
S="$S" FP="$FP" PIN="$pin" ARCH="$arch" TMPDIR_JOIN="$tmp" sh "$tmp/installer.sh"
