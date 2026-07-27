# vllm-ascend-zeroday
vllm-ascend推理框架0-day加速补丁代码仓库


## 补丁目录约定
一级目录是镜像的版本号
例如：vllm-ascend:v0.19.1rc1
      vllm-ascend:deepseekv4-a3

每个版本号目录保留一个入口脚本：
```bash
apply-patch.sh
```

构建镜像时会执行对应版本目录下的 `apply-patch.sh`。脚本在真正应用补丁前会先执行 `git apply --check`，如果目标仓库不存在、补丁文件不存在，或者补丁无法应用，会明确报错并退出。
