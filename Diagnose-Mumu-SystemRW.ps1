param(
    [string]$AdbPath = "adb"
)
$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DeviceConfigPath = Join-Path $ScriptRoot "config\last-device.txt"
$cmd = Get-Command $AdbPath -ErrorAction SilentlyContinue
if ($null -eq $cmd) { throw "找不到 adb。" }
$adb = $cmd.Source

& $adb devices | Out-Host
$Device = ""
if (Test-Path -LiteralPath $DeviceConfigPath) {
    $Device = (Get-Content -LiteralPath $DeviceConfigPath -Raw -ErrorAction SilentlyContinue).Trim()
}
if ([string]::IsNullOrWhiteSpace($Device)) {
    $Device = Read-Host "输入 Mumu IP 或 IP:端口（只输入 IP 默认 5555）"
} else {
    $answer = Read-Host "Mumu 设备地址 [$Device]"
    if (-not [string]::IsNullOrWhiteSpace($answer)) { $Device = $answer.Trim() }
}
if ($Device -match '^[0-9]{1,3}(?:\.[0-9]{1,3}){3}$') { $Device += ":5555" }
if ($Device -notmatch '^[0-9]{1,3}(?:\.[0-9]{1,3}){3}:[0-9]{1,5}$') { throw "设备地址格式无效。" }

& $adb connect $Device | Out-Host
& $adb -s $Device root | Out-Host
Start-Sleep -Seconds 3
& $adb connect $Device | Out-Host
$local = Join-Path $env:TEMP "mumu-system-rw-probe.sh"
@'
#!/system/bin/sh
P=/system/etc/init/.mumu_magisk_rw_test
rm -f "$P"
if touch "$P"; then
  echo MUMU_SYSTEM_RW
  ls -lZ "$P" 2>/dev/null || ls -l "$P"
  rm -f "$P"
  exit 0
fi
id
id -Z 2>/dev/null
exit 1
'@ | Set-Content -LiteralPath $local -Encoding Ascii
& $adb -s $Device push $local /data/local/tmp/mumu-system-rw-probe.sh | Out-Host
& $adb -s $Device shell chmod 0755 /data/local/tmp/mumu-system-rw-probe.sh | Out-Host
Write-Host "[1] adbd root"
& $adb -s $Device shell /data/local/tmp/mumu-system-rw-probe.sh | Out-Host
Write-Host "[2] su -c（安装 Magisk 前不存在 su 属于正常情况）"
& $adb -s $Device shell su -c /data/local/tmp/mumu-system-rw-probe.sh | Out-Host
Write-Host "[3] su 0（安装 Magisk 前不存在 su 属于正常情况）"
& $adb -s $Device shell su 0 /data/local/tmp/mumu-system-rw-probe.sh | Out-Host
