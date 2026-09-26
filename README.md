# 语言导航 / Language Navigation

| 语言 / Language | 说明文档 / Documentation | 架构与技术规范 / Architecture & Standards |
| :--- | :--- | :--- |
| 中文 | [README.zh.md](./README.zh.md) | [ARCHITECTURE.zh.md](./ARCHITECTURE.zh.md) |
| English | [README.en.md](./README.en.md) | [ARCHITECTURE.en.md](./ARCHITECTURE.en.md) |

# 简介 / Overview

macOS 原生轻量级网络存储（SMB）自动化挂载工具。基于物理网关 MAC 指纹识别与 Tailscale 异地互联，提供完全静默、免密码、断网自动超时熔断清理的稳定挂载体验。

A native, lightweight network storage (SMB) automation tool for macOS. Powered by physical gateway MAC fingerprinting and Tailscale remote interconnection, providing silent, password-free, and timeout-fused volume mounting.

仅支持 macOS 27.0 或更高版本的 Apple silicon（arm64）；不支持 Intel Mac。项目以 macOS 27 SDK 和新 API 为优先目标，不维护旧 macOS 或 Intel 的兼容代码；代码保持精简，且继续支持必要的配置升级迁移。

Supports macOS 27.0 or later on Apple silicon (arm64) only. The project prioritizes the macOS 27 SDK and APIs, keeps the implementation concise, and does not maintain compatibility code for older macOS releases or Intel Macs. Forward configuration migrations remain supported.
