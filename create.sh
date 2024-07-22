#!/bin/sh -eu
# shellcheck disable=SC2039

#############################################################################
# Generated on Mon Jul 22 07:43:22 2024 by create-alpine-disk-image
# version 0.3-DEV using the following options:
#
#   --arch x86_64
#   --barebones
#   --cloud aliyun
#   --release 3.18
#   --script-host-arch x86_64
#   --script-host-os ubuntu
#   --script-filename create.sh
#
#############################################################################

if [ "$(id -u)" -ne 0 ]; then
  printf '\nThis script must be run as the root user!\n\n'
  exit 1
fi


#############################################################################
##   Functions
#############################################################################

#
# Checks that the host OS has all necessary packages installed.
#
check_for_required_packages() {
  local _required_packages
  local _host_os

  _host_os=$(detect_host_os)
  case $_host_os in
    ubuntu )
      _required_packages="coreutils jq mount qemu-utils util-linux wget parted e2fsprogs"

      # shellcheck disable=SC2086
      if ! dpkg-query -W -f='${Status}\n' $_required_packages 1>/dev/null 2>&1; then
        printf '\nThe following packages need to be installed:\n\n'
        printf '  %s\n\n' "$_required_packages"
        exit 1
      fi
      # The apk.static package requires a CAs file to use for trusting HTTPS
      # connections but it is hardcoded to look for /etc/apk/ca.pem, which is
      # Alpine-specific. Create this directory on the host machine and copy
      # the host's usual CA file there. This directory will be deleted when
      # this script finishes.
      if [ ! -d /etc/apk ]; then
        mkdir -p /etc/apk
        temp_ca_dir_created=true
      else
        temp_ca_dir_created=false
      fi
      if [ ! -f /etc/apk/ca.pem ]; then
        cp /etc/ssl/certs/ca-certificates.crt /etc/apk/ca.pem
        temp_ca_file_created=true
      else
        temp_ca_file_created=false
      fi
      ;;

    * )
      case $_host_os in
        alpine | debian | ubuntu )
          printf \
            '\nRe-run create-alpine-disk-image specifying '\''--script-host-os %s'\''!\n\n' \
            "$_host_os"
          ;;
        * )
          printf '\nUnsupported host OS!\n\n' ;;
      esac
      exit 1
      ;;
  esac
}

#
# Determine the host architecture that script is being run on.
#
detect_host_arch() {
  uname -m
}

#
# Determine the Linux distro that script is being run on.
#
detect_host_os() {
  grep "^ID=" /etc/os-release | sed -e 's/^ID=//'
}

#
# Unmount filesystems whenever an error occurs in the script.
#
# shellcheck disable=SC2317
error_cleanup() {
  write_log
  write_log
  write_log "AN ERROR OCCURRED, cleaning up before aborting!"
  write_log
  write_log

  if [ -f "$chroot_dir"/chroot.log ]; then
    cat "$chroot_dir"/chroot.log >> "$logfile"
  fi

  normal_cleanup "error"
}

#
# Get the UUID of the filesystem in the specified device.
#
get_uuid_from_device() {
  blkid -s UUID -o value "$1"
}

#
# Unmount filesystems mounted inside chroot directory.
#
normal_cleanup() {
  local _param="${1:-}"

  # Clear exit trap function
  trap EXIT

  if [ -z "$_param" ]; then
    write_log "Normal cleanup"
  fi

  unmount_chroot_fs "/tmp"
  if [ -n "$working_dir" ]; then
    rmdir "$working_dir"
  fi
  unmount_chroot_fs "/dev"
  unmount_chroot_fs "/sys"
  unmount_chroot_fs "/proc"
  unmount_chroot_fs "/"

  if [ -n "$loop_device" ]; then
    write_log "Freeing up loop device '$loop_device'" 2
    losetup -d "$loop_device" >> "$logfile"
    _rc=$?
    if [ $_rc -ne 0 ]; then
      printf '\nThere was a problem freeing the loop device '\''%s'\''!\n\n' \
        "$loop_device"
      exit 1
    fi
  fi
}

#
# Unmount a filesystem inside chroot.
#
unmount_chroot_fs() {
  local _mountpoint="$1"
  local _where_from="${2:-inside chroot}"

  local _full_path _pseudo_path

  if [ "$_mountpoint" = "/" ]; then
    _full_path="$chroot_dir"
    _pseudo_path="root filesystem"
  else
    _full_path="${chroot_dir}${_mountpoint}"
    _pseudo_path="$_mountpoint"
  fi

  if mount | grep -q "$_full_path" ; then
    write_log "Unmounting ${_pseudo_path} ${_where_from}" 2
    umount -l -f "$_full_path" >> "$logfile"
  fi
}

#
# Write debug messages only to the log file.
#
write_debug_log() {
  local _log_entry="$1"
  local _indent="${2:-0}"

  local _current_time

  # Debug not enabled so do nothing
  true
}

#
# Write log messages to both logfile (with timestamp) and stdout.
#
write_log() {
  local _log_entry="${1:-}"
  local _indent="${2:-0}"

  local _current_time

  _current_time=$(printf "[%s]" "$(date -u "+%Y-%m-%d %H:%M:%S")")
  # shellcheck disable=SC1117
  printf "${_current_time} %${_indent}s${_log_entry}\n" >> "$logfile"
  # shellcheck disable=SC1117
  printf "%${_indent}s$_log_entry\n"
}

#############################################################################
##   Main Section
#############################################################################

chroot_dir="./chroot"
images_dir="./alpine-images"
TMPDIR="/var/tmp"

image_filename="./alpine-v3.18-x86_64-cloud-aliyun.img"
logfile="./alpine-v3.18-x86_64-cloud-aliyun.log"


# Create empty logfile
:> $logfile

image_full_filename="$images_dir/$image_filename"
working_dir=""


check_for_required_packages

# Ensure if any errors occur that various cleanup operations happen
trap error_cleanup EXIT

mkdir -p $images_dir

write_log "Creating sparse disk image of 175MiB"
truncate -s 175M $image_full_filename >> $logfile

write_log "Partitioning disk image for BIOS"
{
  write_debug_log "Creating msdos disk label" 2
  parted --machine --script --align=optimal $image_full_filename \
    mklabel msdos >> "$logfile" 2>&1
  write_debug_log "Creating 174MiB Root partition" 2
  parted --machine --script --align=optimal $image_full_filename \
    unit MiB mkpart primary  2MiB 100% >> "$logfile" 2>&1
  write_debug_log "Setting partition boot flag on" 2
  parted --machine --script --align=optimal $image_full_filename \
    set 1 boot on >> "$logfile" 2>&1
}

write_log "Setting up loop device for disk image"
{
  write_log "Ensuring that loop driver is loaded (if necessary)" 2
  if [ ! -c /dev/loop-control ]; then
    loop_module_filename=$(modinfo -F filename loop 2>/dev/null)
    if [ "$loop_module_filename" != "" ] && \
       [ "$loop_module_filename" != "(builtin)" ]; then
      modprobe loop 2>> $logfile
    else
      printf '\nThere is a problem with loop devices!\n\n'
      exit 1
    fi
  fi
  
  write_log "Setting up loop device with 512-byte sector size for disk image" 2
  loop_device=$(losetup -P --show -b 512 -f $image_full_filename 2>> $logfile)
  _rc=$?
  if [ $_rc -ne 0 ]; then
    if [ -n "$loop_device" ]; then
      unset loop_device
      printf '\nThere was a problem creating the loop device!\n\n'
    else
      printf \
        '\nThere was a problem creating the loop device '\''%s'\''!\n\n' \
        "$loop_device"
    fi
    exit 1
  fi
  if [ -z "$loop_device" ]; then
    printf '\nThere was a problem creating the loop device. Aborting!\n\n'
    exit 1
  fi
}

write_log "Formatting and mounting filesystems"
{
  root_part_device="${loop_device}p1"

  write_log "Formatting Ext4 root filesystem on partition" 2
  mkfs.ext4 -L alpine-root -I 256 -q "$root_part_device" >> "$logfile" 2>&1

  root_fs_uuid="$(get_uuid_from_device "$root_part_device")"

  write_log "Mounting root filesystem onto $chroot_dir" 2
  mkdir -p "$chroot_dir"
  mount -o private "$root_part_device" "$chroot_dir" >> "$logfile" 2>&1
}

_host_arch="x86_64"
write_log "Downloading statically built APK tool for ${_host_arch} arch"
{
  wget -q -O /var/tmp/apk.static \
    https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v2.14.0/"${_host_arch}"/apk.static \
    2>> "$logfile"
  _rc=$?
  case $_rc in
    5 )
      error_message "Error with wget HTTPS certificate validation!" ;;
    1 | 3 | 4 | 7 | 8 )
      error_message "A wget error ($_rc) occurred during download!" ;;
  esac
  chmod +x /var/tmp/apk.static

  if ! echo "1c65115a425d049590bec7c729c7fd88357fbb090a6fc8c31d834d7b0bc7d6f2 /var/tmp/apk.static" | sha256sum -c >/dev/null; then
    error_message "The checksum of the downloaded APK tool does not match the expected checksum!"
  fi
}

write_log "Copying system's /etc/resolv.conf into chroot filesystem"
mkdir -p "$chroot_dir"/etc
cp /etc/resolv.conf "$chroot_dir"/etc/

write_log "Creating /etc/apk/repositories file inside chroot"
mkdir -p "$chroot_dir"/etc/apk/keys
{
  printf '%s/%s/main\n' "https://dl-cdn.alpinelinux.org/alpine" "v3.18"
  printf '%s/%s/community\n' "https://dl-cdn.alpinelinux.org/alpine" "v3.18"
} > "$chroot_dir"/etc/apk/repositories

write_log "Bootloader packages to be installed are: grub grub-bios"

write_log \
  "Install base Alpine & bootloader packages for x86_64 arch inside chroot"
{
  _apk_binary="$TMPDIR/apk.static"

  # shellcheck disable=SC2086
  $_apk_binary --arch "x86_64" --initdb --allow-untrusted \
    --root $chroot_dir --update-cache \
    add alpine-base ifupdown-ng mkinitfs grub grub-bios \
    >> "$logfile" 2>&1
  _rc=$?
  if [ $_rc -ne 0 ]; then
    write_log "Failure while installing base Alpine, error code: $_rc"
    exit 1
  fi

  # Tidy-up after apk.static run
  rm -f $TMPDIR/apk.static
  if [ "$temp_ca_dir_created" = "true" ]; then
    echo "deleting the temporary CA directory"
    rm -Rf /etc/apk
  elif [ "$temp_ca_file_created" = "true" ]; then
    echo "deleting the temporary CA file"
    rm -f /etc/apk/ca.pem
  fi
}

write_log "Mounting tmp, /proc, /sys, and /dev special filesystems in chroot"
{
  working_dir=$(mktemp -d -p /tmp create-alpine.XXXXXX)
  _rc=$?
  if [ $_rc -ne 0 ]; then
    printf '\nThere was a problem creating a temporary working directory!\n\n'
    exit 1
  fi
  mount -v -t none -o rbind "$working_dir" $chroot_dir/tmp
  mount -v --make-rprivate $chroot_dir/tmp
  mount -v -t proc none $chroot_dir/proc
  mount -v -t none -o rbind /sys $chroot_dir/sys
  mount -v --make-rprivate $chroot_dir/sys
  mount -v -t none -o rbind /dev $chroot_dir/dev
  mount -v --make-rprivate $chroot_dir/dev
} >> $logfile 2>&1

#############################################################################
##		Start of Chroot section
#############################################################################

cat <<EOT | chroot $chroot_dir /bin/sh -eu
#!/bin/sh -eu

keymap="us us"
locale="en_US.UTF-8"
umask="077"

############################################################################
##		Chroot Functions
############################################################################

add_fstab_entry() {
  local _entry_type="\$1"
  local _entry_value="\$2"
  local _mount_point="\$3"
  local _fs_type="\$4"
  local _fs_options="\${5:-}"
  local _entry_log="\${6:-}"

  local _fstab_entry

  if [ "\$_entry_type" = "BIND" ]; then
    _fs_options="bind,\${_fs_options}"
    local _fs_passno="0"
  elif [ "\$_fs_type" = "swap" ]; then
    _mount_point="none"
    _fs_options="sw"
    local _fs_passno="0"
    _entry_log="Swap partition"
  elif [ "\$_fs_type" = "tmpfs" ]; then
    local _fs_passno="0"
  elif [ "\$_mount_point" = "/" ]; then
    local _fs_passno="1"
  else
    local _fs_passno="2"
  fi

  if [ "\$_entry_type" = "BIND" ] || [ "\$_entry_type" = "DEVICE" ]; then
    _fstab_entry="\${_entry_value}"
  else
    _fstab_entry="\${_entry_type}=\${_entry_value}"
  fi
  _fstab_entry="\${_fstab_entry}\t\${_mount_point}\t\${_fs_type}\t\${_fs_options} 0 \${_fs_passno}"

  write_log "Add \${_entry_log} entry" 2
  # shellcheck disable=SC2059
  printf "\${_fstab_entry}\n" >> /etc/fstab
}

find_module_full_path() {
  local _module="\$1"

  local _module_path

  _module_path="\$(find /lib/modules/ -name "\$_module.ko*" | \
    sed -e 's/^.*kernel/kernel/' -e 's/\.ko.*$//')"

  if [ -z "\$_module_path" ]; then
    _module="\$(echo "\$_module" | sed -e 's/-/_/g')"
    _module_path="\$(find /lib/modules/ -name "\$_module.ko*" | \
      sed -e 's/^.*kernel/kernel/' -e 's/\.ko.*$//')"
  fi

  if [ -n "\$_module_path" ]; then
    _module_path="\${_module_path}.ko*"
  fi

  echo "\$_module_path"
}

get_kernel_package_version() {
  apk info linux-virt | head -n 1 | sed -e "s/^linux-virt-//" \
    -e 's/ .*//'
}

get_kernel_version() {
  apk info linux-virt | head -n 1 | sed -e "s/^linux-virt-//" \
    -e 's/-r/-/' -e 's/ .*//' -Ee "s/^(.*)$/\1-virt/"
}

write_debug_log() {
  local _log_entry="\$1"
  local _indent=\${2:-0}

  local _current_time

  # Debug not enabled so do nothing
  true
}

write_log() {
  local _log_entry="\$1"
  local _indent=\${2:-0}

  local _current_time

  _current_time=\$(printf "[%s]" "\$(date -u "+%Y-%m-%d %H:%M:%S")")
  # shellcheck disable=SC1117
  printf "\$_current_time chroot: %\${_indent}s\${_log_entry}\n" >> /chroot.log
  # shellcheck disable=SC1117
  printf "chroot: %\${_indent}s\${_log_entry}\n"
}

############################################################################
##		Chroot Main Section
############################################################################

write_log "Add /etc/fstab entries"
{
  add_fstab_entry DEVICE "tmpfs" "/tmp" "tmpfs" "nosuid,nodev" "/tmp on tmpfs"
  add_fstab_entry UUID "$root_fs_uuid" "/" "ext4" "rw,relatime" "rootfs"
}

write_log "Adding additional repos"
{
  write_log "Adding community repo to /etc/apk/repositories" 2
  cat <<-_SCRIPT_ >> /etc/apk/repositories
	https://dl-cdn.alpinelinux.org/alpine/v3.18/community
	_SCRIPT_
}

write_log "Updating packages info"
{
  write_log "Updating packages list" 2
  apk update >> /chroot.log

  write_log "Upgrading base packages if necessary" 2
  apk -a upgrade >> /chroot.log
}

write_log "Doing basic OS configuration"
{
  write_log "Setting the login and MOTD messages" 2
  printf '\nWelcome\n\n' > /etc/issue
  printf '\n\n%s\n\n' "Alpine x86_64 aliyun Cloud server" > /etc/motd

  write_log "Setting the keymap to '\$keymap'" 2
  # shellcheck disable=SC2086
  setup-keymap \$keymap >> "/chroot.log" 2>&1

  locale_file="20locale.sh"
  if [ -e "\$locale_file" ]; then
    write_log "Setting locale to \$locale" 2
    sed -i -E -e "s/^(export LANG=)C.UTF-8/\1\$locale/" \\
      /etc/profile.d/\${locale_file}
  else
    write_log "Creating profile file to set locale to \$locale" 2
    {
      printf '# Created by create-alpine-disk-image\n#\n'
      printf 'export LANG=%s\n' "\$locale"
    } > /etc/profile.d/\${locale_file}
  fi

  write_log "Setting system-wide UMASK" 2
  {
    umask_file="05-umask.sh"
    write_log "Creating profile file to set umask to \$umask" 4
    {
      printf '# Created by create-alpine-disk-image\n\n'
      printf 'umask %s\n' "\$umask"
    } > /etc/profile.d/\${umask_file}
  }

  write_log "Set OpenRC to log init.d start/stop sequences" 2
  sed -i -e 's|[#]rc_logger=.*|rc_logger="YES"|g' /etc/rc.conf

  write_log \
    "Configure /etc/init.d/bootmisc to keep previous dmesg logfile" 2
  sed -i -e 's|[#]previous_dmesg=.*|previous_dmesg=yes|g' /etc/conf.d/bootmisc

  write_log "Enable colour shell prompt" 2
  cp /etc/profile.d/color_prompt.sh.disabled /etc/profile.d/color_prompt.sh

  write_log "Enable mdev init.d services" 2
  setup-devd mdev >> /chroot.log 2>&1 || true

  rmdir /media/floppy
}

write_log "Setup /etc/modules-load.d/cloud-aliyun.conf"
{
  if ! grep -q af_packet /etc/modules; then
    cat <<-_SCRIPT_ > /etc/modules-load.d/cloud-aliyun.conf
	af_packet
	_SCRIPT_
  fi

  if ! grep -q ipv6 /etc/modules; then
    cat <<-_SCRIPT_ >> /etc/modules-load.d/cloud-aliyun.conf
	ipv6
	_SCRIPT_
  fi

  cat <<-_SCRIPT_ >> /etc/modules-load.d/cloud-aliyun.conf
	
	# Network
	virtio_net
	
	# Storage
	virtio_blk
	_SCRIPT_
}

write_log "Enable init.d scripts"
{
  rc-update add devfs sysinit
  rc-update add dmesg sysinit

  rc-update add bootmisc boot
  rc-update add hostname boot
  rc-update add modules boot
  rc-update add swap boot
  rc-update add seedrng boot
  rc-update add osclock boot

  rc-update add networking default

  rc-update add killprocs shutdown
  rc-update add mount-ro shutdown
  rc-update add savecache shutdown
} >> /chroot.log 2>&1

add_packages="doas cpio e2fsprogs dhclient dropbear"
write_log "Install additional packages: \$add_packages"
{
  # shellcheck disable=SC2086
  apk add \$add_packages >> /chroot.log 2>&1
}

add_os_config_software_packages="ifupdown-ng-iproute2 iproute2-minimal busybox"
write_log \
  "Install OS configuration software packages: \$add_os_config_software_packages"
{
  # shellcheck disable=SC2086
  apk add \$add_os_config_software_packages >> /chroot.log 2>&1
}

machine_specific_packages="ifupdown-ng-iproute2 iproute2-minimal"
write_log \
  "Install additional machine specific packages: \$machine_specific_packages"
{
  # shellcheck disable=SC2086
  apk add \$machine_specific_packages >> /chroot.log 2>&1
}

write_log "Doing additional OS configuration"
{
  write_log "Configure doas" 2
  {
    write_log "Adding doas configuration for root user" 4
    cat <<-_SCRIPT_ >> /etc/doas.d/doas.conf
	
	# Allow root to run doas (i.e. "doas -u <user> <command>")
	permit nopass root
	_SCRIPT_

    write_log "Enabling doas configuration for wheel group" 4
    sed -i -E -e 's/^[#][ ]*(permit persist :wheel)$/\1/g' \
      /etc/doas.d/doas.conf
  }
}

write_log "Configuring system with neither cloud-init nor tiny-cloud"
{
  write_log "Creating /etc/network/interfaces" 2
  {
    cat <<-_SCRIPT_ >> /etc/network/interfaces
	# /etc/network/interfaces
	
	auto lo
	iface lo inet loopback
	iface lo inet6 loopback
	
	auto eth0
	iface eth0 inet dhcp
	
	# control-alias eth0
	iface eth0 inet6 dhcp
	
	_SCRIPT_
  }

  write_log "Locking the root account" 2
  passwd -l root >> /chroot.log

  write_log "Setting up default user 'alpine'" 2
  {
    write_log "Creating user account" 4
    adduser -D -g "Default user" alpine

    write_log "Default user's account is locked (for password access)" 4

    write_log "Adding user to group 'wheel'" 4
    addgroup alpine wheel >> /chroot.log
  }
}

write_log "Disable non-server kernel modules"
{
  write_log "Blacklisting drivers kernel modules" 2
  {
    cat <<-_SCRIPT_ > /etc/modprobe.d/blacklist-drivers-modules.conf
	blacklist cfbcopyarea
	blacklist cfbfillrect
	blacklist cfbimgblt
	blacklist drm
	blacklist drm_buddy
	blacklist drm_display_helper
	blacklist drm_dma_helper
	blacklist drm_kms_helper
	blacklist drm_mipi_dbi
	blacklist drm_panel_orientation_quirks
	blacklist drm_shmem_helper
	blacklist drm_suballoc_helper
	blacklist drm_ttm_helper
	blacklist drm_vram_helper
	blacklist fb
	blacklist fb_sys_fops
	blacklist fbdev
	blacklist syscopyarea
	blacklist sysfillrect
	blacklist sysimgblt
	blacklist ttm
	blacklist bochs
	blacklist simpledrm
	blacklist amdgpu
	blacklist analogix-anx78xx
	blacklist analogix_dp
	blacklist ast
	blacklist gpu-sched
	blacklist gud
	blacklist mgag200
	blacklist nouveau
	blacklist radeon
	blacklist sil164
	blacklist tda998x
	blacklist vgem
	blacklist gma500_gfx
	blacklist i810
	blacklist i915
	blacklist mga
	blacklist r128
	blacklist savage
	blacklist sis
	blacklist tdfx
	blacklist via
	blacklist cirrus
	blacklist drm_xen_xfront
	blacklist hyperv_drm
	blacklist hyperv_fb
	blacklist qxl
	blacklist vboxvideo
	blacklist virtio_dma_buf
	blacklist virtio-gpu
	blacklist vmwgfx
	blacklist efivars
	blacklist efivarsfs
	blacklist efi-pstore
	blacklist usbkbd
	blacklist mousedev
	blacklist psmouse
	blacklist usbmouse
	blacklist xen-scsiback
	blacklist xen-scsifront
	blacklist hid-apple
	blacklist hid-asus
	blacklist hid-cherry
	blacklist hid-cougar
	blacklist hid-generic
	blacklist hid-keytouch
	blacklist hid-lenovo
	blacklist hid-logitech-hidpp
	blacklist hid-logitech
	blacklist hid-microsoft
	blacklist hid-roccat-arvo
	blacklist hid-roccat-common
	blacklist hid-roccat-isku
	blacklist hid-roccat-ryos
	blacklist hid-roccat
	blacklist hid-semitek
	blacklist ehci-pci
	blacklist ohci-pci
	blacklist uhci-hcd
	blacklist xhci-pci
	blacklist hyperv-keyboard
	blacklist button
	blacklist virtio_rng
	blacklist vmwgfx
	blacklist hv_balloon
	blacklist qemu_fw_cfg
	blacklist vboxguest
	blacklist vmw_balloon
	blacklist vmw_vmci
	blacklist vmw_vsock_virtio_transport
	blacklist vmw_vsock_virtio_transport_common
	blacklist vmw_vsock_vmci_transport
	blacklist vmxnet3
	blacklist vsock
	blacklist vsock_diag
	blacklist vsock_loopback
	blacklist xen-scsiback
	blacklist xen-scsifront
	blacklist ac
	blacklist acpi_power_meter
	blacklist battery
	blacklist evdev
	blacklist hwmon
	blacklist i2c-piix4
	blacklist usb_storage
	blacklist usbmon
	blacklist ehci-platform
	blacklist ohci-platform
	blacklist xhci-plat-hcd
	blacklist efa
	blacklist ena
	blacklist mana
	blacklist hid-hyperv
	blacklist hv_netvsc
	blacklist hv_storvsc
	blacklist hv_utils
	blacklist hv_vmbus
	blacklist pci-hyperv
	blacklist pci-hyperv-intf
	blacklist hv_balloon
	blacklist vmwgfx
	blacklist vmw_balloon
	blacklist vmw_vmci
	blacklist vmw_vsock_virtio_transport
	blacklist vmw_vsock_virtio_transport_common
	blacklist vmw_vsock_vmci_transport
	blacklist vmxnet3
	blacklist vsock
	blacklist vsock_diag
	blacklist vsock_loopback
	blacklist gve
	blacklist amdgpu
	blacklist analogix-anx78xx
	blacklist analogix_dp
	blacklist ast
	blacklist gpu-sched
	blacklist gud
	blacklist mgag200
	blacklist nouveau
	blacklist radeon
	blacklist sil164
	blacklist tda998x
	blacklist vgem
	blacklist gma500_gfx
	blacklist i810
	blacklist i915
	blacklist mga
	blacklist r128
	blacklist savage
	blacklist sis
	blacklist tdfx
	blacklist via
	blacklist ptp
	blacklist ptp_kvm
	blacklist ptp_vmw
	_SCRIPT_

    sort -u -o /etc/modprobe.d/blacklist-drivers-modules.conf \
      /etc/modprobe.d/blacklist-drivers-modules.conf
  }

  write_log "Disabling drivers kernel modules" 2
  {
    cat <<-_SCRIPT_ > /etc/modprobe.d/disable-drivers-modules.conf
	install cfbcopyarea /bin/true
	install cfbfillrect /bin/true
	install cfbimgblt /bin/true
	install drm /bin/true
	install drm_buddy /bin/true
	install drm_display_helper /bin/true
	install drm_dma_helper /bin/true
	install drm_kms_helper /bin/true
	install drm_mipi_dbi /bin/true
	install drm_panel_orientation_quirks /bin/true
	install drm_shmem_helper /bin/true
	install drm_suballoc_helper /bin/true
	install drm_ttm_helper /bin/true
	install drm_vram_helper /bin/true
	install fb /bin/true
	install fb_sys_fops /bin/true
	install fbdev /bin/true
	install syscopyarea /bin/true
	install sysfillrect /bin/true
	install sysimgblt /bin/true
	install ttm /bin/true
	install bochs /bin/true
	install simpledrm /bin/true
	install amdgpu /bin/true
	install analogix-anx78xx /bin/true
	install analogix_dp /bin/true
	install ast /bin/true
	install gpu-sched /bin/true
	install gud /bin/true
	install mgag200 /bin/true
	install nouveau /bin/true
	install radeon /bin/true
	install sil164 /bin/true
	install tda998x /bin/true
	install vgem /bin/true
	install gma500_gfx /bin/true
	install i810 /bin/true
	install i915 /bin/true
	install mga /bin/true
	install r128 /bin/true
	install savage /bin/true
	install sis /bin/true
	install tdfx /bin/true
	install via /bin/true
	install cirrus /bin/true
	install drm_xen_xfront /bin/true
	install hyperv_drm /bin/true
	install hyperv_fb /bin/true
	install qxl /bin/true
	install vboxvideo /bin/true
	install virtio_dma_buf /bin/true
	install virtio-gpu /bin/true
	install vmwgfx /bin/true
	install efivars /bin/true
	install efivarsfs /bin/true
	install efi-pstore /bin/true
	install usbkbd /bin/true
	install mousedev /bin/true
	install psmouse /bin/true
	install usbmouse /bin/true
	install xen-scsiback /bin/true
	install xen-scsifront /bin/true
	install hid-apple /bin/true
	install hid-asus /bin/true
	install hid-cherry /bin/true
	install hid-cougar /bin/true
	install hid-generic /bin/true
	install hid-keytouch /bin/true
	install hid-lenovo /bin/true
	install hid-logitech-hidpp /bin/true
	install hid-logitech /bin/true
	install hid-microsoft /bin/true
	install hid-roccat-arvo /bin/true
	install hid-roccat-common /bin/true
	install hid-roccat-isku /bin/true
	install hid-roccat-ryos /bin/true
	install hid-roccat /bin/true
	install hid-semitek /bin/true
	install ehci-pci /bin/true
	install ohci-pci /bin/true
	install uhci-hcd /bin/true
	install xhci-pci /bin/true
	install hyperv-keyboard /bin/true
	install button /bin/true
	install virtio_rng /bin/true
	install vmwgfx /bin/true
	install hv_balloon /bin/true
	install qemu_fw_cfg /bin/true
	install vboxguest /bin/true
	install vmw_balloon /bin/true
	install vmw_vmci /bin/true
	install vmw_vsock_virtio_transport /bin/true
	install vmw_vsock_virtio_transport_common /bin/true
	install vmw_vsock_vmci_transport /bin/true
	install vmxnet3 /bin/true
	install vsock /bin/true
	install vsock_diag /bin/true
	install vsock_loopback /bin/true
	install xen-scsiback /bin/true
	install xen-scsifront /bin/true
	install ac /bin/true
	install acpi_power_meter /bin/true
	install battery /bin/true
	install evdev /bin/true
	install hwmon /bin/true
	install i2c-piix4 /bin/true
	install usb_storage /bin/true
	install usbmon /bin/true
	install ehci-platform /bin/true
	install ohci-platform /bin/true
	install xhci-plat-hcd /bin/true
	install efa /bin/true
	install ena /bin/true
	install mana /bin/true
	install hid-hyperv /bin/true
	install hv_netvsc /bin/true
	install hv_storvsc /bin/true
	install hv_utils /bin/true
	install hv_vmbus /bin/true
	install pci-hyperv /bin/true
	install pci-hyperv-intf /bin/true
	install hv_balloon /bin/true
	install vmwgfx /bin/true
	install vmw_balloon /bin/true
	install vmw_vmci /bin/true
	install vmw_vsock_virtio_transport /bin/true
	install vmw_vsock_virtio_transport_common /bin/true
	install vmw_vsock_vmci_transport /bin/true
	install vmxnet3 /bin/true
	install vsock /bin/true
	install vsock_diag /bin/true
	install vsock_loopback /bin/true
	install gve /bin/true
	install amdgpu /bin/true
	install analogix-anx78xx /bin/true
	install analogix_dp /bin/true
	install ast /bin/true
	install gpu-sched /bin/true
	install gud /bin/true
	install mgag200 /bin/true
	install nouveau /bin/true
	install radeon /bin/true
	install sil164 /bin/true
	install tda998x /bin/true
	install vgem /bin/true
	install gma500_gfx /bin/true
	install i810 /bin/true
	install i915 /bin/true
	install mga /bin/true
	install r128 /bin/true
	install savage /bin/true
	install sis /bin/true
	install tdfx /bin/true
	install via /bin/true
	install ptp /bin/true
	install ptp_kvm /bin/true
	install ptp_vmw /bin/true
	_SCRIPT_
    sort -u -o /etc/modprobe.d/disable-drivers-modules.conf \
      /etc/modprobe.d/disable-drivers-modules.conf
  }

  write_log "Blacklisting fs kernel modules" 2
  {
    cat <<-_SCRIPT_ > /etc/modprobe.d/blacklist-fs-modules.conf
	blacklist cramfs
	blacklist dlm
	blacklist ecryptfs
	blacklist efs
	blacklist exfat
	blacklist gfs2
	blacklist hfs
	blacklist hfsplus
	blacklist hpfs
	blacklist jfs
	blacklist minix
	blacklist nilfs2
	blacklist ntfs
	blacklist ntfs3
	blacklist ocfs2
	blacklist ocfs2_stack_o2cb
	blacklist ocfs2_stack_user
	blacklist ocfs2_stackglue
	blacklist ocfs2_nodemanager
	blacklist ocfs2_dlm
	blacklist ocfs2_dlmfs
	blacklist omfs
	blacklist reiserfs
	blacklist romfs
	blacklist sysv
	blacklist ufs
	blacklist 9p
	blacklist vboxsf
	blacklist virtiofs
	_SCRIPT_

    sort -u -o /etc/modprobe.d/blacklist-fs-modules.conf \
      /etc/modprobe.d/blacklist-fs-modules.conf
  }

  write_log "Disabling fs kernel modules" 2
  {
    cat <<-_SCRIPT_ > /etc/modprobe.d/disable-fs-modules.conf
	install cramfs /bin/true
	install dlm /bin/true
	install ecryptfs /bin/true
	install efs /bin/true
	install exfat /bin/true
	install gfs2 /bin/true
	install hfs /bin/true
	install hfsplus /bin/true
	install hpfs /bin/true
	install jfs /bin/true
	install minix /bin/true
	install nilfs2 /bin/true
	install ntfs /bin/true
	install ntfs3 /bin/true
	install ocfs2 /bin/true
	install ocfs2_stack_o2cb /bin/true
	install ocfs2_stack_user /bin/true
	install ocfs2_stackglue /bin/true
	install ocfs2_nodemanager /bin/true
	install ocfs2_dlm /bin/true
	install ocfs2_dlmfs /bin/true
	install omfs /bin/true
	install reiserfs /bin/true
	install romfs /bin/true
	install sysv /bin/true
	install ufs /bin/true
	install 9p /bin/true
	install vboxsf /bin/true
	install virtiofs /bin/true
	_SCRIPT_
    sort -u -o /etc/modprobe.d/disable-fs-modules.conf \
      /etc/modprobe.d/disable-fs-modules.conf
  }

  write_log "Blacklisting net kernel modules" 2
  {
    cat <<-_SCRIPT_ > /etc/modprobe.d/blacklist-net-modules.conf
	blacklist ah4
	blacklist ah6
	blacklist esp4
	blacklist esp6
	blacklist fou
	blacklist fou6
	blacklist ife
	blacklist ila
	blacklist ip_gre
	blacklist ip_vti
	blacklist ip6_gre
	blacklist ip6_vti
	blacklist ipcomp
	blacklist ipcomp6
	blacklist libceph
	blacklist llc2
	blacklist mip6
	blacklist nsh
	blacklist pktgen
	blacklist dccp
	blacklist dccp_diag
	blacklist dccp_ipv4
	blacklist dccp_ipv6
	blacklist ip_tunnel
	blacklist ip6_tunnel
	blacklist ip6_udp_tunnel
	blacklist ipip
	blacklist tunnel4
	blacklist udp_tunnel
	blacklist ip_vs
	blacklist ip_vs_dh
	blacklist ip_vs_fo
	blacklist ip_vs_ftp
	blacklist ip_vs_lblc
	blacklist ip_vs_lblcr
	blacklist ip_vs_lc
	blacklist ip_vs_nq
	blacklist ip_vs_ovf
	blacklist ip_vs_pe_sip
	blacklist ip_vs_rr
	blacklist ip_vs_sed
	blacklist ip_vs_sh
	blacklist ip_vs_wlc
	blacklist ip_vs_wrr
	blacklist l2tp_core
	blacklist l2tp_eth
	blacklist l2tp_ip
	blacklist l2tp_ip6
	blacklist l2tp_netlink
	blacklist l2tp_ppp
	blacklist mpls_gso
	blacklist mpls_iptunnel
	blacklist mpls_router
	blacklist openvswitch
	blacklist vport-geneve
	blacklist vport-gre
	blacklist vport-vxlan
	blacklist sctp
	blacklist sctp_diag
	blacklist nf_conntrack_amanda
	blacklist nf_nat_amanda
	blacklist nf_conntrack_ftp
	blacklist nf_nat_ftp
	blacklist nf_conntrack_h323
	blacklist nf_conntrack_irc
	blacklist nf_nat_irc
	blacklist nf_conntrack_sip
	blacklist nf_nat_sip
	blacklist nf_conntrack_snmp
	blacklist nf_conntrack_tftp
	blacklist nf_nat_tftp
	blacklist 9pnet_virtio
	_SCRIPT_

    sort -u -o /etc/modprobe.d/blacklist-net-modules.conf \
      /etc/modprobe.d/blacklist-net-modules.conf
  }

  write_log "Disabling net kernel modules" 2
  {
    cat <<-_SCRIPT_ > /etc/modprobe.d/disable-net-modules.conf
	install ah4 /bin/true
	install ah6 /bin/true
	install esp4 /bin/true
	install esp6 /bin/true
	install fou /bin/true
	install fou6 /bin/true
	install ife /bin/true
	install ila /bin/true
	install ip_gre /bin/true
	install ip_vti /bin/true
	install ip6_gre /bin/true
	install ip6_vti /bin/true
	install ipcomp /bin/true
	install ipcomp6 /bin/true
	install libceph /bin/true
	install llc2 /bin/true
	install mip6 /bin/true
	install nsh /bin/true
	install pktgen /bin/true
	install dccp /bin/true
	install dccp_diag /bin/true
	install dccp_ipv4 /bin/true
	install dccp_ipv6 /bin/true
	install ip_tunnel /bin/true
	install ip6_tunnel /bin/true
	install ip6_udp_tunnel /bin/true
	install ipip /bin/true
	install tunnel4 /bin/true
	install udp_tunnel /bin/true
	install ip_vs /bin/true
	install ip_vs_dh /bin/true
	install ip_vs_fo /bin/true
	install ip_vs_ftp /bin/true
	install ip_vs_lblc /bin/true
	install ip_vs_lblcr /bin/true
	install ip_vs_lc /bin/true
	install ip_vs_nq /bin/true
	install ip_vs_ovf /bin/true
	install ip_vs_pe_sip /bin/true
	install ip_vs_rr /bin/true
	install ip_vs_sed /bin/true
	install ip_vs_sh /bin/true
	install ip_vs_wlc /bin/true
	install ip_vs_wrr /bin/true
	install l2tp_core /bin/true
	install l2tp_eth /bin/true
	install l2tp_ip /bin/true
	install l2tp_ip6 /bin/true
	install l2tp_netlink /bin/true
	install l2tp_ppp /bin/true
	install mpls_gso /bin/true
	install mpls_iptunnel /bin/true
	install mpls_router /bin/true
	install openvswitch /bin/true
	install vport-geneve /bin/true
	install vport-gre /bin/true
	install vport-vxlan /bin/true
	install sctp /bin/true
	install sctp_diag /bin/true
	install nf_conntrack_amanda /bin/true
	install nf_nat_amanda /bin/true
	install nf_conntrack_ftp /bin/true
	install nf_nat_ftp /bin/true
	install nf_conntrack_h323 /bin/true
	install nf_conntrack_irc /bin/true
	install nf_nat_irc /bin/true
	install nf_conntrack_sip /bin/true
	install nf_nat_sip /bin/true
	install nf_conntrack_snmp /bin/true
	install nf_conntrack_tftp /bin/true
	install nf_nat_tftp /bin/true
	install 9pnet_virtio /bin/true
	_SCRIPT_
    sort -u -o /etc/modprobe.d/disable-net-modules.conf \
      /etc/modprobe.d/disable-net-modules.conf
  }
}

write_log "Installing kernel linux-virt"
{
  apk add linux-virt linux-firmware-none >> /chroot.log 2>&1

  _kernel_version=\$(get_kernel_version)
  _kernel_package_version=\$(get_kernel_package_version)
}

write_log "Configuring mkinitfs"
{
  write_log "Setting up mkinitfs.conf" 2

  sed -i -e \
    "s|^features=\".*\"|features=\"optimise-base keymap optimise-ext4 cloud-aliyun\"|" \
    /etc/mkinitfs/mkinitfs.conf

  # Base
  {
    write_log "Setting up features.d/optimise-base.files" 2
    {
      echo "/bin/busybox"
      echo "/bin/sh"
      echo "/etc/mdev.conf"
      echo "/etc/modprobe.d/aliases.conf"
      echo "/etc/modprobe.d/i386.conf"
      echo "/etc/modprobe.d/kms.conf"
      echo "/lib/mdev"
      echo "/sbin/nlplug-findfs"
    } > /etc/mkinitfs/features.d/optimise-base.files

    write_log "Setting up features.d/optimise-base.modules" 2
    cat <<-_SCRIPT_ > /etc/mkinitfs/features.d/optimise-base.modules
	_SCRIPT_
  }

  # Ext4
  {
    write_log "Setting up features.d/optimise-ext4.modules" 2
    cat <<-_SCRIPT_ > /etc/mkinitfs/features.d/optimise-ext4.modules
	kernel/arch/*/crypto/crc32c-intel.ko*
	kernel/crypto/crc32c*.ko*
	kernel/fs/ext4
	kernel/fs/jbd2
	kernel/fs/mbcache
	kernel/lib/crc16.ko*
	_SCRIPT_
  }

  # cloud-aliyun
  {
    write_log "Setting up features.d/cloud-aliyun.modules" 2
    cat <<-_SCRIPT_ > /etc/mkinitfs/features.d/cloud-aliyun.modules
	kernel/drivers/acpi/tiny-power-button.ko*
	kernel/drivers/block/virtio_blk.ko*
	_SCRIPT_

    # Sort and remove duplicate entries
    sort -u -o \
      /etc/mkinitfs/features.d/cloud-aliyun.modules \
      /etc/mkinitfs/features.d/cloud-aliyun.modules
  }

  write_log "Regenerating initramfs" 2
  mkinitfs "\$_kernel_version" >> /chroot.log 2>&1
}

write_log "Configuring Grub"
{
  mkdir -p /boot/grub

  # If relevant package is not already installed then install it
  if [ ! "\$(apk info -e losetup)" ]; then
    write_log "Installing losetup package for losetup" 2
    apk add losetup >> /chroot.log 2>&1
    losetup_package_installed=true
  fi

  write_log "Updating /etc/default/grub" 2
  {
    sed -i \
      -e 's|^GRUB_DISABLE_RECOVERY=.*$|GRUB_DISABLE_RECOVERY=false|g' \
      -e 's|^GRUB_TIMEOUT=.*$|GRUB_TIMEOUT=5|g' \
      -e '/^GRUB_CMDLINE_LINUX_DEFAULT=.*$/d' \
      /etc/default/grub

    cmdline="rootfstype=ext4 log_buf_len=32768 console=ttyS0,115200 tiny_power_button.power_signal=12 consoleblank=0 clocksource=kvm-clock quiet nomodeset"
    {
      echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$cmdline\""
      echo 'GRUB_ENABLE_LINUX_LABEL=false'
      echo 'GRUB_GFXPAYLOAD_LINUX=text'
      echo 'GRUB_DISABLE_LINUX_UUID=false'
      echo 'GRUB_DISABLE_OS_PROBER=true'
      echo 'GRUB_RECORDFAIL_TIMEOUT=20'
    } >> /etc/default/grub
    if ! grep -q "^GRUB_TERMINAL=" /etc/default/grub; then
      echo 'GRUB_TERMINAL=console' >> /etc/default/grub
    fi
    {
      echo 'GRUB_ENABLE_CRYPTODISK=n'
    } >> /etc/default/grub
    {
      write_log "Configure GRUB serial command" 4
      printf 'GRUB_SERIAL_COMMAND="serial %s"\n' "--unit=0 --speed=115200" \
        >> /etc/default/grub
      write_log "Configure GRUB for serial console" 4
      sed -i -e 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL="serial"/' \
        /etc/default/grub
    }

    write_log "Set Grub menu colours" 4
    {
      echo 'GRUB_COLOR_NORMAL=white/blue'
      echo 'GRUB_COLOR_HIGHLIGHT=blue/white'
    } >> /etc/default/grub

    chmod g=,o= /etc/default/grub
  }

  write_log "Generating GRUB config" 2
  grub-mkconfig -o /boot/grub/grub.cfg >> /chroot.log 2>&1

  write_log "Checking GRUB config" 2
  grub-script-check /boot/grub/grub.cfg >> /chroot.log

  chmod g=,o= /boot/grub/grub.cfg
}

write_log "Installing GRUB bootloader"
{
  write_log "Running GRUB installer" 2
  _grub_install_output=\$(grub-install \
    --target=i386-pc --no-floppy \
    --install-modules="acpi disk echo elf gzio linux loadenv minicmd normal search test ext2 serial nativedisk part_msdos" \
    $loop_device \
    2>&1 \
    | sed -e '/^grub-install: info: copying .*$/d' \
    | sed -e \
        '/^grub-install: info: cannot open .*No such file or directory.$/d' \
    | tee -a /chroot.log )
  if [ "\$(echo "\$_grub_install_output" | grep "error:")" != "" ]; then
    exit 1
  fi

  write_log "Storing grub-install options for later use" 2
  {
    printf "# /etc/grub-install-options.conf\n\n"
    printf 'GRUB_INSTALL_OPTIONS="%s' \
      "--target=i386-pc --no-floppy"
    printf ' --install-modules=\"%s\"' \
      "acpi disk echo elf gzio linux loadenv minicmd normal search test ext2 serial nativedisk part_msdos"
    printf '"\n\n'
    printf '# Change this setting to "yes" if you want grub-install to be\n'
    printf '# automatically run whenever the Alpine Grub package is updated.\n'
    printf 'GRUB_AUTO_UPDATE="no"\n\n'
    printf '# The device name used for Grub booting (only needs to be\n'
    printf '# specified if booting MBR - not needed for UEFI booting\n'
    printf '#GRUB_BOOT_DEVICE="/dev/sda"\n\n'
  } > /etc/grub-install-options.conf
  chown root:root /etc/grub-install-options.conf
  chmod u=rwx,g=r,o=r /etc/grub-install-options.conf

  if [ -n "\$losetup_package_installed" ]; then
    write_log "Removing losetup package that was temporarily installed" 2
    apk del losetup >> /chroot.log 2>&1
  fi
}

write_log "Configuring various system services"
{
  write_log "Adjusting modprobe blacklist for tiny-power-button" 4
  {
    write_log "Removing tiny_power_button module from modprobe blacklist" 6
    sed -i -E -e 's/^(blacklist tiny_power_button)$/#\1/' \\
      /etc/modprobe.d/blacklist.conf

    write_log "Adding ACPI button module to modprobe blacklist" 6
    printf '\n# Using tiny_power_button instead\nblacklist button\n' \
      >> /etc/modprobe.d/blacklist.conf
  }

  write_log "Configuring Cron daemon" 2
  {
    write_log "Configuring Busybox cron daemon" 4
    {
      write_log "Enable Busybox cron init.d service" 6
      {
        rc-update add crond default
      } >> /chroot.log 2>&1
    }
  }

  write_log "Configuring DHCP client" 2
  {
    write_log "Configuring dhclient" 4
    {
      :
    }
  }

  write_log "Configuring getty daemons" 2
  {
    write_log "Enable serial console" 4
    {
      write_log "Disabling getty on normal console tty1" 6
      sed -i -E -e 's|^tty1:|#tty1:|g' /etc/inittab
      write_log "Enabling getty on serial console ttyS0" 6
      if grep -E "^#?ttyS0:" /etc/inittab >/dev/null; then
        sed -i -E -e \
          's|^[#]ttyS0:.*|ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100|g' \
          /etc/inittab
      else
        printf \
          '\n#Additional getty for ttyS0\nttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100\n' \
          >> /etc/inittab
      fi
    }

    write_log "Disabling unused gettys" 4
    sed -i -E -e 's|^tty([2-6].*)|#tty\1|g' /etc/inittab
  }

  write_log "Configuring NTP server" 2
  {
    write_log "Configuring Busybox NTP daemon" 4
    {
      write_log "Enable Busybox ntpd init.d service" 6
      {
        rc-update add ntpd default
      } >> /chroot.log 2>&1
    }
  }

  write_log "Configuring Syslog server" 2
  {
    write_log "Configuring Busybox syslogd server" 4
    {
      write_log "Set logfile rotation options" 6
      sed -i -E -e 's|^(SYSLOGD_OPTS="-t)|\1 -b 14 -s 51200|' \
        /etc/conf.d/syslog

      write_log "Enable Busybox syslogd init.d service" 6
      {
        rc-update add syslog boot
      } >> /chroot.log 2>&1
    }
  }

  write_log "Configuring SSH server" 2
  {
    write_log "Configuring Dropbear SSH server" 4
    {
      write_log "Enable Dropbear init.d service" 6
      {
        rc-update add dropbear default
      } >> /chroot.log 2>&1
    }
  }

  write_log "Configuring console-only user account" 2
  {
    write_log "Creating 'console-only' group" 4
    addgroup console-only >> /chroot.log

    write_log "Configuring 'localadmin' user account" 4
    {
      write_log "Creating 'localadmin' user for console-only access" 6
      adduser -g "User for console-only access" -D localadmin >> /chroot.log

      write_log "Fix-up permissions for localadmin home directory" 6
      chmod g-rx,o-rx /home/localadmin

      write_log "Unlocking user account 'localadmin' (for password access)" 6
      passwd -u localadmin >> /chroot.log 2>&1 || true

      write_log "Setting up password-less doas access for 'console-only' group" 6
      {
        write_log \
          "Setting up doas for 'console-only' group" 8
        {
          printf \
            '\n# Enable password-less access for members of group '\''%s'\''\n' \
            "console-only"
          printf 'permit nopass :%s\n' "console-only"
        } >> /etc/doas.d/doas.conf

        write_log "Adding 'localadmin' user to 'console-only' group" 8
        addgroup localadmin console-only >> /chroot.log
      }
    }
  }
}

apk info -v | sort > /final-packages.list

write_log "Clearing APK cache"
rm /var/cache/apk/*

write_debug_log "Final disk space usage:"
busybox df -k >> /chroot.log

EOT

#############################################################################
##		End of Chroot section
#############################################################################

cat "$chroot_dir"/chroot.log >> "$logfile"
rm "$chroot_dir"/chroot.log

write_log "Finished chroot section"

write_log "Removing temporary /etc/resolv.conf from chroot filesystem"
rm "$chroot_dir"/etc/resolv.conf

mv "$chroot_dir"/final-packages.list \
  ./"$(basename -s .log $logfile)".final-packages

write_log "Cleaning up"
normal_cleanup

exit
