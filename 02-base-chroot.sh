#!/usr/bin/env bash
# 新システム内の root で実行する（arch-chroot、または起動後の root）。
# Live ISO では実行しない。失敗してもディスクは消さない。
# ここまでが素のベース OS。ネットワーク、Snapper、Limine までを設定する。
# CachyOS リポジトリ、paru、デスクトップは起動後の 03-desktop.sh。
# /root/aals/install.env があればそれを使い、成功時に削除する。無ければ入力を求める。
if [ -z "${BASH_VERSION:-}" ]; then
  printf 'bash で実行してください。\n' >&2
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
    read -rs -p 'もう一度入力: ' second
    printf '\n' >&2
    if [[ -n "$first" && "$first" == "$second" ]]; then
      printf -v "$var" '%s' "$first"
      return 0
    fi
    printf '一致しないか、空です。\n' >&2
  done
}

has_mount_option() {
  local mountpoint=$1 option=$2 options
  options=$(findmnt -no OPTIONS "$mountpoint" || true)
  [[ -n "$options" && ",${options}," == *",${option},"* ]]
}

assert_environment() {
  local root_type boot_type
  [[ "$(id -u)" -eq 0 ]] || die "root で実行してください。"
  root_type=$(findmnt -no FSTYPE / || true)
  [[ "$root_type" == btrfs ]] || die "新システムの Btrfs ルートで実行してください。Live ISO では 01-base.sh を使ってください。"
  has_mount_option / subvol=@ || has_mount_option / subvol=/@ || die "ルートがサブボリューム @ ではありません。"
  has_mount_option /home subvol=@home || has_mount_option /home subvol=/@home || die "/home がサブボリューム @home ではありません。"
  has_mount_option /.snapshots subvol=@snapshots || has_mount_option /.snapshots subvol=/@snapshots || die "/.snapshots がサブボリューム @snapshots ではありません。"
  boot_type=$(findmnt -no FSTYPE /boot || true)
  [[ "$boot_type" == vfat ]] || die "/boot が ESP（vfat）ではありません。"
  [[ -x "$DESKTOP_SCRIPT" ]] || die "03-desktop.sh がありません: ${DESKTOP_SCRIPT}"
}

validate_settings() {
  local keymap_path
  [[ "$HOST_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die "ホスト名が不正です。"
  [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "ユーザー名が不正です。"
  case "$USER_NAME" in
    root | greeter) die "このユーザー名は使えません。" ;;
  esac
  [[ -n "$ROOT_PASSWORD" && "$ROOT_PASSWORD" != *$'\n'* ]] || die "root のパスワードが不正です。"
  [[ -n "$USER_PASSWORD" && "$USER_PASSWORD" != *$'\n'* ]] || die "ユーザーのパスワードが不正です。"
  [[ "$LOCALE" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "ロケールの指定が不正です。"
  grep -Eq "^#?${LOCALE//./\\.} UTF-8$" /etc/locale.gen || die "locale.gen に無いロケールです: ${LOCALE}"
  [[ "$TIMEZONE" != *..* && "$TIMEZONE" != /* && -f "/usr/share/zoneinfo/${TIMEZONE}" ]] || die "タイムゾーンが見つかりません: ${TIMEZONE}"
  [[ "$KEYMAP" =~ ^[A-Za-z0-9_-]+$ ]] || die "キーマップの指定が不正です。"
  keymap_path=$(find /usr/share/kbd/keymaps -type f -name "${KEYMAP}.map.gz" -print -quit)
  [[ -n "$keymap_path" ]] || die "キーマップが見つかりません: ${KEYMAP}"
  [[ "$CPU" == intel || "$CPU" == amd ]] || die "CPU は intel または amd です。"
  [[ "$GPU" == nvidia || "$GPU" == amd ]] || die "GPU は nvidia または amd です。"
}

load_or_ask_settings() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  else
    prompt HOST_NAME 'ホスト名: '
    prompt USER_NAME 'ユーザー名: '
    prompt_secret ROOT_PASSWORD 'root のパスワード: '
    prompt_secret USER_PASSWORD "${USER_NAME} のパスワード: "
    prompt LOCALE 'ロケール（例: en_US.UTF-8）: '
    prompt TIMEZONE 'タイムゾーン（例: Asia/Tokyo）: '
    prompt KEYMAP 'キーマップ（例: us）: '
  fi
  if [[ -z "$CPU" ]]; then
    prompt CPU 'CPU（intel / amd）: '
  fi
  if [[ -z "$GPU" ]]; then
    prompt GPU 'GPU（nvidia / amd）: '
  fi
  validate_settings
}

configure_system() {
  local locale_re root_uuid
  printf '新システム内の root として設定しています。\n'

  ln -sfn "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  if ! hwclock --systohc; then
    printf 'Warning: ハードウェア時計を設定できませんでした。\n' >&2
  fi

  locale_re=${LOCALE//./\\.}
  sed -i "s/^#${locale_re} UTF-8\$/${LOCALE} UTF-8/" /etc/locale.gen
  grep -qxF "${LOCALE} UTF-8" /etc/locale.gen || die "ロケールを有効にできません: ${LOCALE}"
  printf 'LANG=%s\n' "$LOCALE" >/etc/locale.conf
  locale-gen

  printf 'KEYMAP=%s\n' "$KEYMAP" >/etc/vconsole.conf
  printf '%s\n' "$HOST_NAME" >/etc/hostname
  cat >/etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOST_NAME}.localdomain ${HOST_NAME}
EOF

  if id "$USER_NAME" >/dev/null 2>&1; then
    usermod -aG wheel -s /bin/bash "$USER_NAME"
  else
    useradd -m -G wheel -s /bin/bash "$USER_NAME"
  fi
  printf '%s:%s\n' root "$ROOT_PASSWORD" | chpasswd
  printf '%s:%s\n' "$USER_NAME" "$USER_PASSWORD" | chpasswd

  printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/wheel
  chmod 440 /etc/sudoers.d/wheel
  visudo -c >/dev/null

  install -d -m 755 /etc/aals
  printf 'CPU=%q\nGPU=%q\n' "$CPU" "$GPU" >/etc/aals/hardware
  chmod 644 /etc/aals/hardware

  pacman -S --noconfirm --needed iwd snapper
  configure_network
  configure_snapper

  mkinitcpio -P
  ensure_btrfs_in_initramfs

  systemd-machine-id-setup
  root_uuid=$(findmnt -no UUID /)
  [[ -n "$root_uuid" ]] || die "ルートの UUID を取得できません。"
  deploy_limine "$root_uuid"
  configure_resolved_symlink
}

configure_network() {
  printf 'systemd-networkd、iwd、systemd-resolved を有効にしています。\n'
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
  printf 'Snapper を設定しています。\n'
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
  findmnt -M /.snapshots >/dev/null || die "/.snapshots がマウントされていません。"
  chmod 750 /.snapshots
  systemctl enable snapper-timeline.timer snapper-cleanup.timer
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
  grep -Eq '^MODULES=\([[:space:]]*\)$' /etc/mkinitcpio.conf || die "initramfs に btrfs モジュールがありません。"
  sed -i -E 's/^MODULES=\([[:space:]]*\)$/MODULES=(btrfs)/' /etc/mkinitcpio.conf
  mkinitcpio -P
  initramfs_has_btrfs "$image" || die "initramfs に btrfs モジュールがありません。"
}

initramfs_has_btrfs() {
  local image=$1 listing
  [[ -f "$image" ]] || return 1
  listing=$(lsinitcpio "$image")
  [[ "$listing" == *btrfs.ko* ]]
}

deploy_limine() {
  local root_uuid=$1 efi=/usr/share/limine/BOOTX64.EFI cmdline machine_id
  printf 'Limine を配置しています。\n'
  [[ -f "$efi" ]] || die "Limine の EFI バイナリがありません: ${efi}"
  [[ -f /boot/vmlinuz-linux && -f /boot/initramfs-linux.img && -f /boot/initramfs-linux-fallback.img ]] || die "linux のカーネルまたは initramfs が /boot にありません。"
  machine_id=$(tr -d '[:space:]' </etc/machine-id)
  [[ "$machine_id" =~ ^[a-f0-9]{32}$ ]] || die "machine-id が不正です。"
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
  printf 'ベース OS の設定が完了しました。再起動してください。\n'
  printf '有線は DHCP で接続します。無線は iwctl で接続してから、一般ユーザーで %s を実行してください。\n' "$DESKTOP_SCRIPT"
}

main "$@"
