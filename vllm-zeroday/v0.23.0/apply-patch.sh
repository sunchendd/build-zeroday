#!/usr/bin/env bash
# vLLM v0.23.0 zeroday
# 基础镜像使用官方 vllm/vllm-openai:v0.23.0（vllm 已预构建），无需从源码编译。
# 仅安装 lmcache==0.5.1（升级版本以修复 bug）。PIP_INDEX_URL 由 Dockerfile 注入。
set -euo pipefail

pip install --no-cache-dir lmcache==0.5.1

echo "=== lmcache==0.5.1 安装完成 ==="
