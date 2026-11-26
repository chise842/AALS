#!/usr/bin/env bash
# 新システム内の root で実行する（arch-chroot、または起動後の root）。
# Live ISO では実行しない。失敗してもディスクは消さない。
# ここまでが素のベース OS。ネットワーク、Snapper、Limine までを設定する。
# CachyOS リポジトリ、paru、デスクトップは起動後の 03-desktop.sh。
# /root/aals/install.env があればそれを使い、成功時に削除する。無ければ入力を求める。
if [ -z "${BASH_VERSION:-}" ]; then
  printf 'Run this script with bash.\n' >&2
  exit 1
fi

set -euo pipefail

DESKTOP_SCRIPT=/usr/local/lib/aals/03-desktop.sh
ENV_FILE=/root/aals/install.env

HOST_NAME=
USER_NAME=
ROOT_PASSWORD=
USER_PASSWORD=
LOCALE=
TIMEZONE=
KEYMAP=
CPU=
GPU=

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
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

locale_is_known() {
  local file line name charset
  for file in /etc/locale.gen /usr/share/i18n/SUPPORTED; do
    [[ -r "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line=${line%$'\r'}
      line=${line#"${line%%[![:space:]]*}"}
      [[ -n "$line" ]] || continue
      if [[ "$line" == \#* ]]; then
        line=${line#\#}
        line=${line#"${line%%[![:space:]]*}"}
      fi
      [[ -n "$line" && "$line" != \#* ]] || continue
      read -r name charset <<<"$line"
      if [[ "$name" == "$LOCALE" && "$charset" == UTF-8 ]]; then
        return 0
      fi
    done <"$file"
  done
  return 1
}

has_mount_option() {
  local mountpoint=$1 option=$2 options
  options=$(findmnt -no OPTIONS "$mountpoint" || true)
  [[ -n "$options" && ",${options}," == *",${option},"* ]]
}

assert_environment() {
  local root_type boot_type
  [[ "$(id -u)" -eq 0 ]] || die "Run as root."
  root_type=$(findmnt -no FSTYPE / || true)
  [[ "$root_type" == btrfs ]] || die "Run this on the new Btrfs root. On the live ISO, use 01-base.sh."
  has_mount_option / subvol=@ || has_mount_option / subvol=/@ || die "The root is not subvolume @."
  has_mount_option /home subvol=@home || has_mount_option /home subvol=/@home || die "/home is not subvolume @home."
  has_mount_option /.snapshots subvol=@snapshots || has_mount_option /.snapshots subvol=/@snapshots || die "/.snapshots is not subvolume @snapshots."
  boot_type=$(findmnt -no FSTYPE /boot || true)
  [[ "$boot_type" == vfat ]] || die "/boot is not the ESP (vfat)."
  [[ -x "$DESKTOP_SCRIPT" ]] || die "03-desktop.sh is missing: ${DESKTOP_SCRIPT}"
}

validate_settings() {
  local keymap_path
  [[ "$HOST_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die "Invalid hostname."
  [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username."
  case "$USER_NAME" in
    root | greeter) die "This username is not allowed." ;;
  esac
  [[ -n "$ROOT_PASSWORD" && "$ROOT_PASSWORD" != *$'\n'* ]] || die "Invalid root password."
  [[ -n "$USER_PASSWORD" && "$USER_PASSWORD" != *$'\n'* ]] || die "Invalid user password."
  LOCALE=${LOCALE//[[:space:]]/}
  if [[ -z "$LOCALE" ]]; then
    LOCALE=en_US.UTF-8
  fi
  [[ "$LOCALE" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "Invalid locale."
  locale_is_known || die "Locale is not listed in locale.gen: ${LOCALE}"
  [[ "$TIMEZONE" != *..* && "$TIMEZONE" != /* && -f "/usr/share/zoneinfo/${TIMEZONE}" ]] || die "Timezone not found: ${TIMEZONE}"
  [[ "$KEYMAP" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid keymap."
  keymap_path=$(find /usr/share/kbd/keymaps -type f -name "${KEYMAP}.map.gz" -print -quit)
  [[ -n "$keymap_path" ]] || die "Keymap not found: ${KEYMAP}"
  [[ "$CPU" == intel || "$CPU" == amd ]] || die "CPU must be intel or amd."
  [[ "$GPU" == nvidia || "$GPU" == amd ]] || die "GPU must be nvidia or amd."
}

load_or_ask_settings() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  else
    prompt HOST_NAME 'Hostname: '
    prompt USER_NAME 'Username: '
    prompt_secret ROOT_PASSWORD 'Root password: '
    prompt_secret USER_PASSWORD "Password for ${USER_NAME}: "
    prompt LOCALE 'Locale [en_US.UTF-8]: '
    prompt TIMEZONE 'Timezone (example: Asia/Tokyo): '
    prompt KEYMAP 'Keymap (example: us): '
  fi
  if [[ -z "$CPU" ]]; then
    prompt CPU 'CPU (intel / amd): '
  fi
  if [[ -z "$GPU" ]]; then
    prompt GPU 'GPU (nvidia / amd): '
  fi
  validate_settings
}

configure_system() {
  local locale_re root_uuid user_shell=/bin/bash
  printf 'Configuring the new system as root.\n'

  ln -sfn "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  if ! hwclock --systohc; then
    printf 'Warning: failed to set the hardware clock.\n' >&2
  fi

  locale_re=${LOCALE//./\\.}
  sed -i -E "s/^#?[[:space:]]*(${locale_re})[[:space:]]+UTF-8[[:space:]]*$/${LOCALE} UTF-8/" /etc/locale.gen
  if ! grep -qxF "${LOCALE} UTF-8" /etc/locale.gen; then
    printf '%s UTF-8\n' "$LOCALE" >>/etc/locale.gen
  fi
  grep -qxF "${LOCALE} UTF-8" /etc/locale.gen || die "Failed to enable locale: ${LOCALE}"
  printf 'LANG=%s\n' "$LOCALE" >/etc/locale.conf
  locale-gen

  printf 'KEYMAP=%s\n' "$KEYMAP" >/etc/vconsole.conf
  printf '%s\n' "$HOST_NAME" >/etc/hostname
  cat >/etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOST_NAME}.localdomain ${HOST_NAME}
EOF

  if [[ -x /bin/zsh ]]; then
    user_shell=/bin/zsh
  fi
  if id "$USER_NAME" >/dev/null 2>&1; then
    usermod -aG wheel -s "$user_shell" "$USER_NAME"
  else
    useradd -m -G wheel -s "$user_shell" "$USER_NAME"
  fi
  printf '%s:%s\n' root "$ROOT_PASSWORD" | chpasswd
  printf '%s:%s\n' "$USER_NAME" "$USER_PASSWORD" | chpasswd

  printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/wheel
  chmod 440 /etc/sudoers.d/wheel
  visudo -c >/dev/null

  install -d -m 755 /etc/aals
  printf 'CPU=%q\nGPU=%q\n' "$CPU" "$GPU" >/etc/aals/hardware
  chmod 644 /etc/aals/hardware

  pacman -S --noconfirm --needed iwd snapper zram-generator
  configure_network
  configure_snapper
  configure_zram

  mkinitcpio -P
  ensure_btrfs_in_initramfs

  systemd-machine-id-setup
  root_uuid=$(findmnt -no UUID /)
  [[ -n "$root_uuid" ]] || die "Failed to read the root UUID."
  deploy_limine "$root_uuid"
  configure_resolved_symlink
}

configure_network() {
  printf 'Enabling systemd-networkd, iwd, and systemd-resolved.\n'
  install -d -m 755 /etc/iwd /etc/systemd/network
  cat >/etc/iwd/main.conf <<'EOF'
[General]
EnableNetworkConfiguration=false
EOF
  cat >/etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=en*
Name=eth*

[Network]
DHCP=yes
EOF
  cat >/etc/systemd/network/25-wireless.network <<'EOF'
[Match]
Name=wl*

[Network]
DHCP=yes
EOF
  chmod 644 /etc/iwd/main.conf /etc/systemd/network/20-wired.network /etc/systemd/network/25-wireless.network
  systemctl enable systemd-networkd.service systemd-resolved.service iwd.service
}

configure_snapper() {
  printf 'Configuring Snapper.\n'
  if [[ ! -f /etc/snapper/configs/root ]]; then
    if findmnt -M /.snapshots >/dev/null; then
      umount /.snapshots
    fi
    if [[ -e /.snapshots ]]; then
      if btrfs subvolume show /.snapshots >/dev/null 2>&1; then
        btrfs subvolume delete /.snapshots
      else
        rmdir /.snapshots
      fi
    fi
    snapper -c root create-config /
    btrfs subvolume delete /.snapshots
    mkdir -m 750 /.snapshots
    mount /.snapshots
  fi
  findmnt -M /.snapshots >/dev/null || die "/.snapshots is not mounted."
  chmod 750 /.snapshots
  systemctl enable snapper-timeline.timer snapper-cleanup.timer
}

configure_zram() {
  printf 'Configuring ZRAM.\n'
  install -d -m 755 /etc/systemd
  cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
EOF
  chmod 644 /etc/systemd/zram-generator.conf
}

configure_resolved_symlink() {
  if [[ "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" == /run/systemd/resolve/stub-resolv.conf ]]; then
    return 0
  fi
  if mountpoint -q /etc/resolv.conf; then
    umount /etc/resolv.conf || return 0
  fi
  ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
}

ensure_btrfs_in_initramfs() {
  local image=/boot/initramfs-linux.img
  if initramfs_has_btrfs "$image"; then
    return 0
  fi
  grep -Eq '^MODULES=\([[:space:]]*\)$' /etc/mkinitcpio.conf || die "The initramfs has no btrfs module."
  sed -i -E 's/^MODULES=\([[:space:]]*\)$/MODULES=(btrfs)/' /etc/mkinitcpio.conf
  mkinitcpio -P
  initramfs_has_btrfs "$image" || die "The initramfs has no btrfs module."
}

initramfs_has_btrfs() {
  local image=$1 listing
  [[ -f "$image" ]] || return 1
  listing=$(lsinitcpio "$image")
  [[ "$listing" == *btrfs.ko* ]]
}

deploy_limine() {
  local root_uuid=$1 efi=/usr/share/limine/BOOTX64.EFI cmdline machine_id
  printf 'Installing Limine.\n'
  [[ -f "$efi" ]] || die "Limine EFI binary is missing: ${efi}"
  [[ -f /boot/vmlinuz-linux && -f /boot/initramfs-linux.img && -f /boot/initramfs-linux-fallback.img ]] || die "The linux kernel or initramfs is missing from /boot."
  machine_id=$(tr -d '[:space:]' </etc/machine-id)
  [[ "$machine_id" =~ ^[a-f0-9]{32}$ ]] || die "Invalid machine-id."
  cmdline="root=UUID=${root_uuid} rw rootflags=subvol=@"

  install -Dm644 "$efi" /boot/EFI/BOOT/BOOTX64.EFI
  rm -f /boot/EFI/BOOT/limine.conf
  cat >/boot/limine.conf <<EOF
timeout: 5

/Arch Linux
comment: machine-id=${machine_id}

  //linux
  protocol: linux
  kernel_path: boot():/vmlinuz-linux
  module_path: boot():/initramfs-linux.img
  kernel_cmdline: ${cmdline}

  //linux (fallback)
  protocol: linux
  kernel_path: boot():/vmlinuz-linux
  module_path: boot():/initramfs-linux-fallback.img
  kernel_cmdline: ${cmdline}

  //Snapshots
EOF
}

main() {
  assert_environment
  load_or_ask_settings
  configure_system
  rm -f "$ENV_FILE"
  unset ROOT_PASSWORD USER_PASSWORD
  sync
  printf 'Base system setup is complete. ZRAM is enabled after reboot.\n'
  printf 'Ethernet uses DHCP. For Wi-Fi, connect with iwctl, then run %s as the regular user.\n' "$DESKTOP_SCRIPT"
}

main "$@"
