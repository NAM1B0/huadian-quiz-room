# 华电公共题库练习室 v1.0.4 · iOS 26+

将 Windows v1.0.4 的刷题逻辑移植到原生 iPhone 应用，内置 563 道题与原始 PDF，离线使用。

- 原生底部导航、单手翻题、分组题号面板；选项整行可点，支持系统大字体、深色模式和横竖屏。
- 练习答案预览、即时判分、按规则自动下一题；多选仅在普通练习中选全且正确时自动跳转。
- 考试按部分打乱、前台计时、断点续做、全部作答后交卷并锁定答案。
- 练习按题型与部分汇总；考试记录可编辑勾选删除，删除前自动备份。
- 两类错题独立保存，分别设置“答对后自动移出”。
- 导出及恢复 iOS 备份，也可导入 Windows 版导出的 SQLite 学习备份。两端各自保存进度，不自动同步。

下载 `huadian-quiz-room-v1.0.4-ios26.ipa`，通过 **AltStore Classic / AltServer** 等工具用自己的 Apple 账户重签安装。此包要求 **iOS 26.0 或更新版本、iPhone**。安装及刷新步骤见 [iOS 使用说明](https://github.com/NAM1B0/huadian-quiz-room/blob/v1.0.4-ios/ios/README.md)。

使用 Xcode 26.6 编译，11 项逻辑测试和 5 项原生 UI 测试全部通过；测试设备为 iPhone 13 Pro 模拟器、iOS 26.5。详见 [构建与测试记录](https://github.com/NAM1B0/huadian-quiz-room/actions/runs/40864052937) 和 [验证说明](https://github.com/NAM1B0/huadian-quiz-room/blob/v1.0.4-ios/ios/TESTING.md)。尚未在实体 iPhone 上验证侧载。Windows v1.0.4 下载包保持原样。

IPA 约 1.6 MB。已验证 arm64 真机架构、iOS 26.0 最低版本、563 道题与 PDF 完整性；中文资源名采用标准 ZIP UTF-8 标记，包内全部文件与通过测试的 Xcode 归档逐字节一致。
