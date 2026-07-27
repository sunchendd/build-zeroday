#!/usr/bin/env bash
# clone vLLM v0.22.0 源码并应用补丁，构建并安装 whl 包
# 用法: bash apply-patch.sh [目标目录]
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VLLM_TAG="v0.22.0"
TARGET_REPO="${1:-/vllm-workspace}"

# =============================================================================
# 修复 libnvrtc.so 符号链接（镜像中只有带版本号的 .so.13，cmake find_library 需要无版本号链接）
# =============================================================================
echo "=== 修复 libnvrtc.so 符号链接 ==="
NVRTC_LIB_DIR="/usr/local/cuda-13.0/targets/x86_64-linux/lib"
if [ ! -e "${NVRTC_LIB_DIR}/libnvrtc.so" ]; then
    ln -sf "${NVRTC_LIB_DIR}/libnvrtc.so.13" "${NVRTC_LIB_DIR}/libnvrtc.so"
    echo "  已创建 libnvrtc.so -> libnvrtc.so.13"
fi

# =============================================================================
# 4. 链接缺失的 CUDA 头文件（cusparse.h、cusolverDn.h 等在 nvidia/cu13/include 下）
# =============================================================================
echo "=== 链接 CUDA 头文件 ==="
NVIDIA_INCLUDE="/usr/local/lib/python3.12/dist-packages/nvidia/cu13/include"
CUDA_INCLUDE="/usr/local/cuda-13.0/include"
linked=0
for f in "${NVIDIA_INCLUDE}"/*.h; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    if [ ! -e "${CUDA_INCLUDE}/${base}" ]; then
        ln -sf "$f" "${CUDA_INCLUDE}/${base}"
        linked=$((linked + 1))
    fi
done
echo "  已链接 ${linked} 个头文件到 ${CUDA_INCLUDE}"

# =============================================================================
# 5. 安装 Rust 1.95 工具链（vllm rust-toolchain.toml 锁定 channel = "1.95"）
#    使用 rsproxy 国内镜像加速下载
# =============================================================================
echo "=== 安装 Rust 工具链 ==="
export RUSTUP_DIST_SERVER="https://rsproxy.cn"
export RUSTUP_UPDATE_ROOT="https://rsproxy.cn/rustup"

if [ ! -f /root/.cargo/bin/rustup ]; then
    echo "  安装 rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://rsproxy.cn/rustup-init.sh \
        | sh -s -- -y --default-toolchain none --no-modify-path
fi
# 将 cargo bin 加入 PATH
export PATH="/root/.cargo/bin:${PATH}"

# 确保安装了 vllm 源码 pin 的 Rust 版本
RUST_CHANNEL="1.95"
if ! rustup toolchain list 2>/dev/null | grep -q "^${RUST_CHANNEL}-"; then
    echo "  安装 Rust ${RUST_CHANNEL}..."
    rustup toolchain install "${RUST_CHANNEL}" --profile minimal --no-self-update
fi

# 配置 cargo crates.io 国内镜像（rsproxy sparse）
mkdir -p /root/.cargo
cat > /root/.cargo/config.toml << 'CARGO_EOF'
[source.crates-io]
replace-with = "rsproxy-sparse"
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
[net]
git-fetch-with-cli = true
CARGO_EOF

# =============================================================================
# 6. 拷贝源码、应用补丁、编译、安装
# =============================================================================
echo "=== Clone源码并应用补丁 ==="
git config --global url."https://gh-proxy.com/github.com/".insteadOf "https://github.com/"
rm -rf "$TARGET_REPO"
git clone --branch "$VLLM_TAG" --depth 1 https://github.com/vllm-project/vllm.git "$TARGET_REPO"

cd "$TARGET_REPO"

echo "  应用补丁..."

# 按文件名顺序应用 patch/ 目录下的所有 .patch 补丁
PATCH_DIR="$script_dir/patch"
if [ ! -d "$PATCH_DIR" ]; then
    echo "  ⚠️  未找到补丁目录 $PATCH_DIR"
    exit 1
fi

shopt -s nullglob
patch_files=("$PATCH_DIR"/*.patch)
shopt -u nullglob

if [ ${#patch_files[@]} -eq 0 ]; then
    echo "  ⚠️  补丁目录 $PATCH_DIR 中没有 .patch 文件"
    exit 1
fi

for patch_file in "${patch_files[@]}"; do
    echo "  应用 $(basename "$patch_file") ..."
    git apply --binary --whitespace=nowarn "$patch_file"
done

echo "  补丁应用成功（共 ${#patch_files[@]} 个）"


echo "  准备外部依赖..."

# =============================================================================
# 外部依赖目录（可选，通过 VLLM_EXT_DIR 指定预下载目录）：
#   - 设置了 VLLM_EXT_DIR：使用该目录中的依赖，跳过网络下载
#   - 未设置：不导出 SRC_DIR 变量，cmake FetchContent 在编译时自动下载
#     下载目录：$TARGET_REPO/_skbuild/*/cmake-build/_deps/<name>-src/
# =============================================================================
if [ -n "${VLLM_EXT_DIR:-}" ]; then
    echo "  使用预下载外部依赖目录: $VLLM_EXT_DIR"
    export DEEPGEMM_SRC_DIR="${VLLM_EXT_DIR}/DeepGEMM"
    export FLASH_MLA_SRC_DIR="${VLLM_EXT_DIR}/FlashMLA"
    export QUTLASS_SRC_DIR="${VLLM_EXT_DIR}/qutlass"
    export TRITON_KERNELS_SRC_DIR="${VLLM_EXT_DIR}/triton/python/triton_kernels/triton_kernels"
    export VLLM_FLASH_ATTN_SRC_DIR="${VLLM_EXT_DIR}/flash-attention"
    export VLLM_CUTLASS_SRC_DIR="${VLLM_EXT_DIR}/cutlass"
else
    echo "  未设置 VLLM_EXT_DIR，cmake 将在编译时自动下载外部依赖"
fi

echo "  开始编译..."

export PATH="/usr/local/cuda/bin:${PATH}"
export CUDA_HOME="/usr/local/cuda"
export TRITON_PTXAS_PATH="/usr/local/cuda/bin/ptxas"
export CUDA_ARCH_LIST="120a"
export TORCH_CUDA_ARCH_LIST="12.0a"

WHL_DIR="$script_dir"
echo "  编译 whl 包到 $WHL_DIR ..."
CCACHE_NOHASHDIR=true MAX_JOBS=8 \
    pip wheel --no-build-isolation --no-deps --verbose -w "$WHL_DIR" .

echo "  安装 whl 包..."
pip install --no-deps "$WHL_DIR"/vllm-*.whl

echo ""
echo "=== 验证安装 ==="
python3 -c "import vllm; print('vllm version:', vllm.__version__)"

# =============================================================================
# 修复 flash_attn 模块导入问题
#    vllm_flash_attn/cute/interface.py 等文件依赖外部 flash_attn 包，
#    但该包未编译 C 扩展，需要：
#    (1) 创建 .pth 文件让 Python 找到 flash_attn 源码目录
#    (2) 修复 __init__.py 中 C 扩展的 ImportError（用 try/except 规避）
# =============================================================================
echo "=== 修复 flash_attn 模块导入 ==="
PY_DIST="/usr/local/lib/python3.12/dist-packages"

if [ -n "${VLLM_EXT_DIR:-}" ]; then
    FA_DIR="${VLLM_EXT_DIR}/flash-attention"
else
    FA_DIR="$TARGET_REPO/.deps/vllm-flash-attn-src"
    if [ ! -d "$FA_DIR" ]; then
        echo "  ⚠️  未找到 cmake 自动下载的 flash-attention ($FA_DIR)，跳过 flash_attn 修复"
        FA_DIR=""
    fi
fi

if [ -n "$FA_DIR" ]; then
  # 创建 .pth 让 Python 找到 flash_attn 包（如未存在）
  if [ ! -f "${PY_DIST}/flash_attn.pth" ] || ! grep -q "${FA_DIR}" "${PY_DIST}/flash_attn.pth" 2>/dev/null; then
      echo "${FA_DIR}" > "${PY_DIST}/flash_attn.pth"
      echo "  已创建 ${PY_DIST}/flash_attn.pth"
  fi

  # 修复 flash_attn/__init__.py：C 扩展未编译，用 try/except 规避 ImportError
  cat > "${FA_DIR}/flash_attn/__init__.py" << 'FLASH_ATTN_EOF'
from pkgutil import extend_path
__path__ = extend_path(__path__, __name__)
__version__ = "2.8.4"
try:
    from flash_attn.flash_attn_interface import (
        flash_attn_func, flash_attn_kvpacked_func, flash_attn_qkvpacked_func,
        flash_attn_varlen_func, flash_attn_varlen_kvpacked_func,
        flash_attn_varlen_qkvpacked_func, flash_attn_with_kvcache,
    )
except ImportError:
    pass
FLASH_ATTN_EOF
  echo "  已修复 flash_attn/__init__.py"

  # 修复 transformers import_utils.py：PACKAGE_DISTRIBUTION_MAPPING["flash_attn"] 会
  # 因 flash_attn 未通过 pip 安装而抛出 KeyError。改为 .get() 安全访问。
  TRANSFORMERS_IMPORT_UTILS="${PY_DIST}/transformers/utils/import_utils.py"
  if grep -q 'PACKAGE_DISTRIBUTION_MAPPING\["flash_attn"\]' "${TRANSFORMERS_IMPORT_UTILS}" 2>/dev/null; then
      sed -i 's/PACKAGE_DISTRIBUTION_MAPPING\["flash_attn"\]/PACKAGE_DISTRIBUTION_MAPPING.get("flash_attn", [])/g' "${TRANSFORMERS_IMPORT_UTILS}"
      sed -i 's/PACKAGE_DISTRIBUTION_MAPPING\["flash_attn_interface"\]/PACKAGE_DISTRIBUTION_MAPPING.get("flash_attn_interface", [])/g' "${TRANSFORMERS_IMPORT_UTILS}"
      echo "  已修复 transformers/utils/import_utils.py（PACKAGE_DISTRIBUTION_MAPPING KeyError）"
  fi

  # 验证
  python3 -c "from flash_attn.cute.cache_utils import get_jit_cache; print('  flash_attn.cute OK')"
  python3 -c "from transformers.utils.import_utils import is_flash_attn_2_available; is_flash_attn_2_available(); print('  transformers flash_attn check OK')"
fi  # end if FA_DIR

echo ""
echo "=== 全部完成！==="


