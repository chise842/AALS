#!/usr/bin/env bash
# 新システムに一度ログインしたあと、一般ユーザーで実行する。
# CachyOS リポジトリは公式の cachyos-repo.sh をそのまま実行する（確認プロンプトあり）。
# ユーザ設定ファイルは作らない。
if [ -z "${BASH_VERSION:-}" ]; then
  printf 'bash で実行してください。\n' >&2
  exit 1
fi

set -euo pipefail

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

has_mount_option() {
  local mountpoint=$1 option=$2 options
  options=$(findmnt -no OPTIONS "$mountpoint" || true)
  [[ -n "$options" && ",${options}," == *",${option},"* ]]
}

assert_environment() {
  local root_type groups
  [[ "$(id -u)" -ne 0 ]] || die "一般ユーザーで実行してください。root では 02-base-chroot.sh を使ってください。"
  root_type=$(findmnt -no FSTYPE / || true)
  [[ "$root_type" == btrfs ]] || die "新システム内で実行してください。Live ISO では 01-base.sh を使ってください。"
  has_mount_option /.snapshots subvol=@snapshots || has_mount_option /.snapshots subvol=/@snapshots || die "/.snapshots がサブボリューム @snapshots ではありません。"
  [[ -f /etc/snapper/configs/root ]] || die "Snapper の root 設定がありません。02-base-chroot.sh を実行してください。"
  groups=$(id -nG)
  [[ " ${groups} " == *" wheel "* ]] || die "wheel グループに入っていません。"
  command -v sudo >/dev/null || die "sudo がありません。"
}

load_hardware() {
  if [[ -r /etc/aals/hardware ]]; then
    # shellcheck disable=SC1091
    source /etc/aals/hardware
  fi
  if [[ "$CPU" != intel && "$CPU" != amd ]]; then
    prompt CPU 'CPU（intel / amd）: '
  fi
  if [[ "$GPU" != nvidia && "$GPU" != amd ]]; then
    prompt GPU 'GPU（nvidia / amd）: '
  fi
  [[ "$CPU" == intel || "$CPU" == amd ]] || die "CPU は intel または amd です。"
  [[ "$GPU" == nvidia || "$GPU" == amd ]] || die "GPU は nvidia または amd です。"
}

add_cachyos_repo() {
  printf 'CachyOS の公式スクリプトでリポジトリを追加します。確認が出たら応答してください。\n'
  printf 'この処理にはネットワークが必要です。\n'
  if ! command -v curl >/dev/null; then
    sudo pacman -S --needed curl
  fi
  (
    cd "$HOME"
    curl https://mirror.cachyos.org/cachyos-repo.tar.xz -o cachyos-repo.tar.xz
    tar xvf cachyos-repo.tar.xz && cd cachyos-repo
    sudo ./cachyos-repo.sh
  )
}

remove_if_installed() {
  local pkg
  for pkg in "$@"; do
    if pacman -Q "$pkg" >/dev/null 2>&1; then
      sudo pacman -Rns "$pkg"
    fi
  done
}

install_kernel() {
  local -a packages=(linux-cachyos)
  printf 'linux-cachyos と選択した CPU / GPU のパッケージを入れます。確認が出たら応答してください。\n'
  if [[ "$CPU" == intel ]]; then
    remove_if_installed amd-ucode
    packages+=(intel-ucode)
  else
    remove_if_installed intel-ucode
    packages+=(amd-ucode)
  fi
  if [[ "$GPU" == nvidia ]]; then
    remove_if_installed linux-firmware-amdgpu
    packages+=(linux-cachyos-nvidia-open)
  else
    remove_if_installed linux-cachyos-nvidia-open
    packages+=(linux-firmware-amdgpu)
  fi
  sudo pacman -S --needed "${packages[@]}"
  sudo mkinitcpio -P
  ensure_btrfs_in_initramfs
}

ensure_btrfs_in_initramfs() {
  local image=/boot/initramfs-linux-cachyos.img
  if initramfs_has_btrfs "$image"; then
    return 0
  fi
  grep -Eq '^MODULES=\([[:space:]]*\)$' /etc/mkinitcpio.conf || die "initramfs に btrfs モジュールがありません。"
  sudo sed -i -E 's/^MODULES=\([[:space:]]*\)$/MODULES=(btrfs)/' /etc/mkinitcpio.conf
  sudo mkinitcpio -P
  initramfs_has_btrfs "$image" || die "initramfs に btrfs モジュールがありません。"
}

initramfs_has_btrfs() {
  local image=$1 listing
  [[ -f "$image" ]] || return 1
  listing=$(lsinitcpio "$image")
  [[ "$listing" == *btrfs.ko* ]]
}

deploy_limine() {
  local root_uuid efi=/usr/share/limine/BOOTX64.EFI cmdline machine_id
  root_uuid=$(findmnt -no UUID /)
  [[ -n "$root_uuid" ]] || die "ルートの UUID を取得できません。"
  [[ -f "$efi" && -f /boot/EFI/BOOT/BOOTX64.EFI ]] || die "Limine の EFI バイナリがありません。"
  [[ -f /boot/vmlinuz-linux-cachyos && -f /boot/initramfs-linux-cachyos.img && -f /boot/initramfs-linux-cachyos-fallback.img ]] || die "linux-cachyos のカーネルまたは initramfs が /boot にありません。"
  machine_id=$(tr -d '[:space:]' </etc/machine-id)
  [[ "$machine_id" =~ ^[a-f0-9]{32}$ ]] || die "machine-id が不正です。"
  cmdline="root=UUID=${root_uuid} rw rootflags=subvol=@"
  sudo rm -f /boot/EFI/BOOT/limine.conf
  sudo tee /boot/limine.conf >/dev/null <<EOF
timeout: 5

/CachyOS
comment: machine-id=${machine_id}

  //linux-cachyos
  protocol: linux
  kernel_path: boot():/vmlinuz-linux-cachyos
  module_path: boot():/initramfs-linux-cachyos.img
  kernel_cmdline: ${cmdline}

  //linux-cachyos (fallback)
  protocol: linux
  kernel_path: boot():/vmlinuz-linux-cachyos
  module_path: boot():/initramfs-linux-cachyos-fallback.img
  kernel_cmdline: ${cmdline}

  //Snapshots
EOF
  if [[ -f /boot/vmlinuz-linux && -f /boot/initramfs-linux.img && -f /boot/initramfs-linux-fallback.img ]]; then
    sudo tee -a /boot/limine.conf >/dev/null <<EOF

/Arch Linux
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
EOF
  fi
}

install_paru() {
  if command -v paru >/dev/null; then
    return 0
  fi
  printf 'paru を AUR からビルドします。確認が出たら応答してください。\n'
  sudo pacman -S --needed base-devel git
  local work
  work=$(mktemp -d)
  git clone https://aur.archlinux.org/paru.git "${work}/paru"
  (cd "${work}/paru" && makepkg -si) || {
    rm -rf "$work"
    die "paru のビルドに失敗しました。"
  }
  rm -rf "$work"
  command -v paru >/dev/null || die "paru を実行できません。"
}

install_limine_snapper_sync() {
  printf 'limine-snapper-sync を入れます。確認が出たら応答してください。\n'
  paru -S --needed limine-snapper-sync
  sudo systemctl enable --now limine-snapper-sync.service
  sudo snapper -c root create --description aals
  sudo limine-snapper-sync
}

install_desktop() {
  printf 'Hyprland と greetd を入れます。確認が出たら応答してください。\n'
  sudo pacman -S --needed hyprland greetd greetd-tuigreet
  [[ -x /usr/bin/tuigreet && -x /usr/bin/Hyprland ]] || die "tuigreet または Hyprland がインストールされていません。"
  id greeter >/dev/null || die "greeter ユーザーがありません。"
  sudo tee /etc/greetd/config.toml >/dev/null <<'EOF'
[terminal]
vt = 1

[default_session]
command = "/usr/bin/tuigreet --cmd /usr/bin/Hyprland"
user = "greeter"
EOF
  sudo chmod 644 /etc/greetd/config.toml
  sudo systemctl enable greetd.service
}

main() {
  assert_environment
  load_hardware
  sudo -v
  add_cachyos_repo
  install_kernel
  deploy_limine
  install_desktop
  install_paru
  install_limine_snapper_sync
  printf 'ユーザ設定ファイルは作りません。再起動すると greetd が Hyprland を起動し、既定のカーネルは linux-cachyos です。\n'
  printf 'Snapper のスナップショットは Limine の Snapshots に出ます。\n'
}

main "$@"
