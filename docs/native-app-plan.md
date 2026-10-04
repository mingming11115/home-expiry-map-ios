# 到期地图本机版本：设计与实施

## 目标与边界

用户要求直接使用 iPhone App，现有 WKWebView 因 chatgpt.site 入口拦截不可用。保留现有网页产品的分类、房间、日期、完成记录、参考配色与拍照工作流，将手机核心功能改为 SwiftUI 原生界面、本机持久化、Apple Vision 本机 OCR 和本地通知。使用原 Bundle ID 更新已安装 App。

本次安装版无需登录或访问网站即可新增、编辑、查询、完成、恢复、删除记录，按房间查看，拍照/选图提取标签，确认后保存，以及管理本地提醒和导出/导入备份。历史云数据不自动迁移，家庭共享尚未接通，页面明确说明“仅保存在这台 iPhone，尚未与家人同步”。不能展示假的邀请或同步成功。

UI 采用用户参考中的淡蓝紫背景、大圆角卡片、黑色主按钮，配橙色和浅紫分类。底部为“最近 / 地图 / 我的家”。首屏为空时真实显示 0 件与添加入口，不混入示例数据。

## 文件与接口

- `NativeModel.swift`：Foundation Codable 数据、分类和房间、`LocalDay` 日期工具。
- `NativeStore.swift`：MainActor ObservableObject，原子文件保存，写失败不改变内存，损坏文件保护，JSON 备份导入合并。
- `LabelScanner.swift`：标签日期候选解析和 Vision OCR（日期必须人工确认），SwiftUI 拍照/相册组件。
- `ReminderScheduler.swift`：纯提醒规划与 UserNotifications 权限/调度；最多 60 条未来提醒，权限由用户主动开启。
- `NativeHome.swift`、`NativeEditor.swift`、`NativeSettings.swift`：地图、列表、编辑详情、完成历史、备份与明确的共享状态。
- `ExpiryMapApp.swift` 改为原生入口；旧 WebBrowser 文件留作历史参考，不加入新构建。

## 数据契约

`ExpiryRecord` 包含 `id:UUID`, `name:String`, `kind:ItemKind`, `room:HomeRoom`, `location:String`, `dueDate:String?`（公历 YYYY-MM-DD）, `leadDays:Int`, `notes:String`, `assignee:String`, `createdAt:Date`, `completedAt:Date?`。`isCompleted` 为计算属性。

`ItemKind` 为 food/medicine/care/service/warranty/maintenance，`HomeRoom` 为 kitchen/bath/storage/living/bedroom/service/other。两者提供 `title`、`symbol`、`id`。

`LocalDay.string(from:)`, `LocalDay.date(from:) -> Date?`, `LocalDay.daysUntil(_:now:) -> Int?`, `LocalDay.adding(_:to:) -> String?` 使用公历和当前时区，严格验证 1900—2200 年日期。

`NativeStore` 提供 items/familyName/members/loadError，`upsert(_:)`, `complete(id:nextDue:)`, `restore(id:)`, `delete(id:)`, `renameFamily(_:)`, `setMembers(_:)` 均 throws；`exportData() throws -> Data`；`importData(_:) throws -> Int` 保留本机同 ID 数据、仅合并新记录，失败无部分写入。

## 实施顺序

- [x] 数据与保存：日期、保存重开、损坏保护、完成续期和备份合并检查通过。
- [x] 拍照实现：标签解析 55 项断言通过，本机 Vision OCR、相机和相册组件已集成。
- [x] 界面与提醒：原生页面完成；提醒规划 9 组和调度 10 组检查通过。
- [x] 集成构建与安装：Debug/Release 构建成功，模拟器新增/重开/编辑/完成/恢复/地图已检查；真机安装启动并确认 1.1（2）。
- [ ] 完整设备交互验证：真机相机、通知送达、日历保存和系统备份文件选择器尚未实测。
- [x] 更新交付记录：README 明确验证范围、本机数据、共享边界和当前签名到期时间。

## 执行说明

原生实现阶段在独立目录工作，不修改 synced sources/ 或现有 Site 仓库。2026-10-04 用户选定白底蓝紫钟面图标后，要求打包并推送 Git；原生目录因此初始化为独立仓库，构建 3 接入图标并导出开发 IPA。构建缓存、签名材料、安装包和未选用的设计草稿不进入源码仓库。联网家庭协作仍是未完成的产品能力，不能将本机版本描述为已完成面向其他家庭的正式产品。
