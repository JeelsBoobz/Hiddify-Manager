#!/usr/bin/env bash
# Ubuntu Server or VM Cleaner. Safe by default; aggressive when asked.
# Example safe:       sudo ./clean.sh
# Example aggressive: sudo JOURNAL_DAYS=3 AGGRESSIVE=1 ./clean.sh
# Enable Docker image prune (images only): sudo ./clean.sh --docker-images
# Tested on Ubuntu 20.04, 22.04, 24.04 (server/VM images).

set -Eeuo pipefail
trap 'rc=$?; echo "Error on line $LINENO: $BASH_COMMAND (exit $rc)"; exit $rc' ERR
IFS=$'\n\t'
PATH=/usr/sbin:/usr/bin:/sbin:/bin

###############################################################################
# DISCLAIMER – READ BEFORE RUNNING
#
# This script truncates logs, removes caches, purges orphaned/old packages,
# and can purge older kernels. It is intended for headless/minimal Ubuntu
# servers and VMs where reclaiming space is the priority.
# Not for desktops unless you knowingly opt out of the guard.
#
# No warranty. Use at your own risk. Snapshot first.
###############################################################################

# Config via env or flags
JOURNAL_DAYS="${JOURNAL_DAYS:-7}"           # journal retention in days
KEEP_KERNELS="${KEEP_KERNELS:-2}"           # number of newest kernels to keep (plus current)
SYSPREP="${SYSPREP:-0}"                     # scrub cloud-init state/logs for golden images
AGGRESSIVE="${AGGRESSIVE:-0}"               # remove man pages, docs, APT lists, dev-tool caches
PRUNE_SNAPS="${PRUNE_SNAPS:-1}"             # prune old snap revisions
PRUNE_DOCKER_IMAGES="${PRUNE_DOCKER_IMAGES:-0}"  # prune unused Docker images only (opt-in)
DESKTOP_GUARD="${DESKTOP_GUARD:-1}"         # abort if desktop detected
UPGRADE="${UPGRADE:-0}"                     # optionally run full-upgrade at the end

usage() {
  cat <<EOF
Usage: sudo $(basename "$0") [options]

Options:
  --journal-days N        Keep only last N days of systemd journals   [${JOURNAL_DAYS}]
  --keep-kernels N        Keep N newest kernels (plus current)        [${KEEP_KERNELS}]
  --aggressive            Aggressive cleanup (man/docs/APT lists + dev-tool caches)
  --sysprep               Cloud-init scrub for golden image
  --docker-images         Prune unused Docker images (images only)
  --no-snaps              Skip Snap old-revision prune
  --no-desktop-guard      Do not abort on desktop systems
  --upgrade               Run apt full-upgrade at the end (optional)
  -h, --help              Show help
EOF
}

# Parse flags
while [[ "${1:-}" =~ ^- ]]; do
  case "$1" in
    --journal-days) JOURNAL_DAYS="$2"; shift 2;;
    --keep-kernels) KEEP_KERNELS="$2"; shift 2;;
    --aggressive)   AGGRESSIVE=1; shift;;
    --sysprep)      SYSPREP=1; shift;;
    --docker-images) PRUNE_DOCKER_IMAGES=1; shift;;
    --no-snaps)     PRUNE_SNAPS=0; shift;;
    --no-desktop-guard) DESKTOP_GUARD=0; shift;;
    --upgrade)      UPGRADE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

# Safety
[[ $EUID -eq 0 ]] || { echo "Must be run as root."; exit 1; }
is_cmd(){ command -v "$1" >/dev/null 2>&1; }
detect_desktop(){
  dpkg -l | grep -qE '^(ii)\s+(ubuntu-desktop|xubuntu-desktop|kubuntu-desktop|ubuntustudio-desktop|gnome-shell)\b'
}
if [[ "$DESKTOP_GUARD" -eq 1 ]] && detect_desktop; then
  echo "Desktop detected. Intended for servers/VMs. Use --no-desktop-guard to proceed."; exit 1
fi

echo "== Ubuntu Server or VM Cleaner starting =="

apt_housekeeping() {
  echo "-> APT: clean caches and remove unused packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get -y update || true
  apt-get -y autoremove --purge
  apt-get -y autoclean
  apt-get -y clean

  # Purge residual config packages (state 'rc')
  rc_pkgs=$(dpkg -l | awk '/^rc/{print $2}')
  if [[ -n "${rc_pkgs}" ]]; then
    echo "   Purging residual configs:"
    xargs -r apt-get -y purge <<<"${rc_pkgs}" || true
  fi

  if [[ "$AGGRESSIVE" -eq 1 ]]; then
    echo "   Aggressive: removing /var/lib/apt/lists and package caches"
    rm -rf /var/lib/apt/lists/* /var/lib/apt/lists/partial \
           /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin || true
  fi
}

orphan_purge() {
  echo "-> Orphaned packages"
  if is_cmd deborphan; then
    deborphan --guess-data --guess-multi --guess-all 2>/dev/null | xargs -r apt-get -y purge
  else
    echo "   deborphan not installed; skipping."
  fi
}

# Kernel purge (handles unsigned images; keeps meta packages)
kernel_purge_manual() {
  echo "-> Kernel purge: keep ${KEEP_KERNELS} newest versions + running kernel and meta-packages"
  current="$(uname -r)"

  mapfile -t pkgs < <(
    dpkg -l | awk '
      /^ii/ && $2 ~ /^(linux-(image(-unsigned)?|headers|modules|modules-extra)-[0-9])/ {print $2}
    ' | sort -V
  )

  normver() { echo "$1" | sed -E 's/^linux-(image(-unsigned)?|headers|modules|modules-extra)-//' | sed -E "s/-(generic|lowlatency)$//"; }

  mapfile -t vers < <(
    printf "%s\n" "${pkgs[@]}" | while read -r p; do normver "$p"; done | sort -Vr | uniq
  )

  keep_versions=("${vers[@]:0:${KEEP_KERNELS}}")
  keep_versions+=("$(echo "$current" | sed -E 's/-[[:alnum:]]+$//')")

  meta_keep='^(linux-(image|headers)?-generic|linux-virtual|linux-generic)$'

  to_purge=()
  for p in "${pkgs[@]}"; do
    [[ "$p" =~ $meta_keep ]] && continue
    ver="$(normver "$p")"
    keep=0
    for kv in "${keep_versions[@]}"; do
      [[ "$ver" == "$kv" ]] && keep=1 && break
    done
    (( keep == 0 )) && to_purge+=("$p")
  done

  if (( ${#to_purge[@]} > 0 )); then
    echo "   Purging:"
    printf '     %s\n' "${to_purge[@]}"
    apt-get -y purge "${to_purge[@]}" || true
    apt-get -y autoremove --purge || true
  else
    echo "   Nothing to purge."
  fi
}

journal_vacuum() {
  if is_cmd journalctl; then
    echo "-> Journald: rotate and vacuum to ${JOURNAL_DAYS} days"
    journalctl --rotate || true
    journalctl --vacuum-time="${JOURNAL_DAYS}d" || true
    journalctl --vacuum-size=200M || true
  fi
}

# Truncate broad log set; avoid journald binaries; clear crash dumps
log_clean() {
  echo "-> Logs: truncate active logs; remove rotated/compressed and crashes"
  find /var/log -type f \
    ! -name "*.gz" ! -name "*.xz" ! -regex '.*\.[0-9]$' \
    ! -name "*.journal" ! -name "*.journal~" \
    -exec truncate -s 0 {} + || true

  : > /var/log/wtmp || true
  : > /var/log/btmp || true
  : > /var/log/lastlog || true

  find /var/log -type f -regex '.*\.[0-9]$' -delete  || true
  find /var/log -type f -name '*.gz' -delete        || true
  find /var/log -type f -name '*.xz' -delete        || true
  find /var/crash -type f -delete                   || true
  find /var/lib/systemd/coredump -type f -delete    2>/dev/null || true
}

tmp_clean() {
  echo "-> Temp: cleaning /tmp and /var/tmp"
  find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  find /var/tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  # Clean temp according to tmpfiles.d policies if present
  is_cmd systemd-tmpfiles && systemd-tmpfiles --clean || true
  # Kill old systemd-private-* temp dirs that linger
  find /tmp -maxdepth 1 -type d -name 'systemd-private-*' -mtime +1 -exec rm -rf {} + 2>/dev/null || true
}

user_caches() {
  echo "-> User caches: ~/.cache and Trash"
  rm -rf /home/*/.cache/* 2>/dev/null || true
  rm -rf /root/.cache/* 2>/dev/null || true
  rm -rf /home/*/.local/share/Trash/*/** 2>/dev/null || true
  rm -rf /root/.local/share/Trash/*/** 2>/dev/null || true
  # motd-news cache
  rm -rf /var/cache/motd-news/* 2>/dev/null || true
}

docs_prune() {
  if [[ "$AGGRESSIVE" -eq 1 ]]; then
    echo "-> Aggressive: remove man pages and docs"
    rm -rf /usr/share/man/?? /usr/share/man/??_* /usr/share/doc/* /usr/share/info/* /var/cache/man/* || true
  fi
}

# Extra dev-tool rubbish (only in aggressive mode)
dev_tool_caches() {
  if [[ "$AGGRESSIVE" -ne 1 ]]; then return 0; fi
  echo "-> Aggressive: remove common dev-tool caches"
  # Snap cache
  rm -rf /var/lib/snapd/cache/* 2>/dev/null || true

  # Per-user caches (root + /home/*)
  for uhome in /root /home/*; do
    [[ -d "$uhome" ]] || continue
    rm -rf "$uhome/.cache/pip" "$uhome/.cache/pip3" 2>/dev/null || true
    rm -rf "$uhome/.npm" "$uhome/.cache/npm" 2>/dev/null || true
    rm -rf "$uhome/.yarn" "$uhome/.cache/yarn" 2>/dev/null || true
    rm -rf "$uhome/.composer/cache" 2>/dev/null || true
    rm -rf "$uhome/.cargo/registry" "$uhome/.cargo/git" 2>/dev/null || true
    rm -rf "$uhome/.cache/go-build" "$uhome/go/pkg/mod/cache" 2>/dev/null || true
    rm -rf "$uhome/.gem/specs" 2>/dev/null || true
  done

  # System-wide gem cache if present
  rm -rf /var/lib/gems/*/cache/* 2>/dev/null || true
}

snap_prune() {
  if [[ "$PRUNE_SNAPS" -eq 1 ]] && is_cmd snap; then
    echo "-> Snap: prune disabled old revisions"
    snap list --all | awk '/disabled/{printf "%s:%s\n",$1,$3}' | \
      while IFS=: read -r pkg rev; do
        snap remove "$pkg" --revision="$rev" || true
      done
    [[ "$AGGRESSIVE" -eq 1 ]] && snap set system refresh.retain=2 || true
  fi
}

docker_images_prune() {
  if [[ "$PRUNE_DOCKER_IMAGES" -eq 1 ]] && is_cmd docker; then
    echo "-> Docker: prune unused images only (keeps images used by containers)"
    docker image prune -af || true
  fi
}

cloud_init_cleanup() {
  if [[ "$SYSPREP" -eq 1 ]] && is_cmd cloud-init; then
    echo "-> Cloud-init: scrub logs and instance state for golden image"
    cloud-init clean --logs || true
    rm -rf /var/lib/cloud/* || true
    rm -f /etc/machine-id || true
    systemd-machine-id-setup || true
    # Optional: reset SSH host keys so they regenerate on first boot
    rm -f /etc/ssh/ssh_host_* 2>/dev/null || true
  fi
}

apt_trash() {
  echo "-> APT archives: ensure cleared"
  rm -rf /var/cache/apt/archives/* /var/cache/apt/archives/partial/* || true
}

lib_list_cleanup() {
  if [[ "$AGGRESSIVE" -eq 1 ]]; then
    echo "-> Aggressive: remove APT lists"
    rm -rf /var/lib/apt/lists/* /var/lib/apt/lists/partial 2>/dev/null || true
  fi
}

# Discard free space to the hypervisor without creating junk files
fstrim_fs() {
  if is_cmd fstrim; then
    echo "-> fstrim: TRIM all supported filesystems"
    fstrim -av || true
  fi
}

# Clean up any leftover zero-fill files from previous runs
remove_leftover_zero_files() {
  echo "-> Cleanup: remove any stray /EMPTY* files from past zero-fill runs"
  rm -f /EMPTY /EMPTY.* 2>/dev/null || true
}

maybe_upgrade() {
  if [[ "$UPGRADE" -eq 1 ]]; then
    echo "-> Optional: apt full-upgrade"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -y full-upgrade || true
  fi
}

# Execute
journal_vacuum
log_clean
tmp_clean
user_caches
apt_housekeeping
orphan_purge
kernel_purge_manual
snap_prune
apt_trash
docs_prune
dev_tool_caches
lib_list_cleanup
cloud_init_cleanup
docker_images_prune
remove_leftover_zero_files
fstrim_fs
maybe_upgrade

echo "== Cleaning completed =="
