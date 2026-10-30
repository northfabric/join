#!/bin/sh
# Mining Monitor: add this machine as a worker. Run it as root:   curl -fsSL <address of this script> | sudo sh
# It holds no secret. It asks for the join code from the dashboard, checks the machine, checks that Tailscale is connected (it never
# changes Tailscale), pins the server by its certificate fingerprint and runs the installer that the server hands to a valid code.
set -eu
S='https://100.71.159.41:9443'; FP='8492eb0516417214856a24381559f760727f453dda3b1088b1ec1b0d095180bd'
# SHA-256 of the package signing key of Tailscale's apt repositories (the same file for Debian, Raspberry Pi OS and Ubuntu), pinned here: a
# Dedicated machine without Tailscale installs it from those repositories only if the key is exactly this one.
TS_KEY_SHA256='3e03dacf222698c60b8e2f990b809ca1b3e104de127767864284e6c228f1fb39'
step='start'
say() { printf '==> %s\n' "$1"; }
fail() { printf 'FAILED at step %s: %s\n' "$step" "$1" >&2; exit 1; }
umask 077
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

# A Dedicated machine's command leaves the join code and a one-off Tailscale key in a file only root can read (tmpfs, gone at reboot).
seed=/run/mining-monitor-join; code=''; tskey=''
if [ -r "$seed" ]; then
  { IFS= read -r code; IFS= read -r tskey; } < "$seed" || true
  rm -f "$seed"
fi
if [ -z "$code" ]; then
  [ -r /dev/tty ] || fail 'no terminal to ask the join code on'
  printf 'Join code (on the dashboard, like ABCDE-FGHIJ): ' > /dev/tty
  read -r code < /dev/tty
fi
code="$(printf '%s' "$code" | tr -d ' -' | tr '[:lower:]' '[:upper:]')"
[ -n "$code" ] || fail 'no join code'

install_tailscale() {
  command -v apt-get >/dev/null 2>&1 || fail 'Tailscale is not installed and this system has no apt: install and connect Tailscale yourself, then run this command again.'
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID:-}" in debian|raspbian|ubuntu) ;; *) fail "Tailscale is not installed and this system (${ID:-unknown}) is not one it installs for: install and connect it yourself, then run this command again." ;; esac
  [ -n "${VERSION_CODENAME:-}" ] || fail 'cannot tell which Debian or Ubuntu release this is'
  curl -fsSL -o "$tmp/tailscale.gpg" "https://pkgs.tailscale.com/stable/$ID/$VERSION_CODENAME.noarmor.gpg" || fail 'could not fetch the Tailscale package key'
  [ "$(sha256sum "$tmp/tailscale.gpg" | cut -d' ' -f1)" = "$TS_KEY_SHA256" ] || fail "the Tailscale package key is not the one this script knows. Nothing was installed."
  install -m 644 "$tmp/tailscale.gpg" /usr/share/keyrings/tailscale-archive-keyring.gpg
  printf 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/%s %s main\n' "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/tailscale.list
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tailscale
}

step='tailscale'; say 'Tailscale'
if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  echo '    already connected: used as it is'
elif command -v tailscale >/dev/null 2>&1; then
  fail 'Tailscale is installed but not connected. Run: tailscale up   (then this command again). Nothing was changed.'
elif [ -n "$tskey" ]; then
  echo '    not installed: installing it from its signed package repository'
  install_tailscale
  printf '%s' "$tskey" > "$tmp/tskey"
  tailscale up --auth-key="file:$tmp/tskey" || fail 'Tailscale did not accept the key (used, expired or revoked): make a new code'
  tskey=''
  tailscale status >/dev/null 2>&1 || fail 'Tailscale did not connect'
  echo '    connected, tagged as a dedicated miner'
else
  fail 'Tailscale is not installed here. Install it (https://tailscale.com/download/linux), connect it, then run this command again. Nothing was changed.'
fi

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
