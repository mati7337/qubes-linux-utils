#!/bin/sh
echo "Qubes initramfs script here:"

mkdir -p /proc /sys /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

if [ -w /sys/devices/system/xen_memory/xen_memory0/scrub_pages ]; then
    # re-enable xen-balloon pages scrubbing, after initial balloon down
    echo 1 > /sys/devices/system/xen_memory/xen_memory0/scrub_pages
fi

if [ -e /dev/mapper/dmroot ] ; then 
    echo "Qubes: FATAL error: /dev/mapper/dmroot already exists?!"
fi

/sbin/modprobe xenblk || /sbin/modprobe xen-blkfront || echo "Qubes: Cannot load Xen Block Frontend..."

die() {
    echo "$@" >&2
    exit 1
}

echo "Waiting for /dev/xvda* devices..."
while ! [ -e /dev/xvda ]; do sleep 0.1; done

# prefer partition if exists
if [ -b /dev/xvda1 ]; then
    if [ -d /dev/disk/by-partlabel ]; then
        ROOT_DEV=$(readlink "/dev/disk/by-partlabel/Root\\x20filesystem")
        ROOT_DEV=${ROOT_DEV##*/}
    else
        ROOT_DEV=$(grep -l "PARTNAME=Root filesystem" /sys/block/xvda/xvda*/uevent |\
            grep -o "xvda[0-9]")
    fi
    if [ -z "$ROOT_DEV" ]; then
        # fallback to third partition
        ROOT_DEV=xvda3
    fi
else
    ROOT_DEV=xvda
fi

SWAP_SIZE_GiB=1
SWAP_SIZE_512B=$(( SWAP_SIZE_GiB * 1024 * 1024 * 2 ))

if [ `cat /sys/class/block/$ROOT_DEV/ro` = 1 ] ; then
    echo "Qubes: Doing COW setup for AppVM..."

    while ! [ -e /dev/xvdc ]; do sleep 0.1; done
    VOLATILE_SIZE_512B=$(cat /sys/class/block/xvdc/size)
    if [ $VOLATILE_SIZE_512B -lt $SWAP_SIZE_512B ]; then
        die "volatile.img smaller than $SWAP_SIZE_GiB GiB, cannot continue"
    fi
    /sbin/sfdisk -q /dev/xvdc >/dev/null <<EOF
xvdc1: type=82,start=1MiB,size=${SWAP_SIZE_GiB}GiB
xvdc2: type=83
EOF
    if [ $? -ne 0 ]; then
        echo "Qubes: failed to setup partitions on volatile device"
        exit 1
    fi
    while ! [ -e /dev/xvdc1 ]; do sleep 0.1; done
    /sbin/mkswap /dev/xvdc1
    while ! [ -e /dev/xvdc2 ]; do sleep 0.1; done

    echo "0 `cat /sys/class/block/$ROOT_DEV/size` snapshot /dev/$ROOT_DEV /dev/xvdc2 N 16" | \
        /sbin/dmsetup create dmroot || { echo "Qubes: FATAL: cannot create dmroot!"; exit 1; }
    /sbin/dmsetup mknodes dmroot
    echo Qubes: done.
else
    echo "Qubes: Doing R/W setup for TemplateVM..."
    while ! [ -e /dev/xvdc ]; do sleep 0.1; done
    /sbin/sfdisk -q /dev/xvdc >/dev/null <<EOF
xvdc1: type=82,start=1MiB,size=${SWAP_SIZE_GiB}GiB
xvdc3: type=83
EOF
    if [ $? -ne 0 ]; then
        die "Qubes: failed to setup partitions on volatile device"
    fi
    while ! [ -e /dev/xvdc1 ]; do sleep 0.1; done
    /sbin/mkswap /dev/xvdc1
    ln -s ../$ROOT_DEV /dev/mapper/dmroot
    echo Qubes: done.
fi

/sbin/modprobe ext4

mkdir -p /sysroot
mount /dev/mapper/dmroot /sysroot -o rw
NEWROOT=/sysroot

kver="`uname -r`"
if ! [ -d "$NEWROOT/lib/modules/$kver/kernel" ]; then
    echo "Waiting for /dev/xvdd device..."
    while ! [ -e /dev/xvdd ]; do sleep 0.1; done

    mkdir -p /tmp/modules
    mount -n -t ext3 /dev/xvdd /tmp/modules
    if /sbin/modprobe overlay; then
        # if overlayfs is supported, use that to provide fully writable /lib/modules
        if ! [ -d "$NEWROOT/lib/.modules_work" ]; then
            mkdir -p "$NEWROOT/lib/.modules_work"
        fi
        mount -t overlay none $NEWROOT/lib/modules -o lowerdir=/tmp/modules,upperdir=$NEWROOT/lib/modules,workdir=$NEWROOT/lib/.modules_work
    else
        # otherwise mount only `uname -r` subdirectory, to leave the rest of
        # /lib/modules writable
        if ! [ -d "$NEWROOT/lib/modules/$kver" ]; then
            mkdir -p "$NEWROOT/lib/modules/$kver"
        fi
        mount --bind "/tmp/modules/$kver" "$NEWROOT/lib/modules/$kver"
    fi
    umount /tmp/modules
    rmdir /tmp/modules
fi

umount /dev /sys /proc
mount "$NEWROOT" -o remount,ro

exec /sbin/switch_root $NEWROOT /sbin/init
