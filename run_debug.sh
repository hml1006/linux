#!/bin/bash -x

qemu-system-aarch64 -cpu cortex-a57 -machine virt \
  -m 4096 -smp 2 \
  -kernel arch/arm64/boot/Image \
  --fsdev local,id=kmod_dev,path=$PWD/k_shared,security_model=none \
  -device virtio-9p-device,fsdev=kmod_dev,mount_tag=kmod_mount \
  --append "rdinit=/linuxrc root=/dev/ram rw loglevel=8 console=ttyAMA0"  \
  -serial stdio \
  -initrd ./rootfs.cpio.gz -S -s
  #-S -s
