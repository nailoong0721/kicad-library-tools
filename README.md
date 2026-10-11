# KiCad 工具套件：同事使用说明

三个 Windows 图形工具：Altium SchLib 转 KiCad 符号库并逐符号拆分、Altium PcbLib 批量转 KiCad 封装库，以及把已转换的库安全导入 KiCad 项目。

## 收到压缩包后

1. 在目标电脑安装完整的 **KiCad 10.x Windows 64 位版**。本次本机验证版本为 10.0.4；其他版本需要自行复核转换能力。PCB 转换器需要该安装自带的 bin/python.exe 和 pcbnew，不需要单独安装 Python。
2. 把整个 ZIP 解压到有写权限的普通目录，例如“文档”中的工具目录。支持中文和空格；不要直接从压缩包内启动。
3. 打开对应子目录内的 EXE。在“KiCad CLI”栏选择目标电脑自己的 kicad-cli.exe（位于 KiCad 安装的 bin 目录）。标准安装会自动查找；自定义盘符或目录请用“浏览”选择。
4. 两个转换器点击“开始转换”且输入检查通过时、导入器点击“检查并试运行”时，会保存所选路径到当前 Windows 用户的 %LOCALAPPDATA%\KiCadPortableTools\kicad-cli.txt。仅浏览选择文件不会保存。三个工具共享该设置；发给同事的包不含你的个人设置。
5. 双击根目录 Check-Environment.cmd 检查文件是否齐全，以及 CLI、KiCad Python 和 pcbnew 能否正常使用。看到 FAIL=0 表示环境探测通过；它不能替代真实库的转换复核。

| 工具目录 | 启动程序 | 用途 |
| --- | --- | --- |
| AD2KiCadSchGUI | AD2KiCadSchGUI.exe | .SchLib → 完整 .kicad_sym ＋每符号一个独立库，含符号名及 SVG 校验 |
| AD2KiCadPCBGUI | AD2KiCadPCBGUI.exe | .PcbLib → .pretty，支持批量及逐封装校验 |
| KiCadLibraryImporter | KiCadLibraryImporter.exe | 先检查试运行，再备份并导入项目 |

只分发一个工具时，要复制它的**整个子目录**，包括 EXE、全部 .ps1 和 README。三个工具运行时不依赖 Codex、Visual Studio、开发者用户目录或开发环境的 PATH。本发布包的支持基线是 Windows 10/11 64 位、Windows PowerShell 5.1 和 .NET Framework 4.8 或更高版本。目前没有 macOS/Linux 图形版本。

## 高分辨率显示

三个界面支持 Windows 逐显示器 DPI 缩放。窗口在不同缩放比例的显示器之间移动时，字体、按钮和列表重新布局；可用工作区不足时提供滚动条，以便访问全部输入框和操作按钮。请保留工具目录中的 EXE 和同名 `.exe.config` 文件，后者是高 DPI 设置的一部分；根目录环境检查会检查它是否缺失。

高缩放下不需要强行调小系统字体。先最大化窗口；若仍显示滚动条，可滚动访问底部和右侧内容。导入器的较长检查摘要自动换行。源码目录的 `Tests/Test-DpiLayout.ps1` 检查模拟逻辑工作区，`Tests/Test-NativeDpiLayout.ps1` 检查当前实体显示器的实际 DPI、跨屏移动、按钮文字和滚动可达性，两类测试不会互相替代。

## 符号库拆分输出

SchLib 转换会同时生成完整库和同目录下的单符号库文件夹。例如选择输出 Parts.kicad_sym，会额外生成 Parts_symbols 文件夹，每个顶层符号对应一个独立 .kicad_sym。多单元符号的全部单元保存在同一文件内。GUI 显示拆分目录和文件数量；完整库和拆分目录均不会覆盖已有结果。特殊字符、保留文件名和重名会安全处理，详见 AD2KiCadSchGUI/README.md。

## 路径选择规则

图形界面或脚本显式传入的路径用于本次任务。启动界面的初始路径依次取自：

1. 环境变量 KICAD_CLI；如果它失效会显示该值，便于修正，后端会明确报错。
2. 当前用户已保存、且仍有效的路径。
3. PATH 中的 kicad-cli.exe。
4. Windows 标准 Program Files 下的 KiCad/bin 或 KiCad/版本/bin（版本数字降序），以及当前用户 Programs/KiCad。

不需要配置环境变量。若已设置 KICAD_CLI，它会覆盖下次启动时的初始值；要永久换安装，可更新/移除此变量再在界面选择。更换电脑后重新选择当地安装即可，不要复制另一台电脑的个人设置文件。

## 排错与限制

- 找不到 CLI：确认选中 kicad-cli.exe 文件，而不是文件夹、kicad.exe 或 ZIP 中的文件。
- pcbnew / Python 检查失败：PCB 转换需要同一套完整 KiCad 安装。普通 Python 的 pip 包不能替代 KiCad 自带模块。
- 找不到附带脚本：重新解压整个工具目录；不能只复制 EXE。
- 权限或企业策略阻止启动：使用自己有写权限的工作目录，按公司的软件运行流程处理。工具不请求管理员权限，不修改全局 PowerShell 执行策略。
- 转换输出应选择可写的新路径；工具保留原有源文件哈希、输出不覆盖、暂存验证机制。导入器仍要求试运行，正式操作保留备份。
- KiCad 对 Altium 数据的支持并非无损迁移。分享前请用实际库检查符号、焊盘、尺寸与 3D 模型。各工具 README 中有取消和清理限制。
- 已验证路径发现、中文/空格路径、界面状态、参数传递、真实 KiCad 环境探测和自包含导入测试。SchLib 拆分功能已通过 83 项回归，并用真实 SchLib 样例在 KiCad 10.0.4 下验证整库转换、逐符号拆分、独立库重存及 SVG 导出。尚未在第二台实体电脑测试，也未完成真实 PcbLib 样本的完整转换验收；具体记录见源码目录 VERIFICATION.md。

首次使用自定义安装目录、尚未保存路径时，可在 PowerShell 中运行以下命令，把示例路径换成实际安装路径：

~~~powershell
.\Check-Environment.ps1 -KiCadCliPath 'C:\Program Files\KiCad\10.0\bin\kicad-cli.exe'
~~~

## 维护者：从源码重新生成发布包

本节适用于源码目录；同事使用发布 ZIP 无需构建。源码中 Shared 保存统一环境解析代码：C# 被编译进各 EXE，PowerShell helper 会复制进各应用目录。

在 Windows PowerShell 5.1 中，从源码根目录运行：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Release.ps1
~~~

构建脚本从系统 Windows 目录定位 .NET Framework C# 编译器，重建三个 EXE，再用白名单生成 Releases 下的新目录及 ZIP。不会打包用户设置、库样本、开发探针、测试输出或 Codex 依赖。每个发布目录有 SHA256SUMS.txt，供检查传输完整性；这些哈希不是数字签名。包名带时间与随机后缀，不覆盖旧包。

开发验证入口：Tests/Test-Environment.ps1、两个转换器目录的 Test-Portability.ps1、导入器的 Test-Core.ps1 / Test-Backend.ps1。后端测试需要显式传入当地 KiCad CLI，详细结果见源码根目录的 VERIFICATION.md。
