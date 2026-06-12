# build-zeroday
构建加速特性镜像脚本

## 使用方式

基于已有 vLLM/vLLM Ascend 镜像，把本仓库 submodule 中的补丁和依赖打进新镜像：

vllm-ascend 示例
```bash
./build-zeroday-image.sh \
  -b quay.io/ascend/vllm-ascend:v0.19.1rc1 \
  -e vllm-ascend \
  -v v0.19.1rc1 \
  -o Wings_vllm_ascend_v0.19.1rc1_800I_A3_glm5.1_aarch64.tar
```
vllm 示例
```bash
./build-zeroday-image.sh \
  -b swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/vllm/vllm-openai:v0.22.0 \
  -e vllm \
  -v v0.22.0 \
  -o Wings_vllm_v0.22.0_H20_deepseekv4flash-amd64.tar
```

`-o/--output-tar` 是导出的镜像包路径，等价于 `--save`。

`-e/--engine` 支持：

- `vllm`：使用 `vllm-zeroday/<版本>`
- `vllm-ascend` 或 `ascend`：使用 `vllm-ascend-zeroday/<版本>`

如果引擎不支持，或者对应版本目录不存在，脚本会直接报错退出。

脚本默认执行补丁目录下的 `apply-patch.sh`。如果补丁目录里存在以下文件，也会自动处理：

- `apt-packages.txt`：通过 `apt-get install` 安装系统依赖
- `requirements.txt`：通过 `python3 -m pip install` 安装 Python 依赖
- `install-deps.sh`：执行自定义依赖安装脚本

可用 `--patch-script` 指定其他补丁脚本，用 `--push` 在构建成功后推送镜像。

## Submodule 同步

`vllm-ascend-zeroday/` 和 `vllm-zeroday/` 是独立补丁仓库，在本仓库中以 submodule 方式引用。

首次拉取本仓库后初始化 submodule（若 submodule 有本地修改，以下命令会强制丢弃本地修改并同步到最新远端）：

```bash
git clone https://github.com/sunchendd/build-zeroday.git
cd build-zeroday
git submodule update --init
git submodule foreach --recursive 'git fetch origin && git reset --hard origin/HEAD'
```

如果 submodule 指针更新了，可以在主仓库提交新的指针：

```bash
git add vllm-ascend-zeroday vllm-zeroday
git commit -m "chore(submodules): update zeroday patch refs"
```
## 镜像构建使用方式

基于已有 vLLM/vLLM Ascend 镜像，把本仓库 submodule 中的补丁和依赖打进新镜像，导出镜像包：
vllm-ascend示例
```bash
./build-zeroday-image.sh \
  -b quay.io/ascend/vllm-ascend:v0.19.1rc1-a3 \
  -e vllm-ascend \
  -v 0.19.1rc1 \
  -o Wings_vllm_ascend_v0.19.1rc1_800I_A3_glm5.1_aarch64.tar
```

vllm示例
```bash
./build-zeroday-image.sh \
  -b swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/vllm/vllm-openai:v0.22.0 \
  -e vllm \
  -v 0.22.0 \
  -o Wings_vllm_v0.22.0_H20_deepseekv4flash-amd64.tar
```

`-o/--output-tar` 是导出的镜像包路径，等价于 `--save`。

`-e/--engine` 支持：

- `vllm`：使用 `vllm-zeroday/<版本>`
- `vllm-ascend` 或 `ascend`：使用 `vllm-ascend-zeroday/<版本>`

如果引擎不支持，或者对应版本目录不存在，脚本会直接报错退出。

脚本默认执行补丁目录下的 `apply-patch.sh`。如果补丁目录里存在以下文件，也会自动处理：

- `apt-packages.txt`：通过 `apt-get install` 安装系统依赖
- `requirements.txt`：通过 `python3 -m pip install` 安装 Python 依赖
- `install-deps.sh`：执行自定义依赖安装脚本

可用 `--patch-script` 指定其他补丁脚本，用 `--push` 在构建成功后推送镜像。


