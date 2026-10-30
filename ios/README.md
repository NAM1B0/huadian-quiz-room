# 华电公共题库练习室 · iOS

移植自 Windows v1.0.4，原生 SwiftUI，最低 iOS 26.0，面向 iPhone。题库和原始 PDF 均随应用内置，离线使用，无需账号或手机上的 Python 服务。与 Windows v1.0.4 修复包保持相同判分规则。

## 安装

从 [iOS v1.0.4 修订版下载页](https://github.com/NAM1B0/huadian-quiz-room/releases/tag/v1.0.4-ios.3) 获取 `huadian-quiz-room-v1.0.4-ios26-build10403.ipa`。这是 arm64 iOS 应用，未使用开发者证书签名，需要用户通过 Sideloadly / AltStore Classic / AltServer 等工具自行重签，系统须为 iOS 26 或更新版本。

构建 10403 修复多选题过早判分：普通练习全选正确时或点击“下一题”才检查；两类错题多选只在点击“下一题”时检查。第一次点击显示对错并停留，第二次才翻题。考试错题的单选、判断答对才自动下一题，与练习错题一致。继续包含上一构建的 PDF 原文阅读修复。

版本号仍为 1.0.4，仅内部构建号变为 10403。更新前先导出学习记录，再用原来的签名账号和 App ID 覆盖安装；可在“数据 → 版本”核对 `1.0.4 (10403)`。

1. 在电脑按 [AltStore Classic 官方教程](https://faq.altstore.io/altstore-classic/altserver) 安装 AltServer，并在 iPhone 上安装 AltStore Classic。
2. 将 IPA 保存到 iPhone 的“文件”应用，在 AltStore Classic 的 My Apps 中点 `+` 选择它，使用自己的 Apple 账户完成侧载。
3. 按 AltStore 提示启用开发者模式、信任签名并定期刷新。免费账户通常需要每 7 天刷新，且有同时侧载数量限制，详见 [AltStore 官方说明](https://faq.altstore.io/altstore-classic/your-altstore)。这里指 Classic，不是 AltStore PAL。
4. 更新前从“数据 → 导出学习记录”备份。使用同一账户、同一签名 App ID 覆盖安装有助于保留数据；删除应用会删除其本机数据，签名工具改变 App ID 也可能安装成另一个应用。

## 手机适配

- 原生导航和底部标签，进入题目后隐藏标签栏，把空间留给题目。
- 底部固定“上一题 / 题号 / 下一题”；按题库部分分组的题号在弹出面板中查看，可输入原题号筛选。
- 触控目标至少 44 pt，选项整行可点；题干、选项完整换行，支持系统大字体、深色模式、横竖屏与安全区域。
- 答案预览开关每次进入默认关闭；浏览答案不写作答记录。
- 原题号不变；漏选灰色、错选红色、答对绿色，同时以符号与文字标明状态。考试交卷前仅显示蓝色已答；尚未检查的多选显示蓝色待检查。

| 场景 | 单选、判断 | 多选 |
| --- | --- | --- |
| 普通练习 | 选对自动下一题 | 全部选对自动下一题 |
| 考试交卷前 | 选择并保存后自动下一题 | 手动下一题 |
| 练习错题 | 选对自动下一题，答错停留 | 下一题检查并停留，再点翻题 |
| 考试错题 | 选对自动下一题，答错停留 | 下一题检查并停留，再点翻题 |

每次自动下一题保留短暂停顿供查看反馈，最后一题不会自动交卷。手动导航、进入后台会取消尚未执行的自动跳转。考试只累计在前台答题时的时间，离开答题页或进入后台暂停。

## 记录与备份

普通练习按最新检查结果统计，待检查多选不计入已练习；显示每种题型及其六个部分的已练习数、答对数、正确率，不保存逐次操作日志。考试可按场次编辑删除，删除前自动备份；对应考试错题随该场考试删除。其余 v1.0.4 规则一致。

数据以带版本和题库标识的 JSON 原子写入应用沙盒，关闭后保留。两类错题的复习结果独立于原始答案；“答对后自动移出”分别设置，默认关闭。多选即使全选正确，在显式检查前也不会自动移出。

“数据 → 导入备份”可读取 iOS 导出的 JSON，或电脑版“数据与备份”导出的 SQLite。导入会先校验、提示替换，再备份手机当前数据。手机与电脑不自动同步；iOS 导出的 JSON 不能直接导回原 Windows v1.0.4。旧电脑版的逐次事件日志不导入，最新练习答案、考试与错题记录保留。

## 构建与验证

需要 macOS、Xcode 26 或更新版本以及 iOS 26+ SDK。在 Windows 上不能直接编译 iOS 原生二进制。

```sh
python3 ios/tools/generate_project.py
open ios/HuadianQuiz.xcodeproj
```

项目包含应用、单元测试与原生 UI 测试，不使用第三方依赖。应用标识为 `io.github.nam1b0.huadianquiz`，版本 1.0.4，构建号 10403。生成项目时，会从仓库原 PDF 生成 `ios/Resources/question-bank.pdf`；这个派生副本不纳入 Git。真机开发可在 Xcode 选择自己的 Team；CI 使用 `CODE_SIGNING_ALLOWED=NO`。

GitHub Actions 的 `iOS 26 build and phone checks` 工作流在 macOS 上创建 iPhone 13 Pro 模拟器，执行数据逻辑与 UI 测试、导出原生截图，最后归档 arm64 真机应用并生成 IPA、SHA-256 和构建信息。该流程仅在编译及所选测试成功后上传 IPA。正常推送执行完整 UI 测试；手动的 review_only 选项仅用于在应用代码未变、完整回归已执行后补测多选错题，不能独立当作全套 UI 验证。另有手动工作流 `iOS device package (manual)` 用于独立生成候选包，不代替手机界面测试。模拟器验证不能替代实体 iPhone 上的侧载和使用验证。

构建 10403 通过 18 项单元测试与 10 项原生 UI 场景（完整回归与定向补测，应用代码一致），详见 [构建 10403 验证记录](TESTING-10403.md)。此前记录保留在 [构建 10402](TESTING-10402.md) 和 [构建 10401](TESTING.md)。当前 IPA 的所有包内路径均为 ASCII，PDF 内容与原文逐字节一致。可自行核验安装包：

```sh
python3 ios/tools/verify_ipa.py path/to/huadian-quiz-room-v1.0.4-ios26-build10403.ipa --build 10403
```

源码许可沿用仓库 LICENSE；题库与 PDF 的权利归原权利人所有。
