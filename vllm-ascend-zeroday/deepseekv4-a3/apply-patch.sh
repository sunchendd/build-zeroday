#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/../common/apply-patch-lib.sh"

apply_patch /vllm-workspace/vllm-ascend \
  "$script_dir/0001-vllm_ascend_kvcache2cpu.patch"

apply_patch /vllm-workspace/vllm-ascend \
  "$script_dir/0002-vllm_ascend_kvcache2cpu-fix-performance-fluctuation-issues.patch"
