# MuMu Android 15：Magisk + LSPosed 一键安装工具

> **版本：1.0.2**  
> **作者：Main**
>
> 面向 MuMu Android 15 实例的一键 Magisk、Zygisk-Next、Vector（可选 LSPosed）与 KsuWebUI 安装工具。支持自动在线版本检测、离线包复用、ADB 重启等功能。

---

## 适用范围

本工具仅适用于：

```text
MuMu Android 15
```

不适用于：

- MuMu Android 12
- MuMu Android 9
- 其他安卓模拟器
- Android 15 以外的系统版本

安装器会自动读取设备的 Android 版本。如果检测结果不是 Android 15，脚本会立即停止，不会继续修改系统文件。

---

## 1.0.2 更新说明

- **LSPosed可选**：运行时交互选择 Vector（GitHub `JingMatrix/Vector`）或官方 LSPosed（`https://lsposed.cn/lsposed1`）。
- **Magisk 检测提示优化**：明确说明检测的是系统级二进制（`/system/bin/magisk` 等），卸载 Magisk App 不会移除系统级安装。
- **模块 ZIP 一律原样安装**：不再在主机侧对下载的模块 ZIP（含 lsposed.cn 官方 LSPosed）做任何解压或重新打包，直接把原始 ZIP 交给设备端 `magisk --install-module`。主机侧仅做"尽力而为"的 `module.prop` 读取；若压缩格式不被 .NET 支持（如 ZIP 内的 XZ 条目），跳过主机侧 ID 校验并提示，安装与校验完全由 Magisk 原生完成。
- **下载目录改为 `packages`**：组件下载后直接以原始版本名（如 `Zygisk-Next-1.5.2-864-a4a72ce-release.zip`、`Vector-v2.2-3080-Release.zip`、`LSPosed-v2.2.1-7912-release.zip`）保存到 `packages\`，与本地包同目录同命名，下载即复用、离线可装，不再使用固定的 `-latest` 文件名。
- **卸载脚本重写**：模块删除改为按精确 id 白名单（`zygisksu`/`zygisk_vector`/`zygisk_lsposed`），不再用描述关键字匹配（避免误删）；**默认卸载 Magisk 管理器 APK（`com.topjohnwu.magisk`）与 KsuWebUI（`io.github.a13e300.ksuwebui`）**；**卸载不做自动重启**，完成后提示在 MuMu 窗口手动重启使模块移除生效。
- Zygisk-Next 不再内置于工具包中，安装时下载官方最新稳定版。
- 下载的 Zygisk-Next ZIP 会原样交给 Magisk 安装，不修改模块脚本或二进制。
- 支持复用已经校验的下载缓存。
- 支持通过 `packages\Zygisk-Next-*.zip` 或 PowerShell 参数进行离线安装。
- 增加系统级 Magisk 兼容启动器，避免 MuMu 内置 Root 框架重复执行模块。
- 增加 KernelSU userspace 冲突处理，避免 Zygisk-Next 报告：

  ```text
  Invalid root implementation: Multiple
  ```

- 保留模块 `sepolicy.rule` 动态加载逻辑。
- 增加 Zygisk-Next monitor 数量、`TracerPid`、进程状态和模块运行状态检查。
- 修复 Windows PowerShell 5.1 中文编码及多层命令引号问题。

---

## 安装内容

安装器会完整安装或更新：

- Magisk 完整运行时
- Magisk 管理器（系统级 Magisk 已存在但管理器被卸载时，只补装管理器）
- Zygisk-Next 官方最新稳定版
- Vector / LSPosed 官方最新稳定版
- MuMu 手工 Magisk 启动项
- 模块 SELinux 规则加载逻辑
- 系统级 Magisk 兼容启动器
- KsuWebUI 管理器（用于访问模块内置 WebUI）

> [!NOTE]
> 组件安装采用**单一自动流程**：先检测 `packages\` 本地包是否为最新版——本地缺失则直接下载，已是最新则直接用本地包，不是最新才提示是否下载。安装完成后会提示在 MuMu 中手动重启设备，脚本自动等待重启完成后继续验证。

默认情况下，Magisk、Zygisk-Next 与 KsuWebUI 从 GitHub 官方发布页获取最新稳定版本；LSPosed 按运行时的选择获取：**Vector** 来自 GitHub `JingMatrix/Vector`，**官方 LSPosed** 来自 `https://lsposed.cn/lsposed1`。

---

## 安装前准备

请启动需要安装的 MuMu Android 15 实例，并逐项完成以下设置。

### 1. 确认系统版本

当前实例必须为：

```text
Android 15
```

### 2. 创建实例快照

安装前必须为当前实例创建快照，以便设备无法启动时快速恢复。

### 3. 开启 Root 权限

进入：

```text
设备设置 → 开发者选项 → Root 权限
```

开启 Root 权限。

### 4. 开启系统盘读写

进入：

```text
设备设置 → 开发者选项 → 磁盘共享 → 可写系统盘
```

开启可写系统盘。

### 5. 开启网络桥接模式

进入：

```text
设备设置 → 网络 → 网络桥接模式
```

开启网络桥接模式。

### 6. 开启 ADB

确保：

- MuMu 已开启 ADB；
- 电脑与 MuMu 位于同一局域网；
- 电脑可以通过局域网连接 MuMu 的 ADB 服务。

> [!IMPORTANT]
> 如果刚刚修改了 Root 权限、可写系统盘或网络桥接模式，请先在 MuMu 窗口中点击一次“重启设备”，等待 Android 完整启动后再运行安装器。
>
> 不要只关闭模拟器窗口，也不要只重新连接 ADB。

---

## 运行方法

完整解压工具包后，双击：

```text
install.cmd
```

不要直接在压缩软件中运行。

脚本会先执行：

```bash
adb devices
```

随后列出当前 ADB 中记录的局域网设备，并要求选择 MuMu 设备地址。

支持以下输入：

| 输入方式 | 示例 |
|---|---|
| 列表编号 | `1` |
| IP 地址 | `192.168.1.42` |
| IP 和端口 | `192.168.1.42:5555` |

只输入 IP 时，默认使用：

```text
5555
```

最后一次选择的设备地址会保存到：

```text
config\last-device.txt
```

下次运行时：

- 直接按回车：使用上次地址；
- 修改输入内容：选择新的设备地址。

设备地址不通过 `install.cmd` 命令行参数传入。

---

## 安装过程

安装器会自动检查：

- Android 版本是否为 15；
- `adbd root` 是否真正生效；
- `/system` 是否可以实际写入；
- 设备 ABI 是否受支持；
- Magisk 核心运行时是否完整；
- Zygisk-Next 模块包是否有效；
- Vector 模块包是否有效；
- 设备端 Shell 脚本是否通过语法检查；
- Magisk 与 MuMu 内置 Root 框架是否存在执行冲突。

完成安装文件写入后，脚本会提示你在 MuMu 中手动重启设备，并自动等待重启完成：

```text
请在 MuMu 窗口点击“重启设备”，脚本会自动等待重启完成后继续验证。
```

脚本通过检测 `boot_id` 变化与 `sys.boot_completed=1` 自动确认重启完成（MuMu 上 host 端 `adb reboot` 不生效，因此不再通过 ADB 触发重启），确认完成后自动继续验证与最终设置。

> [!NOTE]
> 若想跳过等待（稍后手动重启并重新运行脚本验证），可加 `-NoReboot`；等待超时时间可用 `-BootTimeoutSeconds` 调整（默认 480 秒）。

> [!WARNING]
> 关闭 MuMu 窗口、重新连接 ADB 或重新启动安装脚本，都不会被视为完整设备重启。

---

## 安装完成后的设置

设备重启完成后，安装器会自动打开 Magisk App。

### 请在 Magisk 中完成

1. 打开“模块”页面，开启 **Zygisk-Next**。
2. 开启已安装的 **LSPosed**（Vector 或 官方 LSPosed）。
3. 本方案使用 Zygisk-Next，请勿同时开启 Magisk 设置页面中的内置 Zygisk。
4. 保持 `Enforce DenyList` 关闭。

### 请在 MuMu 中完成

1. 返回当前设备窗口。
2. 确认 Zygisk-Next 与所选 LSPosed 均处于启用状态。
3. 关闭 MuMu 自带 Root 权限：

   ```text
   设备设置 → 开发者选项 → Root 权限
   ```

4. 在 MuMu 窗口中点击“重启设备”，不要从 Magisk 中重启。
5. 重启完成后打开 Zygisk-Next 检查状态。

> [!CAUTION]
> Zygisk-Next 与 Magisk 内置 Zygisk 不应同时启用，否则可能导致模块冲突、注入异常或设备启动问题。

---

## 最终正常状态

Zygisk-Next 页面应显示：

```text
monitor: tracing
zygote64: injected
daemon64: running
```

同时应满足：

- 系统中只有一个 `zygisk-ptrace64 monitor`；
- `/proc/1/status` 中的 `TracerPid` 指向该 monitor；
- `zygiskd64` 正常运行；
- `lspd` 正常运行；
- 不再出现：

  ```text
  Invalid root implementation: Multiple
  ```

---

## 组件来源与版本检测（单一自动流程）

运行后，安装器先**检测设备是否已安装 Magisk**（检测的是 `/system/bin/magisk` 等**系统级二进制**，不是 Magisk App；卸载 App 不会移除系统级安装）：

- 系统级 Magisk 与管理器 App 都在 → 跳过 Magisk 安装；
- 系统级 Magisk 在、管理器 App 被卸载 → **只补装管理器 APK**，不重复注入运行时；
- 都未检测到 → 完整安装 Magisk 运行时 + 管理器。

随后进入**单一自动流程**，对每个组件（Magisk、Zygisk-Next、LSPosed、KsuWebUI）执行：

1. 在线查询最新稳定版（GitHub Releases；官方 LSPosed 走 `lsposed.cn` 页面解析）；
2. 检测 `packages\` 目录中是否已有对应的本地包，并比较版本；
3. **本地包缺失** → 直接下载最新版并安装，不再询问；
4. **本地包已是最新版** → 直接使用本地包，不再下载；
5. **本地包存在但不是最新版** → 提示「是否下载最新版？[Y/N]」：
   - 选 **Y** → 下载并安装最新版；
   - 选 **N** → 使用本地包；
   - 若在线版本检测本身失败（例如无网络），则自动退回使用本地包（本地缺失则报错）。

LSPosed 会在流程开始前**交互选择**：

```text
1) Vector (GitHub: JingMatrix/Vector)
2) 官方 LSPosed (https://lsposed.cn/lsposed1)
```

输入 `1` 或 `2`（直接回车默认 `1` Vector）。`-Auto` 模式下自动选择 Vector。选择官方 LSPosed 时，安装器会解析 `https://lsposed.cn/lsposed1` 页面中的下载链接（当前为 `LSPosed-v2.2.1-7912-release.zip`）并下载。

整个流程的交互仅剩两处：LSPosed 选择（1/2）、组件来源确认（仅当 `packages\` 已有本地包且非最新时，Y/N 是否更新）。安装完成后不再需要重启确认，脚本会自动等待你在 MuMu 中手动重启并继续验证。所有组件均支持通过参数直接指定本地路径（`-MagiskApk`、`-ZygiskNextZip`、`-VectorZip`、`-KsuWebUIApk`），指定后跳过在线检测。

> [!NOTE]
> **模块 ZIP 一律原样安装，不重新打包**：`lsposed.cn` 的官方 LSPosed 下载下来是 `.zip`，其内部部分条目使用了 XZ 压缩（ZIP method 95）。本工具**不会**在主机侧解压或转换它，而是把原始 ZIP 原样推送到设备并交给 `magisk --install-module`——Magisk 原生模块安装器负责解压这类压缩方法。主机侧的 .NET 读不出 XZ 条目时只会跳过模块 ID 预检并给出黄色提示，不影响实际安装；真正的结构与兼容性校验由设备端 Magisk 完成。

---

## 在线下载与版本缓存

默认情况下，安装器会在线查询以下组件的最新稳定版；本地包缺失时直接下载（不询问），本地包存在且非最新时才提示是否更新：

- Magisk 最新稳定版
- Zygisk-Next 最新稳定版
- LSPosed（按选择：Vector 或 官方 LSPosed）最新版
- KsuWebUI 最新稳定版

下载前会先比对 `packages\` 中的本地包版本：**本地包缺失时直接下载（不询问）**；仅有本地包且非最新版时才会提示是否更新。**下载的文件会直接以上游原始版本名保存到 `packages\`**（例如 `Zygisk-Next-1.5.2-864-a4a72ce-release.zip`、`Vector-v2.2-3080-Release.zip`、`LSPosed-v2.2.1-7912-release.zip`），不使用固定的 `-latest` 文件名，从而避免同一组件多版本并存或选错：

```text
packages
```

因此下载与本地包是同一目录、同一命名规则：下载一次后，下次运行会被本地探测直接命中（复用、离线可装）。

安装失败后重新运行时，会复用已存在且通过校验的同名文件。

如果 GitHub API 返回资产 SHA-256 digest，安装器会进行完整哈希校验；否则会至少检查下载文件大小。模块结构与兼容性由设备端 Magisk 在安装时校验（主机侧对 XZ 等压缩格式只做尽力而为的预读）。

实际使用的模块 ZIP SHA-256 会写入主机端安装日志。

> [!TIP]
> **版本比较规则**：只比较到较短版本号的段数。例如上游 tag 为 `v1.5.2`、本地包为 `1.5.2.864`（构建号后缀），会被判定为同一版本，不会误报“非最新版”。

---

## 离线安装

本工具包不内置任何组件。Magisk、Zygisk-Next、LSPosed 与 KsuWebUI 均支持离线（放入 `packages\`）或指定本地文件；在线下载失败时会自动回退到 `packages\` 下的本地文件。

### Magisk：使用本地 Magisk APK

未通过 `-MagiskApk` 指定文件时，安装器会自动在工具目录、`packages\` 目录和运行目录下查找：

```text
Magisk*.apk
```

找到后按「本地包是否为最新版」处理：是最新版直接使用；不是最新版则提示是否下载最新版。

### Zygisk-Next：使用 packages 目录

将官方 Zygisk-Next ZIP 命名为（保留版本号也可以，安装器按通配符匹配）：

```text
Zygisk-Next-*.zip
```

例如：

```text
Zygisk-Next-v1.2.3.zip
```

放入：

```text
packages
```

安装器会先比对版本：与在线最新版一致时直接使用本地文件；否则提示是否下载最新版。

### 官方 LSPosed：使用 packages 目录

选择「2) 官方 LSPosed」后，安装器会在 `packages\` 中查找：

```text
LSPosed-*.zip
```

若该包与 lsposed.cn 最新版一致则直接使用；不一致会提示下载。无论使用何种内部压缩格式，ZIP 都原样交给设备端 Magisk 安装，不在主机侧重新打包。

### KsuWebUI：使用 packages 目录

将官方 KsuWebUI APK（仓库 `adivenxnataly/KsuWebUI` 的 `*-release.apk`）命名为（安装器按通配符匹配）：

```text
KsuWebUI*.apk
```

例如：

```text
KsuWebUI-1.0-11-release.apk
```

放入：

```text
packages
```

在线下载失败时会自动回退到该文件。KsuWebUI 为纯 APK，安装器仅通过 `adb install` 安装，不会修改其内容。

### 方式二：通过 PowerShell 参数指定

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Mumu-Magisk-Vector.ps1 `
  -MagiskApk .\Magisk-v31.1.apk `
  -ZygiskNextZip .\Zygisk-Next-1.5.2-864-a4a72ce-release.zip `
  -VectorZip .\Vector-v2.2-3080-Release.zip `
  -KsuWebUIApk .\KsuWebUI-1.0-11-release.apk
```

参数说明：

| 参数 | 用途 |
|---|---|
| `-MagiskApk` | 指定本地 Magisk APK（跳过在线下载与交互） |
| `-ZygiskNextZip` | 指定本地 Zygisk-Next 模块 ZIP |
| `-VectorZip` | 指定本地 LSPosed ZIP（Vector 或 官方 LSPosed 均可，例如 `Vector-*.zip` 或 `Lsposed-*.zip`） |
| `-KsuWebUIApk` | 指定本地 KsuWebUI APK（跳过在线下载与交互） |
| `-Auto` | 跳过所有确认：LSPosed 自动选 Vector，组件缺失直接下载/非最新自动下载（安装完成后自动等待手动重启） |
| `-NoReboot` | 不等待重启，安装后立即退出（需稍后在 MuMu 手动重启并重新运行脚本验证） |
| `-BootTimeoutSeconds` | 等待重启完成的最长时间（秒），默认 480 |

本地 Zygisk-Next ZIP 必须是标准模块包，根目录应包含：

```text
module.prop
customize.sh
```

模块 ID 应为：

```text
zygisksu
```

安装器只会校验和安装该 ZIP，不会修改其内容。

---

## 覆盖安装

已经安装旧版本时，可以直接运行本版：

```text
install.cmd
```

安装器会完整更新 Magisk、Zygisk-Next、所选 LSPosed、KsuWebUI 和启动环境。

旧版中曾经内置或修改过的 Zygisk-Next，会被在线下载的官方模块完整替换。

---

## 常用验证命令

首先查看保存的设备地址：

```text
config\last-device.txt
```

假设设备地址为：

```text
192.168.1.42:5555
```

### 检查 Magisk 版本

```bash
adb -s 192.168.1.42:5555 shell "/debug_ramdisk/magisk -v"
```

### 检查 Magisk Root

```bash
adb -s 192.168.1.42:5555 shell "/debug_ramdisk/su -c id"
```

正常输出应包含：

```text
uid=0(root)
```

### 检查模块状态

```bash
adb -s 192.168.1.42:5555 shell "/debug_ramdisk/su -c 'find /data/adb/modules -name unloaded -print'"
```

没有输出通常表示不存在处于 `unloaded` 状态的模块。

### 检查 Zygisk-Next monitor

```bash
adb -s 192.168.1.42:5555 shell "ps -A | grep zygisk-ptrace"
```

正常情况下只应存在一个 monitor。

### 检查 init 的 TracerPid

```bash
adb -s 192.168.1.42:5555 shell "grep TracerPid /proc/1/status"
```

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

安装失败、模块异常或设备重启异常时，请优先检查这些日志。

---

## 卸载方法

双击：

```text
uninstall.cmd
```

卸载器会：

1. 读取上次保存的 MuMu 设备地址；
2. 允许在卸载前修改设备地址；
3. 按精确模块 id 移除本工具安装的三个框架模块（Zygisk-Next → `zygisksu`、Vector → `zygisk_vector`、官方 LSPosed → `zygisk_lsposed`），不会误删其他模块；
4. 移除 Magisk 启动项（`magisk.rc` / `magisk_init.sh`）与系统级 Magisk 兼容启动器（并恢复备份的原始 `/system/bin/magisk`）；
5. 移除 `/data/adb/magisk` 运行时与安装临时痕迹；
6. 恢复安装前备份的 KernelSU userspace（`/data/adb/ksud`）；
7. **默认卸载 Magisk 管理器 App（`com.topjohnwu.magisk`）与 KsuWebUI App（`io.github.a13e300.ksuwebui`）**。

参数：

| 参数 | 用途 |
|---|---|
| `-Force` | 跳过 "输入 YES" 确认 |

> [!NOTE]
> 卸载器**不会**自动重启设备。卸载完成后会在 MuMu 窗口手动点击“重启设备”，使模块移除与 `/system/bin/magisk` 恢复彻底生效。Magisk 管理器 App 与 KsuWebUI 在卸载时默认一并删除，无需额外参数。

---

## 风险说明

> [!WARNING]
> 本工具属于针对 MuMu Android 15 的非官方 live/manual Magisk 注入方案。
>
> 修改系统文件可能导致：
>
> - 实例无法正常启动；
> - Magisk 或模块加载失败；
> - 模拟器更新后功能失效；
> - 系统文件与 MuMu 原始状态不一致；
> - 需要通过快照恢复实例。

首次安装前必须创建并保留可用快照。

默认下载的是安装时 GitHub 标记的最新稳定版本，上游模块更新可能改变兼容性。需要固定版本时，请使用本地文件参数指定已经自行校验的安装包。

使用本工具即表示使用者已经了解相关风险，并自行承担因系统修改产生的后果。