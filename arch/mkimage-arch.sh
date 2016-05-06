#!/usr/bin/env bash
# Generate a minimal filesystem for archlinux and load it into the local
# docker as "arch"
# requires root
set -e

DOCKER_IMAGE_NAME='arch'
DOCKER_IMAGE_TAG='20160501'
TIMEZONE='Europe/Copenhagen'

# Get the path to this script
MY_PATH=$(cd "$(dirname --zero "$0")" && pwd)

hash pacstrap &>/dev/null || {
	echo "Could not find 'pacstrap'. Run 'pacman -S arch-install-scripts'."
	exit 1
}

hash expect &>/dev/null || {
	echo "Could not find 'expect'. Run 'pacman -S expect'."
	exit 1
}

hash docker &>/dev/null || {
	echo "Could not find 'docker'. Run 'pacman -S docker'."
	exit 1
}

export LANG="C.UTF-8"

ROOTFS=$(mktemp -d ${TMPDIR:-/var/tmp}/rootfs-archlinux-XXXXXXXXXX)
chmod 755 ${ROOTFS}

# packages to ignore for space savings
IGNORE_PKGS=(
    cryptsetup
    device-mapper
    dhcpcd
    iproute2
    jfsutils
    linux
    lvm2
    man-db
    man-pages
    mdadm
    nano
    netctl
    openresolv
    pciutils
    pcmciautils
    reiserfsprogs
    s-nail
    systemd-sysvcompat
    usbutils
    vi
    xfsprogs
)
# Extra packages to install
EXTRA_PKGS=(
	haveged
)
IFS=','
IGNORE_PKGS="${IGNORE_PKGS[*]}"
EXTRA_PKGS="${EXTRA_PKGS[*]}"
unset IFS

PACMAN_CONF="${MY_PATH}/mkimage-arch-pacman.conf"

EXPECT_TIMEOUT=60
expect <<EOF
	set send_slow {1 .1}
	proc send {ignore arg} {
		sleep .1
		exp_send -s -- \$arg
	}
	set timeout $EXPECT_TIMEOUT
	spawn pacstrap -C $PACMAN_CONF -c -d -G -i $ROOTFS base $EXTRA_PKGS --ignore $IGNORE_PKGS
	expect {
		-exact "Install anyway? \[Y/n\] " { send -- "n\r"; exp_continue }
		-exact "(default=all): " { send -- "\r"; exp_continue }
		-exact "Proceed with installation? \[Y/n\]" { send -- "y\r"; exp_continue }
	}
EOF

# Copy airootfs overlay
cp -af ${MY_PATH}/airootfs/* ${ROOTFS}

arch-chroot ${ROOTFS} /bin/env TIMEZONE=${TIMEZONE} /bin/bash <<EOF
	rm -r /usr/share/man/*
	haveged -w 1024
	pacman-key --init
	pkill haveged
	pacman -Rs --noconfirm haveged
	pacman-key --populate archlinux
	pkill gpg-agent
	ln -s /usr/share/zoneinfo/$TIMEZONE /etc/localtime
	locale-gen
EOF

# udev doesn't work in containers, rebuild /dev
DEV=${ROOTFS}/dev
rm -rf ${DEV}
mkdir -p ${DEV}
mknod -m 666 ${DEV}/null c 1 3
mknod -m 666 ${DEV}/zero c 1 5
mknod -m 666 ${DEV}/random c 1 8
mknod -m 666 ${DEV}/urandom c 1 9
mkdir -m 755 ${DEV}/pts
mkdir -m 1777 ${DEV}/shm
mknod -m 666 ${DEV}/tty c 5 0
mknod -m 600 ${DEV}/console c 5 1
mknod -m 666 ${DEV}/tty0 c 4 0
mknod -m 666 ${DEV}/full c 1 7
mknod -m 600 ${DEV}/initctl p
mknod -m 666 ${DEV}/ptmx c 5 2
ln -sf /proc/self/fd ${DEV}/fd

# Remove docker image, if it exists
IMAGE_ID=$(docker images --no-trunc --quiet ${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG})
if [ -n "$IMAGE_ID" ]; then
	docker rmi ${IMAGE_ID}
fi

tar --numeric-owner --xattrs --acls -C ${ROOTFS} -c . | docker import - ${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}
docker run --rm -t ${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG} echo Success.
rm -rf ${ROOTFS}

echo "To try the new image, run the following command:"
echo "# docker run --hostname ${DOCKER_IMAGE_NAME} --rm --interactive --tty ${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG} /bin/bash"
