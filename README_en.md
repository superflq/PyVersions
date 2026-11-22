# PyVersions

English | [简体中文](README.md)

An interactive PowerShell tool to install, switch, and uninstall **standalone Python** builds ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)) on Windows — with full **multi-version coexistence** support. No installer, no admin rights required (unless you choose an All-Users location), no Python needed beforehand.

```
  ======================================================
    PyVersions  v1.8.3
    Python 独立版 (install_only) 管理工具
  ======================================================
  当前权限: 管理员 (写入系统级注册表 / 系统 PATH)

  [1] 部署 Python                  (本地离线包 + 在线下载, 自动选择)
  [2] 清理 / 卸载指定版本          (注册表 / PATH / 文件)
  [3] 查看本机已注册的 Python 版本  (可切换主用版本)
  [0] 退出
```

## Features

- **Unified deploy (offline archives + online download in one flow)** — entering deploy lists the offline archives in the script directory and picks the source automatically: a number (`1`) forces the matching archive; an exact version (`3.12.16`) prefers local and falls back to online; a major version (`3.12`) goes **online-first** for the newest build (zero download when the archive is already cached) and degrades to local archives when offline; `o [version]` forces online; with no local archives it goes straight to online mode.
- **Startup-argument deploy** — `PyVersions.ps1 3.12` / `PyVersions.ps1 3.12.16` deploy directly without the menu (same semantics as the interactive input); `-h` shows help. Exit code `0` on success / `1` on failure — script-friendly. Without arguments it enters the interactive menu.
- **Zero-API version discovery** — the newest upstream build tags are resolved via the `releases/latest` HTTP 302 redirect plus `releases.atom` (immune to GitHub API rate limits); the GitHub API remains as a fallback covering old majors the atom feed may miss. Each tag's `SHA256SUMS` manifest (tens of KB) then yields the exact asset candidates.
- **SHA256 integrity check** — every downloaded archive is verified against the upstream `SHA256SUMS` manifest; a bad archive is deleted and the next-newest candidate takes over. Manifests are cached per release tag (`SHA256SUMS-<tag>`) in the system temp directory (Windows `%TEMP%\PyVersions_sums`; Linux `/tmp/pyversions_sums-<uid>`).
- **Cache governance** — after a successful deploy, older-date cached archives of the same exact version are pruned (only the one just used is kept); leftover temp extract dirs (`.py_deploy_*`) from crashed runs are swept automatically at the start of every deploy.
- **LAN proxy acceleration** — before downloads, a list of LAN proxy candidates (200 ms TCP probe each) is tried first; the first reachable one is used as the download proxy. Falls back to the system proxy, then direct connection. Behavior is identical to the Linux sibling `PyVersions_pyenv.sh`.
- **Resilient download** — automatic mirror fallback when GitHub direct fails (`ghfast.top`, `gh-proxy.com`); archives downloaded online are kept in the script directory and automatically become offline candidates next time (cache loop).
- **Integrity self-check with fallback** — every build is extracted to a temp dir and health-checked (`import glob, pathlib, pip`) *before* touching your installation; a defective build automatically falls back to the next-newest candidate. The whole install directory is replaced atomically — no mixed old/new stdlib.
- **Idempotent deploy** — when the target directory already exists, **keep the existing install** is the default (just press Enter); overwrite or relocating requires explicit confirmation, so re-running never wipes your third-party packages by accident.
- **Full environment integration** — PEP 514 registry entries (`HKLM`/`HKCU` with automatic privilege-based fallback), `.py`/`.pyc`/`.pyw` file associations, PATH setup (deduplicated, prepended), and a `WM_SETTINGCHANGE` broadcast so new terminals work immediately.
- **Multi-version coexistence** — each version lives in its own directory (e.g. `D:\Python\python3.12`, `D:\Python\python3.13`). Version-pinned `pip3.12.bat` / `pip3.13.bat` launchers in each `Scripts` folder make `pip` unambiguous.
- **Safe uninstall** — removes the registry keys, file associations, and PATH entries for a chosen version, optionally the install directory too (with a type-the-version confirmation). Orphaned PATH entries are detected even without registry references.
- **Association safety for multi-version machines** — when you uninstall a version that currently owns the `.py` association, it is automatically **re-directed to the newest remaining registered version** instead of being deleted; directories still referenced by other versions are never deleted.
- **Switch the primary version** — view registered versions and promote one to primary: its PATH entries move to the front and the `.py` associations point to it.
- **Chinese interactive UI** — all prompts and messages are in Simplified Chinese.

## Requirements

| | |
|---|---|
| OS | Windows 10 (1803+) / Windows 11 / Windows Server 2019 / 2022 / 2025 |
| Runtime | Windows PowerShell 5.1 (built in — `powershell.exe`) |
| Tools | `curl.exe` and `tar.exe` (built in since the versions above); 7-Zip as an optional tar fallback |
| Network | Only for online install; offline install works fully disconnected |

Older Windows versions are not supported (they lack built-in `curl.exe`).

## Quick Start

```powershell
# 1. Save PyVersions.ps1 anywhere (e.g. D:\Tools)
# 2. Interactive menu:
powershell.exe -ExecutionPolicy Bypass -File PyVersions.ps1
# 3. Or deploy a version directly:
powershell.exe -ExecutionPolicy Bypass -File PyVersions.ps1 3.12
powershell.exe -ExecutionPolicy Bypass -File PyVersions.ps1 3.12.16
```

Recommended: right-click the script → *Run with PowerShell*, or create a shortcut with the command above. Admin rights are optional — as admin it writes system-level registry/PATH (HKLM/HKCR); as a normal user it gracefully falls back to per-user locations (HKCU / user PATH).

## Usage

### Startup-argument mode

| Command | Meaning |
|---|---|
| `PyVersions.ps1` | Enter the interactive main menu |
| `PyVersions.ps1 3.12` | Deploy the newest 3.12 series build directly (major-version semantics: online-first, degrade to local) |
| `PyVersions.ps1 3.12.16` | Deploy that exact version directly (local first, online if missing) |
| `PyVersions.ps1 -h` / `--help` | Show help |

Exit codes in argument mode: `0` deploy succeeded (or existing install kept), `1` deploy failed or invalid argument. Confirmation prompts (install dir / overwrite / registry import) remain interactive; EOF on stdin takes the safe defaults (keep existing install / skip import).

### [1] Deploy Python (offline + online, unified)

On entry, offline archives in the script directory are listed (multiple builds of the same version show only the newest). The input picks the source automatically:

| Input | Meaning |
|---|---|
| Number (e.g. `1`) | Force-deploy the matching local archive |
| Exact version (e.g. `3.12.16`) | Local first; if that exact version isn't local, look it up online |
| Major version (e.g. `3.12`) | **Online-first** for the newest build in that series; zero download if the archive is already cached; auto-**degrade** to local archives on failure |
| `o [version]` (e.g. `o 3.13`) | **Force online** (ignore local archives); bare `o` means `o 3.12` |
| Enter | Same as typing `3.12` |

Then choose the install directory (see below) → prepare the archive (reuse local or download; cached archives skip the download) → extract to a temp folder → health check → swap into place → confirm `Y` to import registry / associations / PATH.

If **all** local archives fail the self-check (bad ones are deleted automatically), you can opt to **switch to online install** — the online source offers more historical builds, skipping defective ones. With no local archives at all, it goes straight to online mode.

### [2] Clean / uninstall

Two modes are listed for you to choose:

- **[1] Clean only** — delete the version's registry keys, file associations, and PATH entries (files stay).
- **[2] Uninstall** — additionally delete the install directory. You must type the full version number to confirm.

### [3] View registered versions / switch primary

Lists every registered Python (registry + PATH, both hives). With two or more valid versions you can **set one as primary**: its PATH entries jump to the front and `.py`/`.pyc`/`.pyw` associations point to it. The current primary version is highlighted with a green `***` marker.

### Install locations

Three built-in choices at install time (or type any custom path):

| # | Location | Style |
|---|---|---|
| 1 | `D:\Python\python<XY>` (configurable via `$ExtractParentDir`) | PyVersions default |
| 2 | `%ProgramFiles%\Python<XY>` (resolved via `%ProgramW6432%` in the script) | Official-installer convention, All Users (needs admin) |
| 3 | `%LocalAppData%\Programs\Python\Python<XY>` | Official-installer convention, current user |

`<XY>` is the version without the dot, e.g. `Python312`. Missing parent folders of a custom path are created automatically (level by level); unreachable drives / network shares are rejected immediately at selection time; the install directory cannot be a drive or share root. When the target directory exists you choose **overwrite / keep existing (default) / relocate** — pressing Enter keeps the existing install, so idempotent re-runs never wipe third-party packages by accident.

### LAN proxy acceleration

The script ships a `$GlobalProxyUrls` list of LAN proxy candidates (e.g. `http://localhost:56666`). Before every deploy each candidate gets a 200 ms TCP probe; the first reachable one is passed **per-invocation** to the download commands (`curl -x` / `-Proxy`) — **system proxy settings and proxy environment variables are never modified**. Pre-set `http_proxy`/`https_proxy` are used as-is; otherwise it falls back to the system proxy, then direct. Edit the config block to match your intranet.

### pip launchers

Each deployment creates in its `Scripts` folder:

- `pip.bat` — generic entry
- `pip3.12.bat` / `pip3.13.bat` … — version-pinned pip that works regardless of PATH order, mirroring the official `pip3.X.exe`

## Multi-version behavior explained

| Scenario | What happens to the `.py` file association |
|---|---|
| Install A | Association points to A |
| Install B | Association now points to B (last-installed wins, same as the official installer) |
| Uninstall B (A remains) | Automatically **re-directed to A** |
| Uninstall A (association already on B) | Untouched — it doesn't belong to A |
| Uninstall the only version | Association removed (nothing left to hand over to) |
| An install directory shared by two registrations | Treated as shared: never deleted during uninstall; associations/PATH for it are preserved |

## How it works

- Version discovery targets [astral-sh/python-build-standalone](https://github.com/astral-sh/python-build-standalone) via a zero-API channel first (the `releases/latest` HTTP 302 redirect + `releases.atom` for the 3 newest tags), with the GitHub API as a fallback for old majors the atom feed may miss; each tag's `SHA256SUMS` manifest matches assets named `cpython-<ver>+<date>-x86_64-pc-windows-msvc-install_only.tar.gz` and doubles as the integrity reference.
- Registry layout follows [PEP 514](https://peps.python.org/pep-0514/) (`PythonCore\<tag>`), which is what tools like `py.exe` and VS Code scan.
- The health check exists because some 20261110-era builds shipped with a broken `glob`/`pathlib` chain that only surfaces at `pip` runtime — the check catches exactly that class of defect before it reaches your machine.
- PATH changes are broadcast via `WM_SETTINGCHANGE`; already-open terminals need to be reopened.

## FAQ

**Q: Do I need admin rights?**
Only if you pick the All-Users location (`%ProgramFiles%\...`) or want system-level PATH/associations. Otherwise everything works per-user.

**Q: Can I move an installation?**
Reinstall into the new directory (the old one stays until you uninstall it), then switch the primary version with menu [3].

**Q: A build failed the self-check, what now?**
Nothing to do — PyVersions deletes the bad archive and falls back to the next-newest build automatically.

**Q: Does it touch existing official Python installations?**
Uninstall/clean only targets the version you type in. Switching primary versions only reorders PATH and rewrites associations.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

- [astral-sh/python-build-standalone](https://github.com/astral-sh/python-build-standalone) — the upstream build provider
- [adang1345/PythonWindows](https://github.com/adang1345/PythonWindows) — historical standalone builds (kept as a fallback reference)
- [ghfast.top](https://ghfast.top/) / [gh-proxy.com](https://gh-proxy.com/) — GitHub download accelerators used as mirror fallbacks
