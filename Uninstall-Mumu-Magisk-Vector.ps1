[CmdletBinding()]
param(
    [string]$AdbPath = "adb",
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
    Write-Host "此操作将：移除 Zygisk-Next / Vector / 官方 LSPosed 模块、手工 Magisk 启动项与系统 Magisk 兼容启动器，"
    Write-Host "删除 /data/adb/magisk 运行时，并恢复安装前备份的 KernelSU userspace（/data/adb/ksud）。"
    Write-Host " - 同时卸载 Magisk 管理器 App（com.topjohnwu.magisk）。"
    Write-Host " - 同时卸载 KsuWebUI App（io.github.a13e300.ksuwebui）。"
    $answer = Read-Host "输入 YES 继续"
    if ($answer -ne "YES") { exit 1 }
}

if ($Device -match ":") { & $adb connect $Device | Out-Host }
& $adb -s $Device root | Out-Host
Start-Sleep -Seconds 2
if ($Device -match ":") { & $adb connect $Device | Out-Null }

# 设备端卸载脚本：
# - 仅按精确模块 id 删除本工具安装的三个框架模块，避免关键字匹配误删其他模块；
# - 移除 magisk.rc / magisk_init.sh / 兼容启动器（恢复备份的原始 /system/bin/magisk）；
# - 删除 /data/adb/magisk 运行时与本工具的临时痕迹；
# - 恢复安装前备份的 KernelSU userspace（ksud）。
$remote = @'
#!/system/bin/sh
LOG=/data/local/tmp/mumu-magisk-uninstall.log
: > "$LOG"
log() { echo "[Mumu Uninstaller] $*"; echo "[$(date '+%F %T')] $*" >> "$LOG"; }

[ -x /debug_ramdisk/magisk ] && /debug_ramdisk/magisk --stop 2>/dev/null || true

# 精确模块 id 白名单（本工具只会安装这三个），不使用描述关键字匹配，防止误删。
MODULE_IDS="zygisksu zygisk_vector zygisk_lsposed"
for root in /data/adb/modules /data/adb/modules_update; do
    [ -d "$root" ] || continue
    for d in "$root"/*; do
        [ -f "$d/module.prop" ] || continue
        id=$(sed -n 's/^id=//p' "$d/module.prop" 2>/dev/null | head -n 1 | tr -d '\r')
        for want in $MODULE_IDS; do
            if [ "$id" = "$want" ]; then
                log "removing module $id ($d)"
                rm -rf "$d"
            fi
        done
    done
done

rm -f /system/etc/init/magisk.rc
rm -f /data/adb/magisk_init.sh
if grep -q 'MUMU_MAGISK_COMPAT_LAUNCHER' /system/bin/magisk 2>/dev/null; then
    rm -f /system/bin/magisk
    if [ -e /data/adb/mumu-magisk-backup/system-bin-magisk ]; then
        cp -af /data/adb/mumu-magisk-backup/system-bin-magisk /system/bin/magisk
        chmod 0755 /system/bin/magisk 2>/dev/null || true
        restorecon /system/bin/magisk 2>/dev/null || true
        log "restored original /system/bin/magisk from backup"
    fi
fi
rm -rf /data/adb/magisk
rm -rf /data/adb/zygisknext-mumu-guard 2>/dev/null || true
# 清理主机侧临时下发文件（不影响系统）。
rm -f /data/local/tmp/mumu-magisk-install.sh /data/local/tmp/mumu-verify-modules.sh \
      /data/local/tmp/magisk.rc /data/local/tmp/magisk_init.sh /data/local/tmp/magisk-compat \
      /data/local/tmp/mumu-magisk-modules.conf /data/local/tmp/Zygisk-Next.zip /data/local/tmp/Vector.zip
rm -rf /data/local/tmp/mumu_magisk_stage /data/local/tmp/mumu_magisk_probe /data/local/tmp/mumu_magisk_backup 2>/dev/null || true

# 恢复安装前被隔离的 KernelSU userspace 守护进程。
if [ ! -e /data/adb/ksud ] && [ ! -L /data/adb/ksud ] && { [ -e /data/adb/mumu-magisk-backup/ksud ] || [ -L /data/adb/mumu-magisk-backup/ksud ]; }; then
    cp -af /data/adb/mumu-magisk-backup/ksud /data/adb/ksud
    chmod 0700 /data/adb/ksud 2>/dev/null || true
    restorecon /data/adb/ksud 2>/dev/null || true
    log "restored KernelSU userspace daemon (ksud)"
fi
rm -rf /data/adb/mumu-magisk-backup
sync
log "uninstall finished"
'@
$tmp = Join-Path $env:TEMP "mumu-magisk-uninstall.sh"
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($tmp, $remote.Replace("`r`n", "`n"), $enc)
& $adb -s $Device push $tmp /data/local/tmp/mumu-magisk-uninstall.sh | Out-Host
& $adb -s $Device shell chmod 0755 /data/local/tmp/mumu-magisk-uninstall.sh | Out-Host
& $adb -s $Device shell sh /data/local/tmp/mumu-magisk-uninstall.sh | Out-Host

Write-Host "卸载 Magisk 管理器 App ..."
& $adb -s $Device uninstall com.topjohnwu.magisk | Out-Host
Write-Host "卸载 KsuWebUI App ..."
& $adb -s $Device uninstall io.github.a13e300.ksuwebui | Out-Host

Write-Host "卸载完成。卸载器已恢复安装前备份的 /system/bin/magisk 与 /data/adb/ksud（如有）。"
Write-Host "如需要让模块移除彻底生效，请在 Mumu 窗口手动重启设备。"
Write-Host "设备日志：/data/local/tmp/mumu-magisk-uninstall.log"
