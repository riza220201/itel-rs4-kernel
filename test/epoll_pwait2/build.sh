#!/usr/bin/env bash
# Build ep2test for arm64 (native syscall table) and arm32 (compat table): static, no libc.
# Uses the project's Neutron clang. Output: ep2test-arm64, ep2test-arm32 (next to this file).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLANG="${CLANG:-$HERE/../../toolchain/neutron-clang-06092026/bin/clang}"
CF=(-O2 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic
    -fuse-ld=lld -Wall -Wextra -Wno-unused-parameter)
"$CLANG" --target=aarch64-linux-gnu "${CF[@]}" -o "$HERE/ep2test-arm64" "$HERE/ep2test.c"
"$CLANG" --target=armv7a-linux-gnueabi -marm "${CF[@]}" -o "$HERE/ep2test-arm32" "$HERE/ep2test.c"
file "$HERE/ep2test-arm64" "$HERE/ep2test-arm32"
