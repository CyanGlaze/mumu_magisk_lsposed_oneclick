[CmdletBinding()]
param(
    [string]$AdbPath = "adb",
    [string]$MagiskApk = "",
    [string]$NeoZygiskZip = "",
    [string]$VectorZip = "",
    [switch]$NoReboot,
    [switch]$AutoReboot,
    [int]$BootTimeoutSeconds = 480,
    [switch]$ReplaceManager,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkRoot = Join-Path $ScriptRoot "work"
$DownloadRoot = Join-Path $WorkRoot "downloads"
$ExtractRoot = Join-Path $WorkRoot "magisk_apk"
$StageRoot = Join-Path $WorkRoot "stage"
$LogRoot = Join-Path $ScriptRoot "logs"
$BackupRoot = Join-Path $ScriptRoot "backups"
$ConfigRoot = Join-Path $ScriptRoot "config"
$DeviceConfigPath = Join-Path $ConfigRoot "last-device.txt"
$ToolVersion = "1.0"
$Device = ""
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$HostLog = Join-Path $LogRoot "install-$Stamp.log"

New-Item -ItemType Directory -Force -Path $WorkRoot, $DownloadRoot, $LogRoot, $BackupRoot, $ConfigRoot | Out-Null

function Write-Step {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -LiteralPath $HostLog -Value $line -Encoding UTF8
}

function Fail {
    param([string]$Message)
    throw $Message
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $cmd = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        Fail "找不到 adb。请把 platform-tools 加入 PATH，或通过 -AdbPath 指定 adb.exe。"
    }
    return $cmd.Source
}

$script:Adb = Resolve-Adb

# Windows PowerShell 5.1 会把原生程序写入 stderr 的普通信息转换成
# NativeCommandError；在 ErrorActionPreference=Stop 时，adb push 的传输进度
# 也会让脚本提前终止。这里直接使用 .NET Process 分别读取 stdout/stderr，
# 只按 adb 的真实退出码判断成败。
function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { $Value = "" }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0

    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $slashes++
            continue
        }

        if ($ch -eq '"') {
            if ($slashes -gt 0) {
                [void]$builder.Append(('\' * ($slashes * 2)))
            }
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }

        if ($slashes -gt 0) {
            [void]$builder.Append(('\' * $slashes))
            $slashes = 0
        }
        [void]$builder.Append($ch)
    }

    # 结尾反斜杠位于双引号前时需要翻倍。
    if ($slashes -gt 0) {
        [void]$builder.Append(('\' * ($slashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()

    # 异步读取两条流，避免任一缓冲区写满造成死锁。
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $code = $process.ExitCode
    $process.Dispose()

    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { $parts += $stdout.TrimEnd() }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { $parts += $stderr.TrimEnd() }
    $text = $parts -join "`n"

    return [PSCustomObject]@{
        Code = $code
        Stdout = $stdout
        Stderr = $stderr
        Output = $text
    }
}

function Invoke-AdbRaw {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFail,
        [switch]$Quiet
    )

    if (-not $Quiet) {
        Write-Step ("adb " + ($Arguments -join " "))
    }

    $result = Invoke-NativeProcess -FilePath $script:Adb -Arguments $Arguments
    $text = $result.Output
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        Add-Content -LiteralPath $HostLog -Value $text -Encoding UTF8
        if (-not $Quiet) { Write-Host $text }
    }

    if ($result.Code -ne 0 -and -not $AllowFail) {
        Fail "adb 命令失败，退出码 $($result.Code)。请查看 $HostLog"
    }

    return [PSCustomObject]@{
        Code = $result.Code
        Output = $text.Trim()
        Stdout = $result.Stdout
        Stderr = $result.Stderr
    }
}


function Normalize-DeviceAddress {
    param([string]$Value)

    $valueText = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($valueText)) { return "" }

    $hostText = $valueText
    $port = 5555
    if ($valueText -match '^(?<host>[0-9]{1,3}(?:\.[0-9]{1,3}){3}):(?<port>[0-9]{1,5})$') {
        $hostText = $Matches['host']
        $port = [int]$Matches['port']
    } elseif ($valueText -notmatch '^[0-9]{1,3}(?:\.[0-9]{1,3}){3}$') {
        return ""
    }

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($hostText, [ref]$parsed)) { return "" }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return "" }
    if ($port -lt 1 -or $port -gt 65535) { return "" }
    return ("{0}:{1}" -f $hostText, $port)
}

function Read-EditableDefault {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$DefaultValue = ""
    )

    # 在普通交互式 CMD/PowerShell 中把上次地址直接放进输入区，按回车即可确认。
    # 输入被重定向时退回 Read-Host，避免 Console.ReadKey 抛异常。
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        $suffix = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { "" } else { " [$DefaultValue]" }
        $answer = Read-Host ($Prompt + $suffix)
        if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultValue }
        return $answer
    }

    [Console]::Write($Prompt + ": ")
    $buffer = New-Object System.Text.StringBuilder
    if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
        [void]$buffer.Append($DefaultValue)
        [Console]::Write($DefaultValue)
    }

    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) {
            [Console]::WriteLine()
            return $buffer.ToString()
        }
        if ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($buffer.Length -gt 0) {
                [void]$buffer.Remove($buffer.Length - 1, 1)
                [Console]::Write("`b `b")
            }
            continue
        }
        if ($key.Key -eq [ConsoleKey]::Escape) {
            while ($buffer.Length -gt 0) {
                [void]$buffer.Remove($buffer.Length - 1, 1)
                [Console]::Write("`b `b")
            }
            continue
        }
        if (-not [char]::IsControl($key.KeyChar)) {
            [void]$buffer.Append($key.KeyChar)
            [Console]::Write($key.KeyChar)
        }
    }
}

function Select-MumuDevice {
    Write-Step "运行 adb devices"
    $devicesResult = Invoke-AdbRaw -Arguments @("devices") -AllowFail -Quiet
    if ($devicesResult.Code -ne 0) {
        Fail "adb devices 执行失败。请确认 ADB 已开启，并检查 adb.exe 是否可用。"
    }

    $networkDevices = @()
    foreach ($line in ($devicesResult.Stdout -split "`r?`n")) {
        if ($line -match '^([0-9]{1,3}(?:\.[0-9]{1,3}){3})(?::([0-9]{1,5}))?\s+(device|offline|unauthorized)$') {
            $serial = $Matches[1]
            if (-not [string]::IsNullOrWhiteSpace($Matches[2])) {
                $serial += ":" + $Matches[2]
            } else {
                $serial += ":5555"
            }
            $networkDevices += [PSCustomObject]@{
                Serial = $serial
                State = $Matches[3]
            }
        }
    }

    Write-Host ""
    Write-Host "================ 选择 Mumu 设备 ================" -ForegroundColor Cyan
    if ($networkDevices.Count -gt 0) {
        Write-Host "adb devices 当前记录的局域网设备："
        for ($i = 0; $i -lt $networkDevices.Count; $i++) {
            Write-Host ("  {0}. {1}  [{2}]" -f ($i + 1), $networkDevices[$i].Serial, $networkDevices[$i].State)
        }
    } else {
        Write-Host "adb devices 当前没有列出局域网设备。"
        Write-Host "请在 Mumu 中查看桥接网络 IP，然后在下方直接输入。"
    }
    Write-Host "可输入列表编号、IP 或 IP:端口；只输入 IP 时默认使用 5555。"

    $saved = ""
    if (Test-Path -LiteralPath $DeviceConfigPath) {
        $saved = Normalize-DeviceAddress ((Get-Content -LiteralPath $DeviceConfigPath -Raw -ErrorAction SilentlyContinue).Trim())
    }
    if ([string]::IsNullOrWhiteSpace($saved) -and $networkDevices.Count -eq 1) {
        $saved = $networkDevices[0].Serial
    }

    while ($true) {
        $inputValue = Read-EditableDefault -Prompt "Mumu 设备地址" -DefaultValue $saved
        $trimmed = ([string]$inputValue).Trim()

        if ($trimmed -match '^[0-9]+$') {
            $index = [int]$trimmed
            if ($index -ge 1 -and $index -le $networkDevices.Count) {
                $selected = $networkDevices[$index - 1].Serial
            } else {
                Write-Host "编号无效，请重新输入。" -ForegroundColor Yellow
                continue
            }
        } else {
            $selected = Normalize-DeviceAddress $trimmed
            if ([string]::IsNullOrWhiteSpace($selected)) {
                Write-Host "地址格式无效。示例：192.168.1.42 或 192.168.1.42:5555" -ForegroundColor Yellow
                continue
            }
        }

        [System.IO.File]::WriteAllText($DeviceConfigPath, $selected, (New-Object System.Text.UTF8Encoding($false)))
        Write-Step "已选择 Mumu 设备：$selected"
        return $selected
    }
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFail,
        [switch]$Quiet
    )
    $allArgs = @("-s", $Device) + $Arguments
    return Invoke-AdbRaw -Arguments $allArgs -AllowFail:$AllowFail -Quiet:$Quiet
}

function Connect-Device {
    param([int]$TimeoutSeconds = 45)

    Write-Step "连接设备 $Device"
    $connectResult = Invoke-AdbRaw -Arguments @("connect", $Device) -AllowFail -Quiet
    if ($connectResult.Code -ne 0 -and $connectResult.Output -notmatch "already connected") {
        Write-Host $connectResult.Output
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = Invoke-AdbRaw -Arguments @("-s", $Device, "get-state") -AllowFail -Quiet
        if ($state.Code -eq 0 -and $state.Output.Trim() -eq "device") { return }
        Start-Sleep -Seconds 2
        Invoke-AdbRaw -Arguments @("connect", $Device) -AllowFail -Quiet | Out-Null
    }

    Fail "无法连接 $Device。请确认 Mumu 已开启网络桥接模式和 ADB，IP 正确，并允许防火墙中的 ADB 通信。"
}

function Test-AdbdRoot {
    $id = Invoke-Adb -Arguments @("shell", "id") -AllowFail -Quiet
    return ($id.Code -eq 0 -and $id.Output -match "uid=0")
}

function Enable-AdbRoot {
    param([switch]$AllowManualRestart)

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Write-Step "请求 adbd root（第 $attempt 次）"
        Invoke-AdbRaw -Arguments @("-s", $Device, "root") -AllowFail -Quiet | Out-Null
        Start-Sleep -Seconds 3
        Connect-Device
        if (Test-AdbdRoot) {
            Write-Step "adbd root 已生效"
            return
        }
    }

    if (-not $AllowManualRestart) {
        Fail "adbd 没有获得 root。请确认：设备设置 -> 开发者选项 -> Root 权限 已开启，然后在 Mumu 中手动点击“重启设备”。"
    }

    Write-Host ""
    Write-Host "================ 需要手动重启 Mumu ================" -ForegroundColor Yellow
    Write-Host "ADB root 当前没有生效。请确认 Root 权限已开启。" -ForegroundColor Yellow
    Write-Host "请现在切换到当前设备窗口并执行："
    Write-Host "  1. 点击重启设备。"
    Write-Host "  2. 点击重启后回到此窗口输入 RESTART；脚本会继续等待设备完成启动。"
    $beforeBootId = Get-DeviceBootId
    $answer = Read-Host "已重启设备？输入 RESTART"
    if ($answer -ne "RESTART") {
        Fail "未确认手动重启，安装已停止。"
    }
    Wait-ForRestartCompletion -PreviousBootId $beforeBootId -TimeoutSeconds $BootTimeoutSeconds

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Step "重启后再次请求 adbd root（第 $attempt 次）"
        Invoke-AdbRaw -Arguments @("-s", $Device, "root") -AllowFail -Quiet | Out-Null
        Start-Sleep -Seconds 4
        Connect-Device
        if (Test-AdbdRoot) {
            Write-Step "重启后 adbd root 已生效"
            return
        }
    }

    Fail "重启后 adbd 仍未获得 root。请再次检查：设备设置 -> 开发者选项 -> Root 权限，并确认重启的是当前 Android 15 实例。"
}

function Get-GitHubReleaseAsset {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][scriptblock]$Selector,
        [Parameter(Mandatory = $true)][string]$OutputName
    )
    $headers = @{
        "User-Agent" = "Mumu-Magisk-LSPosed-OneClick/1.0"
        "Accept" = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    Write-Step "查询 $Repository 最新稳定版"
    $release = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri "https://api.github.com/repos/$Repository/releases/latest"
    $assets = @($release.assets | Where-Object $Selector)
    if ($assets.Count -eq 0) {
        Fail "在 $Repository 的最新稳定版 $($release.tag_name) 中找不到匹配的安装包。"
    }
    $asset = $assets | Select-Object -First 1
    $target = Join-Path $DownloadRoot $OutputName
    $digestProp = $asset.PSObject.Properties["digest"]
    $expected = $null
    if ($null -ne $digestProp -and -not [string]::IsNullOrWhiteSpace([string]$digestProp.Value) -and [string]$digestProp.Value -match "^sha256:(.+)$") {
        $expected = $Matches[1].ToLowerInvariant()
    }

    # 失败后重跑时复用已经下载并通过校验的文件，避免重复下载数百 MB。
    if (Test-Path -LiteralPath $target) {
        $cachedOk = $false
        if ($null -ne $expected) {
            $cachedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
            $cachedOk = ($cachedHash -eq $expected)
        } elseif ($null -ne $asset.PSObject.Properties["size"]) {
            $cachedOk = ((Get-Item -LiteralPath $target).Length -eq [int64]$asset.size)
        }
        if ($cachedOk) {
            Write-Step "复用已校验下载：$($asset.name) ($($release.tag_name))"
            return $target
        }
        Remove-Item -Force -LiteralPath $target -ErrorAction SilentlyContinue
    }

    Write-Step "下载 $($asset.name) ($($release.tag_name))"
    Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $asset.browser_download_url -OutFile $target

    if ($null -ne $expected) {
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            Remove-Item -Force -LiteralPath $target
            Fail "SHA-256 校验失败：$($asset.name)"
        }
        Write-Step "SHA-256 校验通过"
    }
    return $target
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n"), $encoding)
}

function Get-DeviceBootId {
    $result = Invoke-AdbRaw -Arguments @("-s", $Device, "shell", "cat", "/proc/sys/kernel/random/boot_id") -AllowFail -Quiet
    if ($result.Code -eq 0) { return $result.Output.Trim() }
    return ""
}

function Wait-ForRestartCompletion {
    param(
        [string]$PreviousBootId = "",
        [int]$TimeoutSeconds = 480
    )

    Write-Step "等待 Mumu 完成真正的设备重启（最长 $TimeoutSeconds 秒）"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $sawOffline = $false
    $lastNotice = Get-Date

    while ((Get-Date) -lt $deadline) {
        if ($Device -match ":") {
            Invoke-AdbRaw -Arguments @("connect", $Device) -AllowFail -Quiet | Out-Null
        }

        $state = Invoke-AdbRaw -Arguments @("-s", $Device, "get-state") -AllowFail -Quiet
        if ($state.Code -ne 0 -or $state.Output.Trim() -ne "device") {
            $sawOffline = $true
            Start-Sleep -Seconds 3
            continue
        }

        $bootId = Get-DeviceBootId
        $bootCompleted = Invoke-AdbRaw -Arguments @("-s", $Device, "shell", "getprop", "sys.boot_completed") -AllowFail -Quiet
        $bootChanged = $false
        if (-not [string]::IsNullOrWhiteSpace($PreviousBootId)) {
            $bootChanged = (-not [string]::IsNullOrWhiteSpace($bootId) -and $bootId -ne $PreviousBootId)
        } else {
            $bootChanged = $sawOffline
        }

        if ($bootChanged -and $bootCompleted.Output.Trim() -eq "1") {
            Write-Step "检测到新的 boot_id，Android 已完成重启"
            return
        }

        if (((Get-Date) - $lastNotice).TotalSeconds -ge 30) {
            Write-Step "仍在等待设备重启完成；请确认已在 Mumu 中点击“重启设备”"
            $lastNotice = Get-Date
        }
        Start-Sleep -Seconds 3
    }

    Fail "没有检测到完整的设备重启。请在 Mumu 中点击“重启设备”，等待 Android 桌面出现后重新运行脚本；若卡启动，请使用快照恢复。"
}

function Request-ManualMumuRestart {
    param(
        [string]$PreviousBootId,
        [string]$Reason = "安装后的模块需要重启才能加载"
    )

    Write-Host ""
    Write-Host "================ 请手动重启 Mumu 设备 ================" -ForegroundColor Yellow
    Write-Host $Reason -ForegroundColor Yellow
    Write-Host "请现在切换到当前设备窗口并执行："
    Write-Host "  1. 点击重启设备。"
    Write-Host "  2. 点击重启后回到此窗口输入 RESTART；脚本会继续等待设备完成启动。"
    $answer = Read-Host "已重启设备？输入 RESTART"
    if ($answer -ne "RESTART") {
        Fail "未确认手动重启。NeoZygisk 与 Vector 已安装但尚未加载；请稍后手动重启设备。"
    }
    Wait-ForRestartCompletion -PreviousBootId $PreviousBootId -TimeoutSeconds $BootTimeoutSeconds
}

Write-Step "Mumu Android 15 Magisk + LSPosed 一键安装工具 $ToolVersion"
Write-Host ""
Write-Host "================ 安装前必须确认 ================" -ForegroundColor Cyan
Write-Host "1. 当前 Mumu 实例的 Android 版本是 Android 15。"
Write-Host "2. 已开启 Root 权限：设备设置 -> 开发者选项 -> Root 权限。"
Write-Host "3. 已开启系统读写：设备设置 -> 开发者选项 -> 磁盘共享 -> 可写系统盘。"
Write-Host "4. 已开启网络桥接模式：设备设置 -> 网络 -> 网络桥接模式。"
Write-Host "5. 已开启 ADB；电脑和 Mumu 位于同一局域网。"
Write-Host "6. 已为当前实例创建快照。"
Write-Host ""
Write-Host "如果上述任意设置刚修改过，请先在 Mumu 重启当前设备。" -ForegroundColor Yellow
Write-Host "安装过程中还会要求手动重启一次。" -ForegroundColor Yellow
Write-Host ""
if (-not $Force) {
    $answer = Read-Host "确认以上 6 项均已完成？输入 YES"
    if ($answer -ne "YES") { Fail "用户取消。请完成安装前设置后再运行。" }
}

$Device = Select-MumuDevice
Connect-Device
$android = Invoke-Adb -Arguments @("shell", "getprop", "ro.build.version.release") -Quiet
if ($android.Output.Trim() -notmatch '^15(?:\.|$)') {
    Fail "检测到 Android=$($android.Output.Trim())，本脚本只适用于 Mumu Android 15 实例。请切换到 Android 15 实例后重新运行。"
}
Write-Step "Android 15 检查通过"

Enable-AdbRoot -AllowManualRestart
$abilist = Invoke-Adb -Arguments @("shell", "getprop", "ro.product.cpu.abilist") -Quiet
$selinux = Invoke-Adb -Arguments @("shell", "getenforce") -Quiet -AllowFail
Write-Step "Android=$($android.Output), ABI=$($abilist.Output), SELinux=$($selinux.Output)"

function Test-SystemWritable {
    Write-Step "检查 /system 是否可写（使用远端探测脚本，避免 Windows/adb/sh 多层引号误判）"

    $probePath = Join-Path $WorkRoot "mumu-system-rw-probe.sh"
    $probeText = @'
#!/system/bin/sh
PROBE=/system/etc/init/.mumu_magisk_rw_test
ERR=/data/local/tmp/mumu-system-rw-probe.err
rm -f "$PROBE" "$ERR"

if touch "$PROBE" 2>"$ERR"; then
    chmod 0644 "$PROBE" 2>/dev/null || true
    echo MUMU_SYSTEM_RW
    ls -lZ "$PROBE" 2>/dev/null || ls -l "$PROBE" 2>/dev/null || true
    rm -f "$PROBE" "$ERR"
    exit 0
fi

echo MUMU_SYSTEM_RW_FAILED
cat "$ERR" 2>/dev/null || true
id 2>/dev/null || true
id -Z 2>/dev/null || true
grep ' /system ' /proc/mounts 2>/dev/null || true
mount 2>/dev/null | grep -E ' on /system | /system ' || true
exit 1
'@
    Write-Utf8NoBom -Path $probePath -Content $probeText
    Invoke-Adb -Arguments @("push", $probePath, "/data/local/tmp/mumu-system-rw-probe.sh") -Quiet | Out-Null
    Invoke-Adb -Arguments @("shell", "chmod", "0755", "/data/local/tmp/mumu-system-rw-probe.sh") -Quiet | Out-Null

    # 1) 优先使用 adb root 后的直接 shell。用户手工验证成功的就是这个通道。
    $direct = Invoke-Adb -Arguments @("shell", "/data/local/tmp/mumu-system-rw-probe.sh") -AllowFail -Quiet
    if ($direct.Code -eq 0 -and $direct.Output -match "MUMU_SYSTEM_RW") {
        Write-Step "/system 写入探测成功；执行通道：adbd root"
        return "adbd"
    }

    # 2) 某些 Mumu 构建的 adbd 虽然 uid=0，但只有内置 su 域能写 system。
    $suC = Invoke-Adb -Arguments @("shell", "su", "-c", "/data/local/tmp/mumu-system-rw-probe.sh") -AllowFail -Quiet
    if ($suC.Code -eq 0 -and $suC.Output -match "MUMU_SYSTEM_RW") {
        Write-Step "/system 写入探测成功；执行通道：su -c"
        return "su-c"
    }

    # 3) 兼容采用 su 0 COMMAND 语法的 Mumu Root 实现。
    $su0 = Invoke-Adb -Arguments @("shell", "su", "0", "/data/local/tmp/mumu-system-rw-probe.sh") -AllowFail -Quiet
    if ($su0.Code -eq 0 -and $su0.Output -match "MUMU_SYSTEM_RW") {
        Write-Step "/system 写入探测成功；执行通道：su 0"
        return "su0"
    }

    Write-Host ""
    Write-Host "直接通道诊断："
    Write-Host $direct.Output
    Write-Host "su -c 通道诊断："
    Write-Host $suC.Output
    Write-Host "su 0 通道诊断："
    Write-Host $su0.Output
    Fail "/system 写入探测在 adbd root、su -c、su 0 三种通道均失败。请查看 $HostLog。"
}

$script:SystemWriteChannel = Test-SystemWritable

if ([string]::IsNullOrWhiteSpace($MagiskApk)) {
    $MagiskApk = Get-GitHubReleaseAsset -Repository "topjohnwu/Magisk" -OutputName "Magisk-latest.apk" -Selector {
        $_.name -match "^Magisk-v.+\.apk$" -and $_.name -notmatch "debug"
    }
} elseif (-not (Test-Path -LiteralPath $MagiskApk)) {
    Fail "找不到 Magisk APK：$MagiskApk"
} else {
    $MagiskApk = (Resolve-Path -LiteralPath $MagiskApk).Path
}

if ([string]::IsNullOrWhiteSpace($NeoZygiskZip)) {
    $NeoZygiskZip = Get-GitHubReleaseAsset -Repository "JingMatrix/NeoZygisk" -OutputName "NeoZygisk-latest.zip" -Selector {
        $_.name -match "\.zip$" -and $_.name -notmatch "(?i)debug|source"
    }
} elseif (-not (Test-Path -LiteralPath $NeoZygiskZip)) {
    Fail "找不到 NeoZygisk ZIP：$NeoZygiskZip"
} else {
    $NeoZygiskZip = (Resolve-Path -LiteralPath $NeoZygiskZip).Path
}

if ([string]::IsNullOrWhiteSpace($VectorZip)) {
    $VectorZip = Get-GitHubReleaseAsset -Repository "JingMatrix/Vector" -OutputName "Vector-latest.zip" -Selector {
        $_.name -match "\.zip$" -and $_.name -match "(?i)release" -and $_.name -notmatch "(?i)debug|source"
    }
} elseif (-not (Test-Path -LiteralPath $VectorZip)) {
    Fail "找不到 Vector ZIP：$VectorZip"
} else {
    $VectorZip = (Resolve-Path -LiteralPath $VectorZip).Path
}

Write-Step "读取 Magisk APK 核心文件（跳过 res，避免 Windows 大小写文件名冲突）"
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Test-ModuleArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $propEntry = $archive.Entries | Where-Object { $_.FullName -ceq "module.prop" } | Select-Object -First 1
        $customEntry = $archive.Entries | Where-Object { $_.FullName -ceq "customize.sh" } | Select-Object -First 1
        if ($null -eq $propEntry -or $propEntry.Length -le 0) {
            Fail "$DisplayName 安装包缺少根目录 module.prop。"
        }
        if ($null -eq $customEntry -or $customEntry.Length -le 0) {
            Fail "$DisplayName 安装包缺少根目录 customize.sh。"
        }

        $reader = New-Object System.IO.StreamReader($propEntry.Open())
        try {
            $propText = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
        $idMatch = [regex]::Match($propText, "(?m)^id=(.+)$")
        if (-not $idMatch.Success) {
            Fail "$DisplayName 的 module.prop 缺少 id。"
        }
        return $idMatch.Groups[1].Value.Trim()
    } finally {
        $archive.Dispose()
    }
}

$neoModuleId = Test-ModuleArchive -Path $NeoZygiskZip -DisplayName "NeoZygisk"
$vectorModuleId = Test-ModuleArchive -Path $VectorZip -DisplayName "Vector"
Write-Step "模块 ZIP 预检通过：NeoZygisk=$neoModuleId，Vector=$vectorModuleId"

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $StageRoot
New-Item -ItemType Directory -Force -Path $StageRoot | Out-Null
$ProbeRoot = Join-Path $WorkRoot "magisk_probe"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $ProbeRoot
New-Item -ItemType Directory -Force -Path $ProbeRoot | Out-Null

function Copy-ZipEntryToFile {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $inputStream = $Entry.Open()
    $outputStream = [System.IO.File]::Open(
        $Destination,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $inputStream.CopyTo($outputStream)
    } finally {
        $outputStream.Dispose()
        $inputStream.Dispose()
    }
}

$propAbis = @()
if (-not [string]::IsNullOrWhiteSpace($abilist.Output)) {
    $propAbis = $abilist.Output.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
$candidates = @($propAbis + @("x86_64", "arm64-v8a", "x86", "armeabi-v7a") | Select-Object -Unique)
$selectedAbi = $null
$zip = [System.IO.Compression.ZipFile]::OpenRead($MagiskApk)
try {
    Invoke-Adb -Arguments @("shell", "rm", "-rf", "/data/local/tmp/mumu_magisk_probe") -Quiet | Out-Null
    Invoke-Adb -Arguments @("shell", "mkdir", "-p", "/data/local/tmp/mumu_magisk_probe") -Quiet | Out-Null

    foreach ($abi in $candidates) {
        $magiskPathInApk = "lib/$abi/libmagisk.so"
        $policyPathInApk = "lib/$abi/libmagiskpolicy.so"
        $busyboxPathInApk = "lib/$abi/libbusybox.so"

        # 使用 -ceq 做大小写敏感匹配。PowerShell 默认比较不区分大小写，
        # 而 APK/ZIP 条目名区分大小写。
        $magiskEntry = $zip.Entries | Where-Object { $_.FullName -ceq $magiskPathInApk } | Select-Object -First 1
        $policyEntry = $zip.Entries | Where-Object { $_.FullName -ceq $policyPathInApk } | Select-Object -First 1
        $busyboxEntry = $zip.Entries | Where-Object { $_.FullName -ceq $busyboxPathInApk } | Select-Object -First 1
        if ($null -eq $magiskEntry -or $null -eq $policyEntry -or $null -eq $busyboxEntry) { continue }

        Write-Step "探测 Magisk 二进制 ABI：$abi"
        $probeLocal = Join-Path $ProbeRoot ("magisk-" + $abi)
        Copy-ZipEntryToFile -Entry $magiskEntry -Destination $probeLocal
        Invoke-Adb -Arguments @("push", $probeLocal, "/data/local/tmp/mumu_magisk_probe/magisk") -Quiet | Out-Null
        Invoke-Adb -Arguments @("shell", "chmod", "0755", "/data/local/tmp/mumu_magisk_probe/magisk") -Quiet | Out-Null
        $probe = Invoke-Adb -Arguments @("shell", "/data/local/tmp/mumu_magisk_probe/magisk", "-c") -AllowFail -Quiet
        if ($probe.Code -eq 0 -and $probe.Output -match "MAGISK") {
            $selectedAbi = $abi
            Write-Step "已选择 ABI：$abi；版本：$($probe.Output)"
            break
        }
    }

    if ($null -eq $selectedAbi) {
        Fail "APK 内的 Magisk 二进制都无法在当前 Mumu 实例执行。可通过 -MagiskApk 指定已验证的 Magisk 30.6 APK。"
    }

    # 不只提取三个常驻二进制。Magisk 的模块安装入口会检查
    # /data/adb/magisk/util_functions.sh 和 busybox；官方 AVD live_setup 也会
    # 安装完整的 assets/*.sh、magiskboot 与 magiskinit。缺少这些文件会直接报
    # "Incomplete Magisk install"。
    $coreEntries = @{
        "magisk" = "lib/$selectedAbi/libmagisk.so"
        "magiskpolicy" = "lib/$selectedAbi/libmagiskpolicy.so"
        "busybox" = "lib/$selectedAbi/libbusybox.so"
        "magiskboot" = "lib/$selectedAbi/libmagiskboot.so"
        "magiskinit" = "lib/$selectedAbi/libmagiskinit.so"
    }
    foreach ($name in $coreEntries.Keys) {
        $entryPath = $coreEntries[$name]
        $entry = $zip.Entries | Where-Object { $_.FullName -ceq $entryPath } | Select-Object -First 1
        if ($null -eq $entry) { Fail "Magisk APK 缺少条目：$entryPath" }
        Copy-ZipEntryToFile -Entry $entry -Destination (Join-Path $StageRoot $name)
    }

    # 64 位系统同时准备 32 位 magisk applet，行为与 Magisk 官方 live_setup 一致。
    $abi32Map = @{
        "x86_64" = "x86"
        "arm64-v8a" = "armeabi-v7a"
    }
    if ($abi32Map.ContainsKey($selectedAbi)) {
        $abi32 = $abi32Map[$selectedAbi]
        $entryPath = "lib/$abi32/libmagisk.so"
        $entry = $zip.Entries | Where-Object { $_.FullName -ceq $entryPath } | Select-Object -First 1
        if ($null -ne $entry) {
            Copy-ZipEntryToFile -Entry $entry -Destination (Join-Path $StageRoot "magisk32")
        }
    }

    # 模块安装、管理器 Shell 初始化和卸载流程依赖这些官方运行时脚本。
    $runtimeAssets = @(
        "util_functions.sh",
        "boot_patch.sh",
        "addon.d.sh",
        "app_functions.sh",
        "uninstaller.sh",
        "module_installer.sh"
    )
    foreach ($asset in $runtimeAssets) {
        $entryPath = "assets/$asset"
        $entry = $zip.Entries | Where-Object { $_.FullName -ceq $entryPath } | Select-Object -First 1
        if ($null -eq $entry) { Fail "Magisk APK 缺少运行时脚本：$entryPath" }
        Copy-ZipEntryToFile -Entry $entry -Destination (Join-Path $StageRoot $asset)
    }

    # 正式版 Magisk 通常把 stub 放在 assets/stub.apk；同时保留按文件名查找的兼容逻辑。
    $stubEntry = $zip.Entries | Where-Object { $_.FullName -ceq "assets/stub.apk" } | Select-Object -First 1
    if ($null -eq $stubEntry) {
        $stubEntry = $zip.Entries | Where-Object { $_.Name -ceq "stub.apk" } | Select-Object -First 1
    }
    if ($null -ne $stubEntry) {
        Copy-ZipEntryToFile -Entry $stubEntry -Destination (Join-Path $StageRoot "stub.apk")
    } else {
        Write-Step "警告：APK 中未找到 stub.apk；核心 root 仍可安装，但管理器自动修复能力可能受限。"
    }
} finally {
    $zip.Dispose()
}

$requiredRuntimeFiles = @(
    "magisk", "magiskpolicy", "busybox", "magiskboot", "magiskinit",
    "util_functions.sh", "boot_patch.sh", "addon.d.sh", "app_functions.sh",
    "uninstaller.sh", "module_installer.sh"
)
foreach ($required in $requiredRuntimeFiles) {
    $candidate = Join-Path $StageRoot $required
    if (-not (Test-Path -LiteralPath $candidate) -or (Get-Item -LiteralPath $candidate).Length -le 0) {
        Fail "Magisk 运行时预检失败：缺少或为空 $required"
    }
}
$utilFunctionsText = Get-Content -Raw -LiteralPath (Join-Path $StageRoot "util_functions.sh")
if ($utilFunctionsText -notmatch '(?m)^MAGISK_VER_CODE=\d+') {
    Fail "Magisk APK 中的 util_functions.sh 没有版本元数据，拒绝继续。"
}
Write-Step "Magisk 完整运行时预检通过（核心二进制、安装脚本、版本元数据）"

$rcText = @'
on post-fs
    mkdir /debug_ramdisk 0755 root root
    mount tmpfs tmpfs /debug_ramdisk mode=0755

on post-fs-data
    exec u:r:su:s0 root root -- /system/bin/sh /data/adb/magisk_init.sh
    exec u:r:su:s0 root root -- /debug_ramdisk/magisk --daemon
    exec u:r:su:s0 root root -- /debug_ramdisk/magisk --post-fs-data

on boot
    exec u:r:su:s0 root root -- /debug_ramdisk/magisk --service

on property:sys.boot_completed=1
    exec u:r:su:s0 root root -- /debug_ramdisk/magisk --boot-complete
'@

$initText = @'
#!/system/bin/sh
export MAGISKTMP=/debug_ramdisk
export PATH=$MAGISKTMP/.magisk/busybox:/sbin:/system/bin:/system_ext/bin:/system/xbin:/vendor/bin:/odm/bin
MAGISKBIN=/data/adb/magisk
LOG=/data/local/tmp/magisk_init.log

log() {
    echo "[$(date '+%F %T')] $*" >> "$LOG"
}

log "Starting Magisk initialization"
[ -x "$MAGISKBIN/magisk" ] || { log "Missing $MAGISKBIN/magisk"; exit 1; }

mkdir -p "$MAGISKTMP/.magisk/device" "$MAGISKTMP/.magisk/worker"
mkdir -p /data/adb/modules /data/adb/post-fs-data.d /data/adb/service.d
chmod 0755 "$MAGISKTMP/.magisk"
chmod 0711 "$MAGISKTMP/.magisk/device"

for file in magisk magisk32 magiskpolicy busybox; do
    [ -f "$MAGISKBIN/$file" ] || continue
    cp -af "$MAGISKBIN/$file" "$MAGISKTMP/$file" || exit 1
    chmod 0755 "$MAGISKTMP/$file"
done
if [ -f "$MAGISKBIN/stub.apk" ]; then
    cp -af "$MAGISKBIN/stub.apk" "$MAGISKTMP/stub.apk"
    chmod 0644 "$MAGISKTMP/stub.apk"
fi

ln -sf ./magisk "$MAGISKTMP/su"
ln -sf ./magisk "$MAGISKTMP/resetprop"
ln -sf ./magiskpolicy "$MAGISKTMP/supolicy"

if ! grep -q " $MAGISKTMP/.magisk/worker " /proc/mounts; then
    chmod 0000 "$MAGISKTMP/.magisk/worker"
    "$MAGISKTMP/busybox" mount -t tmpfs -o mode=0755 magisk "$MAGISKTMP/.magisk/worker" || true
fi
"$MAGISKTMP/busybox" mount --make-private "$MAGISKTMP/.magisk/worker" 2>/dev/null || true
chmod 0755 "$MAGISKTMP/.magisk/worker" 2>/dev/null || true

mkdir -p "$MAGISKTMP/.magisk/busybox"
"$MAGISKTMP/busybox" --install -s "$MAGISKTMP/.magisk/busybox"
export PATH=$MAGISKTMP/.magisk/busybox:$PATH

# 与 Magisk 官方 AVD live_setup 保持一致：config 表示运行时配置目录已就绪，
# live 标记当前属于 live/manual setup，而不是 boot image patch 安装。
touch "$MAGISKTMP/.magisk/config" "$MAGISKTMP/.magisk/live"
chmod 0644 "$MAGISKTMP/.magisk/config" "$MAGISKTMP/.magisk/live" 2>/dev/null || true

log "Preinit device: $(MAKEDEV=1 "$MAGISKTMP/magisk" --preinit-device 2>&1)"

RULESCMD=""
rule="$MAGISKTMP/.magisk/preinit/sepolicy.rule"
[ -f "$rule" ] && RULESCMD="--apply $rule"
if [ -d /sys/fs/selinux ]; then
    if [ -f /vendor/etc/selinux/precompiled_sepolicy ]; then
        "$MAGISKTMP/magiskpolicy" --load /vendor/etc/selinux/precompiled_sepolicy --live --magisk $RULESCMD >> "$LOG" 2>&1 || true
    elif [ -f /sepolicy ]; then
        "$MAGISKTMP/magiskpolicy" --load /sepolicy --live --magisk $RULESCMD >> "$LOG" 2>&1 || true
    else
        "$MAGISKTMP/magiskpolicy" --live --magisk $RULESCMD >> "$LOG" 2>&1 || true
    fi
fi

log "Magisk initialization complete"
exit 0
'@

$remoteInstallText = @'
#!/system/bin/sh
LOG=/data/local/tmp/mumu-magisk-oneclick.log
: > "$LOG"

log() {
    echo "[Mumu Installer] $*"
    echo "[$(date '+%F %T')] $*" >> "$LOG"
}

fail() {
    log "ERROR: $*"
    exit 1
}

log "Checking root"
id | grep -q 'uid=0' || fail "adbd is not root"

BACKUP=/data/local/tmp/mumu_magisk_backup
rm -rf "$BACKUP"
mkdir -p "$BACKUP"
[ -f /system/etc/init/magisk.rc ] && cp -af /system/etc/init/magisk.rc "$BACKUP/magisk.rc.old"
[ -f /data/adb/magisk_init.sh ] && cp -af /data/adb/magisk_init.sh "$BACKUP/magisk_init.sh.old"
[ -f /data/adb/magisk.db ] && cp -af /data/adb/magisk.db "$BACKUP/magisk.db.old"

mkdir -p /data/adb/magisk || fail "cannot create /data/adb/magisk"

# 安装完整 Magisk 运行时，而不是只放 magisk/magiskpolicy/busybox。
# magisk --install-module 会硬性检查 util_functions.sh；官方 live_setup 也会
# 把 assets/*.sh、magiskboot、magiskinit 一并放入 MAGISKBIN。
for file in magisk magisk32 magiskpolicy busybox magiskboot magiskinit util_functions.sh boot_patch.sh addon.d.sh app_functions.sh uninstaller.sh module_installer.sh stub.apk; do
    [ -f "/data/local/tmp/mumu_magisk_stage/$file" ] || continue
    cp -af "/data/local/tmp/mumu_magisk_stage/$file" "/data/adb/magisk/$file" || fail "copy $file"
done

for file in magisk magiskpolicy busybox magiskboot magiskinit util_functions.sh; do
    [ -s "/data/adb/magisk/$file" ] || fail "incomplete Magisk runtime: missing $file"
done
chmod 0755 /data/adb/magisk/magisk /data/adb/magisk/magiskpolicy /data/adb/magisk/busybox /data/adb/magisk/magiskboot /data/adb/magisk/magiskinit /data/adb/magisk/*.sh
[ -f /data/adb/magisk/magisk32 ] && chmod 0755 /data/adb/magisk/magisk32
[ -f /data/adb/magisk/stub.apk ] && chmod 0644 /data/adb/magisk/stub.apk

# 在产生持久化改动之前检查脚本与版本占位符，避免把半成品写入模块目录。
/data/adb/magisk/busybox sh -n /data/adb/magisk/util_functions.sh || fail "util_functions.sh syntax"
grep -q '^MAGISK_VER_CODE=' /data/adb/magisk/util_functions.sh || fail "util_functions.sh has no version metadata"

cp -af /data/local/tmp/magisk.rc /system/etc/init/magisk.rc || fail "install magisk.rc"
cp -af /data/local/tmp/magisk_init.sh /data/adb/magisk_init.sh || fail "install magisk_init.sh"
chmod 0644 /system/etc/init/magisk.rc
chmod 0755 /data/adb/magisk_init.sh
chown root:root /system/etc/init/magisk.rc /data/adb/magisk_init.sh /data/adb/magisk/* 2>/dev/null || true
restorecon /system/etc/init/magisk.rc /data/adb/magisk_init.sh /data/adb/magisk/* 2>/dev/null || true

[ -x /debug_ramdisk/magisk ] && /debug_ramdisk/magisk --stop 2>/dev/null || true
mkdir -p /debug_ramdisk
if ! grep -q ' /debug_ramdisk ' /proc/mounts; then
    mount -t tmpfs -o mode=0755 tmpfs /debug_ramdisk || fail "mount /debug_ramdisk"
fi

/system/bin/sh /data/adb/magisk_init.sh || fail "magisk_init.sh"
/debug_ramdisk/magisk --daemon || fail "start magisk daemon"
sleep 1
/debug_ramdisk/magisk --post-fs-data || fail "post-fs-data"
/debug_ramdisk/magisk --service || true
[ "$(getprop sys.boot_completed)" = "1" ] && /debug_ramdisk/magisk --boot-complete || true
/debug_ramdisk/magisk --restorecon 2>/dev/null || true

log "Magisk version: $(/debug_ramdisk/magisk -v 2>&1)"
/debug_ramdisk/su -c id || fail "MagiskSU verification"

# NeoZygisk replaces built-in Zygisk in this unsupported emulator setup.
# This installer is already running as uid 0, so call magisk directly. Avoid nested
# su -c quoting: Android mksh would parse SQL parentheses as shell syntax.
/debug_ramdisk/magisk --sqlite "INSERT OR REPLACE INTO settings SELECT 'zygisk',0;" || true

install_module_zip() {
    name="$1"
    zipfile="$2"
    [ -s "$zipfile" ] || fail "$name zip missing"

    modid=$(/data/adb/magisk/busybox unzip -p "$zipfile" module.prop 2>/dev/null | sed -n 's/^id=//p' | head -n 1 | tr -d '\015')
    [ -n "$modid" ] || fail "$name module.prop/id missing"
    log "Installing $name (id=$modid)"

    # 首选 Magisk 官方入口。若某个版本的 CLI 环境检查仍不兼容手工 live setup，
    # 直接执行同一份官方 util_functions.sh 作为等价回退，并保留完整输出。
    if ! /debug_ramdisk/magisk --install-module "$zipfile"; then
        log "$name: Magisk CLI installer failed; trying official util_functions fallback"
        OUTFD=1 ZIPFILE="$zipfile" ASH_STANDALONE=1 MAGISKTMP=/debug_ramdisk PATH=/debug_ramdisk:/data/adb/magisk:$PATH /data/adb/magisk/busybox sh -c '. /data/adb/magisk/util_functions.sh; install_module' || fail "$name install"
    fi

    if [ ! -s "/data/adb/modules_update/$modid/module.prop" ] && [ ! -s "/data/adb/modules/$modid/module.prop" ]; then
        fail "$name installer returned success but module was not staged"
    fi
    log "$name staged successfully"
}

install_module_zip "NeoZygisk" /data/local/tmp/NeoZygisk.zip
install_module_zip "Vector" /data/local/tmp/Vector.zip

log "Installation staged successfully. Reboot is required."
exit 0
'@

$rcPath = Join-Path $WorkRoot "magisk.rc"
$initPath = Join-Path $WorkRoot "magisk_init.sh"
$remoteInstallerPath = Join-Path $WorkRoot "mumu-magisk-install.sh"
Write-Utf8NoBom -Path $rcPath -Content $rcText
Write-Utf8NoBom -Path $initPath -Content $initText
Write-Utf8NoBom -Path $remoteInstallerPath -Content $remoteInstallText

Write-Step "上传 Magisk 文件和模块"
Invoke-Adb -Arguments @("shell", "rm", "-rf", "/data/local/tmp/mumu_magisk_stage") -Quiet | Out-Null
Invoke-Adb -Arguments @("shell", "mkdir", "-p", "/data/local/tmp/mumu_magisk_stage") -Quiet | Out-Null
# 上传所有已从 APK 精确提取的运行时文件，避免后续新增资产时再次漏传。
Get-ChildItem -LiteralPath $StageRoot -File | ForEach-Object {
    Invoke-Adb -Arguments @("push", $_.FullName, "/data/local/tmp/mumu_magisk_stage/$($_.Name)") -Quiet | Out-Null
}
Invoke-Adb -Arguments @("push", $rcPath, "/data/local/tmp/magisk.rc") -Quiet | Out-Null
Invoke-Adb -Arguments @("push", $initPath, "/data/local/tmp/magisk_init.sh") -Quiet | Out-Null
Invoke-Adb -Arguments @("push", $remoteInstallerPath, "/data/local/tmp/mumu-magisk-install.sh") -Quiet | Out-Null
Invoke-Adb -Arguments @("push", $NeoZygiskZip, "/data/local/tmp/NeoZygisk.zip") -Quiet | Out-Null
Invoke-Adb -Arguments @("push", $VectorZip, "/data/local/tmp/Vector.zip") -Quiet | Out-Null
Invoke-Adb -Arguments @("shell", "chmod", "0755", "/data/local/tmp/mumu-magisk-install.sh", "/data/local/tmp/magisk_init.sh", "/data/local/tmp/mumu_magisk_stage/busybox") -Quiet | Out-Null

# 先在临时目录验证官方 Magisk 模块安装运行时；此阶段尚未改写 /system 或 /data/adb。
Write-Step "在设备端预检 Magisk 完整运行时"
Invoke-Adb -Arguments @("shell", "/data/local/tmp/mumu_magisk_stage/busybox", "sh", "-n", "/data/local/tmp/mumu_magisk_stage/util_functions.sh") -Quiet | Out-Null
$runtimeVersionCheck = Invoke-Adb -Arguments @("shell", "grep", "-E", "^MAGISK_VER_CODE=[0-9]+", "/data/local/tmp/mumu_magisk_stage/util_functions.sh") -Quiet
if ($runtimeVersionCheck.Output -notmatch "MAGISK_VER_CODE=") {
    Fail "设备端运行时预检失败：util_functions.sh 缺少 MAGISK_VER_CODE。"
}

# Validate the generated Android shell scripts before making persistent changes.
# This catches quoting/syntax regressions while the operation is still reversible.
Write-Step "在设备端执行 shell 语法检查"
Invoke-Adb -Arguments @("shell", "sh", "-n", "/data/local/tmp/magisk_init.sh") -Quiet | Out-Null
Invoke-Adb -Arguments @("shell", "sh", "-n", "/data/local/tmp/mumu-magisk-install.sh") -Quiet | Out-Null

Write-Step "执行远端安装（沿用已验证的 /system 写入通道：$script:SystemWriteChannel）"
switch ($script:SystemWriteChannel) {
    "adbd" {
        $remoteRun = Invoke-Adb -Arguments @("shell", "/data/local/tmp/mumu-magisk-install.sh")
    }
    "su-c" {
        $remoteRun = Invoke-Adb -Arguments @("shell", "su", "-c", "/data/local/tmp/mumu-magisk-install.sh")
    }
    "su0" {
        $remoteRun = Invoke-Adb -Arguments @("shell", "su", "0", "/data/local/tmp/mumu-magisk-install.sh")
    }
    default {
        Fail "未知的 system 写入通道：$script:SystemWriteChannel"
    }
}

$localBackup = Join-Path $BackupRoot $Stamp
New-Item -ItemType Directory -Force -Path $localBackup | Out-Null
Invoke-Adb -Arguments @("pull", "/data/local/tmp/mumu_magisk_backup", $localBackup) -AllowFail -Quiet | Out-Null

Write-Step "安装/更新 Magisk 管理器 APK"
$apkInstall = Invoke-Adb -Arguments @("install", "-r", $MagiskApk) -AllowFail
if ($apkInstall.Code -ne 0 -and $apkInstall.Output -match "INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
    if ($ReplaceManager) {
        Write-Step "管理器签名不兼容，按 -ReplaceManager 卸载旧管理器"
        Invoke-Adb -Arguments @("uninstall", "com.topjohnwu.magisk") -AllowFail | Out-Null
        Invoke-Adb -Arguments @("install", $MagiskApk) | Out-Null
    } else {
        Write-Host "管理器 APK 签名不兼容。核心已安装；可重新运行并加 -ReplaceManager，或手动卸载旧管理器后安装。"
    }
}

if ($NoReboot) {
    Write-Step "已按 -NoReboot 跳过重启。NeoZygisk 与 Vector 必须手动重启设备后才能加载。"
    Write-Host "请稍后在 Mumu 中点击“重启设备”，"
    Write-Host "日志：$HostLog"
    exit 0
}

$beforeRebootBootId = Get-DeviceBootId
if ($AutoReboot) {
    Write-Step "按 -AutoReboot 尝试通过 ADB 重启 Mumu 实例"
    Invoke-Adb -Arguments @("reboot") -AllowFail -Quiet | Out-Null
    try {
        Wait-ForRestartCompletion -PreviousBootId $beforeRebootBootId -TimeoutSeconds $BootTimeoutSeconds
    } catch {
        Write-Host "ADB 重启未能确认完成，将改为人工重启。" -ForegroundColor Yellow
        Request-ManualMumuRestart -PreviousBootId $beforeRebootBootId -Reason "ADB 重启未成功或响应过慢，请改为在 Mumu 中手动点击“重启设备”。"
    }
} else {
    Request-ManualMumuRestart -PreviousBootId $beforeRebootBootId -Reason "Magisk、NeoZygisk 和 Vector 已写入；必须进行一次完整设备重启才能加载。"
}
Enable-AdbRoot -AllowManualRestart

Write-Step "验证 Magisk"
$magiskVersion = Invoke-Adb -Arguments @("shell", "/debug_ramdisk/magisk", "-v") -AllowFail
$suCheck = Invoke-Adb -Arguments @("shell", "/debug_ramdisk/su", "-c", "id") -AllowFail

Write-Step "验证 NeoZygisk / Vector"
$moduleCheck = Invoke-Adb -Arguments @("shell", "/debug_ramdisk/su", "-c", 'for f in /data/adb/modules/*/module.prop; do echo ====$f; cat $f; done') -AllowFail
$unloaded = Invoke-Adb -Arguments @("shell", "/debug_ramdisk/su", "-c", "find /data/adb/modules -path '*/zygisk/unloaded' -print 2>/dev/null") -AllowFail
$processes = Invoke-Adb -Arguments @("shell", "ps -A | grep -Ei 'neozygisk|zygiskd|lspd|lsposed|vector' || true") -AllowFail
$lspd = Invoke-Adb -Arguments @("shell", "/debug_ramdisk/su", "-c", "ls -la /data/adb/lspd 2>/dev/null") -AllowFail

Write-Host ""
Write-Host "================ 安装结果 ================"
Write-Host "Magisk: $($magiskVersion.Output)"
Write-Host "SU: $($suCheck.Output)"
if (-not [string]::IsNullOrWhiteSpace($unloaded.Output)) {
    Write-Host "发现不兼容 Zygisk 库："
    Write-Host $unloaded.Output
}
if ($lspd.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($lspd.Output)) {
    Write-Host "Vector/LSPosed 数据目录已生成，框架大概率已激活。"
} else {
    Write-Host "尚未检测到 /data/adb/lspd。请查看日志目录中的诊断信息；可能需要再重启一次。"
}
Write-Host "主机日志：$HostLog"
Write-Host "设备日志：/data/local/tmp/mumu-magisk-oneclick.log 和 /data/local/tmp/magisk_init.log"

Write-Step "打开 Magisk App"
$managerCheck = Invoke-Adb -Arguments @("shell", "pm", "path", "com.topjohnwu.magisk") -AllowFail -Quiet
if ($managerCheck.Code -eq 0 -and $managerCheck.Output -match "package:") {
    Invoke-Adb -Arguments @("shell", "monkey", "-p", "com.topjohnwu.magisk", "-c", "android.intent.category.LAUNCHER", "1") -AllowFail -Quiet | Out-Null
} else {
    Write-Host "没有检测到 Magisk App，请从下载目录手动安装 Magisk APK。" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "================ 请在 Magisk 中完成 ================" -ForegroundColor Cyan
Write-Host "1. 打开“模块”页面，开启 NeoZygisk（Zygisk）。"
Write-Host "2. 开启 Vector（LSPosed）。"
Write-Host "3. 本方案使用 NeoZygisk，请不要同时开启 Magisk 设置页里的内置 Zygisk。"
Write-Host "4. 在 Mumu 中关闭 Root 权限：设备设置 -> 开发者选项 -> Root 权限。"
Write-Host ""
Write-Host "================ 请在 Mumu 中完成 ================" -ForegroundColor Cyan
Write-Host "1. 返回当前设备窗口。"
Write-Host "2. 点击重启设备，不要在 Magisk 中重启。"
Write-Host "3. 重启完成后，再打开 NeoZygisk 和 Vector 检查状态。"
