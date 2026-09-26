<!-- Sync Impact Report
Version change: placeholder scaffold → 1.0.0 (initial project constitution)
Modified principles: all five principle placeholders were replaced with project rules.
Added sections: Project Constraints; Development and Release Workflow.
Removed sections: none.
Follow-up: project maintainers must confirm the original ratification date.
-->

# 核心原则

## I. 配置数据必须来自探测或用户输入

程序不得在源码、交互默认值或回退逻辑中写入特定用户环境的 IP、MAC、主机名、域名、共享路径或用户名。配置值只能来自运行期真实探测或用户在向导中的明确输入。开发和验证过程不得手工伪造业务配置；配置必须由程序自身的初始化和配置功能生成。

## II. 命令行负责配置，LaunchAgent 负责常驻运行

主要配置和维护入口保持为命令行交互界面。LaunchAgent 负责登录后的持续网络评估和自动挂载。若未来增加图形界面，该界面只负责配置和状态查看，不得创建常驻的第二个运行进程或替代 LaunchAgent。

## III. 每个用户配置只有一个活动来源

守护进程和交互命令必须读取同一份活动配置。旧版本存在多份配置时，迁移必须先备份；内容相同时可以合并；内容不同时必须让用户选择来源。迁移完成后，程序不得长期维护多份可独立编辑并互相同步的活动配置。

## IV. 安装和更新必须尊重单一文件所有者

终端用户运行和部署程序时必须使用已构建的预编译二进制，不得要求用户机器安装 Xcode 或现场编译源码。每个安装渠道负责其安装文件的升级和回滚；程序内的自动更新可以发起升级，但必须委托给当前安装渠道，不能直接覆盖由包管理器拥有的文件。

## V. 版本和发布必须可追溯

`auto_mount.swift` 顶部的 `autoMountVersion` 是唯一版本来源。配置版本、命令输出、HTTP User-Agent、Git Tag 和 Release 标题均须从该值同步。MAJOR、MINOR、PATCH 按项目 SemVer 规则递增。

# 项目约束

## 支持平台

AutoMount 面向 Apple silicon（arm64）设备和 macOS 27.0 或更高版本。守护服务使用当前登录用户的 LaunchAgent，不需要 Root 权限。实现优先使用 macOS 原生能力，并保持依赖精简。

## 安全和网络请求

SMB 凭据由 macOS 钥匙串管理；程序不得把密码写入配置或日志。自动更新默认关闭，`off` 模式不得发起后台版本检查。`notify` 和 `auto` 必须由用户明确选择，并保留清晰的失败记录和重试边界。

## 分发渠道

Homebrew 是主要安装入口。Homebrew 安装的文件由 Homebrew 管理；程序的更新策略不得绕过 Homebrew 直接改写其安装路径。其他分发方式及其更新所有者必须在对应 Feature 规格中明确。

# 开发与发布流程

## Spec Kit 工作流

实质性功能工作必须使用项目的 Spec Kit 工作流。新 Feature 开始前，先确认当前 Constitution 和既有项目状态；高风险 Feature 先完成结构化 Discovery。高风险工作采用何种审查配置，由维护者针对该 Feature 明确选择。实现前，规格、计划和任务必须与已接受的决定一致。

## 发布要求

向 `main` 推送包含核心代码的变更时，版本必须严格递增。创建提交、推送或 GitHub Release 前，必须用最新源码在 macOS 27 SDK 环境生成预编译二进制，并通过全部内置自测。正式 Release 必须包含与源码版本一致的可执行文件。GitHub 状态、PR、Release 和其他 GitHub 操作只使用 `gh` CLI。

## 公开文档

新增或实质性重写的项目文档使用中文，除非用户或更具体的项目指令另有要求。README 和公开技术文档面向未参与开发讨论的第三方，描述应独立、客观、可验证，不包含临时讨论代号或私人环境数据。

# 治理

本 Constitution 是项目持续适用的工程原则。维护者修改原则或约束时，必须说明变更范围和理由，并按 SemVer 规则递增 Constitution 版本。Feature 规格不得静默改变项目默认治理配置。产品、安全、隐私、数据保留和发布决定必须由用户明确给出，或标为待确认，不得用未声明的行业默认值替代。

**版本**：1.0.0 | **批准日期**：TODO(RATIFICATION_DATE): 由维护者确认首次批准日期 | **最后修订**：2026-09-27
