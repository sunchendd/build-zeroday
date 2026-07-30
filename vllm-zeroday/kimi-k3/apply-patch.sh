#!/usr/bin/env bash
# vLLM kimi-k3 zeroday patch
# 修复 MRv2 路径下 dcp_world_size=-1 泄漏到 FA3 内核，导致 Kimi-K3 在 Hopper
# (H20/H100/H200, SM90) 上报 "cp_world_size must be positive" 的 bug。
# 仅作用于已安装的 vllm 包（dist-packages），不重新编译。
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

echo "=== 应用 kimi-k3 cp_world_size 补丁 ==="

# patch 脚本退出码：0=打补丁成功，1=此前已打过（幂等，视为成功），2=写入失败（终止构建）
set +e
python3 "$script_dir/patch_vllm_cp_world_size.py"
rc=$?
set -e

case "$rc" in
  0|1)
    echo "=== kimi-k3 补丁应用完成 ==="
    ;;
  *)
    echo "[kimi-k3] patch 失败，退出码 $rc" >&2
    exit "$rc"
    ;;
esac
