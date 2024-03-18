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

cur_dir=`pwd`
gdb_cfg=${HOME}/.config/gdb
mkdir -p ${gdb_cfg}
echo "add-auto-load-safe-path ${cur_dir}/.gdbinit"
echo "set auto-load python-scripts on" > .gdbinit
echo "add-auto-load-safe-path ${cur_dir}/" >> .gdbinit
echo "source ${cur_dir}/add-auto-load-safe-path /home/louis/code/linux/" >> .gdbinit
echo "set architecture aarch64" >> .gdbinit
echo "file vmlinux" >> .gdbinit
echo "b start_kernel" >> .gdbinit

sudo cp qemu-ifup /etc/

sudo qemu-system-aarch64 -cpu cortex-a57 -machine virt \
  -m 4096 -smp 2 \
  -net tap,ifname=tap0 -net nic \
  -drive file=nvme.img,format=raw,if=none,id=nvm0 \
  -device nvme,serial=12345678,drive=nvm0 \
  -kernel arch/arm64/boot/Image \
  --fsdev local,id=kmod_dev,path=$PWD/k_shared,security_model=none \
  -device virtio-9p-device,fsdev=kmod_dev,mount_tag=kmod_mount \
  --append "root=/dev/vda rootfstype=ext4 rw loglevel=8 console=ttyAMA0"  \
  -serial stdio \
  -drive file=ubuntu-rootfs.img,index=0,media=disk,format=raw -S -s
