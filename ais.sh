set -e
FS_TYPE="f2fs"
DRIVE="/dev/CHANGETHIS nvme0n1"
KEYMAP="en"
ROOT_ENCRYPTED_MAPPER_NAME="cryptsystem"
BOOT_ENCRYPTED_MAPPER_NAME="cryptboot"
SYSTEM_PART="/dev/disk/by-partlabel/${ROOT_ENCRYPTED_MAPPER_NAME}"
BOOT_PART="/dev/disk/by-partlabel/${BOOT_ENCRYPTED_MAPPER_NAME}"
EFI_MOUNTPOINT="/boot/efi"
MOUNTPOINT="/mnt"

load_settings() {
    mount -o remount,size=2G /run/archiso/cowspace
    pacman -S base-devel
    #loadkeys $KEYMAP
    #setfont sun12x22
}

chroot_cmd() {
    arch-chroot ${MOUNTPOINT} /bin/bash -c "${1}"
}

#SETUP PARTITION{{{
create_partitions(){
    echo $DRIVE
    sgdisk --zap-all ${DRIVE}
    sgdisk --clear \
           --new=1:0:+550MiB --typecode=1:ef00 --change-name=1:EFI \
           --new=2:0:+1GiB   --typecode=2:8300 --change-name=2:${BOOT_ENCRYPTED_MAPPER_NAME} \
           --new=3:0:0       --typecode=3:8300 --change-name=3:${ROOT_ENCRYPTED_MAPPER_NAME} \
           ${DRIVE}
}

setup_luks(){
    echo "\nCreate encrypted boot partition\n"
    cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue --type luks1 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-random --verify-passphrase luksFormat ${BOOT_PART}
    cryptsetup open --type luks ${BOOT_PART} ${BOOT_ENCRYPTED_MAPPER_NAME}
    echo "\nCreate encrypted main partition\n"
    cryptsetup luksFormat --perf-no_read_workqueue --perf-no_write_workqueue --type luks2 --cipher aes-xts-plain64 --key-size 512 --iter-time 2000 --pbkdf argon2id --hash sha3-512 ${SYSTEM_PART}
    cryptsetup --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue --persistent open ${SYSTEM_PART} ${ROOT_ENCRYPTED_MAPPER_NAME}
}

format_parts(){
    echo "\nFormatting partitions..."
    mkfs.fat -F32 -n EFI /dev/disk/by-partlabel/EFI
    mkfs.ext2 /dev/mapper/${BOOT_ENCRYPTED_MAPPER_NAME}
    mkfs.btrfs -L ROOT /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME}
}

create_btrfs_subvolumes() {
    echo "\nCreating BTRFS subvolumes..."
    mount /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}
    btrfs sub create ${MOUNTPOINT}/@
    btrfs sub create ${MOUNTPOINT}/@home
    btrfs sub create ${MOUNTPOINT}/@cache
    btrfs sub create ${MOUNTPOINT}/@log
    btrfs sub create ${MOUNTPOINT}/@abs
    btrfs sub create ${MOUNTPOINT}/@tmp
    btrfs sub create ${MOUNTPOINT}/@srv
    btrfs sub create ${MOUNTPOINT}/@snapshots
    btrfs sub create ${MOUNTPOINT}/@btrfs
    btrfs sub create ${MOUNTPOINT}/@swap
    umount ${MOUNTPOINT}
    btrfs check --clear-space-cache v2 /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME}
}

mount_parts() {
    echo "\nMounting subvolumes.."
    mount -o noatime,nodiratime,compress=zstd,commit=120,space_cache,ssd,discard=async,autodefrag,subvol=@ /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME} /mnt
    #mkdir -p /mnt/{boot,home,var/cache/pacman/pkg,.snapshots,.swapvol,btrfs}
    mkdir -p ${MOUNTPOINT}/{boot,home,.snapshots,.swapvol,btrfs}
    mkdir -p ${MOUNTPOINT}/var/{cache,abs,tmp,log}
    mkdir -p ${MOUNTPOINT}/srv
    mount -o noatime,nodiratime,compress=zstd,commit=120,space_cache=v2,ssd,discard=async,autodefrag,subvol=@home /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}/home
    mount -o nodev,nosuid,noexec,noatime,nodiratime,compress=zstd,commit=120,space_cache=v2,ssd,discard=async,autodefrag,subvol=@cache /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}/var/cache
    mount -o nodev,nosuid,noexec,noatime,nodiratime,compress=zstd,commit=120,space_cache=v2,ssd,discard=async,autodefrag,subvol=@log /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}/var/log
    mount -o nodev,nosuid,noexec,noatime,nodiratime,compress=zstd,commit=120,space_cache=v2,ssd,discard=async,autodefrag,subvol=@abs /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}/var/abs
    mount -o nodev,nosuid,noexec,noatime,nodiratime,compress=zstd,commit=120,space_cache=v2,ssd,discard=async,autodefrag,subvol=@tmp /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}/var/tmp
    mount -o noatime,nodiratime,compress=zstd,commit=120,space_cache=v2,ssd,discard=async,autodefrag,subvol=@srv /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}/srv
    mount -o noatime,nodiratime,compress=zstd,commit=120,space_cache=v2,ssd,discard=async,autodefrag,subvol=@snapshots /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}/.snapshots
    mount -o compress=no,space_cache=v2,ssd,discard=async,subvol=@swap /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}/.swapvol
    mount -o noatime,nodiratime,compress=zstd,commit=120,space_cache=v2,ssd,discard=async,autodefrag,subvolid=5 /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}/btrfs

    # Create Swapfile
    #truncate -s 0 ${MOUNTPOINT}/.swapvol/swapfile
    #chattr +C ${MOUNTPOINT}/.swapvol/swapfile
    btrfs filesystem mkswapfile --size 17g ${MOUNTPOINT}/.swapvol/swapfile
    chmod 600 ${MOUNTPOINT}/.swapvol/swapfile
    #mkswap ${MOUNTPOINT}/.swapvol/swapfile
    swapon ${MOUNTPOINT}/.swapvol/swapfile

    #mkdir  ${MOUNTPOINT}/boot
    mount -o nodev,nosuid,noexec /dev/mapper/${BOOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}/boot
    mkdir  ${MOUNTPOINT}${EFI_MOUNTPOINT}

    # Mount the EFI partition
    mount LABEL=EFI  ${MOUNTPOINT}${EFI_MOUNTPOINT}
}

install_base() {
    echo "\nInstalling base system..."

    pacstrap ${MOUNTPOINT} base linux linux-firmware grub os-prober efibootmgr dosfstools grub-efi-x86_64 amd-ucode iw wireless_tools dhcpcd dialog wpa_supplicant base base-devel linux linux-firmware btrfs-progs sbsigntools zstd go iwd networkmanager mesa vulkan-radeon libva-mesa-driver mesa-vdpau docker libvirt qemu openssh zsh zsh-completions \
             zsh-autosuggestions zsh-history-substring-search zsh-syntax-highlighting git \
             pigz pbzip2 bc unbound vim
    genfstab -U ${MOUNTPOINT} >> ${MOUNTPOINT}/etc/fstab
    cat ${MOUNTPOINT}/etc/fstab
}

conf_locale_and_time() {
    echo "\nConfiguring time locale and host..."

    timedatectl set-ntp true
    # Replace username with the name for your new user
    export USER=koolkat
    # Replace hostname with the name for your host
    export HOST=MacBook
    # Replace Europe/London with your Region/City
    export TZ="America/Mexico_City"
    # - set locale
    echo "en_US.UTF-8 UTF-8" > ${MOUNTPOINT}/etc/locale.gen
    chroot_cmd locale-gen
    echo "LANG=\"en_US.UTF-8\"" > ${MOUNTPOINT}/etc/locale.conf
    echo "KEYMAP=us" > ${MOUNTPOINT}/etc/vconsole.conf
    export LANG="en_US.UTF-8"
    export LC_COLLATE="C"
    # - set timezone
    chroot_cmd "ln -sf /usr/share/zoneinfo/$TZ /etc/localtime"
    chroot_cmd "hwclock -uw" # or hwclock --systohc --utc
    # - set hostname
    echo $HOST > ${MOUNTPOINT}/etc/hostname
    # - add user
    chroot_cmd "useradd -mg users -G wheel,storage,power,docker,libvirt,kvm -r -s /bin/zsh $USER"

    echo "$USER ALL=(ALL) ALL" >> ${MOUNTPOINT}/etc/sudoers
    echo "Defaults timestamp_timeout=0" >> ${MOUNTPOINT}/etc/sudoers
    # - set hosts
    cat << EOF >> ${MOUNTPOINT}/etc/hosts
echo "# <ip-address>	<hostname.domain.org>	<hostname>"
echo "127.0.0.1	localhost"
echo "::1		localhost"
echo "127.0.1.1	$HOST.localdomain	$HOST"
EOF
    # - Set Network Manager iwd backend
    echo "[device]" > ${MOUNTPOINT}/etc/NetworkManager/conf.d/nm.conf
    echo "wifi.backend=iwd" >> ${MOUNTPOINT}/etc/NetworkManager/conf.d/nm.conf

    # - Preventing snapshot slowdowns
    echo 'PRUNENAMES = ".snapshots"' >> ${MOUNTPOINT}/etc/updatedb.conf
}

conf_mkinitcpio() {
    echo "\nConfiguring iniramfs..."

    sed -i 's/MODULES=()/MODULES=(amdgpu)/' ${MOUNTPOINT}/etc/mkinitcpio.conf
    echo "FILES=/etc/cryptsetup-keys.d/${ROOT_ENCRYPTED_MAPPER_NAME}.key" >> ${MOUNTPOINT}/etc/mkinitcpio.conf
    sed -i 's/#COMPRESSION="lz4"/COMPRESSION="lz4"/' ${MOUNTPOINT}/etc/mkinitcpio.conf
    sed -i 's/#COMPRESSION_OPTIONS=()/COMPRESSION_OPTIONS=(-9)/' ${MOUNTPOINT}/etc/mkinitcpio.conf
    sed -i 's/HOOKS=.*/HOOKS=(base systemd autodetect modconf block sd-encrypt resume filesystems keyboard fsck)/' ${MOUNTPOINT}/etc/mkinitcpio.conf

    ### dont ask pass second time for boot part
    mkdir ${MOUNTPOINT}/etc/cryptsetup-keys.d
    dd bs=512 count=4 if=/dev/random of=${MOUNTPOINT}/etc/cryptsetup-keys.d/${ROOT_ENCRYPTED_MAPPER_NAME}.key iflag=fullblock
    chroot_cmd "chmod 600 /etc/cryptsetup-keys.d/${ROOT_ENCRYPTED_MAPPER_NAME}.key"
    chroot_cmd "cryptsetup luksAddKey /dev/nvme0n1p2 /etc/cryptsetup-keys.d/${ROOT_ENCRYPTED_MAPPER_NAME}.key"
    chroot_cmd "cryptsetup luksAddKey /dev/nvme0n1p3 /etc/cryptsetup-keys.d/${ROOT_ENCRYPTED_MAPPER_NAME}.key"
    chroot_cmd "mkinitcpio -p linux"
}

optimize_mkpkg() {
    echo "\nSetting compiler flags for makepkg..."
    # Optimize Makepkg
    sed -i 's/^CFLAGS/CFLAGS="-march=native -mtune=native -O2 -pipe -fstack-protector-strong --param=ssp-buffer-size=4 -fno-plt"/' ${MOUNTPOINT}/etc/makepkg.conf
    sed -i 's/^CXXFLAGS/CXXFLAGS="${CFLAGS}"/' ${MOUNTPOINT}/etc/makepkg.conf
    sed -i 's/^#RUSTFLAGS/RUSTFLAGS="-C opt-level=2 -C target-cpu=native"/' ${MOUNTPOINT}/etc/makepkg.conf
    sed -i 's/^#BUILDDIR/BUILDDIR=\/tmp\/makepkg makepkg/' ${MOUNTPOINT}/etc/makepkg.conf
    sed -i 's/^#MAKEFLAGS/MAKEFLAGS="-j$(getconf _NPROCESSORS_ONLN) --quiet"/' ${MOUNTPOINT}/etc/makepkg.conf
    sed -i 's/^COMPRESSGZ/COMPRESSGZ=(pigz -c -f -n)/' ${MOUNTPOINT}/etc/makepkg.conf
    sed -i 's/^COMPRESSBZ2/COMPRESSBZ2=(pbzip2 -c -f)/' ${MOUNTPOINT}/etc/makepkg.conf
    sed -i 's/^COMPRESSXZ/COMPRESSXZ=(xz -T "$(getconf _NPROCESSORS_ONLN)" -c -z --best -)/' ${MOUNTPOINT}/etc/makepkg.conf
    sed -i 's/^COMPRESSZST/COMPRESSZST=(zstd -c -z -q --ultra -T0 -22 -)/' ${MOUNTPOINT}/etc/makepkg.conf
    sed -i 's/^COMPRESSLZ/COMPRESSLZ=(lzip -c -f)/' ${MOUNTPOINT}/etc/makepkg.conf
    sed -i 's/^COMPRESSLRZ/COMPRESSLRZ=(lrzip -9 -q)/' ${MOUNTPOINT}/etc/makepkg.conf
    sed -i 's/^COMPRESSLZO/COMPRESSLZO=(lzop -q --best)/' ${MOUNTPOINT}/etc/makepkg.conf
    sed -i 's/^COMPRESSZ/COMPRESSZ=(compress -c -f)/' ${MOUNTPOINT}/etc/makepkg.conf
    sed -i 's/^COMPRESSLZ4/COMPRESSLZ4=(lz4 -q --best)/' ${MOUNTPOINT}/etc/makepkg.conf

# Misc options
    sed -i 's/#UseSyslog/UseSyslog/' ${MOUNTPOINT}/etc/pacman.conf
    sed -i 's/#Color/Color\\\nILoveCandy/' ${MOUNTPOINT}/etc/pacman.conf
    sed -i 's/#TotalDownload/TotalDownload/' ${MOUNTPOINT}/etc/pacman.conf
    sed -i 's/#CheckSpace/CheckSpace/' ${MOUNTPOINT}/etc/pacman.conf
}

install_mech_kernel(){
    #https://wiki.archlinux.org/title/Sysctl#TCP/IP_stack_hardening
    #https://wiki.archlinux.org/title/Security#Kernel_hardening
    cat << EOF >> ${MOUNTPOINT}/etc/sysctl.d/51-sec.conf
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
kernel.kexec_load_disabled = 1
kernel.unprivileged_userns_clone = 0
kernel.kptr_restrict = 2
vm.dirty_ratio = 3
vm.dirty_background_ratio = 2
vm.vfs_cache_pressure = 50
EOF
    echo "\nInstalling mech17 kernel..."

    makepkg -si
}

# add boot partition to crypttab (replace <identifier> with UUID from 'blkid /dev/sda2')
conf_grub(){
    echo "\nConfiguring GRUB..."
    # Get resume  offset for BTRFS swapfile
    curl -LJO https://raw.githubusercontent.com/osandov/osandov-linux/master/scripts/btrfs_map_physical.c
    gcc -O2 -o btrfs_map_physical btrfs_map_physical.c
    rm btrfs_map_physical.c
    mv btrfs_map_physical /usr/local/bin

    sed -i -e "s%GRUB_CMDLINE_LINUX=.*%GRUB_CMDLINE_LINUX=\"lockdown=confidentiality rd.luks.name=$(blkid /dev/nvme0n1p3 | cut -d " " -f2 | cut -d '=' -f2 | sed 's/\"//g')=${ROOT_ENCRYPTED_MAPPER_NAME} root=/dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME} rootflags=subvol=@ resume=/dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME} resume_offset=$( echo "$(btrfs_map_physical ${MOUNTPOINT}/.swapvol/swapfile | head -n2 | tail -n1 | awk '{print $6}') / $(getconf PAGESIZE) " | bc) rw quiet nmi_watchdog=0 acpi_backlight=native acpi_osi=linux nvidia_drm.modeset=1 apparmor=1 security=apparmor amdgpu.cik_support=1\"%g" ${MOUNTPOINT}/etc/default/grub


    echo "GRUB_ENABLE_CRYPTODISK=y" >> ${MOUNTPOINT}/etc/default/grub
    echo "${BOOT_ENCRYPTED_MAPPER_NAME}  ${BOOT_PART}   /etc/cryptsetup-keys.d/${BOOT_ENCRYPTED_MAPPER_NAME}.key     noauto,luks" >> ${MOUNTPOINT}/etc/crypttab
    chroot_cmd "grub-install --target=x86_64-efi --efi-directory=${EFI_MOUNTPOINT} --bootloader-id=arch_grub --recheck"
    chroot_cmd "grub-mkconfig -o /boot/grub/grub.cfg"
}

mount_system() {
    cryptsetup open --type luks ${BOOT_PART} ${BOOT_ENCRYPTED_MAPPER_NAME}
    cryptsetup open --type luks ${SYSTEM_PART} ${ROOT_ENCRYPTED_MAPPER_NAME}
    sleep 2
    sync
    sleep 2
    mount /dev/mapper/lvm-root ${MOUNTPOINT}
    mount /dev/mapper/lvm-home ${MOUNTPOINT}/home
    mount /dev/mapper/${BOOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}/boot
    mount LABEL=EFI  ${MOUNTPOINT}${EFI_MOUNTPOINT}
}

load_settings
echo "Starting instalation"
echo "Seetings:"
echo "Install drive: ${DRIVE}"
lsblk -o NAME,SIZE,MOUNTPOINT $DRIVE
echo "Keymap: ${KEYMAP}"
echo "Filesystem: ${FS_TYPE}"
echo "ROOT / cryptab name: ${ROOT_ENCRYPTED_MAPPER_NAME}"
echo "BOOT /boot name: ${BOOT_ENCRYPTED_MAPPER_NAME}"
echo "System partition: ${SYSTEM_PART}"
echo "Boot partition: ${BOOT_PART}"
echo "Efi mountpoint ${EFI_MOUNTPOINT}"
echo "Chroot mountpoint ${MOUNTPOINT}"

install_mech(){
    create_partitions
    sleep 2
    setup_luks
    sleep 2
    format_parts
    sleep 2
    create_btrfs_subvolumes
    sleep 2
    mount_parts
    sleep 2
    install_base
    conf_locale_and_time
    sleep 1
    conf_mkinitcpio
    sleep 2
    #optimize_mkpkg
    #install_mech_kernel
    conf_grub
}

#install_mech
mount_system
