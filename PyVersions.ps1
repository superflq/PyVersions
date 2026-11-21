# =========================================================
#  PyVersions  v1.6.0
#  Python 独立版 (install_only) 多版本管理工具
#  下载源: astral-sh/python-build-standalone (持续更新)
#
#  主菜单功能:
#    [1] 部署 Python - 本地离线包 + 在线下载 融合入口:
#        编号 / 精确版本 (如 3.12.16) 优先使用本地离线包 (本地没有转在线),
#        大版本 (如 3.12) 在线优先获取最新构建 (本地缓存命中免下载,
#        断网自动降级本地离线包), o [版本] 强制在线, 无离线包时直接在线;
#        解压自检通过才安装 (缺陷构建自动回退次新构建),
#        按版本自动命名安装目录 (如 D:\Python\python3.12, 支持多版本共存,
#        目录已存在时可选择 覆盖安装 / 跳过部署 / 更换目录),
#        自动创建 Scripts\pip*.bat, 自动导入注册表与 PATH
#    [2] 清理 / 卸载指定版本 - 二选一: 仅清理注册表键 / 文件关联 / PATH,
#        或连同安装目录文件一起删除 (卸载需输入版本号二次确认;
#        被其他版本共享的安装目录只清理注册项, 文件保留)
#    [3] 查看本机已注册版本 - 扫描 HKLM/HKCU 注册表与 PATH,
#        可将指定版本设为主用 (PATH 置前 + .py 关联指向)
#
#  运行方式: powershell.exe -ExecutionPolicy Bypass -File PyVersions.ps1
#  系统要求: Windows 10 (1803+) / Windows 11 / Windows Server 2019/2022/2025
#            (系统自带 curl 与 tar, 开箱即用), 不支持更早版本系统
#
#  注意: 本文件必须以 UTF-8 with BOM 编码保存,
#        否则中文在 Windows PowerShell 5.1 下会乱码
# =========================================================

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

trap {
    Write-Host ""
    Write-Host "[致命错误] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "出错位置: 第 $($_.InvocationInfo.ScriptLineNumber) 行: $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray
    Read-Host "按回车键退出"
    exit 1
}

if ($PSScriptRoot) { Set-Location -Path $PSScriptRoot }

# ----------------------- 配置区 -----------------------
# 资源仓库 (数组形式便于日后扩展备用源; 当前仅使用单一源)
$RepoSlugs        = @("astral-sh/python-build-standalone")
$ExtractParentDir = "D:\Python"                                   # 安装/解压父目录 (压缩包内含 python\ 顶层目录)
$TargetArch       = "x86_64-pc-windows-msvc-install_only.tar.gz"  # 目标资源后缀
$DefaultVersion   = "3.12"                                        # 直接回车时使用的默认版本
# 安装目录备选根 (对应官方 Python 安装器路径惯例, 安装目录 = 备选根\Python<XY>, 如 Python312)
$AllUsersRoot     = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles } # All Users 安装 (需管理员); ProgramW6432 避开 32 位进程的 WOW64 重定向
$UserRoot         = Join-Path $env:LOCALAPPDATA "Programs\Python" # 当前用户安装 (无需管理员)
# 下载加速线路 (按顺序尝试; 留空字符串表示 GitHub 直连。镜像失效会自动换下一线路)
$DownloadMirrors  = @("", "https://ghfast.top/", "https://gh-proxy.com/")
# -------------------------------------------------------

$SevenZipExe = "C:\Program Files\7-Zip\7z.exe"
$TarExe      = Join-Path $env:SystemRoot "System32\tar.exe"

# ======================= 基础工具函数 =======================

function Write-Banner([string]$text, [string]$color = "Cyan") {
    Write-Host "=========================================" -ForegroundColor $color
    Write-Host $text -ForegroundColor $color
    Write-Host "=========================================" -ForegroundColor $color
}

# 计算字符串的控制台显示宽度 (CJK 等全角字符按 2 列计, 用于菜单项对齐)
function Get-DisplayWidth([string]$s) {
    $w = 0
    foreach ($ch in $s.ToCharArray()) {
        if ([int]$ch -ge 0x2E80) { $w += 2 } else { $w += 1 }
    }
    return $w
}

# 读取一行用户输入并去除首尾空白; 输入流结束 (EOF) 时返回 $null
function Read-Input([string]$prompt) {
    $v = Read-Host $prompt
    if ($null -eq $v) { return $null }
    return $v.Trim()
}

# 循环读取 Y/N 确认; 输入流结束 (EOF) 时返回 "N" 以防误操作
function Read-YesNo([string]$prompt, [string]$default = "Y") {
    while ($true) {
        $v = Read-Input "$prompt (Y/N) [默认: $default]"
        if ($null -eq $v) { return "N" }
        if ([string]::IsNullOrWhiteSpace($v)) { $v = $default }
        $v = $v.Substring(0, 1).ToUpper()
        if ($v -eq "Y" -or $v -eq "N") { return $v }
        Write-Host "请输入 Y 或 N。" -ForegroundColor Red
    }
}

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 广播环境变量变更 (WM_SETTINGCHANGE), 让新开终端立即识别, 无需注销/重启
function Invoke-EnvBroadcast {
    try {
        if (-not ('Win32.Win32Broadcast' -as [type])) {
            $sig = '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
            Add-Type -MemberDefinition $sig -Name "Win32Broadcast" -Namespace "Win32" | Out-Null
        }
        $broadcast = 'Win32.Win32Broadcast' -as [type]
        [UIntPtr]$result = [UIntPtr]::Zero
        $null = $broadcast::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result)
        Write-Host "[成功] 已广播环境变量变更, 新开的终端即刻生效 (已开着的终端需重开)。" -ForegroundColor Green
    } catch {
        Write-Host "[提示] 环境变量变更广播失败 (不影响写入), 重新打开终端即可生效。" -ForegroundColor DarkYellow
    }
}

# 获取单个资源压缩包: 本地已有同名文件(>1MB)则直接复用不重复下载,
# 否则按 直连/镜像 依次尝试下载。成功返回本地路径, 失败返回 $null
function Invoke-AssetDownload([string]$assetName, [string]$assetUrl) {
    if (Test-Path $assetName) {
        $localItem = Get-Item $assetName -ErrorAction SilentlyContinue
        if ($localItem -and $localItem.Length -gt 1MB) {
            $localPath = (Resolve-Path $assetName).Path
            Write-Host "发现本地已有同名压缩包, 跳过下载: $localPath" -ForegroundColor Green
            return $localPath
        }
        # 本地文件过小 (下载残留/损坏), 删除后重新下载
        Remove-Item $assetName -Force -ErrorAction SilentlyContinue
    }

    # curl.exe 前置检查: Windows 10 1803+ / Server 2019+ 系统自带, 更早版本系统请升级后再使用
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        Write-Host "[错误] 未找到 curl.exe, 无法下载。" -ForegroundColor Red
        Write-Host "       本工具要求 Windows 10 (1803+) / Windows 11 / Server 2019 及以上系统 (自带 curl)。" -ForegroundColor Red
        return $null
    }

    foreach ($mirror in $DownloadMirrors) {
        $tryUrl = "$mirror$assetUrl"
        if ($mirror) { Write-Host "正在通过加速镜像下载: $mirror" -ForegroundColor Cyan }
        else         { Write-Host "正在通过 GitHub 直连下载..." -ForegroundColor Cyan }

        & curl.exe -f -L --retry 3 --retry-delay 2 --connect-timeout 20 --ssl-no-revoke -o "$assetName" "$tryUrl"
        if ($LASTEXITCODE -eq 0 -and (Test-Path $assetName) -and ((Get-Item $assetName).Length -gt 1MB)) {
            $okPath = (Resolve-Path $assetName).Path
            Write-Host "下载完成: $okPath" -ForegroundColor Green
            return $okPath
        }
        Write-Host "该线路下载失败, 尝试下一线路..." -ForegroundColor Yellow
        if (Test-Path $assetName) { Remove-Item $assetName -Force -ErrorAction SilentlyContinue }
    }
    return $null
}

# ======================= 注册表扫描 =======================

# 扫描注册表 (HKLM / HKLM 32位视图 / HKCU) 中已注册的 Python (PEP 514 PythonCore)
function Get-RegisteredPythons {
    $result = @()
    $hives = @(
        @{ Root = "HKLM:\SOFTWARE\Python\PythonCore";             Label = "HKLM" },
        @{ Root = "HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore"; Label = "HKLM(32)" },
        @{ Root = "HKCU:\Software\Python\PythonCore";             Label = "HKCU" }
    )
    foreach ($h in $hives) {
        if (-not (Test-Path $h.Root)) { continue }
        foreach ($tagKey in @(Get-ChildItem -Path $h.Root -ErrorAction SilentlyContinue)) {
            $p     = Get-ItemProperty -Path $tagKey.PSPath -ErrorAction SilentlyContinue
            $ipKey = Join-Path $tagKey.PSPath "InstallPath"
            $installPath = ""
            if (Test-Path $ipKey) {
                $installPath = ([string]((Get-Item -Path $ipKey).GetValue("")))
                if ($installPath -match '[\r\n"]') {
                    # 清洗历史残缺值: 形如 "路径" /f 或含换行的损坏注册, 取引号内/首个路径段
                    $installPath = (($installPath -split '\r?\n')[0] -split '"\s+')[0].Trim().Trim('"').Trim()
                }
                $installPath = $installPath.TrimEnd("\")
            }
            $result += [PSCustomObject]@{
                Hive        = $h.Label
                Tag         = $tagKey.PSChildName
                DisplayName = [string]$p.DisplayName
                Version     = [string]$p.Version
                SysVersion  = [string]$p.SysVersion
                InstallPath = $installPath
                KeyPath     = $tagKey.PSPath
            }
        }
    }
    return ,$result
}

# 按 "3.12" (tag / SysVersion) 或 "3.12.16" (完整版本号) 匹配已注册 Python
function Get-MatchedRegistrations([string]$inputVer) {
    # 注意: 必须先赋值再过滤。直接写 Get-RegisteredPythons | Where-Object 会让
    # 整个数组作为单个 $_ 进入管道, 成员枚举导致所有注册都被错误匹配
    $esc        = [regex]::Escape($inputVer)
    $registered = Get-RegisteredPythons
    return @($registered | Where-Object {
        ($_.Tag -eq $inputVer) -or
        ($_.Version -eq $inputVer) -or
        ($_.SysVersion -eq $inputVer) -or
        ($inputVer -match '^[0-9]+\.[0-9]+$' -and $_.Tag -match "^${esc}(\.|-|$)")
    })
}

# 判断 PATH 条目是否位于 root 之下 (root 本身 / root\Scripts / root 的子目录段, 大小写不敏感)
function Test-PathUnder([string]$entry, [string]$root) {
    $e = $entry.TrimEnd("\"); $r = $root.TrimEnd("\")
    if (-not $r) { return $false }
    return ($e -ieq $r -or $e -match ("^" + [regex]::Escape($r) + "(\\.+)?$"))
}

# 展示已注册 Python 列表与 PATH 中的 Python 相关条目 (功能 3 / 清理前预览)
function Show-RegisteredPythons {
    $registered = Get-RegisteredPythons
    if ($registered.Count -eq 0) {
        Write-Host "注册表中未发现任何 PythonCore 注册信息 (HKLM/HKCU 均无)。" -ForegroundColor Yellow
    } else {
        Write-Host "注册表中的 Python (PEP 514 PythonCore):" -ForegroundColor White
        foreach ($r in $registered) {
            $ver = if ($r.Version) { $r.Version } else { "(版本未知)" }
            $ip  = if ($r.InstallPath) { $r.InstallPath } else { "(InstallPath 缺失, 疑似残留残键)" }
            Write-Host ("  [{0,-7}] {1,-8} 版本 {2,-12} 安装目录: {3}" -f $r.Hive, $r.Tag, $ver, $ip)
        }
    }

    Write-Host ""
    Write-Host "PATH 中的 Python 相关条目:" -ForegroundColor White
    $foundAny = $false
    foreach ($target in @([EnvironmentVariableTarget]::Machine, [EnvironmentVariableTarget]::User)) {
        $raw = [Environment]::GetEnvironmentVariable("Path", $target)
        if (-not $raw) { continue }
        foreach ($e in @($raw -split ";")) {
            if ($e -and $e -match "(?i)python") {
                Write-Host ("  [{0}] {1}" -f $target, $e)
                $foundAny = $true
            }
        }
    }
    if (-not $foundAny) { Write-Host "  (无)" }
}

# ============ 功能 1 内部: 在线部署执行体 (供统一部署流程调用) ============

# 在线部署执行体: 代理检测 -> 选版本 -> 查询 GitHub -> 下载/缓存 -> 部署。
# 返回 $true = 版本已部署 (或保留现有安装); $false = 未完成部署 (统一部署流程可据此降级本地)
function Invoke-InstallFlow([string]$presetVersion = "") {
    # ---------- 1. 检测系统代理 ----------
    Write-Banner "1. 正在检测系统代理..."

    $regProxy = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($regProxy.ProxyEnable -eq 1 -and $regProxy.ProxyServer) {
        $rawProxy = ($regProxy.ProxyServer -split ';')[0]
        $sysProxy = if ($rawProxy -match '=') { ($rawProxy -split '=')[1] } else { $rawProxy }
        if ($sysProxy -notmatch '^https?://') { $sysProxy = "http://$sysProxy" }
        $env:http_proxy  = $sysProxy
        $env:https_proxy = $sysProxy
        Write-Host "已检测到系统代理并应用: $sysProxy" -ForegroundColor Green
    } else {
        Write-Host "未启用系统代理, 将使用直连/TUN 模式。" -ForegroundColor Yellow
    }
    Write-Host ""

    # ---------- 2. 选择 Python 版本 ----------
    Write-Banner "2. 选择 Python 版本"
    Write-Host "提示:"
    Write-Host "  - 输入 大版本.小版本 (如 3.12)   -> 自动选择 3.12.x 中补丁号最高、构建日期最新的包"
    Write-Host "  - 输入 完整版本号 (如 3.12.13)  -> 下载 3.12.13 中构建日期最新的包"
    Write-Host "  - 直接回车                     -> 默认使用 $DefaultVersion"
    Write-Host ""

    $inputVer = $null
    # 支持从其他流程 (如离线部署失败转在线) 预置版本号, 跳过手动输入
    if ($presetVersion -match '^[0-9]+\.[0-9]+(\.[0-9]+)?$') {
        $inputVer = $presetVersion
        Write-Host "使用指定版本: $inputVer" -ForegroundColor Cyan
    }
    while ($null -eq $inputVer) {
        $inputVer = Read-Input "请输入 Python 版本 [默认: $DefaultVersion]"
        if ($null -eq $inputVer) {
            Write-Host "输入已结束, 返回主菜单。" -ForegroundColor Yellow
            return $false
        }
        if ([string]::IsNullOrWhiteSpace($inputVer)) { $inputVer = $DefaultVersion }
        if ($inputVer -match '^[0-9]+\.[0-9]+(\.[0-9]+)?$') { break }
        Write-Host "版本号格式无效: [$inputVer], 请输入类似 3.12 或 3.12.13 的格式。" -ForegroundColor Red
        $inputVer = $null
    }
    Write-Host ""

    # ---------- 3. 查询 GitHub Releases ----------
    Write-Banner "3. 正在查询 GitHub Releases [$inputVer] ..."

    $escapedVer  = [regex]::Escape($inputVer)
    $escapedArch = [regex]::Escape($TargetArch)
    # 版本号后必须紧跟 + 或 -, 以排除 3.16.0a1 / 3.14.0rc1 等预发布版
    if ($inputVer -match '^[0-9]+\.[0-9]+$') {
        $namePattern = "^c?python-${escapedVer}\.[0-9]+[\+\-].*${escapedArch}$"
    } else {
        $namePattern = "^c?python-${escapedVer}[\+\-].*${escapedArch}$"
    }

    $candidates    = @()
    $sampleNames   = @()
    $networkErrors = @()
    $anyRepoOk     = $false
    $headers = @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
        "Accept"     = "application/vnd.github+json"
    }

    foreach ($slug in $RepoSlugs) {
        Write-Host "正在查询仓库: $slug ..." -ForegroundColor Cyan
        $apiBase    = "https://api.github.com/repos/$slug/releases"
        $repoFailed = $false

        for ($page = 1; $page -le 3; $page++) {
            $uri      = "${apiBase}?per_page=15&page=$page"
            $releases = $null
            $lastErr  = $null

            # 每次请求自动重试 3 次, 应对网络波动 / 网关超时
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    $releases = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 40
                    $lastErr  = $null
                    break
                } catch {
                    $lastErr = $_.Exception.Message
                    if ($attempt -lt 3) {
                        Write-Host "  查询失败 (第 $attempt/3 次): $lastErr" -ForegroundColor DarkYellow
                        Write-Host "  3 秒后自动重试..." -ForegroundColor DarkYellow
                        Start-Sleep -Seconds 3
                    }
                }
            }

            if ($null -ne $releases) {
                foreach ($rel in @($releases)) {
                    if ($rel.draft) { continue }
                    $relDate = [int64]0
                    try {
                        $relDate = [int64]([DateTimeOffset]::Parse($rel.published_at, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString("yyyyMMddHHmmss"))
                    } catch {}

                    foreach ($asset in @($rel.assets)) {
                        if ($sampleNames.Count -lt 3 -and $asset.name -like "*.tar.gz") { $sampleNames += $asset.name }
                        if ($asset.name -notmatch $namePattern) { continue }

                        $pyVerStr = $null
                        if ($asset.name -match "^c?python-([0-9]+\.[0-9]+\.[0-9]+)[\+\-]") { $pyVerStr = $Matches[1] }
                        if (-not $pyVerStr) { continue }

                        $buildDate = $relDate
                        if ($asset.name -match "[\+\-]([0-9]{8})[\+\-]") { $buildDate = [int64]($Matches[1] + "000000") }

                        $candidates += [PSCustomObject]@{
                            Name      = $asset.name
                            Url       = $asset.browser_download_url
                            PyVer     = [version]$pyVerStr
                            BuildDate = $buildDate
                            Tag       = $rel.tag_name
                            Repo      = $slug
                        }
                    }
                }
            } elseif ($lastErr) {
                # 该仓库查询彻底失败 (已重试), 记录错误详情
                $repoFailed = $true
                break
            } else {
                # 分页已取完
                break
            }

            if ($candidates.Count -gt 0) { break }
        }

        if ($repoFailed) {
            $networkErrors += "${slug}: $lastErr"
            Write-Host "仓库 $slug 查询失败。" -ForegroundColor Yellow
        } else {
            $anyRepoOk = $true
        }
        if ($candidates.Count -gt 0) { break }
    }

    $bestMatch = $candidates |
        Sort-Object -Property @{ Expression = "PyVer"; Descending = $true }, @{ Expression = "BuildDate"; Descending = $true } |
        Select-Object -First 1

    if (-not $bestMatch) {
        Write-Host ""
        if (-not $anyRepoOk) {
            Write-Host "[错误] 查询 GitHub API 失败 (已自动重试):" -ForegroundColor Red
            $networkErrors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
            Write-Host "可能原因: 网络不稳定 / 代理未生效 / GitHub API 限流 (未认证每小时 60 次)。" -ForegroundColor Yellow
        } else {
            Write-Host "[错误] 仓库中未找到匹配 [$inputVer] 且后缀为 [$TargetArch] 的资源。" -ForegroundColor Red
            if ($sampleNames.Count -gt 0) {
                Write-Host "源中部分 .tar.gz 资源名示例:" -ForegroundColor Yellow
                $sampleNames | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
            } else {
                Write-Host "未获取到任何 .tar.gz 资源, 请检查网络后重试。" -ForegroundColor Yellow
            }
        }
        return $false
    }

    Write-Host ""
    Write-Host "匹配成功!" -ForegroundColor Green
    Write-Host "来源仓库    : $($bestMatch.Repo)"
    Write-Host "Release 标签: $($bestMatch.Tag)"
    Write-Host "目标文件    : $($bestMatch.Name)"
    Write-Host ""

    # ---------- 4. 获取压缩包 (本地已有则复用) ----------
    Write-Banner "4. 获取压缩包 (本地已有则跳过下载)"

    $archiveFilePath = Invoke-AssetDownload $bestMatch.Name $bestMatch.Url
    if (-not $archiveFilePath) {
        Write-Host "[错误] 所有线路均下载失败, 请检查网络/代理后重试。" -ForegroundColor Red
        return $false
    }
    Write-Host ""

    # ---------- 5. 部署 (先自检后安装, 缺陷构建自动回退) ----------
    Write-Banner "5. 部署 Python"
    Write-Host "将安装: $($bestMatch.Name)"

    # 安装目录: 默认 D:\Python\python<tag> (如 python3.12), 支持多版本共存, 可自定义
    $pyTagInput = $inputVer
    if ($inputVer -match '^([0-9]+\.[0-9]+)') { $pyTagInput = $Matches[1] }

    $sel = Get-InstallDestDir $pyTagInput
    if ($null -eq $sel) { return $false }
    if ($sel.Skip) {
        Write-Host "已保留现有安装, 跳过部署。压缩包保留在: $archiveFilePath" -ForegroundColor Yellow
        return $true
    }
    $destDir = $sel.Dir

    # 候选构建队列: 最优匹配在前, 最多尝试 3 个构建 (应对个别构建自检不通过)
    $deployQueue = @($bestMatch) + @($candidates | Where-Object { $_.Name -ne $bestMatch.Name } | Select-Object -First 2)

    $installedName = $null
    foreach ($cand in $deployQueue) {
        if ($cand.Name -ne $bestMatch.Name) {
            Write-Host ""
            Write-Host "自动回退, 尝试次新构建: $($cand.Name)" -ForegroundColor Cyan
            if (Test-Path $archiveFilePath) { Remove-Item $archiveFilePath -Force -ErrorAction SilentlyContinue }
            $archiveFilePath = Invoke-AssetDownload $cand.Name $cand.Url
            if (-not $archiveFilePath) {
                Write-Host "[警告] 回退构建获取失败, 尝试下一个..." -ForegroundColor Yellow
                continue
            }
        }
        if (Invoke-DeployPipeline $archiveFilePath $destDir) { $installedName = $cand.Name; break }
    }

    if (-not $installedName) {
        Write-Host "[错误] 所有候选构建均部署失败 (下载失败或自检未通过), 请稍后重试。" -ForegroundColor Red
        return $false
    }
    if ($installedName -ne $bestMatch.Name) {
        Write-Host "[提示] 最新构建 $($bestMatch.Name) 未通过自检, 已自动回退安装: $($installedName)" -ForegroundColor Yellow
    }
    Write-Host ""
    return $true
}

# ============== 部署共用: 安装目录交互 + 部署管线 (本地 / 在线统一使用) ===============

# 询问安装目录 (默认 D:\Python\python<tag>; 已存在时 O/K/N 交互)。
# 返回 @{ Dir = 安装目录; Skip = 是否保留现有跳过部署 }; 输入流结束 (EOF) 返回 $null
function Get-InstallDestDir([string]$pyTagInput) {
    $tagCompact  = $pyTagInput -replace '\.', ''     # 3.12 -> 312
    $defaultDest = Join-Path $ExtractParentDir "python$pyTagInput"
    # 备选目录: 本工具默认 + 官方 Python 安装器惯例路径 (All Users / 当前用户)
    $allUsersNote = "(官方惯例, All Users)"
    if (-not (Test-IsAdmin)) { $allUsersNote = "(官方惯例, All Users - 需管理员权限)" }
    $options = @(
        @{ Dir = $defaultDest;                                Note = "(本工具默认)" },
        @{ Dir = Join-Path $AllUsersRoot "Python$tagCompact"; Note = $allUsersNote },
        @{ Dir = Join-Path $UserRoot "Python$tagCompact";     Note = "(官方惯例, 当前用户)" }
    )
    while ($true) {
        Write-Host ""
        Write-Host "请选择安装目录 [直接回车 = 1]:" -ForegroundColor White
        for ($i = 0; $i -lt $options.Count; $i++) {
            Write-Host ("  [{0}] {1}  {2}" -f ($i + 1), $options[$i].Dir, $options[$i].Note) -ForegroundColor DarkGray
        }
        Write-Host "  或直接输入自定义路径" -ForegroundColor DarkGray
        $dirInput = Read-Input "请输入编号或路径"
        if ($null -eq $dirInput) { return $null }
        if ([string]::IsNullOrWhiteSpace($dirInput)) {
            $destDir = $defaultDest
        } elseif ($dirInput -match '^[0-9]+$' -and [int]$dirInput -ge 1 -and [int]$dirInput -le $options.Count) {
            $destDir = $options[[int]$dirInput - 1].Dir
        } elseif ([System.IO.Path]::IsPathRooted($dirInput)) {
            $destDir = $dirInput.TrimEnd("\")
        } else {
            $destDir = (Join-Path $ExtractParentDir $dirInput).TrimEnd("\")
        }
        # 目录合法性检查 (排除非法字符, 盘符冒号除外)
        $checkPart = $destDir -replace '^[A-Za-z]:', ''
        if ($checkPart.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0 -or $checkPart -match '[<>:"|?*]') {
            Write-Host "目录路径含非法字符: [$destDir], 请重新输入。" -ForegroundColor Red
            continue
        }

        if (Test-Path $destDir) {
            Write-Host ""
            Write-Host "目标目录已存在: $destDir" -ForegroundColor Yellow
            Write-Host "  [O] 覆盖安装 (清理后全新安装, pip 已装的第三方包不保留) [默认]"
            Write-Host "  [K] 保留现有安装, 跳过部署"
            Write-Host "  [N] 更换安装目录"
            $act = Read-Input "请选择"
            if ($null -eq $act) { return $null }
            if ([string]::IsNullOrWhiteSpace($act)) { $act = "O" }
            $act = $act.Substring(0, 1).ToUpper()
            if ($act -eq "K") { return @{ Dir = $destDir; Skip = $true } }
            if ($act -eq "N") { continue }   # 重新输入目录
            # O -> 清理后覆盖安装
        }
        return @{ Dir = $destDir; Skip = $false }
    }
}

# 部署管线 (本地 / 在线统一使用): 解压自检 -> 整体替换 -> pip 脚本 -> 注册表/PATH -> 完成汇总。
# 返回 $true = 部署成功; $false = 解压/自检失败 (已清理现场, 调用方可换下一个包重试)
function Invoke-DeployPipeline([string]$archiveFilePath, [string]$destDir) {
    # 解压到临时目录 (不直接覆盖旧目录, 自检通过后再整体替换)
    $tempExtract = Join-Path $ExtractParentDir (".py_deploy_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null
    Write-Host "正在解压并自检构建 ..."

    try {
        if (Test-Path $TarExe) {
            # Windows 10/11 自带 tar.exe, 可直接解压 .tar.gz
            & $TarExe -xzf "$archiveFilePath" -C "$tempExtract"
            if ($LASTEXITCODE -ne 0) { throw "tar.exe 解压失败, 退出码 $LASTEXITCODE。" }
        } elseif (Test-Path $SevenZipExe) {
            & $SevenZipExe x "$archiveFilePath" "-o$tempExtract" -y | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "7-Zip 第一阶段 (.gz) 解压失败, 退出码 $LASTEXITCODE。" }
            $tarFile = Get-ChildItem -Path $tempExtract -Filter "*.tar" | Select-Object -First 1
            if (-not $tarFile) { throw "压缩包内未找到 .tar 文件。" }
            & $SevenZipExe x "$($tarFile.FullName)" "-o$tempExtract" -aoa | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "7-Zip 第二阶段 (.tar) 解压失败, 退出码 $LASTEXITCODE。" }
        } else {
            throw "未找到 tar.exe 和 7-Zip ($SevenZipExe), 无法解压。"
        }

        $tmpPyExe = Join-Path $tempExtract "python\python.exe"
        if (-not (Test-Path $tmpPyExe)) { throw "解压后未找到 python.exe。" }

        # 构建自检: 标准库 glob/pathlib 必须可导入, 且 sitecustomize 无报错
        # (20261110 构建曾在 pip 依赖的 pathlib -> glob 链路上存在缺陷)
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $healthOut  = (& $tmpPyExe -c "import glob, pathlib; print('HEALTH_OK')" 2>&1 | Out-String)
            $healthCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }

        if ($healthCode -ne 0 -or $healthOut -notmatch 'HEALTH_OK' -or $healthOut -match 'Error in sitecustomize' -or $healthOut -match 'ImportError') {
            throw "构建自检未通过 (标准库导入异常), 该构建可能存在缺陷。"
        }
        Write-Host "构建自检通过!" -ForegroundColor Green
    } catch {
        Write-Host "[警告] $($_.Exception.Message)" -ForegroundColor Yellow
        Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        # 压缩包解压/自检失败: 删除本地文件 (可能是损坏的缓存包), 避免下次继续复用坏包
        if (Test-Path $archiveFilePath) { Remove-Item $archiveFilePath -Force -ErrorAction SilentlyContinue }
        return $false
    }

    # 自检通过: 停止占用旧目录的进程 -> 整体替换
    $targetPythonExe = Join-Path $destDir "python.exe"
    Get-Process -Name "python", "pythonw" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $targetPythonExe } |
        ForEach-Object {
            Write-Host "正在停止占用该目录的 Python 进程 (PID: $($_.Id))..." -ForegroundColor Yellow
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }

    if (Test-Path $destDir) {
        Write-Host "正在清理旧安装 (覆盖模式) ..."
        Remove-Item -Path $destDir -Recurse -Force
    } else {
        Write-Host "正在安装 ..."
    }
    Move-Item -Path (Join-Path $tempExtract "python") -Destination $destDir
    Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "部署完成: $destDir\" -ForegroundColor Green
    Write-Host ""

    # 检测已安装的 Python 版本 (供注册表导入与汇总展示使用)
    $pyFullVer = ""
    try {
        $pyFullVer = (& $targetPythonExe -c "import sys; print('.'.join(map(str, sys.version_info[:3])))").Trim()
    } catch {}
    if ([string]::IsNullOrWhiteSpace($pyFullVer)) {
        try { $pyFullVer = (& $targetPythonExe --version) -replace '^Python\s+', '' } catch { $pyFullVer = "" }
    }
    $pyTag = ""
    if ($pyFullVer -match '^([0-9]+\.[0-9]+)') { $pyTag = $Matches[1] }

    # ---------- 6. 创建 Scripts\pip 启动脚本 ----------
    Write-Banner "6. 正在创建 Scripts\pip 启动脚本 ..."

    $scriptsDir = Join-Path $destDir "Scripts"
    if (-not (Test-Path $scriptsDir)) {
        New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
    }

    # pip.bat: 通用入口; pip3.<minor>.bat (如 pip3.13.bat): 多版本共存时精确指定本版本的 pip (不受 PATH 顺序影响)
    $pipBatContent = "@echo off`r`n`"%~dp0..\python.exe`" -m pip %*`r`n"
    $batNames = @("pip.bat")
    if ($pyTag) { $batNames += "pip$pyTag.bat" }
    $batFailed = $false
    foreach ($n in $batNames) {
        $batPath = Join-Path $scriptsDir $n
        Set-Content -Path $batPath -Value $pipBatContent -Encoding Ascii
        if (Test-Path $batPath) {
            Write-Host "创建成功: $batPath" -ForegroundColor Green
        } else {
            Write-Host "[错误] $n 创建失败!" -ForegroundColor Red
            $batFailed = $true
        }
    }
    if ($batFailed) { return $true }
    Write-Host ""

    # ---------- 7. 注册表信息与 PATH 环境变量 ----------
    Write-Banner "7. 注册表信息与 PATH 环境变量"

    $IsAdmin = Test-IsAdmin
    if ($IsAdmin) {
        Write-Host "当前权限: 管理员 -> 将写入系统级注册表 (HKLM/HKCR) 与系统 PATH" -ForegroundColor Cyan
    } else {
        Write-Host "当前权限: 普通用户 -> 将写入当前用户注册表 (HKCU, PEP 514 标准) 与用户 PATH" -ForegroundColor Cyan
    }

    $doRegister = Read-YesNo "是否自动导入注册表信息 (含 .py 文件关联) 并加入 PATH"

    if ($doRegister -eq "N") {
        Write-Host "已跳过注册表与 PATH 导入。" -ForegroundColor Yellow
    } elseif ([string]::IsNullOrWhiteSpace($pyTag)) {
        Write-Host "[警告] 无法获取 Python 版本号, 已跳过注册表与 PATH 导入。" -ForegroundColor Yellow
    } else {

        # ---- 7.1 写入 PythonCore 注册表 (PEP 514, 供 py 启动器/VS Code 等识别) ----
        # 仅写入有实际消费者的字段; 不写 PythonPath / Idle / InstalledFeatures 等无消费者的遗留项
        $regRoot = if ($IsAdmin) { "HKLM:\SOFTWARE\Python\PythonCore" } else { "HKCU:\Software\Python\PythonCore" }
        $tagKey  = "$regRoot\$pyTag"
        if (Test-Path $tagKey) { Remove-Item -Path $tagKey -Recurse -Force }   # 清理旧注册, 防止残留

        New-Item -Path $tagKey -Force | Out-Null
        Set-ItemProperty -Path $tagKey -Name "DisplayName"     -Value "Python $pyTag (64-bit)"
        Set-ItemProperty -Path $tagKey -Name "SupportUrl"      -Value "https://www.python.org/"
        Set-ItemProperty -Path $tagKey -Name "Version"         -Value $pyFullVer
        Set-ItemProperty -Path $tagKey -Name "SysVersion"      -Value $pyTag
        Set-ItemProperty -Path $tagKey -Name "SysArchitecture" -Value "64bit"

        $installPathKey = "$tagKey\InstallPath"
        New-Item -Path $installPathKey -Force | Out-Null
        Set-Item -Path $installPathKey -Value "$destDir\"
        Set-ItemProperty -Path $installPathKey -Name "ExecutablePath" -Value $targetPythonExe
        $pythonwExe = Join-Path $destDir "pythonw.exe"
        if (Test-Path $pythonwExe) {
            Set-ItemProperty -Path $installPathKey -Name "WindowedExecutablePath" -Value $pythonwExe
        }
        Write-Host "[成功] PythonCore 注册表已写入: $tagKey (版本 $pyFullVer)" -ForegroundColor Green

        # ---- 7.2 文件关联 (.py / .pyw / .pyc) ----
        $classRoot = if ($IsAdmin) { "Registry::HKEY_CLASSES_ROOT" } else { "HKCU:\Software\Classes" }
        $pyIco     = Join-Path $destDir "DLLs\py.ico"
        $pycIco    = Join-Path $destDir "DLLs\pyc.ico"

        # .py -> Python.File
        New-Item -Path "$classRoot\.py" -Force | Out-Null
        Set-Item -Path "$classRoot\.py" -Value "Python.File"
        Set-ItemProperty -Path "$classRoot\.py" -Name "Content Type" -Value "text/plain"

        if (Test-Path "$classRoot\Python.File") { Remove-Item -Path "$classRoot\Python.File" -Recurse -Force }
        New-Item -Path "$classRoot\Python.File" -Force | Out-Null
        Set-Item -Path "$classRoot\Python.File" -Value "Python File"
        if (Test-Path $pyIco) {
            New-Item -Path "$classRoot\Python.File\DefaultIcon" -Force | Out-Null
            Set-Item -Path "$classRoot\Python.File\DefaultIcon" -Value $pyIco
        }
        New-Item -Path "$classRoot\Python.File\shell\open\command" -Force | Out-Null
        Set-Item -Path "$classRoot\Python.File\shell\open\command" -Value "`"$targetPythonExe`" `"%1`" %*"
        New-Item -Path "$classRoot\Python.File\shellex\DropHandler" -Force | Out-Null
        Set-Item -Path "$classRoot\Python.File\shellex\DropHandler" -Value "{60254CA5-953B-11CF-8C96-00AA00B8708C}"

        # .pyc -> Python.CompiledFile
        New-Item -Path "$classRoot\.pyc" -Force | Out-Null
        Set-Item -Path "$classRoot\.pyc" -Value "Python.CompiledFile"
        if (Test-Path "$classRoot\Python.CompiledFile") { Remove-Item -Path "$classRoot\Python.CompiledFile" -Recurse -Force }
        New-Item -Path "$classRoot\Python.CompiledFile" -Force | Out-Null
        Set-Item -Path "$classRoot\Python.CompiledFile" -Value "Compiled Python File"
        if (Test-Path $pycIco) {
            New-Item -Path "$classRoot\Python.CompiledFile\DefaultIcon" -Force | Out-Null
            Set-Item -Path "$classRoot\Python.CompiledFile\DefaultIcon" -Value $pycIco
        }
        New-Item -Path "$classRoot\Python.CompiledFile\shell\open\command" -Force | Out-Null
        Set-Item -Path "$classRoot\Python.CompiledFile\shell\open\command" -Value "`"$targetPythonExe`" `"%1`" %*"
        New-Item -Path "$classRoot\Python.CompiledFile\shellex\DropHandler" -Force | Out-Null
        Set-Item -Path "$classRoot\Python.CompiledFile\shellex\DropHandler" -Value "{60254CA5-953B-11CF-8C96-00AA00B8708C}"

        # .pyw -> Python.NoConFile
        New-Item -Path "$classRoot\.pyw" -Force | Out-Null
        Set-Item -Path "$classRoot\.pyw" -Value "Python.NoConFile"
        Set-ItemProperty -Path "$classRoot\.pyw" -Name "Content Type" -Value "text/plain"
        if (Test-Path "$classRoot\Python.NoConFile") { Remove-Item -Path "$classRoot\Python.NoConFile" -Recurse -Force }
        New-Item -Path "$classRoot\Python.NoConFile" -Force | Out-Null
        Set-Item -Path "$classRoot\Python.NoConFile" -Value "Python File (no console)"
        if (Test-Path $pyIco) {
            New-Item -Path "$classRoot\Python.NoConFile\DefaultIcon" -Force | Out-Null
            Set-Item -Path "$classRoot\Python.NoConFile\DefaultIcon" -Value $pyIco
        }
        New-Item -Path "$classRoot\Python.NoConFile\shell\open\command" -Force | Out-Null
        Set-Item -Path "$classRoot\Python.NoConFile\shell\open\command" -Value "`"$pythonwExe`" `"%1`" %*"
        New-Item -Path "$classRoot\Python.NoConFile\shellex\DropHandler" -Force | Out-Null
        Set-Item -Path "$classRoot\Python.NoConFile\shellex\DropHandler" -Value "{60254CA5-953B-11CF-8C96-00AA00B8708C}"

        Write-Host "[成功] .py / .pyc / .pyw 文件关联已写入 ($classRoot)" -ForegroundColor Green

        # ---- 7.3 加入 PATH 环境变量 (去重后置前, 参考 @Python_Env 脚本逻辑) ----
        $envTarget = if ($IsAdmin) { [EnvironmentVariableTarget]::Machine } else { [EnvironmentVariableTarget]::User }
        $rawPath   = [Environment]::GetEnvironmentVariable("Path", $envTarget)
        if (-not $rawPath) { $rawPath = "" }
        $entries    = @($rawPath -split ";" | Where-Object { $_ -ne "" })
        $normalized = @($entries | ForEach-Object { $_.TrimEnd("\").ToLower() })
        $toAdd      = @()
        if ($normalized -notcontains $destDir.ToLower()) { $toAdd += $destDir }
        if ($normalized -notcontains $scriptsDir.ToLower())    { $toAdd += $scriptsDir }

        if ($toAdd.Count -gt 0) {
            $newPath = (@($toAdd) + @($entries)) -join ";"
            [Environment]::SetEnvironmentVariable("Path", $newPath, $envTarget)
            Write-Host "[成功] 已将以下路径写入 PATH ($envTarget): $($toAdd -join '; ')" -ForegroundColor Green
        } else {
            Write-Host "[跳过] PATH 中已存在该 Python 路径, 无需重复添加。" -ForegroundColor Yellow
        }

        Invoke-EnvBroadcast
    }
    Write-Host ""

    # ---------- 完成 ----------
    Write-Banner "部署完成!" "Green"
    Write-Host "Python 版本 : $pyFullVer"
    Write-Host "构建包      : $(Split-Path $archiveFilePath -Leaf)"
    Write-Host "Python 目录 : $destDir\"
    Write-Host "pip 脚本    : $scriptsDir\pip*.bat"
    Write-Host "压缩包位置  : $archiveFilePath"
    Write-Host ""
    if ($doRegister -eq "Y") {
        Write-Host "已自动导入注册表信息并配置 PATH, 新开终端即可在任意位置使用 python / pip。" -ForegroundColor DarkCyan
    } else {
        Write-Host "小提示: 可将以下目录加入 PATH 环境变量, 即可在任意位置使用 python 和 pip:" -ForegroundColor DarkCyan
        Write-Host "  $destDir" -ForegroundColor DarkCyan
        Write-Host "  $scriptsDir" -ForegroundColor DarkCyan
    }
    Write-Host ""
    Read-Input "按回车键返回主菜单" | Out-Null
    return $true
}

# ============ 离线包扫描 (统一部署流程使用) ============

# 扫描脚本目录中的离线压缩包 (任何 *-x86_64-pc-windows-msvc-install_only.tar.gz),
# 从文件名宽松提取版本号与构建日期; 同一版本多个构建日期仅保留最新的
function Get-OfflineArchives {
    $found = @()
    foreach ($f in @(Get-ChildItem -Path $PSScriptRoot -Filter "*x86_64-pc-windows-msvc-install_only.tar.gz" -File -ErrorAction SilentlyContinue)) {
        $name = $f.Name
        $pyVer = $null
        if ($name -match '(?:^|[+\-_])v?([0-9]+\.[0-9]+\.[0-9]+)(?:[+\-_]|$)') { $pyVer = [version]$Matches[1] }
        if (-not $pyVer) { continue }   # 文件名中无法识别版本号的包不参与匹配
        $dateStr = ""
        if ($name -match '(?:^|[+\-_])([0-9]{8})(?:[+\-_]|$)') { $dateStr = $Matches[1] }
        $buildDate   = [int64]0
        $dateDisplay = "未知日期"
        if ($dateStr) {
            $buildDate   = [int64]($dateStr + "000000")
            $dateDisplay = "$($dateStr.Substring(0,4))-$($dateStr.Substring(4,2))-$($dateStr.Substring(6,2))"
        }
        $found += [PSCustomObject]@{
            Name      = $name
            Path      = $f.FullName
            PyVer     = $pyVer
            BuildDate = $buildDate
            DateStr   = $dateDisplay
        }
    }
    # 同一版本多个构建日期: 仅保留最新的一个
    $dedup = @()
    foreach ($a in @($found | Sort-Object PyVer, BuildDate -Descending)) {
        $dup = $false
        foreach ($b in $dedup) { if ($b.PyVer -eq $a.PyVer) { $dup = $true; break } }
        if (-not $dup) { $dedup += $a }
    }
    # 注意: 不用 ",$dedup" 包裹 —— 调用处已用 @(Get-OfflineArchives) 收集,
    # 逗号包裹会让 @() 再套一层导致嵌套数组 (元素全变成 System.Object[])
    return $dedup
}

# ============ 本地离线包部署 (统一部署流程的本地分支) ============

# 本地离线包部署: 选目录 -> 按候选队列逐个部署 (自检失败自动回退次新包)。
# 返回 $true = 部署成功 (或保留现有安装); $false = 未完成部署
function Invoke-LocalDeploy([object]$best, [object[]]$queue, [string]$pyTagInput) {
    Write-Host ""
    Write-Host "匹配成功!" -ForegroundColor Green
    Write-Host "将优先使用: $($best.Name) (构建日期 $($best.DateStr))"
    if ($queue.Count -gt 1) {
        Write-Host "另有 $($queue.Count - 1) 个次新包, 自检失败时自动回退。" -ForegroundColor DarkCyan
    }
    Write-Host ""

    $sel = Get-InstallDestDir $pyTagInput
    if ($null -eq $sel) { return $false }
    if ($sel.Skip) {
        Write-Host "已保留现有安装, 跳过部署。压缩包保留在: $($best.Path)" -ForegroundColor Yellow
        return $true
    }

    $installedName = $null
    foreach ($cand in $queue) {
        if ($cand.Name -ne $best.Name) {
            Write-Host ""
            Write-Host "自动回退, 尝试次新离线包: $($cand.Name)" -ForegroundColor Cyan
        }
        if (Invoke-DeployPipeline $cand.Path $sel.Dir) { $installedName = $cand.Name; break }
    }

    if (-not $installedName) {
        Write-Host "[错误] 所有离线压缩包均部署失败 (自检未通过), 请检查压缩包完整性。" -ForegroundColor Red
        return $false
    }
    if ($installedName -ne $best.Name) {
        Write-Host "[提示] 最新离线包 $($best.Name) 未通过自检, 已自动回退安装: $($installedName)" -ForegroundColor Yellow
    }
    Write-Host ""
    return $true
}

# 功能 1: 统一部署 —— 本地离线包 + 在线下载 融合入口
# 输入语义:
#   编号 (如 1)            -> 强制使用对应离线包
#   精确版本 (如 3.12.16)  -> 本地优先, 本地无则在线查找同一版本
#   大版本 (如 3.12)       -> 在线优先获取最新构建 (本地缓存命中免下载), 失败降级本地
#   o [版本] (如 o 3.13)   -> 强制在线 (忽略本地包); 裸 o 等价 o 3.12
#   直接回车               -> 等价输入大版本 $DefaultVersion
function Invoke-DeployFlow {
    Write-Banner "部署 Python (离线包优先, 支持在线)"
    Write-Host "本功能将:"
    Write-Host "  - 自动扫描脚本目录内所有 *-x86_64-pc-windows-msvc-install_only.tar.gz 离线包并罗列"
    Write-Host "  - 同一版本存在多个构建日期时, 仅显示最新的一个"
    Write-Host "  - 按输入自动选择 本地离线包 或 在线下载, 后续部署流程完全一致"
    Write-Host ""

    $archives = @(Get-OfflineArchives)
    if ($archives.Count -eq 0) {
        # 无本地包: 直接进入在线模式 (本地无可降级对象, 无需二次确认)
        Write-Host "[提示] 脚本目录未发现任何离线压缩包, 将直接进入在线模式。" -ForegroundColor Yellow
        Write-Host "  (在线下载的压缩包会保留在脚本目录, 下次即可作为离线包复用)" -ForegroundColor Yellow
        Write-Host ""
        Invoke-InstallFlow
        return
    }

    # 罗列本地可选包 (已按版本降序, 同版本多日期仅保留最新)
    Write-Host "发现 $($archives.Count) 个可用的离线压缩包:" -ForegroundColor White
    for ($i = 0; $i -lt $archives.Count; $i++) {
        $a = $archives[$i]
        Write-Host ("  [{0}] {1}  ({2}, 约 {3} MB)" -f ($i + 1), $a.Name, $a.DateStr, [math]::Round((Get-Item $a.Path).Length / 1MB, 1))
    }
    Write-Host ""
    Write-Host "输入说明:" -ForegroundColor White
    Write-Host "  - 编号 (如 1)           -> 使用对应离线包部署 (强制本地)"
    Write-Host "  - 完整版本 (如 3.12.16) -> 优先使用本地同版本包, 本地没有则在线查找"
    Write-Host "  - 大版本 (如 3.12)      -> 在线获取该系列最新构建 (本地命中缓存则免下载), 失败自动降级本地"
    Write-Host "  - o [版本] (如 o 3.13)  -> 强制在线 (忽略本地包)"
    Write-Host "  - 直接回车              -> 等价输入 $DefaultVersion"
    Write-Host ""

    $pick = Read-Input "请输入编号 / 版本号 / o [版本] (直接回车 = $DefaultVersion)"
    if ($null -eq $pick) {
        Write-Host "输入已结束, 返回主菜单。" -ForegroundColor Yellow
        return
    }
    if ([string]::IsNullOrWhiteSpace($pick)) { $pick = $DefaultVersion }

    # ---- 输入 1: 编号 -> 强制本地指定包 ----
    if ($pick -match '^[0-9]+$') {
        $idx = 0
        if (-not [int]::TryParse($pick, [ref]$idx)) {
            Write-Host "编号无效: [$pick]" -ForegroundColor Red
            return
        }
        if ($idx -lt 1 -or $idx -gt $archives.Count) {
            Write-Host "编号超出范围: [$pick], 请输入 1-$($archives.Count)。" -ForegroundColor Red
            return
        }
        $best       = $archives[$idx - 1]
        $pyTagInput = "$($best.PyVer.Major).$($best.PyVer.Minor)"
        # 回退候选: 同 小版本 的其他离线包 (降序, 最多 2 个)
        $queue = @($best) + @($archives |
            Where-Object { $_.Name -ne $best.Name -and $_.PyVer.ToString().StartsWith("$pyTagInput.") } |
            Select-Object -First 2)
        if ((Invoke-LocalDeploy $best $queue $pyTagInput) -eq $false) {
            # 坏包已被部署管线删除; 转在线可从 GitHub 获取更多历史构建, 绕过缺陷构建
            if ((Read-YesNo "是否转在线方式重新下载安装 $pyTagInput (需要网络)" "Y") -eq "Y") {
                Write-Host ""
                Invoke-InstallFlow $pyTagInput
            }
        }
        return
    }

    # ---- 输入 2: o [版本] -> 强制在线 ----
    if ($pick -match '^(?i:o)(\s+([0-9]+\.[0-9]+(\.[0-9]+)?))?\s*$') {
        $oVer = $Matches[2]
        if ([string]::IsNullOrEmpty($oVer)) {
            Invoke-InstallFlow $DefaultVersion        # 裸 o -> 强制在线, 默认大版本
        } else {
            Invoke-InstallFlow $oVer                  # o 3.13 / o 3.13.18
        }
        return
    }

    # ---- 输入 3: 版本号 ----
    if ($pick -notmatch '^[0-9]+\.[0-9]+(\.[0-9]+)?$') {
        Write-Host "无效输入: [$pick] (应为编号 / 版本号 / o [版本])。" -ForegroundColor Red
        return
    }
    $pyTagInput = $pick
    if ($pick -match '^([0-9]+\.[0-9]+)') { $pyTagInput = $Matches[1] }
    $isMajor = ($pick -match '^[0-9]+\.[0-9]+$')

    if (-not $isMajor) {
        # ---- 精确版本 (如 3.12.16): 本地优先, 本地无则在线查找同一版本 ----
        $matched = @($archives | Where-Object { $_.PyVer -eq [version]$pick })
        if ($matched.Count -gt 0) {
            $best  = $matched[0]   # $archives 已按 版本/日期 降序, 匹配结果天然有序
            $queue = @($matched | Select-Object -First 3)
            if ((Invoke-LocalDeploy $best $queue $pyTagInput) -eq $false) {
                if ((Read-YesNo "是否转在线方式重新下载安装 $pyTagInput (需要网络)" "Y") -eq "Y") {
                    Write-Host ""
                    Invoke-InstallFlow $pyTagInput
                }
            }
        } else {
            Write-Host "[提示] 本地没有精确版本 [$pick] 的离线包, 转在线查找。" -ForegroundColor Yellow
            Write-Host ""
            Invoke-InstallFlow $pick
        }
        return
    }

    # ---- 大版本 (如 3.12): 在线优先 (最新构建, 本地缓存命中则免下载), 失败降级本地 ----
    Write-Host ""
    Write-Host "大版本 [$pick]: 优先在线获取该系列最新构建 (本地已有相同压缩包时免下载)..." -ForegroundColor Cyan
    Write-Host ""
    if (Invoke-InstallFlow $pick) { return }

    Write-Host ""
    Write-Host "在线部署未完成, 自动降级: 尝试本地离线包 [$pick.x] ..." -ForegroundColor Yellow
    $matched = @($archives | Where-Object { $_.PyVer.ToString().StartsWith("$pick.") })
    if ($matched.Count -eq 0) {
        Write-Host "[错误] 本地也没有匹配 [$pick] 的离线压缩包。" -ForegroundColor Red
        $avail = @()
        foreach ($a in $archives) { if ($avail -notcontains $a.PyVer.ToString()) { $avail += $a.PyVer.ToString() } }
        Write-Host "  当前可用的离线包版本: $($avail -join ', ')" -ForegroundColor Yellow
        return
    }
    $best  = $matched[0]
    $queue = @($matched | Select-Object -First 3)
    Invoke-LocalDeploy $best $queue $pyTagInput | Out-Null
    # 注: 此分支在线已失败过, 不再重复提示转在线
}

# ============== 清理/卸载共用: 识别与执行 ==============

# 生成清理/卸载计划: 识别注册表键、文件关联、PATH 条目 (双通道: 注册表驱动 + 孤儿)
function Get-CleanupPlan([string]$inputVer) {
    # 强制数组化: 函数匹配到单个对象时返回值不是数组, 其 .Count 为 $null 会误判为空
    $matched = @(Get-MatchedRegistrations $inputVer)   # 可能为空 (此时仍会继续扫描孤儿 PATH 条目)
    $removableAssoc = @()
    $pathRemovals   = @()

    # ---- 共享目录保护: 被其他未清理版本引用的安装目录, 其文件关联与 PATH 均不动 ----
    $matchedKeys = @($matched | ForEach-Object { $_.KeyPath })
    $allRegs     = Get-RegisteredPythons
    $otherPaths  = @($allRegs |
        Where-Object { $_.InstallPath -and ($matchedKeys -notcontains $_.KeyPath) } |
        ForEach-Object { $_.InstallPath } | Select-Object -Unique)
    $matchedPaths  = @($matched | Where-Object { $_.InstallPath } | ForEach-Object { $_.InstallPath } | Select-Object -Unique)
    $sharedOverlap = @($otherPaths | Where-Object { $matchedPaths -icontains $_ })

    # ---- 关联重定向目标: Python.File 等类键是全局共享的 (后装版本覆盖), 清理/卸载时
    #      若直接删除会使剩余版本丢失 .py 关联, 应重定向到剩余版本中版本号最高者
    #      (仅考虑安装目录仍有效的版本, 避免把关联重定向到已被删除的 exe) ----
    $redirectTarget = $null
    $otherRegs = @($allRegs | Where-Object {
        $_.InstallPath -and ($matchedKeys -notcontains $_.KeyPath) -and
        (Test-Path (Join-Path $_.InstallPath "python.exe"))
    })
    if ($otherRegs.Count -gt 0) {
        $redirectTarget = $otherRegs | Sort-Object -Property @{ Expression = {
            $v = [version]"0.0"
            [void][version]::TryParse($_.Tag, [ref]$v)
            $v
        } } -Descending | Select-Object -First 1
    }

    # ---- 文件关联检查: 仅列出 open 命令指向该版本安装目录的关联 ----
    foreach ($m in $matched) {
        if (-not $m.InstallPath) { continue }
        if ($sharedOverlap -icontains $m.InstallPath) {
            Write-Host "跳过 [$($m.Hive)] $($m.Tag) 的文件关联清理: 其安装目录 $($m.InstallPath) 同时被其他版本引用。" -ForegroundColor DarkYellow
            continue
        }
        foreach ($hive in @("Registry::HKEY_CLASSES_ROOT", "HKCU:\Software\Classes")) {
            $pairs = @(
                @{ Ext = ".py";  Cls = "Python.File" },
                @{ Ext = ".pyc"; Cls = "Python.CompiledFile" },
                @{ Ext = ".pyw"; Cls = "Python.NoConFile" }
            )
            foreach ($pair in $pairs) {
                $cmdKey = "$($hive)\$($pair.Cls)\shell\open\command"
                if (-not (Test-Path $cmdKey)) { continue }
                $cmd = [string]((Get-Item -Path $cmdKey).GetValue(""))
                if ($cmd -and $cmd.ToLower().Contains($m.InstallPath.ToLower())) {
                    $removableAssoc += [PSCustomObject]@{ Hive = $hive; Ext = $pair.Ext; Cls = $pair.Cls }
                }
            }
        }
    }

    # ---- PATH 条目识别 (双通道) ----
    #   1) 注册表驱动: 条目位于本次清理版本的安装目录段内 (目录本身 / Scripts / 任意子目录)
    #   2) 孤儿条目:   路径含版本号模式但已无任何注册表引用
    #                  (覆盖"有 PATH 没注册表"场景: 换目录安装留下的旧路径、手动删注册残留等)
    $maj = ''; $min = ''
    if ($inputVer -match '^([0-9]+)\.([0-9]+)') { $maj = $Matches[1]; $min = $Matches[2] }
    # 匹配 python3.12 / python_3_12 / python-3-12 / Python312 等命名; 前后非数字, 避免误匹配 13.12 / 3.121
    $verPattern = "(?<![0-9])$maj[._\-]?$min(?![0-9])"

    foreach ($target in @([EnvironmentVariableTarget]::Machine, [EnvironmentVariableTarget]::User)) {
        $raw = [Environment]::GetEnvironmentVariable("Path", $target)
        if (-not $raw) { continue }
        $toRemove    = @()
        $marked      = @()   # 已标记条目 (TrimEnd 后)
        $orphanRoots = @()   # 实测版本命中的孤儿根目录 (其 Scripts 等子条目需跟随标记)
        foreach ($e in @($raw -split ";")) {
            if (-not $e) { continue }
            $en = $e.TrimEnd("\")
            $source = $null

            # 通道 1: 注册表驱动 (被其他版本共享的条目自动跳过)
            foreach ($m in $matched) {
                if (-not $m.InstallPath) { continue }
                if (Test-PathUnder $en $m.InstallPath) {
                    $shared = $false
                    foreach ($op in $otherPaths) {
                        if (Test-PathUnder $en $op) { $shared = $true; break }
                    }
                    if (-not $shared) { $source = "注册表关联" }
                    break
                }
            }

            # 通道 2: 孤儿条目 —— 无任何注册表引用, 且满足其一:
            #   a) 路径含版本号模式 (python3.12 / Python312 / python_3_12 等命名)
            #   b) 条目下 python.exe 实测版本与清理版本吻合 (路径无版本号特征的旧目录)
            if (-not $source) {
                $hit    = ($en -match $verPattern)
                $verHit = $null
                if (-not $hit) {
                    $pyExe = Join-Path $en "python.exe"
                    if (Test-Path $pyExe) {
                        $prevEap = $ErrorActionPreference
                        $ErrorActionPreference = 'Continue'
                        try { $vout = (& $pyExe -V 2>$null) } catch { $vout = $null }
                        $ErrorActionPreference = $prevEap
                        if ($LASTEXITCODE -eq 0 -and $vout) {
                            $vreal = (($vout | Out-String) -replace '^Python\s+', '').Trim()
                            if ($vreal -match ("^" + [regex]::Escape($inputVer))) { $hit = $true; $verHit = $vreal }
                        }
                    }
                }
                if ($hit) {
                    $underAnyReg = $false
                    foreach ($r in @($allRegs | Where-Object { $_.InstallPath })) {
                        if (Test-PathUnder $en $r.InstallPath) { $underAnyReg = $true; break }
                    }
                    if (-not $underAnyReg) {
                        if ($verHit) { $source = "孤儿: 实测版本 $verHit"; $orphanRoots += $en }
                        else         { $source = "孤儿: 无注册表引用" }
                    }
                }
            }

            if ($source) {
                $toRemove += [PSCustomObject]@{ Entry = $e; Source = $source }
                $marked   += $en
            }
        }

        # 跟随标记: 孤儿根目录 (实测版本命中) 的 Scripts 等其他子条目一并清理
        if ($orphanRoots.Count -gt 0) {
            foreach ($e in @($raw -split ";")) {
                if (-not $e) { continue }
                $en = $e.TrimEnd("\")
                if ($marked -icontains $en) { continue }
                foreach ($orr in $orphanRoots) {
                    if (Test-PathUnder $en $orr) {
                        $toRemove += [PSCustomObject]@{ Entry = $e; Source = "孤儿: 隶属实测版本目录" }
                        $marked   += $en
                        break
                    }
                }
            }
        }

        if ($toRemove.Count -gt 0) {
            $pathRemovals += [PSCustomObject]@{ Target = $target; Items = $toRemove }
        }
    }

    # ---- 残缺注册 (缺 InstallPath): 只删注册表键本身 ----
    $broken = @($matched | Where-Object { -not $_.InstallPath })

    return @{
        Matched        = $matched
        RemovableAssoc = $removableAssoc
        PathRemovals   = $pathRemovals
        Broken         = $broken
        SharedOverlap  = $sharedOverlap
        RedirectTarget = $redirectTarget
        AllRegs        = $allRegs
    }
}

# 展示清理/卸载计划; 返回 $true 表示存在可处理内容
function Show-CleanupPlan($plan, [string]$inputVer) {
    if ($plan.Matched.Count -eq 0 -and $plan.RemovableAssoc.Count -eq 0 -and $plan.PathRemovals.Count -eq 0) {
        Write-Host "未找到与 [$inputVer] 相关的注册表键 / 文件关联 / PATH 条目, 无需处理。" -ForegroundColor Yellow
        return $false
    }

    Write-Host ""
    if ($plan.Matched.Count -gt 0) {
        Write-Host "以下注册表键将被删除:" -ForegroundColor Yellow
        foreach ($m in $plan.Matched) {
            Write-Host "  [$($m.Hive)] $($m.Tag)  版本 $($m.Version)  $($m.KeyPath)"
        }
    } else {
        Write-Host "注册表中无 [$inputVer] 的注册键 (可能已删除或从未注册), 仅清理下方识别到的 PATH 残留。" -ForegroundColor DarkYellow
    }

    if ($plan.RemovableAssoc.Count -gt 0) {
        if ($null -ne $plan.RedirectTarget) {
            Write-Host "以下文件关联指向该版本, 将重定向到剩余最新版本 $($plan.RedirectTarget.Tag) (无剩余版本时才删除):" -ForegroundColor Yellow
        } else {
            Write-Host "以下文件关联指向该版本, 将一并删除:" -ForegroundColor Yellow
        }
        foreach ($a in $plan.RemovableAssoc) {
            Write-Host "  [$($a.Hive)] $($a.Ext) -> $($a.Cls)"
        }
    }

    if ($plan.PathRemovals.Count -gt 0) {
        Write-Host "以下 PATH 条目将被移除:" -ForegroundColor Yellow
        foreach ($pr in $plan.PathRemovals) {
            foreach ($it in $pr.Items) {
                Write-Host "  [$($pr.Target)] [$($it.Source)] $($it.Entry)"
            }
        }
    }

    if ($plan.Broken.Count -gt 0) {
        Write-Host "注意: 以下注册缺少 InstallPath (残留残键), 仅删除注册表键本身:" -ForegroundColor DarkYellow
        foreach ($b in $plan.Broken) { Write-Host "  [$($b.Hive)] $($b.Tag)" }
    }

    if ($plan.SharedOverlap.Count -gt 0) {
        Write-Host "注意: 以下安装目录同时被其他未清理的版本引用, 其文件关联与 PATH 条目将保留:" -ForegroundColor DarkYellow
        foreach ($s in $plan.SharedOverlap) { Write-Host "  $s" -ForegroundColor DarkYellow }
    }
    return $true
}

# 执行清理: 删除注册表键 / 文件关联 / PATH 条目 (PATH 变更时广播); 返回统计
function Invoke-CleanupExecution($plan) {
    $stat = @{ RegKeys = 0; Assoc = 0; PathEntries = 0 }

    # ---- 执行: 删除注册表键 ----
    foreach ($m in $plan.Matched) {
        try {
            Remove-Item -Path $m.KeyPath -Recurse -Force -ErrorAction Stop
            Write-Host "[成功] 已删除注册表键: [$($m.Hive)] $($m.Tag)" -ForegroundColor Green
            $stat.RegKeys++
        } catch {
            Write-Host "[失败] 删除 [$($m.Hive)] $($m.Tag): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # ---- 执行: 文件关联 (存在剩余版本时重定向 open command, 无剩余版本才删除) ----
    foreach ($a in $plan.RemovableAssoc) {
        $redir = $plan.RedirectTarget
        if ($null -ne $redir) {
            $exeName = "python.exe"
            if ($a.Cls -eq "Python.NoConFile") { $exeName = "pythonw.exe" }
            $newExe = Join-Path $redir.InstallPath $exeName
            if (Test-Path $newExe) {
                try {
                    # 类键 open command 重定向 (格式与部署管线写入一致)
                    $cmdKey = "$($a.Hive)\$($a.Cls)\shell\open\command"
                    New-Item -Path $cmdKey -Force | Out-Null
                    Set-Item -Path $cmdKey -Value "`"$newExe`" `"%1`" %*"
                    # DefaultIcon 同步重定向 (原图标在被删目录时失效)
                    $icoName = "py.ico"
                    if ($a.Cls -eq "Python.CompiledFile") { $icoName = "pyc.ico" }
                    $newIco = Join-Path $redir.InstallPath "DLLs\$icoName"
                    if (Test-Path $newIco) {
                        $iconKey = "$($a.Hive)\$($a.Cls)\DefaultIcon"
                        New-Item -Path $iconKey -Force | Out-Null
                        Set-Item -Path $iconKey -Value $newIco
                    }
                    # 扩展键 (.py 等) 必须存在且指向类名
                    $extKey = "$($a.Hive)\$($a.Ext)"
                    if (-not (Test-Path $extKey) -or ([string]((Get-Item -Path $extKey).GetValue(""))) -ne $a.Cls) {
                        New-Item -Path $extKey -Force | Out-Null
                        Set-Item -Path $extKey -Value $a.Cls
                    }
                    Write-Host "[成功] 文件关联已重定向到剩余版本 $($redir.Tag): [$($a.Hive)] $($a.Cls)" -ForegroundColor Green
                    $stat.Assoc++
                    continue
                } catch {
                    Write-Host "[失败] 重定向 $($a.Cls) ($($a.Hive)): $($_.Exception.Message), 转为删除。" -ForegroundColor Red
                }
            }
        }
        try {
            Remove-Item -Path "$($a.Hive)\$($a.Cls)" -Recurse -Force -ErrorAction Stop
            Write-Host "[成功] 已删除文件关联类: [$($a.Hive)] $($a.Cls)" -ForegroundColor Green
            $stat.Assoc++
        } catch {
            Write-Host "[失败] 删除 $($a.Cls) ($($a.Hive)): $($_.Exception.Message)" -ForegroundColor Red
            continue
        }
        $extKey = "$($a.Hive)\$($a.Ext)"
        try {
            if (Test-Path $extKey) {
                $extCls = [string]((Get-Item -Path $extKey).GetValue(""))
                if ($extCls -eq $a.Cls) {
                    Remove-Item -Path $extKey -Recurse -Force -ErrorAction Stop
                    Write-Host "[成功] 已删除扩展名关联: [$($a.Hive)] $($a.Ext)" -ForegroundColor Green
                }
            }
        } catch {
            Write-Host "[失败] 删除 $($a.Ext) ($($a.Hive)): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # ---- 执行: 清理 PATH ----
    $pathChanged = $false
    foreach ($pr in $plan.PathRemovals) {
        $raw     = [Environment]::GetEnvironmentVariable("Path", $pr.Target)
        $removal = @($pr.Items | ForEach-Object { $_.Entry.TrimEnd("\") })
        $keep    = @(@($raw -split ";") | Where-Object {
            if (-not $_) { return $false }
            -not ($removal -icontains $_.TrimEnd("\"))
        })
        try {
            [Environment]::SetEnvironmentVariable("Path", ($keep -join ";"), $pr.Target)
            Write-Host "[成功] 已从 PATH ($($pr.Target)) 移除 $($pr.Items.Count) 个条目" -ForegroundColor Green
            $stat.PathEntries += $pr.Items.Count
            $pathChanged = $true
        } catch {
            Write-Host "[失败] 修改 PATH ($($pr.Target)) 失败 (可能权限不足): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    if ($pathChanged) { Invoke-EnvBroadcast }
    return $stat
}

# ======================= 功能 3: 清理 / 卸载指定版本 =======================

# 清理与卸载合并入口: 罗列两种模式供选择, 共用识别与执行引擎
function Invoke-CleanOrUninstallFlow {
    Write-Banner "清理 / 卸载指定版本的 Python"
    Write-Host "两种模式:"
    Write-Host "  [1] 仅清理 - 删除注册表键 / .py 等文件关联 / PATH 条目 (不删除文件)"
    Write-Host "      同时识别孤儿条目: 路径含该版本号但已无注册表引用的残留"
    Write-Host "  [2] 卸载   - 在清理的基础上同时删除安装目录 (所有文件, 不可恢复!)"
    Write-Host ""

    Show-RegisteredPythons
    Write-Host ""

    $inputVer = Read-Input "请输入要处理的版本 (如 3.12 或 3.12.16, 直接回车取消)"
    if ($null -eq $inputVer -or [string]::IsNullOrWhiteSpace($inputVer)) {
        Write-Host "已取消。" -ForegroundColor Yellow
        return
    }
    if ($inputVer -notmatch '^[0-9]+\.[0-9]+(\.[0-9]+)?$') {
        Write-Host "版本号格式无效: [$inputVer]" -ForegroundColor Red
        return
    }

    $mode = Read-Input "请选择模式 [1=仅清理 / 2=卸载, 默认 1]"
    if ($null -eq $mode) {
        Write-Host "已取消。" -ForegroundColor Yellow
        return
    }
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = "1" }
    $mode = $mode.Substring(0, 1).ToUpper()
    if ($mode -ne "1" -and $mode -ne "2") {
        Write-Host "无效模式: [$mode], 请输入 1 或 2。" -ForegroundColor Red
        return
    }

    $plan = Get-CleanupPlan $inputVer
    if (-not (Show-CleanupPlan $plan $inputVer)) { return }

    $dirs     = @($plan.Matched | Where-Object { $_.InstallPath } | ForEach-Object { $_.InstallPath } | Select-Object -Unique)
    # 共享目录保护同样适用于文件删除: 被其他未清理版本引用的目录绝不删除 (否则会连带删掉别的版本)
    $existing = @($dirs | Where-Object { (Test-Path $_) -and ($plan.SharedOverlap -inotcontains $_) })
    $sharedDirs = @($dirs | Where-Object { (Test-Path $_) -and ($plan.SharedOverlap -icontains $_) })
    $removedFiles = 0

    if ($mode -eq "2") {
        # ---- 卸载: 文件删除清单 + 高危确认 (输入版本号, 防止误删) ----
        if ($existing.Count -gt 0) {
            Write-Host ""
            Write-Host "以下安装目录将被整个删除 (不可恢复):" -ForegroundColor Red
            foreach ($d in $existing) {
                $sizeMB = 0
                try {
                    $sum = (Get-ChildItem -Path $d -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                    if ($sum) { $sizeMB = [math]::Round($sum / 1MB, 1) }
                } catch {}
                Write-Host ("  {0}  (约 {1} MB)" -f $d, $sizeMB) -ForegroundColor Red
            }
            Write-Host "[警告] 目录中的所有文件 (含 pip 已装的第三方包) 将一并删除!" -ForegroundColor Red
        } else {
            Write-Host ""
            Write-Host "[提示] 未发现该版本独占的安装目录 (可能已被手动删除, 或被其他版本共用), 将只清理注册表 / PATH / 关联。" -ForegroundColor DarkYellow
        }
        if ($sharedDirs.Count -gt 0) {
            Write-Host "以下安装目录被其他版本共用, 文件将保留 (仅清理注册表 / PATH / 关联):" -ForegroundColor DarkYellow
            foreach ($d in $sharedDirs) { Write-Host "  $d" -ForegroundColor DarkYellow }
        }
        Write-Host ""
        $confirmVer = Read-Input "确认卸载请完整输入版本号 ($inputVer), 直接回车或输入其他内容取消"
        if ($null -eq $confirmVer -or $confirmVer -ne $inputVer) {
            Write-Host "已取消, 未做任何更改。" -ForegroundColor Yellow
            return
        }
    } else {
        # ---- 仅清理: 普通确认 ----
        Write-Host ""
        $confirm = Read-YesNo "确认执行清理" "N"
        if ($confirm -ne "Y") {
            Write-Host "已取消, 未做任何更改。" -ForegroundColor Yellow
            return
        }
    }

    if ($mode -eq "2") {
        # ---- 停止占用该目录的 Python 进程 -> 删除安装目录 ----
        foreach ($d in $existing) {
            Get-Process -Name "python", "pythonw" -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -and ($_.Path.TrimEnd("\") -ieq $d.TrimEnd("\")) } |
                ForEach-Object {
                    Write-Host "正在停止占用该目录的 Python 进程 (PID: $($_.Id))..." -ForegroundColor Yellow
                    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                }
        }
        foreach ($d in $existing) {
            try {
                Remove-Item -Path $d -Recurse -Force -ErrorAction Stop
                Write-Host "[成功] 已删除安装目录: $d" -ForegroundColor Green
                $removedFiles++
            } catch {
                Write-Host "[失败] 删除安装目录 $d : $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # ---- 注册表 / 关联 / PATH (两种模式共用) ----
    $stat = Invoke-CleanupExecution $plan

    # ---- 汇总 ----
    Write-Host ""
    if ($mode -eq "2") {
        Write-Host "卸载完成: 安装目录 $($removedFiles)/$($existing.Count), 注册表键 $($stat.RegKeys), 文件关联 $($stat.Assoc), PATH 条目 $($stat.PathEntries)。" -ForegroundColor Green
    } else {
        foreach ($d in $dirs) {
            if (Test-Path $d) {
                Write-Host "[提示] 安装目录仍存在 (未删除, 可重新运行本功能选择模式 2 卸载): $d" -ForegroundColor DarkYellow
            }
        }
        Write-Host "清理完成。" -ForegroundColor Green
    }
    Write-Host ""
    Read-Input "按回车键返回主菜单" | Out-Null
}

# ======================= 功能 4: 查看已注册版本 =======================

# 切换主用版本: 目标版本的 PATH 条目在 Machine/User 两层中置前, .py/.pyc/.pyw 关联改指向该版本
function Invoke-SwitchDefaultVersion($r) {
    $destDir = $r.InstallPath.TrimEnd("\")
    $pyExe   = Join-Path $destDir "python.exe"
    $pywExe  = Join-Path $destDir "pythonw.exe"
    if (-not (Test-Path $pyExe)) {
        Write-Host "[错误] 该版本的 python.exe 不存在: $pyExe, 无法切换。" -ForegroundColor Red
        return
    }

    # ---- 1. PATH: 目标版本的条目在两层 PATH 中分别移到最前 (保持 主目录 -> Scripts 顺序) ----
    $changed = $false
    foreach ($target in @([EnvironmentVariableTarget]::Machine, [EnvironmentVariableTarget]::User)) {
        $raw = [Environment]::GetEnvironmentVariable("Path", $target)
        if (-not $raw) { continue }
        $entries = @($raw -split ";" | Where-Object { $_ -ne "" })
        $mine    = @($entries | Where-Object { Test-PathUnder $_ $destDir })
        if ($mine.Count -eq 0) { continue }
        $others  = @($entries | Where-Object { -not (Test-PathUnder $_ $destDir) })
        $ordered = @($mine | Sort-Object -Property @{ Expression = { if ($_ -ieq $destDir) { 0 } else { 1 } } })
        $newPath = (@($ordered) + @($others)) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, $target)
        Write-Host "[成功] PATH ($target) 已置前: $($mine -join '; ')" -ForegroundColor Green
        $changed = $true
    }
    if (-not $changed) {
        Write-Host "[提示] PATH 中未发现该版本的条目 (重新部署该版本可写入 PATH)。" -ForegroundColor DarkYellow
    }

    # ---- 2. 文件关联: .py/.pyc/.pyw 的打开方式指向该版本 ----
    # 关联可能存在于两个层级: 系统级 (HKCR, 需管理员) 与 用户级 (HKCU\Software\Classes, 优先级更高)。
    # 管理员两层都写保证一致; 普通用户仅能写用户级。
    $hives = @()
    if ($IsAdmin) {
        $hives += "Registry::HKEY_CLASSES_ROOT"
    } else {
        Write-Host "[提示] 当前为普通用户权限, 仅修改用户级关联 (HKCU); 系统级关联需以管理员运行。" -ForegroundColor DarkYellow
    }
    $hives += "HKCU:\Software\Classes"
    $pairs = @(
        @{ Ext = ".py";  Cls = "Python.File";         Exe = $pyExe;  Ico = "py.ico" },
        @{ Ext = ".pyc"; Cls = "Python.CompiledFile"; Exe = $pyExe;  Ico = "pyc.ico" },
        @{ Ext = ".pyw"; Cls = "Python.NoConFile";    Exe = $pywExe; Ico = "py.ico" }
    )
    foreach ($cr in $hives) {
        foreach ($p in $pairs) {
            if (-not (Test-Path $p.Exe)) { continue }   # pythonw.exe 缺失时跳过对应关联
            try {
                $cmdKey = "$cr\$($p.Cls)\shell\open\command"
                New-Item -Path $cmdKey -Force | Out-Null
                Set-Item -Path $cmdKey -Value "`"$($p.Exe)`" `"%1`" %*"
                $extKey = "$cr\$($p.Ext)"
                if (-not (Test-Path $extKey) -or ([string]((Get-Item -Path $extKey).GetValue(""))) -ne $p.Cls) {
                    New-Item -Path $extKey -Force | Out-Null
                    Set-Item -Path $extKey -Value $p.Cls
                }
                $ico = Join-Path $destDir "DLLs\$($p.Ico)"
                if (Test-Path $ico) {
                    $iconKey = "$cr\$($p.Cls)\DefaultIcon"
                    New-Item -Path $iconKey -Force | Out-Null
                    Set-Item -Path $iconKey -Value $ico
                }
            } catch {
                Write-Host "[失败] 写入关联 $($p.Ext) ($cr): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        Write-Host "[成功] .py / .pyc / .pyw 打开方式已指向 $($r.Tag) ($cr)" -ForegroundColor Green
    }

    Invoke-EnvBroadcast
}

function Invoke-ShowFlow {
    Write-Banner "查看本机已注册的 Python 版本"
    Show-RegisteredPythons

    # ---- 切换主用版本 (仅列出安装目录仍有效的版本) ----
    $usable = @()
    foreach ($r in (Get-RegisteredPythons)) {
        if ($r.InstallPath -and (Test-Path (Join-Path $r.InstallPath "python.exe"))) { $usable += $r }
    }
    if ($usable.Count -ge 2) {
        Write-Host ""
        Write-Host "可切换为主用的版本 (调整 PATH 顺序 + .py 打开方式):" -ForegroundColor White
        for ($i = 0; $i -lt $usable.Count; $i++) {
            Write-Host ("  [{0}] {1,-8} {2}" -f ($i + 1), $usable[$i].Tag, $usable[$i].InstallPath)
        }
        $pick = Read-Input "输入编号将对应版本设为主用 (直接回车跳过)"
        if ($null -eq $pick) { return }   # EOF
        if (-not [string]::IsNullOrWhiteSpace($pick)) {
            $idx = 0
            if ([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $usable.Count) {
                $sel = $usable[$idx - 1]
                Write-Host ""
                Write-Host ("将把 {0} ({1}) 设为主用版本:" -f $sel.Tag, $sel.InstallPath)
                Write-Host "  - PATH 中该版本的条目移动到最前 (python 目录与 Scripts)"
                Write-Host "  - .py / .pyc / .pyw 文件关联改为指向该版本"
                if ((Read-YesNo "确认切换" "Y") -eq "Y") {
                    Write-Host ""
                    Invoke-SwitchDefaultVersion $sel
                } else {
                    Write-Host "已取消。" -ForegroundColor Yellow
                }
            } else {
                Write-Host "无效编号: [$pick], 已跳过切换。" -ForegroundColor Red
            }
        }
    } elseif ($usable.Count -eq 1) {
        Write-Host ""
        Write-Host "[提示] 当前仅有一个可用版本 ($($usable[0].Tag)), 无需切换主用。" -ForegroundColor DarkGray
    }

    Write-Host ""
    Read-Input "按回车键返回主菜单" | Out-Null
}

# ======================= 主菜单 =======================

function Show-MainMenu {
    # 回到主菜单时清屏 (ISE 等无真实控制台环境下静默跳过)
    try { Clear-Host } catch { }
    Write-Host ""
    Write-Host "  ======================================================" -ForegroundColor Cyan
    Write-Host "    PyVersions  " -ForegroundColor Cyan -NoNewline
    Write-Host "v1.6.0" -ForegroundColor Yellow
    Write-Host "    Python 独立版 (install_only) 管理工具" -ForegroundColor DarkGray
    Write-Host "  ======================================================" -ForegroundColor Cyan
    Write-Host "  当前权限: " -NoNewline
    if (Test-IsAdmin) {
        Write-Host "管理员" -ForegroundColor Green -NoNewline
        Write-Host " (写入系统级注册表 / 系统 PATH)" -ForegroundColor DarkGray
    } else {
        Write-Host "普通用户" -ForegroundColor Yellow -NoNewline
        Write-Host " (写入当前用户注册表 / 用户 PATH)" -ForegroundColor DarkGray
    }
    Write-Host ""
    $items = @(
        @{ Key = "1"; Title = "部署 Python";                   Desc = "(本地离线包 + 在线下载, 自动选择)" },
        @{ Key = "2"; Title = "清理 / 卸载指定版本";           Desc = "(注册表 / PATH / 文件)" },
        @{ Key = "3"; Title = "查看本机已注册的 Python 版本";  Desc = "(可切换主用版本)" },
        @{ Key = "0"; Title = "退出";                          Desc = "" }
    )
    # 标题列统一宽度: 以最长标题的显示宽度为基准, 说明列从同一位置起
    $titleWidth = 0
    foreach ($it in $items) {
        $w = Get-DisplayWidth $it.Title
        if ($w -gt $titleWidth) { $titleWidth = $w }
    }
    foreach ($it in $items) {
        Write-Host "  [" -NoNewline
        Write-Host $it.Key -ForegroundColor Yellow -NoNewline
        Write-Host "] " -NoNewline
        Write-Host $it.Title -ForegroundColor White -NoNewline
        if ($it.Desc) {
            $pad = $titleWidth - (Get-DisplayWidth $it.Title)
            if ($pad -lt 2) { $pad = 2 }
            Write-Host (" " * $pad) -NoNewline
            Write-Host $it.Desc -ForegroundColor DarkGray
        } else {
            Write-Host ""
        }
    }
    Write-Host ""
}

while ($true) {
    Show-MainMenu
    $choice = Read-Input "请输入选项编号"
    if ($null -eq $choice) { break }   # 输入流结束 (EOF), 退出
    if ([string]::IsNullOrWhiteSpace($choice)) { continue }
    if ($choice -eq "0") {
        Write-Host "再见!" -ForegroundColor Cyan
        break
    }
    switch ($choice) {
        "1" { Invoke-DeployFlow }
        "2" { Invoke-CleanOrUninstallFlow }
        "3" { Invoke-ShowFlow }
        default { Write-Host "无效选项: [$choice], 请输入 0-3。" -ForegroundColor Red }
    }
}
