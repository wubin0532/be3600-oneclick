# GL-BE3600 一键配置脚本

面向 GL.iNet GL-BE3600（Slate 7）的维护脚本：先移除原厂 Tailscale 和 AdGuard Home，再安装三个插件的最新正式版，最后恢复真实 OpenWrt 版本显示。

| 安装的插件 | 最新正式版来源 |
|---|---|
| AndeyProxy | [wubin0532/Reverse_Proxy](https://github.com/wubin0532/Reverse_Proxy/releases/latest) |
| Tailscale LuCI | [wubin0532/tailscale](https://github.com/wubin0532/tailscale/releases/latest) |
| ScreenPlus | [VAIO-Dong/gl-be3600-screenplus](https://github.com/VAIO-Dong/gl-be3600-screenplus/releases/latest) |

每次运行从 GitHub 查询最新正式版，自动选择 BE3600 对应架构的发布包，并验证发布端 SHA-256。全部下载与校验通过后才开始卸载原厂组件，避免原厂 Tailscale 与自定义安装器冲突。

## 在路由器上运行

SSH 登录路由器，以 root 执行下面一条命令：

```sh
curl -fSL --retry 2 --connect-timeout 15 https://raw.githubusercontent.com/wubin0532/be3600-oneclick/main/be3600-oneclick.sh -o /tmp/be3600-oneclick.sh && sh /tmp/be3600-oneclick.sh
```

默认执行会删除原厂 Tailscale、AdGuard Home 的配置和本地数据。已经安装的自定义 Tailscale 会保留身份和配置；检测到原厂与自定义组件混装时会停止。

仅检查环境、下载并校验安装包，不执行卸载、安装或配置更改：

```sh
curl -fSL --retry 2 --connect-timeout 15 https://raw.githubusercontent.com/wubin0532/be3600-oneclick/main/be3600-oneclick.sh -o /tmp/be3600-oneclick.sh && sh /tmp/be3600-oneclick.sh --check
```

也可以[下载脚本](https://raw.githubusercontent.com/wubin0532/be3600-oneclick/main/be3600-oneclick.sh)后通过 LuCI 上传到 `/tmp`，再运行 `sh /tmp/be3600-oneclick.sh`。

## 执行顺序

1. 检查机型、架构、LuCI、firewall4、TUN、剩余空间及未保存的网络配置。
2. 下载三个最新正式版的匹配架构包并校验 SHA-256。
3. **卸载 GL 原厂 Tailscale、AdGuard Home**，清理专属组件和相关网络规则。
4. 安装 **AndeyProxy、Tailscale LuCI、ScreenPlus**。
5. 从只读固件记录读取实际发行版本，只修正 `DISTRIB_DESCRIPTION`。
6. 验证安装结果并刷新管理服务。

新安装的 AndeyProxy、Tailscale 使用上游默认的关闭状态；Tailscale 需要在 LuCI 中启用并登录。新安装的 ScreenPlus 默认启用。已有安装保留配置与启停状态，不自动降级。

## 文件

- [`be3600-oneclick.sh`](be3600-oneclick.sh)：一键脚本。
- [一键脚本使用说明](一键脚本使用说明.md)：适用条件、重复运行行为及验证边界。
- [完整 ZIP 包](BE3600一键配置脚本.zip)：脚本、说明和校验清单。
- [`SHA256SUMS.txt`](SHA256SUMS.txt)：原始交付文件的校验清单。
- [`tests/test_oneclick.py`](tests/test_oneclick.py)：15 项隔离测试，不连接真实路由器。

ZIP 是已生成的脚本发布快照；脚本实际安装的插件版本仍在每次运行时动态获取。

## 适用条件与验证

适用于 GL-BE3600、`aarch64_cortex-a53_neon-vfpv4` 的 GL/OpenWrt 固件，要求 opkg、LuCI、firewall4 和匹配当前内核的 TUN 支持。至少需要 96 MiB 可写空闲空间和 128 MiB `/tmp` 空闲空间。

脚本不处理 PassWall、OpenClash 或 Nikki，不重刷固件。只读 `/rom` 中的原厂副本不会被擦除，恢复出厂后可能重新出现。默认流程不是全系统事务回滚，出错会停止，之前完成的更改可能已生效。

2026-10-12 已在真实 BE3600 上通过 `--check`，当时解析出的插件版本为 AndeyProxy v0.3.7、Tailscale LuCI v2.2.0（安装器 2.2.0-r2）、ScreenPlus v1.2.3。该验证没有在恢复出厂固件上重跑整个默认流程。

本地验证：

```sh
sh -n be3600-oneclick.sh
shellcheck -s sh be3600-oneclick.sh
python3 tests/test_oneclick.py
```

脚本没有内置路由器用户名、密码、GitHub Token 或 Tailscale 授权密钥。
