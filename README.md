# 语言导航 / Language Navigation

| 语言 / Language | 说明文档 / Documentation | 架构与技术规范 / Architecture & Standards |
| :--- | :--- | :--- |
| 中文 | [README.zh.md](./README.zh.md) | [ARCHITECTURE.zh.md](./ARCHITECTURE.zh.md) |
| English | [README.en.md](./README.en.md) | [ARCHITECTURE.en.md](./ARCHITECTURE.en.md) |

# 简介 / Overview

macOS 原生轻量级网络存储（SMB）自动化挂载工具。基于目标主机 TCP 445 端口服务可达性探测与事件驱动响应，提供完全静默、免密码、断网自动超时清理的稳定挂载体验。

A native, lightweight network storage (SMB) automation tool for macOS. Powered by target host TCP 445 reachability probing and event-driven daemon evaluation, providing silent, password-free, and bounded cleanup volume mounting.

仅支持 macOS 27.0 或更高版本的 Apple silicon（arm64）；不支持 Intel Mac。项目以 macOS 27 SDK 和新 API 为优先目标，不维护旧 macOS 或 Intel 的兼容代码；代码保持精简，且继续支持必要的配置升级迁移。

Supports macOS 27.0 or later on Apple silicon (arm64) only. The project prioritizes the macOS 27 SDK and APIs, keeps the implementation concise, and does not maintain compatibility code for older macOS releases or Intel Macs. Forward configuration migrations remain supported.
