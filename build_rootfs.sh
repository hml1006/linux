#!/bin/bash

# 创建Ubuntu ARM64 rootfs 方法
# https://qubot.org/2023/08/09/h618-%E7%A7%BB%E6%A4%8Dubuntu-22-04-rootfs/

sudo apt-get install qemu-user-static
if [ ! -e ubuntu-base-23.10-base-arm64.tar.gz ];then
    wget http://cdimage.ubuntu.com/ubuntu-base/releases/mantic/release/ubuntu-base-23.10-base-arm64.tar.gz
fi
if [ ! -e ca-certificates_20230311ubuntu1_all.deb ];then
    wget http://ports.ubuntu.com/pool/main/c/ca-certificates/ca-certificates_20230311ubuntu1_all.deb
fi
if [ ! -e libssl3_3.0.10-1ubuntu4_arm64.deb ];then
    wget http://ports.ubuntu.com/pool/main/o/openssl/libssl3_3.0.10-1ubuntu4_arm64.deb
fi
if [ ! -e openssl_3.0.10-1ubuntu4_arm64.deb ];then
    wget http://ports.ubuntu.com/pool/main/o/openssl/openssl_3.0.10-1ubuntu4_arm64.deb
fi
if [ ! -e rootfs ];then
    mkdir rootfs
    tar -xzvf ubuntu-base-23.10-base-arm64.tar.gz -C rootfs
fi

sudo cp *.deb ./rootfs/root
sudo cp /etc/resolv.conf ./rootfs/etc/
# sudo cp /etc/apt/sources.list ./rootfs/etc/apt/
echo "nameserver 8.8.8" | sudo tee -a ./rootfs/etc/resolv.conf
echo "options edns0 trust-ad" | sudo tee -a ./rootfs/etc/resolv.conf
echo "search localdomain" | sudo tee -a ./rootfs/etc/resolv.conf

sudo rm -f ./rootfs/root/install.sh
echo "#!/bin/sh" | sudo tee -a ./rootfs/root/install.sh
echo "cd /root/" | sudo tee -a ./rootfs/root/install.sh

echo "dpkg -i libssl3_3.0.10-1ubuntu4_arm64.deb" | sudo tee -a ./rootfs/root/install.sh
echo "dpkg -i openssl_3.0.10-1ubuntu4_arm64.deb" | sudo tee -a ./rootfs/root/install.sh
echo "dpkg -i ca-certificates_20230311ubuntu1_all.deb" | sudo tee -a ./rootfs/root/install.sh
echo "chmod 777 /tmp/" | sudo tee -a ./rootfs/root/install.sh
echo "apt update" | sudo tee -a ./rootfs/root/install.sh
echo "apt install -y systemd sudo vim nano kmod net-tools ethtool ifupdown rsyslog htop iputils-ping language-pack-en-base ssh" | sudo tee -a ./rootfs/root/install.sh
echo "ln -s /lib/systemd/system/getty\@.service /etc/systemd/system/getty.target.wants/getty\@ttyAMA0.service" | sudo tee -a ./rootfs/root/install.sh

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
