# 黄区 Zeroday 镜像构建 Runbook

> 记录 2026-07-09 一次完整的黄区构建过程：在受限网络下用两台机器（x86_64 + aarch64）原生构建 6 个 zeroday 镜像并汇总到 `70.189.16.9:/AI/images/0DAY/0709/`。供以后复用。

## 1. 任务

构建 6 个 zeroday 镜像（基于 `build-zeroday-image.sh`，`--skip-patch`，加装 engine-requirements：`ray` + `mooncake-transfer-engine`），分两个架构：

| 架构 | 基础镜像 |
|---|---|
| aarch64 | `quay.io/ascend/vllm-ascend:v0.21.0rc1`、`v0.21.0rc1-310p`、`v0.21.0rc1-a3` |
| x86_64  | `quay.io/ascend/vllm-ascend:v0.21.0rc1`、`v0.21.0rc1-310p`、`vllm/vllm-openai:v0.23.0` |

最终 6 个 tar 全部保存到 `70.189.16.9:/AI/images/0DAY/0709/`。

## 2. 环境（关键约束）

| 主机 | 角色 | 网络 | 备注 |
|---|---|---|---|
| **70.189.16.9** (`root`/`Fusion@123`) | x86_64 构建机 | **无公网**（quay/tsinghua/pypi 都不通）；可直达内网镜像 `mirrors.xfusion.com` | 跑着**生产 Harbor**（80 端口，admin/`admin@123123`）+ SigNoz，~11 个容器 `restart=always`。docker daemon 代理是**死的**（`90.90.99.124:3128`），用户给的 `192.168.108.12:8080` 也不通。**不要重启 docker**（会拉掉 Harbor）。构建容器会从 `~/.docker/config.json` 拿到一个可用代理 `70.189.23.254:8080`。输出目录 `/AI/images/0DAY/` 在其 64T 根盘（12T 空闲）。 |
| **172.24.194.3**（DMZ，hostname `ecs-maas-dmz-01`） | aarch64 构建机 | **有公网**（quay + tsinghua 通） | 只能**跳板**访问：`ssh root@70.189.16.9` → `ssh root@172.24.194.3`（免密，用 16.9 的 key）。小机器（4 核 / 6.5G 内存），根盘 `/` 100% 满，docker data-root 在 `/Maas/docker_space`（5T，~900G 空闲）——构建/导出都放 `/Maas`。构建容器不注入代理。 |

要点：**16.9 既拉不了 quay，pip 也走不了公网**；只有 DMZ 有公网。这决定了整个流程。

## 3. 有效构建方案

> 用户给的两个 docker 代理都不通，所以**不重启 docker**（保住 Harbor）。改用：DMZ 负责拉公网镜像，16.9 用内网 pip 源构建 x86_64。

1. **aarch64 镜像**：在 DMZ 原生构建（arm64 基础镜像已在本地；pip 走默认 tsinghua）。
2. **amd64 基础镜像**：在 DMZ 用 `docker pull --platform=linux/amd64` 拉取（这些镜像是**多架构**的），`docker save` 后传到 16.9 再 `docker load`。
   - **先做 aarch64 构建，再拉 amd64**——否则 amd64 pull 会把 DMZ 上同 tag 的 arm64 镜像顶掉。
3. **x86_64 镜像**：在 16.9 原生构建，pip 用内网源：
   ```
   PIP_INDEX_URL=https://mirrors.xfusion.com/pypi/simple
   PIP_TRUSTED_HOST=mirrors.xfusion.com
   ```
   vllm GPU 镜像要显式 `--hardware cu130`（见下方「坑」）。
4. **汇总**：aarch64 的 tar 用 rsync 从 16.9 拉过来（16.9 有到 DMZ 的 key）：`rsync root@172.24.194.3:/Maas/... /AI/images/0DAY/...`，内网约 94 MB/s。

## 4. 本次代码改动（已在本分支提交）

为支持隔离主机用内网 pip 源，做了两处向后兼容改动：
- **`Dockerfile`**：新增 `ARG PIP_TRUSTED_HOST=` + `ENV PIP_TRUSTED_HOST`（`PIP_INDEX_URL` 原本就支持）。
- **`build-zeroday-image.sh`**：若环境里设了 `PIP_INDEX_URL` / `PIP_TRUSTED_HOST`，则作为 `--build-arg` 传给构建（不设则维持原 tsinghua 默认，行为不变）。

## 5. 踩过的坑 & 解决

| 坑 | 解决 |
|---|---|
| 16.9 的 docker 代理是死的（拉 quay 卡死） | 不在 16.9 拉；改在 DMZ 拉 amd64 后传过来 |
| 16.9 构建容器 pip 走不通公网 | 用内网源 `mirrors.xfusion.com`（已验证容器内可达，ray ~7 MB/s） |
| 用户建议的代理 `192.168.108.12:8080` 也不通 | 放弃代理方案；上面两步已足够 |
| 重启 docker 会拉掉生产 Harbor | 全程不重启 docker |
| **嵌套 ssh 传脚本会丢内容**（`local→16.9→DMZ` 的 `cat \| ssh` 经常落地为空文件） | 脚本先单跳传到 16.9，再 `scp` 16.9→DMZ，跑前 `wc -l` 校验非空 |
| `&` 把含 `cat`（读 stdin）的 `&&` 链一起后台 → 文件写空 | 拆开：先写文件（前台），再单独后台启动 |
| 给大 scp/rsync 加了 `timeout 120` → 51G 传输 2 分钟被掐 | 大传输不加 timeout，用 rsync `--partial` 可断点续传 |
| ssh 后台进程占着 channel 导致客户端挂起 | `setsid ... > log 2>&1 < /dev/null &`，用单独 `pgrep` 确认 |
| `vllm/vllm-openai:v0.23.0` 的 CUDA 环境变量是 `NV_CUDA_CUDART_VERSION`，不是脚本自动检测的 `CUDA_VERSION`/`NV_CUDA_VERSION` → 自动检测会报错退出 | 显式 `--hardware cu130`（CUDA 13.0） |

## 6. 交付物（6 个 tar，md5 全部校验 OK）

均在 `70.189.16.9:/AI/images/0DAY/0709/`，每个带 `.manifest.json`（base image / engine / md5 / build time）：

| 架构 | 文件 | 大小 | md5 |
|---|---|---|---|
| aarch64 | `Wings_vllm_ascend_v0.21.0rc1_20260709144216_aarch64.tar` | 18G | `eaeef91c51595d332f68a080092dce91` |
| aarch64 | `Wings_vllm_ascend_v0.21.0rc1-310p_20260709144759_aarch64.tar` | 15G | `80c31e7a1e286c8297c957f4e31a4e9c` |
| aarch64 | `Wings_vllm_ascend_v0.21.0rc1-a3_20260709145242_aarch64.tar` | 18G | `376df2d9afdbb71ec3ac151652b4b21d` |
| x86_64 | `Wings_vllm_ascend_v0.21.0rc1_20260709162053_x86_64.tar` | 18G | `9b403fe0890a16a9d8a20ec417b65835` |
| x86_64 | `Wings_vllm_ascend_v0.21.0rc1-310p_20260709162935_x86_64.tar` | 16G | `c45afcf7c1713333459ead4420e25f52` |
| x86_64 | `Wings_vllm_v0.23.0_cu130_20260709163633_x86_64.tar` | 20G | `abbb711316505eae8a6d1dcf4e10d932` |

md5 校验方式：对每个 tar 重新 `md5sum`，与对应 `.manifest.json` 里的 `md5` 字段比对，全部一致。

## 7. 复现要点（关键命令）

```bash
# 凭据/跳板
SSHPASS='Fusion@123' sshpass -e ssh root@70.189.16.9                       # x86_64 机
ssh root@70.189.16.9 'ssh root@172.24.194.3 "..."'                          # 经跳板到 DMZ

# 同步构建仓库到两台机（单跳到 16.9，再 scp 到 DMZ）
tar czf /tmp/bzd.tar.gz --exclude='.git' -C /root build-zeroday
cat /tmp/bzd.tar.gz | sshpass -e ssh root@70.189.16.9 'tar xzf - -C /root'   # 16.9
# DMZ 走 16.9 跳板，注意嵌套流可能丢内容 → 传到 16.9 后再 scp 过去

# aarch64 构建（DMZ）：./build-zeroday-image.sh -b <img> -e vllm-ascend --skip-patch --output-dir /Maas/0day-out

# amd64 基础镜像（DMZ 拉 + 导出）
docker pull --platform=linux/amd64 quay.io/ascend/vllm-ascend:v0.21.0rc1
docker save quay.io/ascend/vllm-ascend:v0.21.0rc1 -o /Maas/bases/....tar
# 16.9 上从 DMZ 拉过来并 load（16.9→DMZ 走 key）
rsync -av --partial root@172.24.194.3:/Maas/bases/....tar /root/amd64-bases/
docker load -i /root/amd64-bases/....tar

# x86_64 构建（16.9，pip 走 xfusion）
PIP_INDEX_URL=https://mirrors.xfusion.com/pypi/simple \
PIP_TRUSTED_HOST=mirrors.xfusion.com \
./build-zeroday-image.sh -b vllm/vllm-openai:v0.23.0 -e vllm --hardware cu130 \
  --skip-patch --output-dir /AI/images/0DAY/0709

# md5 校验
cd /AI/images/0DAY/0709 && for t in *.tar; do python3 -c "import json;print(json.load(open('$t.manifest.json'))['md5'])"; md5sum "$t"; done
```

## 8. 遗留中间文件（可清理）

- 16.9 `/root/amd64-bases/`（3 个 amd64 基础镜像 tar，53G，已 load，可删）
- DMZ `/Maas/bases/`（53G）+ `/Maas/0day-out/`（aarch64 tar 副本 + 脚本/日志，已汇总到 0709）
