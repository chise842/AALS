#!/usr/bin/env bash
# Live ISO の root で、次で取得して実行する。
#   curl -fsSL https://raw.githubusercontent.com/chise842/AALS/main/01-base.sh | bash
# このスクリプトは同じリポジトリの 02 と 03 を取得してから実行する。
# パーティション、ファイルシステム、pacstrap、fstab までを行い、
# arch-chroot で 02-base-chroot.sh に渡す。NVRAM 登録は ISO 側の efibootmgr で行う。
# ここまでが素のベース OS。デスクトップと CachyOS リポジトリは起動後に 03-desktop.sh。
if [ -z "${BASH_VERSION:-}" ]; then
  printf 'Run this script with bash.\n' >&2
  exit 1
fi

set -euo pipefail

MIN_ESP_MIB=4096
MIN_ROOT_BYTES=$((8 * 1024 * 1024 * 1024))
REPO_RAW=https://raw.githubusercontent.com/chise842/AALS/main
SCRIPT_DIR=${AALS_SCRIPT_DIR:-}

DISK=
ESP_MIB=
HOST_NAME=
USER_NAME=
ROOT_PASSWORD=
USER_PASSWORD=
LOCALE=
TIMEZONE=
KEYMAP=
CPU=
GPU=
ESP_PART=
ROOT_PART=
SUCCESS=0

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local status=$?
  trap - EXIT
  unset ROOT_PASSWORD USER_PASSWORD
  if [[ "$SUCCESS" -eq 1 ]]; then
    if findmnt -M /mnt >/dev/null 2>&1; then
      umount -R /mnt || printf 'Warning: failed to unmount /mnt.\n' >&2
    fi
  elif findmnt -M /mnt >/dev/null 2>&1; then
    printf 'Failed. /mnt is still mounted.\n' >&2
    if [[ -x /mnt/root/aals/02-base-chroot.sh ]]; then
      printf 'To retry setup without wiping the disk: arch-chroot /mnt /root/aals/02-base-chroot.sh\n' >&2
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Command not found: ${cmd}"
  done
}

prompt() {
  local var=$1 text=$2 value
  read -r -p "$text" value
  printf -v "$var" '%s' "$value"
}

prompt_secret() {
  local var=$1 text=$2 first second
  while true; do
    read -rs -p "$text" first
    printf '\n' >&2
    read -rs -p 'Enter it again: ' second
    printf '\n' >&2
    if [[ -n "$first" && "$first" == "$second" ]]; then
      printf -v "$var" '%s' "$first"
      return 0
    fi
    printf 'Entries do not match, or are empty.\n' >&2
  done
}

on_disk() {
  local source=$1 disk=$2 pk
  [[ "$source" == "$disk" ]] && return 0
  pk=$(LC_ALL=C lsblk -no PKNAME "$source" 2>/dev/null || true)
  [[ -n "$pk" && "/dev/${pk}" == "$disk" ]]
}

assert_not_live_medium() {
  local disk=$1 source target
  while read -r source target; do
    [[ -n "$source" ]] || continue
    if on_disk "$source" "$disk"; then
      die "The installer media cannot be the target disk (${target})."
    fi
  done < <(findmnt -rn -o SOURCE,TARGET /run/archiso)
}

unmount_disk() {
  local disk=$1 source target pk
  local -a mountpoints=()

  while read -r pk; do
    [[ -n "$pk" ]] || continue
    if on_disk "$pk" "$disk"; then
      swapoff "$pk"
    fi
  done < <(swapon --noheadings --show=NAME 2>/dev/null || true)

  while read -r source target; do
    [[ -n "$source" && -n "$target" ]] || continue
    if on_disk "$source" "$disk"; then
      mountpoints+=("$target")
    fi
  done < <(findmnt -rn -o SOURCE,TARGET)

  local i
  for ((i = ${#mountpoints[@]} - 1; i >= 0; i--)); do
    umount "${mountpoints[i]}"
  done
}

fetch_setup_scripts() {
  local dest name src dir
  if [[ "${AALS_FROM_REPO:-}" == 1 ]]; then
    return 0
  fi
  src=${BASH_SOURCE[0]}
  if [[ -n "$src" && -f "$src" ]]; then
    dir=$(cd "$(dirname "$src")" && pwd)
    if [[ -f "${dir}/02-base-chroot.sh" && -f "${dir}/03-desktop.sh" ]]; then
      SCRIPT_DIR=$dir
      return 0
    fi
  fi
  dest=$(mktemp -d)
  printf 'Fetching scripts from https://github.com/chise842/AALS.\n'
  for name in 01-base.sh 02-base-chroot.sh 03-desktop.sh; do
    curl -fsSL --max-time 60 -o "${dest}/${name}" "${REPO_RAW}/${name}" \
      || die "Failed to download: ${name}"
    [[ "$(head -n 1 "${dest}/${name}")" == '#!/usr/bin/env bash' ]] || die "Downloaded ${name} is not a script."
  done
  chmod 755 "${dest}/01-base.sh" "${dest}/03-desktop.sh"
  chmod 700 "${dest}/02-base-chroot.sh"
  AALS_FROM_REPO=1 AALS_SCRIPT_DIR=$dest exec bash "${dest}/01-base.sh" "$@"
}

preflight() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root."
  [[ -d /run/archiso ]] || die "Run this from the Arch Linux installation ISO."
  [[ -d /sys/firmware/efi ]] || die "Boot the ISO in UEFI mode."
  [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/02-base-chroot.sh" && -f "${SCRIPT_DIR}/03-desktop.sh" ]] || die "Setup scripts were not fetched."
  if findmnt -M /mnt >/dev/null 2>&1; then
    die "/mnt is already mounted. Unmount it before starting over. To retry setup only: arch-chroot /mnt /root/aals/02-base-chroot.sh"
  fi

  require_cmd pacstrap genfstab arch-chroot parted mkfs.fat mkfs.btrfs \
    blkid lsblk findmnt curl wipefs partprobe udevadm btrfs install

  if ! curl -fsL --max-time 20 -o /dev/null https://archlinux.org; then
    die "Network is unreachable. Connect from the ISO, then run this again."
  fi
  timedatectl set-ntp true || true
}

ask_inputs() {
  local keymap_path

  prompt DISK 'Target disk (example: /dev/nvme0n1): '
  [[ -n "$DISK" && "$DISK" != *" "* ]] || die "Invalid disk."
  DISK=$(readlink -f "$DISK")
  [[ -b "$DISK" ]] || die "Not a block device: ${DISK}"
  [[ "$(LC_ALL=C lsblk -dno TYPE "$DISK")" == "disk" ]] || die "Specify a whole disk, not a partition: ${DISK}"
  assert_not_live_medium "$DISK"

  prompt ESP_MIB "ESP size in MiB (at least ${MIN_ESP_MIB}): "
  [[ "$ESP_MIB" =~ ^[1-9][0-9]*$ ]] || die "ESP size must be a positive integer in MiB."
  ((10#$ESP_MIB >= MIN_ESP_MIB)) || die "ESP must be at least ${MIN_ESP_MIB} MiB."

  local disk_bytes esp_bytes
  disk_bytes=$(LC_ALL=C lsblk -bdno SIZE "$DISK")
  esp_bytes=$((10#$ESP_MIB * 1024 * 1024))
  ((disk_bytes >= esp_bytes + MIN_ROOT_BYTES)) || die "Disk is too small. The root needs at least 8 GiB in addition to the ESP."

  prompt HOST_NAME 'Hostname: '
  [[ "$HOST_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die "Invalid hostname."

  prompt USER_NAME 'Username: '
  [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username."
  case "$USER_NAME" in
    root | greeter) die "This username is not allowed." ;;
  esac

  prompt_secret ROOT_PASSWORD 'Root password: '
  prompt_secret USER_PASSWORD "Password for ${USER_NAME}: "

  prompt LOCALE 'Locale (example: en_US.UTF-8): '
  [[ "$LOCALE" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "Invalid locale."
  grep -Eq "^#?${LOCALE//./\\.} UTF-8$" /etc/locale.gen || die "Locale is not listed in locale.gen: ${LOCALE}"

  prompt TIMEZONE 'Timezone (example: Asia/Tokyo): '
  [[ "$TIMEZONE" != *..* && "$TIMEZONE" != /* && -f "/usr/share/zoneinfo/${TIMEZONE}" ]] || die "Timezone not found: ${TIMEZONE}"

  prompt KEYMAP 'Keymap (example: us): '
  [[ "$KEYMAP" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid keymap."
  keymap_path=$(find /usr/share/kbd/keymaps -type f -name "${KEYMAP}.map.gz" -print -quit)
  [[ -n "$keymap_path" ]] || die "Keymap not found: ${KEYMAP}"

  prompt CPU 'CPU (intel / amd): '
  [[ "$CPU" == intel || "$CPU" == amd ]] || die "CPU must be intel or amd."
  prompt GPU 'GPU (nvidia / amd): '
  [[ "$GPU" == nvidia || "$GPU" == amd ]] || die "GPU must be nvidia or amd."
}

confirm_wipe() {
  local typed
  printf '\nThe following setup will erase %s completely.\n' "$DISK"
  LC_ALL=C lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL "$DISK"
  cat <<EOF

  ESP: ${ESP_MIB} MiB (/boot, FAT32, at least 4096 MiB for snapshot kernels)
  Root: the rest of the disk (Btrfs, subvolumes @, @home, @snapshots, no encryption)
  Swap: no partition. ZRAM (half of RAM, at most 4 GiB)
  Network: systemd-networkd + iwd + systemd-resolved
  Hostname: ${HOST_NAME}
  User: ${USER_NAME} (wheel / sudo)
  Locale: ${LOCALE}
  Timezone: ${TIMEZONE}
  Keymap: ${KEYMAP}
  CPU: ${CPU}
  GPU: ${GPU}
  First boot: linux (console)
  After boot: 03-desktop.sh adds the CachyOS repository and the desktop
EOF
  prompt typed 'Type the target disk path again to confirm the wipe: '
  [[ "$typed" == "$DISK" ]] || die "Confirmation did not match. Aborted."
}

partition_and_format() {
  local esp_end
  esp_end=$((10#$ESP_MIB + 1))

  printf 'Creating partitions.\n'
  unmount_disk "$DISK"
  wipefs -a "$DISK"
  parted -s -a optimal "$DISK" \
    mklabel gpt \
    mkpart ESP fat32 1MiB "${esp_end}MiB" \
    set 1 esp on \
    mkpart root "${esp_end}MiB" 100%
  partprobe "$DISK" || true
  udevadm settle

  case "$DISK" in
    *[0-9])
      ESP_PART="${DISK}p1"
      ROOT_PART="${DISK}p2"
      ;;
    *)
      ESP_PART="${DISK}1"
      ROOT_PART="${DISK}2"
      ;;
  esac

  local _
  for _ in $(seq 1 50); do
    [[ -b "$ESP_PART" && -b "$ROOT_PART" ]] && break
    sleep 0.1
  done
  [[ -b "$ESP_PART" && -b "$ROOT_PART" ]] || die "Partition devices did not appear."

  printf 'Creating filesystems.\n'
  mkfs.fat -F 32 "$ESP_PART"
  mkfs.btrfs -f "$ROOT_PART"

  mkdir -p /mnt
  mount -o subvolid=5 "$ROOT_PART" /mnt
  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@home
  btrfs subvolume create /mnt/@snapshots
  local subvol_id
  subvol_id=$(LC_ALL=C btrfs subvolume list /mnt | awk '$NF == "@" { print $2; found = 1 } END { if (!found) exit 1 }')
  btrfs subvolume set-default "$subvol_id" /mnt
  umount /mnt

  mount -o subvol=@ "$ROOT_PART" /mnt
  mkdir -p /mnt/home /mnt/.snapshots /mnt/boot
  mount -o subvol=@home "$ROOT_PART" /mnt/home
  mount -o subvol=@snapshots "$ROOT_PART" /mnt/.snapshots
  mount "$ESP_PART" /mnt/boot
}

install_packages() {
  printf 'Installing packages.\n'
  # Load btrfs before the target initramfs is generated so autodetect can see it.
  modprobe btrfs || true
  # kbd applies the keymap from /etc/vconsole.conf.
  pacstrap -K /mnt \
    base \
    linux \
    btrfs-progs \
    kbd \
    limine \
    sudo
  genfstab -U /mnt >>/mnt/etc/fstab
  grep -q '[[:space:]]/[[:space:]]' /mnt/etc/fstab || die "fstab has no / entry."
  grep -q 'subvol' /mnt/etc/fstab || die "fstab has no Btrfs subvolume."
  grep -q '@snapshots' /mnt/etc/fstab || die "fstab has no @snapshots entry."
}

stage_chroot_scripts() {
  install -d -m 700 /mnt/root/aals
  install -m 700 "${SCRIPT_DIR}/02-base-chroot.sh" /mnt/root/aals/02-base-chroot.sh
  install -d -m 755 /mnt/usr/local/lib/aals
  install -m 755 "${SCRIPT_DIR}/03-desktop.sh" /mnt/usr/local/lib/aals/03-desktop.sh
  (
    umask 077
    {
      printf 'HOST_NAME=%q\n' "$HOST_NAME"
      printf 'USER_NAME=%q\n' "$USER_NAME"
      printf 'LOCALE=%q\n' "$LOCALE"
      printf 'TIMEZONE=%q\n' "$TIMEZONE"
      printf 'KEYMAP=%q\n' "$KEYMAP"
      printf 'ROOT_PASSWORD=%q\n' "$ROOT_PASSWORD"
      printf 'USER_PASSWORD=%q\n' "$USER_PASSWORD"
      printf 'CPU=%q\n' "$CPU"
      printf 'GPU=%q\n' "$GPU"
    } >/mnt/root/aals/install.env
  )
  unset ROOT_PASSWORD USER_PASSWORD
}

register_limine_boot_entry() {
  printf 'Registering the UEFI boot entry.\n'
  if command -v efibootmgr >/dev/null 2>&1; then
    efibootmgr \
      --create \
      --disk "$DISK" \
      --part 1 \
      --label "Limine" \
      --loader '\EFI\BOOT\BOOTX64.EFI' \
      --unicode \
      || printf 'Warning: failed to create the NVRAM boot entry. The firmware will use the default path.\n' >&2
  else
    printf 'Warning: efibootmgr is missing, so NVRAM was not updated. The firmware will use the default path.\n' >&2
  fi
}

main() {
  fetch_setup_scripts "$@"
  preflight
  ask_inputs
  confirm_wipe
  partition_and_format
  install_packages
  stage_chroot_scripts
  printf 'Entering arch-chroot to run 02-base-chroot.sh.\n'
  arch-chroot /mnt /root/aals/02-base-chroot.sh
  if [[ ! -L /mnt/etc/resolv.conf ]]; then
    rm -f /mnt/etc/resolv.conf
    ln -s /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
  fi
  register_limine_boot_entry
  sync
  SUCCESS=1
  printf 'Installation finished. Reboot.\n'
  printf 'After booting, run /usr/local/lib/aals/03-desktop.sh as the regular user.\n'
}

main "$@"
