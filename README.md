# 电池管家 for macOS

原生 Mac 菜单栏电池养护工具，提供中文仪表盘和设置窗口。SwiftUI 负责界面，AppKit 提供菜单栏和设置窗口，IOKit 提供真实电池数据。仅在用户松手完成上限拖动、点击加减或其他充电操作后，更改系统充电上限。应用初次启动只读取当前充电管理状态。

## 构建

需要 macOS、Xcode／Command Line Tools、Swift 5.9 或更高版本。当前应用在 Apple Silicon macOS 27.0.1、Swift 6.4 上通过验证。

```sh
./build.sh
open ../电池管家.app
```

默认构建缓存在本目录 `.build`。可通过 `IA_BUILD_DIR` 环境变量指定其他构建缓存目录。构建脚本生成相邻目录的 `电池管家.app`，并进行本地 ad-hoc 签名。没有联网依赖。

```sh
../电池管家.app/Contents/MacOS/BatteryCare --self-test
../电池管家.app/Contents/MacOS/BatteryCare --render-qa /tmp/battery-care-render
../电池管家.app/Contents/MacOS/BatteryCare --render-power-qa /tmp/battery-care-power-render
../电池管家.app/Contents/MacOS/BatteryCare --render-care-qa /tmp/battery-care-care-render
../电池管家.app/Contents/MacOS/BatteryCare --render-protection-qa /tmp/battery-care-protection-render
```

`--self-test` 读取真实数据，检查范围、无效充电上限的拒绝、菜单面板的全屏窗口配置及多显示器定位，不提交有效充电写入。`--render-qa` 渲染应用自身界面，绕过桌面屏幕捕捉；毛玻璃背景、原生滚动和控件使用等效静态绘制以便检查布局。正常运行时保留原生控件。`--background` 仅启动菜单栏；`--preview` 明确启用隔离的演示数据，普通启动始终读取本机数据。

## 代码结构

- `AppIdentity.swift`：应用显示名称；系统标识和偏好保持稳定，改名后保留原有设置。
- `Application.swift`：应用生命周期、状态栏、设置窗口和只读检查。
- `DashboardPanel.swift`：不激活主应用的菜单浮层，支持其他应用的全屏空间、多显示器定位及外部点击／Esc 收起。
- `AppModel.swift`：持久化偏好、通知、登录项、充电控制与临时上限恢复。
- `BatteryMonitor.swift`：后台 IOKit 采样、功率历史、固定参数进程 CPU 查询与应用图标。
- `BatteryTemperature.swift`：区分摄氏度与百分之一摄氏度，校验实时温度并过滤缺失／异常值。
- `StatusReadout.swift`：电池内部闪电标志、充电状态绿色图标与文字绘制；未充电图标也使用相同绿色，非充电文字保留系统自动对比度。
- `DesignSystem.swift`：截图中的颜色、材质、卡片、图标、开关、分段控件。
- `SettingsView.swift`：六个设置页面。
- `DashboardView.swift`：实时仪表盘、快捷养护、电池详情与控制能力说明。
- `PowerFlowDiagram.swift`：适配器、系统使用、电池三路功率；充电与电池供电时显示对应方向，未提供的数值保留为空。
- `QuickCareCard.swift`、`QuickCareState.swift`：常用上限、临时充满、恢复系统管理；按真实系统状态标记当前选择，说明与反馈就近显示。
- `ProtectionCard.swift`、`ProtectionState.swift`：实时温度、系统温控、可选高温提醒、实际系统上限和睡眠充电能力，区分未知与关闭状态。
- `TemperatureReminderGate.swift`、`TemperatureReminderChecks.swift`：纯状态温度提醒门控及行为检查；无通知、权限或硬件调用。
- `RenderingChecks.swift`：开发阶段组件渲染。
- `ChargeLimitControl.swift`、`ChargeLimitOptions.swift`：系统支持值、拖动松手提交、加减与无障碍调整，界面草稿与实际回读分开。
- `Native/NativeChargeBridge.m`：可选系统充电上限桥接。

## 实际能力和边界

菜单栏与设置使用实际电量、电源状态、循环次数、容量估算及系统可提供的实时功率。温度或其他传感器缺失时为空。应用排序百分比是 `ps` 的 CPU 使用率参考，不是耗电份额。

温度读取覆盖 IOPS 摄氏度、`AppleSmartBatteryPack.BatteryData.Temperature` 和旧版 `AppleSmartBattery.Temperature`；Registry 数值按百分之一摄氏度转换。macOS 27 的独立电池包节点读取路径已通过实机验证。没有用历史平均值补出实时温度，也没有增加 SMC 调用。新节点与单位经过实机只读核对，并参考 [SystemInfoKit 的 macOS 27 读取路径](https://github.com/Kyome22/SystemInfoKit/blob/main/Sources/SystemInfoKit/Repositories/BatteryRepository.swift) 和 [Stats 的温度读取实现](https://github.com/exelban/stats/blob/master/Modules/Battery/readers.swift)。

实时功率分流上方展示适配器和系统使用，下方展示电池支路。充电时箭头朝向电池；未接电源时，电池支路朝向系统。接电但未充电时，不推测未验证的电池功率方向。三路功率独立读取，缺失值为“—”，不使用相减方式补出缺失的功率。`--render-power-qa` 单独渲染这一组件的当前实测、充电、电池供电、读数缺失和宽窗口布局，示意状态不改变硬件。

快捷养护位于实时功率分流下方。80%／90% 按钮直接应用系统上限，选中标记依据系统回读，滑块松手或加减按钮也会立即提交，并以系统回读显示实际上限。未接电源时仍可设置上限；临时 100% 需已接电、电量低于 100% 且能读取原设置。临时模式期间其他上限与系统管理入口禁用，保留“恢复原设置”按钮；重复启动不会覆盖恢复点，恢复失败允许重试，读取失败不会清除待恢复记录。已确认的外部充电设置变更会结束临时跟踪，避免覆盖外部选择。暂停、主动放电和校准收进功能说明。`--render-care-qa` 渲染当前实测、80% 已应用、临时充满、未接电、读数未知、不支持控制等状态，所有按钮使用空回调；`--self-test` 另核对开始条件和临时模式的共享入口保护，不写入有效硬件设置。

菜单浮层使用预先配置的非激活 `NSPanel`，通过 macOS 13 起的 [`canJoinAllApplications`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications) 进入其他应用的全屏空间；显示时不激活主应用。浮层高度和位置按点击时状态栏按钮所在的显示器计算。鼠标外部点击、Esc、切换空间或打开设置会收起浮层；鼠标全局监测不申请辅助功能权限。

菜单与设置页均可自由拖动滑块，松手后自动应用，或使用加减按钮逐档调整；不用再点击“应用”。选择值作为界面草稿，不提前写入已应用的设置；界面分别显示目标和系统当前回读，失败或未知状态有就近提示。可用值从系统接口读取，UI 与写入校验共用该列表；本机目前为 80–100% 的 5% 步进，不能承诺系统未公布的任意整数或低于 80% 的实际上限。本机通过 80% 写入／回读和恢复默认 100% 的测试。桥接加载固定的系统 PowerUI 框架路径，检查方法签名、当前支持值、返回错误，捕获 Objective-C 异常；私有接口会随系统变化，失效时提供系统设置入口。没有 root helper、SMC 写入或管理员授权流程。此工程的桥接是原创代码，未复制其他项目的实现。

临时上限 100% 记录原来的上限和启用状态，达到 100% 后恢复。正常退出也尝试恢复；失败保留待恢复记录。异常关闭时上限可能暂留在 100%，下次打开程序恢复跟踪；用户也可在系统电池设置中调整。优化充电仍决定具体充电时机。

当前系统不提供可用的直接暂停／强制放电／睡眠暂停路径，界面诚实显示为未支持。容量校准与高温保护由系统维护。提醒只在程序运行时生效，权限在用户开启功能时请求。登录项只在用户切换开关时注册。

自动保护采用逐项状态显示。高温提醒是独立的通知功能，默认关闭，提醒值默认 40°C，用户可在“计划与自动化”中设为 35–55°C；这是自定提醒值，不是系统温控阈值。仅使用有效且不超过 120 秒的温度，连续两次不同时间的采样达到提醒值才提交通知。同一次升温成功提醒一次；连续两次降至提醒值以下 3°C 后重新监测，成功通知至少相隔 10 分钟，最近成功时间保存在本机。发送失败至少间隔 60 秒重试，关闭提醒或修改阈值会作废旧候选，未知数据不当作降温。用户开启时才请求首次权限；提交前确认权限，区分横幅、通知中心和声音能力。应用退出或 Mac 睡眠时不持续监测，提醒不更改充电和风扇。系统上限根据实际回读区分已应用、系统默认、临时 100% 和状态待确认。`--render-protection-qa` 用空回调核对当前读数、提醒开启、高温、无读数、权限不足、静默通知、临时恢复未知、过期、发送失败和宽布局。全部组件渲染通过仅渲染模式完成，不提交提醒或充电写入。

公开 API 依据 [Apple IOPowerSources](https://developer.apple.com/documentation/iokit/iopowersources_h) 和 [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)。系统充电上限行为见 [Apple Support](https://support.apple.com/en-us/102338)，当前私有充电路径的兼容性研究参考 [batt 的 PowerUI 工程](https://github.com/charlie0129/batt/tree/master/pkg/powerui) 与其 [macOS 27 兼容性说明](https://github.com/charlie0129/batt#macos-27-firmware-with-gated-charge-keys-adapter-mode)。
