#!/bin/bash -x

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
echo "add-auto-load-safe-path ${cur_dir}/.gdbinit" > ${gdb_cfg}/gdbinit
echo "set auto-load python-scripts on" > .gdbinit
echo "add-auto-load-safe-path ${cur_dir}" >> .gdbinit

echo "set architecture aarch64" >> .gdbinit
echo "file vmlinux" >> .gdbinit
echo "b start_kernel" >> .gdbinit

br0_exists=`ifconfig | grep br0 | wc -l`
if [ ${br0_exists} -eq 1 ];then
  sudo brctl delbr br0 # 删除网桥设备 br0
fi

#获取当前使用中的网卡
nic=`awk 'BEGIN {max = 0} {if ($2+0 > max+0) {max=$2 ;content=$0} } END {print $1}' /proc/net/dev | cut -d : -f 1`
nic=wlp4s0
sudo apt-get install bridge-utils -y # 安装网桥设备工具箱
sudo ifconfig ${nic} down
sudo ifconfig br0 down
sudo brctl addbr br0 # 创建网桥设备 br0
sudo brctl addif br0 ${nic} # 添加网卡 ${nic} 到网桥 br0
sudo brctl stp br0 off # 关闭网桥 br0 的生成树协议
sudo brctl setfd br0 1 # 设置网桥 br0 转发延迟为1秒
sudo brctl sethello br0 1 # 设置网桥 br0 'hello time' 为1秒
sudo ifconfig br0 0.0.0.0 promisc up # 设置网桥 br0 为混杂模式
sudo ifconfig ${nic} 0.0.0.0 promisc up # 设置网卡 ${nic} 为混杂模式
sudo dhclient br0 # 为网桥 br0 获取 IP

sudo apt-get install uml-utilities -y # 安装 tun/tap 工具箱
sudo tunctl -t tap0 -u root # 建立 tap0
sudo brctl addif br0 tap0 # 将 tap0 添加到网桥 br0
sudo ifconfig tap0 0.0.0.0 promisc up # 将 tap0 设置为混杂模式

# 修改ctr c
stty intr ^]

sudo qemu-system-aarch64 -cpu cortex-a57 -machine virt \
  -m 4096 -smp 2 \
  -net nic -net tap,ifname=tap0,script=no,downscript=no \
  -drive file=nvme.img,format=raw,if=none,id=nvm0 \
  -device nvme,serial=12345678,drive=nvm0 \
  -kernel arch/arm64/boot/Image \
  --fsdev local,id=kmod_dev,path=$PWD/k_shared,security_model=none \
  -device virtio-9p-device,fsdev=kmod_dev,mount_tag=kmod_mount \
  --append "root=/dev/vda rootfstype=ext4 rw loglevel=8 console=ttyAMA0"  \
  -serial stdio \
  -drive file=ubuntu-rootfs.img,index=0,media=disk,format=raw -S -s

# 恢复ctr c
stty intr ^c