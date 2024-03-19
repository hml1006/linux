#!/bin/bash

# 创建Ubuntu ARM64 rootfs 方法
# https://qubot.org/2023/08/09/h618-%E7%A7%BB%E6%A4%8Dubuntu-22-04-rootfs/

sudo apt-get install qemu-user-static
if [ ! -e ubuntu-base-23.10-base-arm64.tar.gz ];then
    wget http://cdimage.ubuntu.com/ubuntu-base/releases/mantic/release/ubuntu-base-23.10-base-arm64.tar.gz
fi
if [ ! -e rootfs ];then
    mkdir rootfs
    tar -xzvf ubuntu-base-23.10-base-arm64.tar.gz -C rootfs
fi

sudo rm -f ./rootfs/etc/resolv.conf
resolv=$(cat <<"EOF"
nameserver 8.8.8
options edns0 trust-ad
search localdomain
EOF
)
echo "${resolv}" | sudo tee -a ./rootfs/etc/resolv.conf

interfaces=$(cat <<"EOF"
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
)
echo "${interfaces}" | sudo tee -a ./rootfs/etc/network/interfaces

install=$(cat <<"EOF"
#!/bin/sh
cd /root/
useradd -G sudo -m -s /bin/bash louis
echo louis:yes | chpasswd
passwd root
echo louis.arm > /etc/hostname
echo 127.0.0.1	localhost > /etc/hosts
chmod 777 /tmp/
apt update
apt upgrade -y
apt install -y dialog perl systemd sudo vim nano kmod net-tools ethtool ifupdown rsyslog htop iputils-ping language-pack-en-base ssh iputils-ping resolvconf wget apt-utils
ln -s /lib/systemd/system/getty\@.service /etc/systemd/system/getty.target.wants/getty\@ttyAMA0.service
EOF
)
echo "${install}" | sudo tee -a ./rootfs/root/install.sh

sudo chmod +x ./rootfs/root/install.sh
sudo cp /usr/bin/qemu-arm-static ./rootfs/usr/bin/
sudo mount -t proc /proc ./rootfs/proc
sudo mount -t sysfs /sys ./rootfs/sys
sudo mount -o bind /dev ./rootfs/dev
sudo mount -o bind /dev/pts ./rootfs/dev/pts
sudo chroot ${PWD}/rootfs /root/install.sh
sudo umount ./rootfs/proc
sudo umount ./rootfs/sys
sudo umount ./rootfs/dev/pts
sudo umount ./rootfs/dev/

dd if=/dev/zero of=ubuntu-rootfs.img bs=1M count=2048
sudo mkfs.ext4  ubuntu-rootfs.img
rm -rf ubuntu-mount
mkdir ubuntu-mount
sudo mount ubuntu-rootfs.img ubuntu-mount/
sudo cp -rfp rootfs/*  ubuntu-mount/
sudo umount ubuntu-mount/
sudo rm -rf ubuntu-mount/
e2fsck -p -f ubuntu-rootfs.img
