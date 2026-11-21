# PyVersions

[English](README_en.md) | 简体中文

一个交互式 PowerShell 工具，用于在 Windows 上安装、切换、卸载 **Python 独立版**（[python-build-standalone](https://github.com/astral-sh/python-build-standalone)），原生支持**多版本共存**。无需安装器、无需预先安装 Python，除 All Users 目录外无需管理员权限。

```
  ======================================================
    PyVersions  v1.5.0
    Python 独立版 (install_only) 管理工具
  ======================================================
  当前权限: 管理员 (写入系统级注册表 / 系统 PATH)

  [1] 下载并部署 Python           (在线, 交互选版本)
  [2] 离线部署 Python             (罗列脚本目录内的压缩包供选择)
  [3] 清理 / 卸载指定版本         (注册表 / PATH / 文件)
  [4] 查看本机已注册的 Python 版本  (可切换主用版本)
  [0] 退出
```

## 功能特性

- **在线安装** — 交互选版本（`3.12` 取 3.12.x 最新补丁版，`3.12.16` 精确匹配）；GitHub 直连失败自动切换镜像（`ghfast.top`、`gh-proxy.com`）；脚本目录已有同名压缩包时直接复用缓存。
- **离线安装** — 把任意 `*-x86_64-pc-windows-msvc-install_only.tar.gz` 放进脚本目录即可罗列选择（编号或版本号）。同版本多个构建日期只显示最新的一个。
- **自检 + 自动回退** — 每个构建先解压到临时目录做健康检查（`import glob, pathlib`），通过后才替换正式目录；缺陷构建自动回退次新候选。整体替换安装目录，绝不新旧 stdlib 混杂。
- **环境全自动集成** — PEP 514 注册表（`HKLM`/`HKCU` 按权限自动降级）、`.py`/`.pyc`/`.pyw` 文件关联、PATH 去重置前、`WM_SETTINGCHANGE` 广播（新开终端即刻可用）。
- **多版本共存** — 每个版本独立目录（如 `D:\Python\python3.12`、`python3.13`）；各 `Scripts` 下生成版本锁定的 `pip3.12.bat` / `pip3.13.bat`，不受 PATH 顺序影响。
- **安全卸载** — 按版本删除注册表键 / 文件关联 / PATH 条目，可选连同安装目录（需完整输入版本号二次确认）；孤儿 PATH 条目（无注册表引用）也能识别清理。
- **多版本关联安全** — 卸载当前持有 `.py` 关联的版本时，关联自动**重定向到剩余最新版本**而非删除；仍被其他版本引用的安装目录绝不删除。
- **切换主用版本** — 罗列已注册版本，一键把某版本设为主用：PATH 条目置前 + `.py` 关联指向它。
- **全中文交互界面**。

## 系统要求

| | |
|---|---|
| 操作系统 | Windows 10 (1803+) / Windows 11 / Windows Server 2019 / 2022 / 2025 |
| 运行环境 | Windows PowerShell 5.1（系统自带 `powershell.exe`） |
| 依赖工具 | `curl.exe` 与 `tar.exe`（上述系统自带）；7-Zip 为可选解压兜底 |
| 网络 | 仅在线安装需要；离线安装完全断网可用 |

更早的 Windows 版本不支持（缺少自带的 `curl.exe`）。

## 快速开始

```powershell
# 1. 把 PyVersions.ps1 放到任意目录 (如 D:\Tools)
# 2. 运行:
powershell.exe -ExecutionPolicy Bypass -File PyVersions.ps1
```

推荐右键脚本 → *使用 PowerShell 运行*，或按上述命令创建快捷方式。管理员权限可选——管理员写入系统级注册表/PATH（HKLM/HKCR），普通用户自动降级为当前用户位置（HKCU / 用户 PATH）。

## 使用说明

### [1] 在线下载部署

1. 输入版本：`3.12`（取 3.12.x 最新）或 `3.12.16`（精确）。直接回车默认 `3.12`。
2. 选择安装目录（见下表）。
3. 压缩包下载（或命中脚本目录缓存）→ 临时目录解压 → 健康检查 → 整体替换。
4. 确认 `Y` 自动导入注册表 / 关联 / PATH。

### [2] 离线部署

把 `cpython-*.tar.gz` 压缩包放到脚本同目录，按编号（`1`、`2`）或版本号（`3.12`、`3.12.16`）选择。最新构建自检失败时自动回退次新包。

### [3] 清理 / 卸载

罗列两种模式供选择：

- **[1] 仅清理** — 删除该版本的注册表键 / 文件关联 / PATH 条目（文件保留）。
- **[2] 卸载** — 额外删除安装目录，需完整输入版本号二次确认。

### [4] 查看已注册版本 / 切换主用

罗列本机全部已注册 Python（注册表 + PATH，双 hive）。存在两个及以上有效版本时可**设为主用**：PATH 条目置前，`.py`/`.pyc`/`.pyw` 关联指向它。

### 安装目录

安装时内置三个备选（也可直接输入自定义路径）：

| # | 位置 | 说明 |
|---|---|---|
| 1 | `D:\Python\python<XY>`（可通过 `$ExtractParentDir` 配置） | 本工具默认 |
| 2 | `%ProgramFiles%\Python<XY>`（脚本内经 `%ProgramW6432%` 解析，避开 32 位进程重定向） | 官方安装器惯例，All Users（需管理员） |
| 3 | `%LocalAppData%\Programs\Python\Python<XY>` | 官方安装器惯例，当前用户 |

`<XY>` 为去掉点号的版本号，如 `Python312`。

### pip 启动脚本

每次部署会在 `Scripts` 下创建：

- `pip.bat` — 通用入口
- `pip3.12.bat` / `pip3.13.bat` … — 版本锁定，不受 PATH 顺序影响，等价官方安装器的 `pip3.X.exe`

## 多版本行为说明

| 场景 | `.py` 文件关联的变化 |
|---|---|
| 安装 A | 关联指向 A |
| 再安装 B | 关联被 B 覆盖（后装赢得，与官方安装器一致） |
| 卸载 B（A 还在） | 自动**重定向回 A** |
| 卸载 A（关联已在 B 上） | 不动——关联不属于 A |
| 卸载唯一版本 | 删除关联（无剩余版本可接管） |
| 两个注册指向同一安装目录 | 视为共享目录：卸载绝不删除文件，其关联与 PATH 条目保留 |

## 工作原理

- 版本发现走 [astral-sh/python-build-standalone](https://github.com/astral-sh/python-build-standalone) 的 GitHub API（资源名 `cpython-<ver>+<date>-x86_64-pc-windows-msvc-install_only.tar.gz`）。
- 注册表遵循 [PEP 514](https://peps.python.org/pep-0514/)（`PythonCore\<tag>`），`py.exe`、VS Code 等工具均按此扫描。
- 健康检查的由来：部分 20261110 期构建的 `glob`/`pathlib` 链路存在缺陷，只在 pip 运行时暴露——自检正是为了在进入你的机器前拦住这类问题。
- PATH 变更通过 `WM_SETTINGCHANGE` 广播；已打开的终端需要重开。

## 常见问题

**Q: 需要管理员权限吗？**
仅当选 All Users 位置（`%ProgramFiles%\...`）或希望写系统级 PATH/关联时需要；否则全程按当前用户工作。

**Q: 能移动安装位置吗？**
先装到新目录（旧目录保留），再用菜单 [4] 切换主用版本，最后卸载旧目录的注册即可。

**Q: 构建自检失败了怎么办？**
无需处理——PyVersions 会删除坏包并自动回退次新构建。

**Q: 会影响已有的官方 Python 安装吗？**
清理/卸载只针对你输入的那个版本；切换主用只调整 PATH 顺序与关联指向。

## 许可证

MIT — 见 [LICENSE](LICENSE)。

## 致谢

- [astral-sh/python-build-standalone](https://github.com/astral-sh/python-build-standalone) — 上游构建来源
- [adang1345/PythonWindows](https://github.com/adang1345/PythonWindows) — 历史独立版构建（备用参考）
- [ghfast.top](https://ghfast.top/) / [gh-proxy.com](https://gh-proxy.com/) — GitHub 下载加速镜像
