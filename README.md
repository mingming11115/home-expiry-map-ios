# 到期地图 iPhone App

1.1（构建 3）是 SwiftUI 原生本机版本，最低支持 iOS 17。启动、记录和地图直接在手机运行，不再加载 chatgpt.site。Bundle ID 保持为 `com.homeexpiry.map.bubblybread0945`，可覆盖更新已安装版本。

<img src="design/app-icon-v8-white-background.png" width="160" alt="到期地图图标：白底黑线小屋与蓝紫色钟面">

构建 3 使用用户选定的白色背景、蓝紫色钟面图标。图标母版和完整尺寸资源均保存在仓库中。

## 功能与数据

- 最近到期、七天概览、分类和搜索，以及按厨房、浴室等位置查看记录。
- 新增、编辑、完成、恢复、删除、完成并记录下一期；到期日期可以暂不填写。
- 相机拍摄或系统相册选图，Apple Vision 在本机提取标签文字。生产日期不会被直接作为到期日；识别到期日必须人工核对后才能保存。照片不上传、不另存副本。
- 用户主动开启本地通知后，按提前天数在当地上午 9 点提醒；最多安排最近的 60 条未来通知。已经过去的时间不补发。
- 将单条记录交给系统日历编辑器，以及 JSON 备份导出、导入。导入只添加新 ID，保留已有同 ID 记录。

记录原子保存到 App 的 Application Support/ExpiryMap/native-store.json。写入失败不会改变内存；损坏或未知版本文件会阻止覆盖。界面明确显示本机保存状态。卸载 App 会清除本机容器，应先导出备份。

**家庭云同步尚未接通，旧网页云数据不会自动迁移。** 家庭名称和成员仅为本机标签。本版本没有账号登录、邀请或共享服务，尚未成为可公开分发的完整家庭协作产品。

## 构建与安装

使用 Xcode 及有效的 Apple 开发签名；首次运行需在 Xcode 中登录开发账号。工程中保留当前团队设置，其他账号可在 Xcode 修改，或在下列脚本后传入 `DEVELOPMENT_TEAM=YOUR_TEAM_ID`。签名私钥、描述文件和构建产物不提交到 Git。

在仓库根目录执行：

```sh
bash scripts/test.sh
bash scripts/package.sh
```

打包脚本先从选定母版生成 8 个图标尺寸，再创建 `dist/ExpiryMap.xcarchive`，最后将开发安装包导出到 `dist/export/ExpiryMap.ipa`。`scripts/ExportOptions.plist` 使用 `debugging` 导出方式，包只能用于描述文件允许的设备；它不是 App Store 或 TestFlight 分发包。`dist/` 保留在本机并被 Git 忽略。

只更新图标资源可执行 `bash scripts/generate-app-icons.sh`。

在 Xcode 打开 `ExpiryMap.xcodeproj`，选择签名团队和已连接 iPhone，运行 `ExpiryMap` scheme。命令行示例：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project ExpiryMap.xcodeproj -scheme ExpiryMap -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build-native -allowProvisioningUpdates build
xcrun devicectl device install app --device YOUR_DEVICE_ID build-native/Build/Products/Release-iphoneos/ExpiryMap.app
xcrun devicectl device process launch --device YOUR_DEVICE_ID com.homeexpiry.map.bubblybread0945
```

2026-10-04：Release 构建和系统签名校验通过，已在连接的 iPhone 16 Pro（iOS 26.5.2）覆盖安装并成功启动。设备应用清单确认版本 1.1、构建 2。当前个人团队描述文件到期时间为 **2026-10-10 21:55:22（北京时间）**；到期需重新签名安装。尚未提交 App Store 或 TestFlight。

2026-10-04 构建 3：新图标 8 个尺寸及无透明通道检查通过；核心逻辑检查通过；Release archive 与 IPA 导出成功。安装包中的版本为 1.1（3），图标名为 AppIcon。当前签名仍于上述时间到期。此记录不代表构建 3 已更新到真机。

## 验证记录

- 数据存储 10 组检查全部通过，覆盖保存重开、写失败、损坏保护、完成续期、恢复删除、备份合并和无效备份无部分写入；上海和洛杉矶两个时区均通过。
- 标签解析 55 项断言通过，覆盖明确中英文到期日期、生产日期、歧义、日期边界与无效输入。
- 提醒规划 9 组、调度 10 组检查在两个时区通过，包含夏令时、60 条上限、权限拒绝、并发更新、损坏存档不删除已有通知。
- 最终 Debug 模拟器构建和 Release 真机构建通过。
- iPhone 18 Pro 模拟器实际完成新增、退出重启后保留、厨房筛选、编辑、完成和恢复；覆盖更新后的记录仍然保留。
- 真机已验证安装和启动。尚未完成真机相机拍摄、通知实际送达、日历保存和系统文件选择器的完整交互验证。Device Hub 在继续选图交互时连接失效，不能据此声称选图流程已经验证通过。

`Tests/NativeStoreTests.swift`、`Tests/LabelParserTests.swift` 和 `Tests/ReminderSchedulerTests.swift` 为独立 Swift 测试入口。提醒调度测试需编译标记 `-D REMINDER_SCHEDULER_TESTS`，并与 NativeModel、NativeStore、ReminderPlan、ReminderScheduler 一起编译。

## 源码结构

入口为 `ExpiryMapApp.swift` → `NativeRootView`。当前 target 仅包含 NativeHome、NativeEditor、NativeSettings、NativeModel、NativeStore、LabelParser、LabelScanner、ReminderPlan、ReminderScheduler 及入口文件。

旧 AppView、WebBrowser、NavigationRules、CalendarDraft 与其测试保留为历史参考，已从 target 移除。旧版依赖 Site 页面，用户遇到 Cloudflare 入口拦截；原生版通过移除核心功能对该页面的依赖解决可用性问题，没有更改网站安全策略。
