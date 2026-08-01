# MuMu Android 15：Magisk + LSPosed 一键安装工具

> **版本：1.0**
> 
> 面向 MuMu Android 15 实例的一键 Magisk、NeoZygisk 与 Vector（LSPosed）安装工具。

---

## 适用范围

本工具**仅适用于 MuMu 的 Android 15 实例**，不适用于以下环境：

* MuMu Android 12
* MuMu Android 9
* 其他安卓模拟器
* Android 15 以外的系统版本

安装脚本会自动读取设备的 Android 版本。

如果检测结果不是 **Android 15**，脚本会立即停止，不会继续修改系统文件。

---

## 安装前准备

请启动需要安装的 **MuMu Android 15 实例**，并逐项确认以下设置。

### 1. 确认系统版本

当前实例的系统版本必须为：

```text
Android 15
```

### 2. 开启 Root 权限

进入：

```text
设备设置 → 开发者选项 → Root 权限
```

开启 Root 权限。

### 3. 开启系统盘读写

进入：

```text
设备设置 → 开发者选项 → 磁盘共享 → 可写系统盘
```

开启可写系统盘。

### 4. 开启网络桥接模式

进入：

```text
设备设置 → 网络 → 网络桥接模式
```

开启网络桥接模式。

### 5. 开启 ADB

确保：

* MuMu 已开启 ADB；
* 电脑与 MuMu 位于同一局域网；
* 电脑能够通过局域网连接 MuMu 的 ADB 服务。

### 6. 创建实例快照

请为当前实例创建快照，以便在设备无法正常启动时快速恢复。

> [!IMPORTANT]
> 如果刚刚开启了以下任意功能：
>
> * Root 权限
> * 可写系统盘
> * 网络桥接模式
>
> 请先在 MuMu 中点击一次 **“重启设备”**，等待设备完整启动后，再运行安装脚本。
>
> 不要只关闭模拟器窗口，也不要只断开 ADB。

---

## 运行方法

双击运行：

```text
install.cmd
```

脚本会首先执行：

```bash
adb devices
```

随后，脚本会列出当前 ADB 中记录的局域网设备，并要求选择 MuMu 的设备地址。

支持以下输入方式：

| 输入方式     | 示例                  |
| -------- | ------------------- |
| 列表编号     | `1`                 |
| IP 地址    | `192.168.1.42`      |
| IP 地址和端口 | `192.168.1.42:5555` |

只输入 IP 地址时，脚本默认使用端口：

```text
5555
```

脚本会将最后一次选择的设备地址保存到：

```text
config\last-device.txt
```

下次运行时，该地址会自动显示在输入位置：

* 直接按回车：确认使用上次的地址；
* 按退格键修改：输入新的设备地址。

> 设备 IP 不再通过 `install.cmd` 的命令行参数传入。

---

## 安装过程

安装脚本会自动检查以下项目：

* Android 系统版本是否为 15；
* `adbd root` 是否真正生效；
* `/system/etc/init` 是否能够实际写入；
* Magisk 核心二进制是否匹配当前设备 ABI；
* NeoZygisk 安装包是否有效；
* Vector 安装包是否有效；
* Magisk 模块安装运行时是否完整；
* 生成的设备端 Shell 脚本是否能够通过语法检查。

完成安装文件写入后，脚本会提示在 MuMu 中点击：

```text
重启设备
```

点击重启后，返回命令窗口并输入：

```text
RESTART
```

脚本会通过以下状态判断设备是否完成了真正的完整重启：

* `boot_id`
* `sys.boot_completed`

> [!WARNING]
> 仅关闭 MuMu 窗口、重新连接 ADB 或重新启动脚本，不会被视为完整重启。

---

## 安装完成后的设置

设备重启完成后，脚本会自动打开 **Magisk App**。

请进入 Magisk 的 **“模块”** 页面，确认并开启：

1. **NeoZygisk**

   * 用于提供 Zygisk 环境。

2. **Vector**

   * 用于提供 LSPosed 功能。

### Zygisk 设置要求

本方案使用的是：

```text
NeoZygisk
```

因此，请勿同时开启 Magisk 设置页面中的内置 Zygisk。

> [!CAUTION]
> NeoZygisk 与 Magisk 内置 Zygisk 不应同时启用，否则可能导致模块冲突、Zygisk 注入异常或设备启动问题。

---

## 使用本地安装包

默认情况下，脚本会使用预设的安装包。

需要指定本地安装包时，请在 PowerShell 中运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-MuMu-Magisk-Vector.ps1 `
  -MagiskApk .\Magisk.apk `
  -NeoZygiskZip .\NeoZygisk.zip `
  -VectorZip .\Vector.zip
```

参数说明：

| 参数              | 用途                   |
| --------------- | -------------------- |
| `-MagiskApk`    | 指定本地 Magisk APK      |
| `-NeoZygiskZip` | 指定本地 NeoZygisk 模块压缩包 |
| `-VectorZip`    | 指定本地 Vector 模块压缩包    |

设备地址仍然会在脚本启动时选择，不能通过命令行参数传入。

---

## 常用验证命令

首先查看上次保存的设备地址：

```text
config\last-device.txt
```

假设设备地址为：

```text
192.168.1.42:5555
```

可以执行以下命令进行验证。

### 检查 Magisk 版本

```bash
adb -s 192.168.1.42:5555 shell "/debug_ramdisk/magisk -v"
```

### 检查 Root 权限

```bash
adb -s 192.168.1.42:5555 shell "/debug_ramdisk/su -c id"
```

正常情况下，输出中应包含：

```text
uid=0(root)
```

### 检查是否存在被禁用的模块

```bash
adb -s 192.168.1.42:5555 shell "/debug_ramdisk/su -c 'find /data/adb/modules -name unloaded -print'"
```

如果没有任何输出，通常表示没有模块处于 `unloaded` 状态。

### 检查 LSPosed 数据目录

```bash
adb -s 192.168.1.42:5555 shell "/debug_ramdisk/su -c 'ls -la /data/adb/lspd 2>/dev/null'"
```

---

## 日志位置

### 主机端日志

```text
logs\install-日期时间.log
```

例如：

```text
logs\install-20260801-231500.log
```

### 设备端日志

```text
/data/local/tmp/mumu-magisk-oneclick.log
```

```text
/data/local/tmp/magisk_init.log
```

安装失败或设备重启异常时，请优先检查上述日志。

---

## 卸载方法

双击运行：

```text
uninstall.cmd
```

卸载脚本会：

1. 默认读取上次保存的 MuMu 设备地址；
2. 在执行卸载前允许修改设备地址；
3. 移除本工具写入的相关文件和配置。

卸载完成后，请在 MuMu 中手动点击：

```text
重启设备
```

等待设备完成完整重启。

---

## 风险说明

> [!WARNING]
> 本工具属于针对 **MuMu Android 15** 的非官方手工 Magisk 注入方案。
>
> 修改系统文件可能导致：
>
> * 实例无法正常启动；
> * Magisk 或模块加载失败；
> * 模拟器更新后功能失效；
> * 系统文件与 MuMu 原始状态不一致；
> * 需要通过快照恢复实例。

首次安装前，必须为当前实例创建并保留可用快照。

使用本工具即表示使用者已了解相关风险，并自行承担因系统修改产生的后果。
