cp arm64_config .config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
make CROSS_COMPILE=aarch64-linux-gnu- ARCH=arm64 -j12
./scripts/clang-tools/gen_compile_commands.py
