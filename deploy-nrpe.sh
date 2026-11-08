#!/usr/bin/env bash
# Scan an IPv4 range for SSH hosts and run the Icinga2 NRPE Universal Bootstrap Kit on the
# selected devices: https://github.com/Michdo93/Icinga2-NRPE-Universal-Bootstrap-Kit
set -uo pipefail

readonly SSH_PORT="${SSH_PORT:-22}"
readonly CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-4}"
readonly SCAN_PARALLEL="${SCAN_PARALLEL:-32}"

LOG=$(mktemp) || exit 1
trap 'rm -f "$LOG"' EXIT

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ask_yes_no() {
  local prompt="$1" default="$2" answer
  while true; do
    if [[ "$default" == y ]]; then read -r -p "$prompt [Y/n] " answer || return 1
    else read -r -p "$prompt [y/N] " answer || return 1; fi
    answer=${answer,,}
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      '') [[ "$default" == y ]] && return 0 || return 1 ;;
      *) printf 'Please answer y/yes or n/no.\n' ;;
    esac
  done
}
ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 )) || return 1
  printf '%u' "$(( (10#$a<<24) | (10#$b<<16) | (10#$c<<8) | 10#$d ))"
}
int_to_ipv4() { local n=$1; printf '%d.%d.%d.%d' "$((n>>24&255))" "$((n>>16&255))" "$((n>>8&255))" "$((n&255))"; }

# Prints the address if an SSH server answers. An authentication failure for a user that
# does not exist still proves that sshd is there. No host keys are stored while scanning.
probe_ssh() {
  local ip=$1 out
  out=$(timeout "$((CONNECT_TIMEOUT + 3))" ssh -F /dev/null -p "$SSH_PORT" -o BatchMode=yes \
    -o ConnectTimeout="$CONNECT_TIMEOUT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "ssh-scan@$ip" true 2>&1) && { printf '%s\n' "$ip"; return; }
  case "$out" in
    *'Permission denied'*|*'Too many authentication failures'*|*'no mutual signature'*) printf '%s\n' "$ip" ;;
  esac
}

ask_range() {
  while true; do
    printf '\nEnter the first and last IPv4 address in the range.\n'
    read -r -p 'First address: ' first || exit 0
    read -r -p 'Last address:  ' last || exit 0
    first_n=$(ipv4_to_int "$first") || { printf 'Invalid first IPv4 address.\n'; continue; }
    last_n=$(ipv4_to_int "$last") || { printf 'Invalid last IPv4 address.\n'; continue; }
    (( first_n <= last_n )) || { printf 'The first address must not be greater than the last address.\n'; continue; }
    (( last_n - first_n <= 65535 )) || { printf 'Ranges are limited to 65,536 addresses.\n'; continue; }
    if ask_yes_no "Scan ${first} through ${last}?" y; then break; fi
  done
}

# Fills the array "reachable" (sorted) with all addresses of the range that run sshd.
scan_range() {
  local n
  printf '\nScanning for SSH services on TCP port %d (%d parallel probes)...\n' "$SSH_PORT" "$SCAN_PARALLEL"
  export -f probe_ssh
  export SSH_PORT CONNECT_TIMEOUT
  mapfile -t reachable < <(
    for ((n=first_n; n<=last_n; n++)); do int_to_ipv4 "$n"; printf '\n'; done |
      xargs -P "$SCAN_PARALLEL" -I{} bash -c 'probe_ssh "$1"' _ {} |
      sort -t . -k1,1n -k2,2n -k3,3n -k4,4n)
  if ((${#reachable[@]} == 0)); then printf 'No SSH-reachable devices found in the range.\n'; exit 0; fi
  printf 'Found %d SSH-reachable device(s).\n' "${#reachable[@]}"
}

# run_remote USER IP SCRIPT [ARG...]
# The POSIX-sh script is sent base64-encoded as the remote command, NOT on stdin. That way
# the remote terminal (-tt) is connected to the local keyboard: password prompts of sudo and
# questions of the script work, and the script text is never echoed back (an echoed script
# would contain its own result markers). Output is shown live and copied to $LOG.
# Returns the exit code of ssh (255 = connection/authentication failed).
run_remote() {
  local user=$1 ip=$2 script=$3 b64 cmd arg q="'"
  shift 3
  b64=$(printf '%s' "$script" | base64 | tr -d '\n')
  cmd="sh -c \"\$(echo $b64 | base64 -d)\" remote"
  for arg in "$@"; do cmd+=" '${arg//$q/$q\\$q$q}'"; done
  ssh -tt -p "$SSH_PORT" -o ConnectTimeout="$CONNECT_TIMEOUT" -o ServerAliveInterval=15 \
    -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=publickey,keyboard-interactive,password \
    -o StrictHostKeyChecking=accept-new "$user@$ip" "$cmd" 2>&1 | tee "$LOG"
  return "${PIPESTATUS[0]}"
}

# Last result marker the remote script printed ("" if none).
remote_result() { grep -ao '@@RESULT:[A-Z_]*@@' "$LOG" | tail -n 1 | sed 's/^@@RESULT://; s/@@$//'; }

# with_login IP REMOTE_SCRIPT [ARG...] - asks for the user name and tries up to three
# logins. Sets "result" to the marker of the remote script, or LOGIN_FAILED / NO_RESULT.
with_login() {
  local ip=$1 rc attempt
  shift
  result=LOGIN_FAILED
  read -r -p 'SSH username: ' username || return 1
  [[ -n "$username" ]] || { printf 'Skipped: username cannot be empty.\n'; result=SKIPPED; return 1; }
  for attempt in 1 2 3; do
    printf 'SSH login attempt %d of 3 for %s.\n' "$attempt" "$ip"
    run_remote "$username" "$ip" "$@"; rc=$?
    result=$(remote_result)
    [[ -n "$result" ]] && return 0
    if (( rc != 255 )); then result=NO_RESULT; return 0; fi
    if grep -aq 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$LOG"; then
      printf 'The host key of %s has changed. Verify the device, then remove the old key with: ssh-keygen -R %s\n' "$ip" "$ip"
      return 1
    fi
    if (( attempt < 3 )); then printf 'SSH login failed.\n'; else printf 'SSH login failed after 3 attempts; moving to the next device.\n'; fi
  done
  return 1
}

command -v ssh >/dev/null || die 'OpenSSH client (ssh) is required.'
command -v timeout >/dev/null || die "The 'timeout' command is required (available on Linux and WSL)."
command -v base64 >/dev/null || die "The 'base64' command is required."
command -v xargs >/dev/null || die "The 'xargs' command is required."


INSTALLER_URL="${INSTALLER_URL:-https://raw.githubusercontent.com/Michdo93/Icinga2-NRPE-Universal-Bootstrap-Kit/main/install.sh}"
# Optional: other source of nrpe-bootstrap.py (fork, local mirror)
NRPE_BOOTSTRAP_URL="${NRPE_BOOTSTRAP_URL:-}"

# Remote part (POSIX sh), arguments: installer URL, optional VAR=value for the installer
# ("" for none), installer arguments...
# Downloads the installer and runs it as root (sudo asks for the password in this terminal).
read -r -d '' REMOTE_SCRIPT <<'REMOTE'
mark() { printf '@@RESULT:%s@@\r\033[K' "$1"; }
url=$1; envspec=$2; shift 2
[ "$(uname -s 2>/dev/null)" = Linux ] || { mark UNSUPPORTED; exit 0; }
command -v apt-get >/dev/null 2>&1 || { mark UNSUPPORTED; exit 0; }
if [ "$(id -u)" = 0 ]; then SUDO=""
elif command -v sudo >/dev/null 2>&1; then SUDO="sudo"
else mark PRIVILEGE; exit 0; fi
if [ -n "$SUDO" ]; then $SUDO -v || { mark PRIVILEGE; exit 0; }; fi
tmp=$(mktemp) || { mark DOWNLOAD_FAILED; exit 0; }
if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
  echo 'Installing wget...'
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null &&
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wget ca-certificates </dev/null >/dev/null
fi
if command -v wget >/dev/null 2>&1; then wget -qO "$tmp" "$url"
elif command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$tmp"
fi
[ -s "$tmp" ] || { rm -f "$tmp"; mark DOWNLOAD_FAILED; exit 0; }
$SUDO env ${envspec:+"$envspec"} sh "$tmp" "$@"
rc=$?
rm -f "$tmp"
if [ "$rc" -eq 0 ]; then mark SUCCESS; else mark INSTALL_FAILED; fi
REMOTE

installer_message() {  # result ip
  case "$1" in
    SUCCESS) printf 'Installer finished successfully on %s.\n' "$2" ;;
    PRIVILEGE) printf 'Skipped: administrator privileges (root or sudo) are unavailable on %s.\n' "$2" ;;
    UNSUPPORTED) printf 'Skipped: %s is not a Debian-based Linux system.\n' "$2" ;;
    DOWNLOAD_FAILED) printf 'Could not download the installer on %s (no Internet access or neither wget nor curl).\n' "$2" ;;
    INSTALL_FAILED) printf 'The installer reported an error on %s - see the output above.\n' "$2" ;;
    *) printf 'The remote session ended without a result on %s (unsupported shell or interrupted).\n' "$2" ;;
  esac
}

valid_master() {  # IPv4/IPv6 address, CIDR network or host name
  local addr=${1%/*} pfx=""
  [[ "$1" == */* ]] && pfx=${1#*/}
  [[ -z "$pfx" || "$pfx" =~ ^[0-9]{1,3}$ ]] || return 1
  if [[ "$addr" =~ ^[0-9.]+$ ]]; then ipv4_to_int "$addr" >/dev/null && { [[ -z "$pfx" ]] || (( pfx <= 32 )); }; return; fi
  if [[ "$addr" == *:* ]]; then [[ "$addr" =~ ^[0-9A-Fa-f:]+$ ]] && { [[ -z "$pfx" ]] || (( pfx <= 128 )); }; return; fi
  [[ -z "$pfx" && ${#addr} -le 253 && "$addr" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$addr" != *..* ]]
}
yes_no_flag() { if ask_yes_no "$1" "$2"; then printf -- '--%s' "$3"; else printf -- '--no-%s' "$3"; fi; }

declare -a nrpe_args=()
printf 'Installer: %s\n' "$INSTALLER_URL"
if ask_yes_no 'Answer the NRPE setup questions once for all devices? (No: the wizard asks on every device)' y; then
  while true; do
    printf '\nNRPE settings for all selected devices.\n'
    read -r -p 'Icinga2 master/satellite address(es), comma separated: ' masters || exit 0
    masters=${masters// /}
    ok=true
    IFS=, read -r -a list <<< "$masters"
    ((${#list[@]})) || ok=false
    for m in "${list[@]}"; do valid_master "$m" || { ok=false; printf 'Invalid address: %s\n' "$m"; }; done
    [[ "$ok" == true ]] || continue
    nrpe_args=(--master "$masters" --yes
      "$(yes_no_flag 'Standard checks (load, disk, swap, users, processes)?' y defaults)"
      "$(yes_no_flag 'Check the SSH server?' y ssh)"
      "$(yes_no_flag 'Add checks for all listening TCP ports (discovered per device)?' y ports)"
      "$(yes_no_flag 'Add checks for running systemd services (discovered per device)?' n services)"
      "$(yes_no_flag 'Install nagios-plugins-contrib (large, pulls in a mail server)?' n contrib)"
      "$(yes_no_flag 'Allow command arguments (dont_blame_nrpe=1, less secure)?' n arguments)")
    printf 'NRPE options: %s\n' "${nrpe_args[*]}"
    if ask_yes_no 'Are these settings correct?' y; then break; fi
  done
fi

ask_range
scan_range

envspec=""
[[ -z "$NRPE_BOOTSTRAP_URL" ]] || envspec="NRPE_BOOTSTRAP_URL=$NRPE_BOOTSTRAP_URL"
declare -a done_hosts=() failed_hosts=()
for ip in "${reachable[@]}"; do
  printf '\nDevice: %s\n' "$ip"
  ask_yes_no 'Install and configure NRPE on this device?' y || { printf 'Skipped %s.\n' "$ip"; continue; }
  if with_login "$ip" "$REMOTE_SCRIPT" "$INSTALLER_URL" "$envspec" "${nrpe_args[@]}"; then
    installer_message "$result" "$ip"
    [[ "$result" == SUCCESS ]] && done_hosts+=("$ip") || failed_hosts+=("$ip")
  else
    [[ "$result" == SKIPPED ]] || failed_hosts+=("$ip")
  fi
done
printf '\nFinished. NRPE configured: %d' "${#done_hosts[@]}"
((${#done_hosts[@]})) && printf ' (%s)' "${done_hosts[*]}"
printf ', failed: %d' "${#failed_hosts[@]}"
((${#failed_hosts[@]})) && printf ' (%s)' "${failed_hosts[*]}"
printf '\n'
((${#done_hosts[@]})) && printf 'Icinga2 service examples were written to /etc/nagios/icinga2-services.conf.example on each device.\n'
exit 0
