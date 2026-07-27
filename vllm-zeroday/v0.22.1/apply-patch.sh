#!/usr/bin/env bash


script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

cd /usr/local/lib/python3.12/dist-packages/nvidia_cutlass_dsl
patch -p1 < "$script_dir/0001-fix-cutlass-global-dtors-llvm-binding.patch"

cd /usr/local/lib/python3.12/dist-packages/vllm
patch -p1 < "$script_dir/0002-adapt-indexcache-on-h20-dsv4flash.patch"


