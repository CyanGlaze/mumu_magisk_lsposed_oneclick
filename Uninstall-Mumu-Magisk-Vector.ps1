[CmdletBinding()]
param(
    [string]$AdbPath = "adb",
    [switch]$UninstallManager,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$cmd = Get-Command $AdbPath -ErrorAction SilentlyContinue
if ($null -eq $cmd) { throw "找不到 adb。" }
$adb = $cmd.Source
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DeviceConfigPath = Join-Path $ScriptRoot "config\last-device.txt"
$Device = ""
if (Test-Path -LiteralPath $DeviceConfigPath) {
    $Device = (Get-Content -LiteralPath $DeviceConfigPath -Raw -ErrorAction SilentlyContinue).Trim()
}
Write-Host ""
& $adb devices | Out-Host
if ([string]::IsNullOrWhiteSpace($Device)) {
    $Device = Read-Host "输入 Mumu IP 或 IP:端口（只输入 IP 默认 5555）"
} else {
    $answerDevice = Read-Host "Mumu 设备地址 [$Device]"
    if (-not [string]::IsNullOrWhiteSpace($answerDevice)) { $Device = $answerDevice.Trim() }
}
if ($Device -match '^[0-9]{1,3}(?:\.[0-9]{1,3}){3}$') { $Device += ":5555" }
if ($Device -notmatch '^[0-9]{1,3}(?:\.[0-9]{1,3}){3}:[0-9]{1,5}$') { throw "设备地址格式无效。" }

if (-not $Force) {
    Write-Host "此操作将移除手工 Magisk 启动项、官方 NeoZygisk/Vector 模块和系统 Magisk 兼容启动器，并恢复安装前备份的 KernelSU userspace。"
    $answer = Read-Host "输入 YES 继续"
    if ($answer -ne "YES") { exit 1 }
}

if ($Device -match ":") { & $adb connect $Device | Out-Host }
& $adb -s $Device root | Out-Host
Start-Sleep -Seconds 2
if ($Device -match ":") { & $adb connect $Device | Out-Null }

$remote = @'
#!/system/bin/sh
[ -x /debug_ramdisk/magisk ] && /debug_ramdisk/magisk --stop 2>/dev/null || true
for root in /data/adb/modules /data/adb/modules_update; do
    for d in "$root"/*; do
        [ -f "$d/module.prop" ] || continue
        if grep -qiE 'NeoZygisk|Vector|LSPosed' "$d/module.prop"; then
            rm -rf "$d"
        fi
    done
done
rm -f /system/etc/init/magisk.rc
rm -f /data/adb/magisk_init.sh
if grep -q 'MUMU_MAGISK_COMPAT_LAUNCHER_v1.0.1' /system/bin/magisk 2>/dev/null; then
    rm -f /system/bin/magisk
    if [ -e /data/adb/mumu-magisk-backup/system-bin-magisk ]; then
        cp -af /data/adb/mumu-magisk-backup/system-bin-magisk /system/bin/magisk
        chmod 0755 /system/bin/magisk 2>/dev/null || true
        restorecon /system/bin/magisk 2>/dev/null || true
    fi
fi
rm -rf /data/adb/magisk
rm -rf /data/adb/neozygisk /data/adb/neozygisk-mumu-guard
if [ ! -e /data/adb/ksud ] && [ ! -L /data/adb/ksud ] && { [ -e /data/adb/mumu-magisk-backup/ksud ] || [ -L /data/adb/mumu-magisk-backup/ksud ]; }; then
    cp -af /data/adb/mumu-magisk-backup/ksud /data/adb/ksud
    chmod 0700 /data/adb/ksud 2>/dev/null || true
    restorecon /data/adb/ksud 2>/dev/null || true
fi
rm -rf /data/adb/mumu-magisk-backup
sync
'@
$tmp = Join-Path $env:TEMP "mumu-magisk-uninstall.sh"
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($tmp, $remote.Replace("`r`n", "`n"), $enc)
& $adb -s $Device push $tmp /data/local/tmp/mumu-magisk-uninstall.sh | Out-Host
& $adb -s $Device shell chmod 0755 /data/local/tmp/mumu-magisk-uninstall.sh | Out-Host
& $adb -s $Device shell sh /data/local/tmp/mumu-magisk-uninstall.sh | Out-Host
if ($UninstallManager) {
    & $adb -s $Device uninstall com.topjohnwu.magisk | Out-Host
}
& $adb -s $Device reboot | Out-Host
Write-Host "已提交卸载并重启。卸载器会恢复安装前备份的 /system/bin/magisk 与 /data/adb/ksud（如有）。"
