# AD2KiCadPCBGUI

双击 `AD2KiCadPCBGUI.exe` 即可批量把 Altium Designer `.PcbLib` 转换为 KiCad `.pretty` 封装库。程序可以一次选择多个文件、选择一个目录，或直接拖入文件和目录。

程序支持选择本机安装的 `kicad-cli.exe`，不依赖固定盘符、用户名或 Codex 目录。请把完整工具目录复制给同事，并在目标电脑安装完整 KiCad。

## 目标电脑与运行文件

- Windows 10/11 64 位、Windows PowerShell 5.1，以及 .NET Framework 4.8 或更高版本。不需要安装开发 SDK。
- 完整 KiCad 安装：选中的 `bin` 目录必须同时有 `kicad-cli.exe` 和 KiCad 自带 `python.exe`，后者须能导入该安装的 `pcbnew`。仅复制 CLI 或另装普通 Python 不足以转换 PcbLib；程序会校验 CLI / pcbnew 版本和模块来源。
- 源库可读、输出父目录可写，且有足够空间保存暂存库。以普通用户运行即可。当前转换逻辑以 KiCad 10 为验证基线；使用其他版本前应先用实际库验证导入和结构检查。

分发时，下列文件必须放在同一目录：

```text
AD2KiCadPCBGUI.exe
AD2KiCadPCB.ps1
KiCadEnvironment.ps1
README.md
```

`probe_*.py`、`adaptive_convert.py`、`slice_worker.py` 和 `log` 是开发诊断资料，GUI/后端不加载它们，不需要分发。不要只分享 EXE。

## 使用

1. 检查“KiCad CLI”路径；可直接编辑或点击“浏览”，选择本机完整 KiCad 安装中的 `bin\kicad-cli.exe`。
2. 点击“添加文件”或“添加目录”，也可以拖入 `.PcbLib`。
3. 默认在每个源文件旁生成同名 `.pretty`；勾选“统一输出到”可集中输出到一个目录。
4. 处理完队列中的路径冲突后，点击“开始转换”。当前路径会校验并保存，执行期间不能更改设置。
5. 在“结果详情”“名称映射”和“运行日志”中检查结果；可直接打开输出库或 JSON 报告。

首次路径按 `KICAD_CLI` 环境变量、当前用户保存的有效路径、`PATH`、标准 KiCad 安装目录的顺序查找；检测结果只是候选，请确认版本。开始转换时的界面选择优先。当前用户设置保存到 `%LOCALAPPDATA%\KiCadPortableTools\kicad-cli.txt`，与另外两个工具共享，不写入工具目录，也不要把开发电脑的设置复制给同事。

命令行也可使用；`-KicadCliPath` 可省略，使用同样的自动查找逻辑。明确指定时必须是完整的 `kicad-cli.exe` 绝对路径：

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\AD2KiCadPCB.ps1 -KicadCliPath 'C:\Program Files\KiCad\10.0\bin\kicad-cli.exe' -SourcePcbLib 'C:\Libraries\Parts.PcbLib'
```

示例路径须换成目标电脑的实际安装位置。

## 校验与安全限制

程序不会覆盖已有文件或目录。每个库先写入临时同级目录，完成逐封装重载与结构指纹校验后才发布最终 `.pretty`。单项失败不会撤销已完成项目，批次会继续处理其余有效项目。结构校验允许 KiCad 导入器在坐标量化时产生不超过 1 µm 的位置误差，但仍会拦截真实的几何、焊盘、图形、字段和模型变化。

强制取消会终止当前 PowerShell/KiCad 进程树。若进程在脚本清理前被终止，输出目录旁可能保留名称含 `.ad2kicadpcb-` 的本次暂存目录；程序不会猜测并递归删除它。

只运行可信来源的工具包和 KiCad 可执行文件。脚本临时执行策略仅对当前子进程生效，不修改系统执行策略；企业组策略、AppLocker 或安全软件仍可能禁止运行，请由本机管理员按组织规则处理。下载文件被阻止时应先确认来源，再解除对应文件的阻止，不应全局关闭安全防护。外部 3D 模型引用可能仍指向原电脑路径；结构校验不代表所有外部模型文件已随库分发。

转换不是对 Altium 专有数据的无损迁移。KiCad 会导入其支持的封装几何、焊盘、钻孔、图形和 3D 模型引用。含 `kicad-embed://` 的内嵌模型会随封装写入 `.kicad_mod` 的 `embedded_files`，并保留原始模型引用。为规避 KiCad 原生写入器在连续处理特定封装序列时的崩溃，程序会按小批次启动隔离的 KiCad worker；失败批次会自动二分重试，最终必要时降到单个封装，因此不会因为内嵌模型而主动停止整个库的转换。

## 重新构建

保留源码仓库的目录结构，确保上级 `Shared` 目录含 `KiCadEnvironment.cs` 和 `KiCadEnvironment.ps1`。构建脚本从当前 Windows 系统目录寻找 .NET Framework C# 编译器，编译共享路径逻辑，并把环境脚本复制到本目录。

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Build.ps1
```
