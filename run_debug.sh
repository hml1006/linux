#!/bin/bash

if [ ! -f "nvme.img" ];then
  echo "Create a nvme SSD"
  dd if=/dev/zero of=nvme.img bs=1M count=512
fi

if [ ! -e "k_shared" ];then
  echo "Create folder k_shared"
  mkdir k_shared
elif [ ! -d "k_shared" ];then
  echo "k_shared not a folder, delete it"
  rm -f k_shared
  echo "Create folder k_shared"
  mkdir k_shared
fi

qemu-system-aarch64 -cpu cortex-a57 -machine virt \
  -m 4096 -smp 2 \
  -drive file=nvme.img,if=none,id=nvm0 \
  -device nvme,serial=12345678,drive=nvm0 \
  -kernel arch/arm64/boot/Image \
  --fsdev local,id=kmod_dev,path=$PWD/k_shared,security_model=none \
  -device virtio-9p-device,fsdev=kmod_dev,mount_tag=kmod_mount \
  --append "rdinit=/linuxrc root=/dev/ram rw loglevel=8 console=ttyAMA0"  \
  -serial stdio \
  -initrd ./rootfs.cpio.gz -S -s
