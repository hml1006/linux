sudo apt install gcc-aarch64-linux-gnu
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
make CROSS_COMPILE=aarch64-linux-gnu- ARCH=arm64 -j8
./scripts/clang-tools/gen_compile_commands.py
