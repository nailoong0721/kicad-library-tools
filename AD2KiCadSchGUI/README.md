# AD2KiCadSchGUI

将 Altium `.SchLib` 转换为 KiCad `.kicad_sym`，同时自动将库中的每个符号导出为独立的 `.kicad_sym`，供 Windows 10/11 电脑本地使用。无需安装 Codex、Python、Visual Studio 或全局 skill。

## 同事电脑需要准备什么

- Windows 10/11 64 位，启用 .NET Framework 4.8 或更高版本和系统自带 Windows PowerShell 5.1。
- 安装带有 `kicad-cli.exe` 的 KiCad；建议 KiCad 10。所选版本必须支持 Altium SchLib 导入、符号库二次保存及 SVG 导出。
- 解压整个工具目录后再运行，不要在压缩包内直接打开 EXE。输入文件应可读，输出目录应可写；程序不要求管理员权限。公司策略若禁止 PowerShell 脚本或未签名程序，请联系管理员按公司要求部署。

发布或移动软件时，请将以下文件放在**同一目录**：

```text
AD2KiCadSchGUI.exe
AD2KiCadSch.ps1
KiCadEnvironment.ps1
README.md
```

KiCad 不随本工具分发，需要在每台电脑上单独安装。

## 使用与 KiCad 路径配置

双击 `AD2KiCadSchGUI.exe`，选择 Altium `.SchLib` 源文件、新的 `.kicad_sym` 输出路径以及本机的 `kicad-cli.exe`，然后点击“开始转换”。也可以把一个 `.SchLib` 文件拖到窗口中。KiCad CLI 输入框可以编辑，也可以点击“浏览...”选择文件，例如安装目录 `bin` 下的 `kicad-cli.exe`。任务运行时配置不可修改。

首次打开会依次检查 `KICAD_CLI` 环境变量、当前用户已保存且有效的路径、`PATH`、Program Files 等标准 KiCad 安装目录（版本降序）以及当前用户的 Programs 目录。未找到时，手动浏览选择即可，无需把 KiCad 安装在指定盘符。已失效的保存路径会被略过；错误的 `KICAD_CLI` 会显示在输入框供修改。

点击“开始转换”且所有输入检查通过后，路径保存在 `%LOCALAPPDATA%\KiCadPortableTools\kicad-cli.txt`，同一用户的工具共用此配置；移动程序不会带走其他电脑的个人配置。当前选择会显式传给本次转换。若设置了 `KICAD_CLI`，它仍会优先影响下次打开时的初始值。

也可使用附带脚本，显式路径优先级最高：

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\AD2KiCadSch.ps1 -SourceSchLib 'C:\Libraries\Parts.SchLib' -OutputKicadSym 'C:\Libraries\Parts.kicad_sym' -KicadCliPath 'C:\Program Files\KiCad\10.0\bin\kicad-cli.exe'
```

脚本省略 `-KicadCliPath` 时使用同样的自动查找规则；省略 `-OutputKicadSym` 时使用源文件旁的同名 `.kicad_sym`。脚本不会改写已保存的 GUI 配置。

## 完整符号库与单符号库

每次转换都保留指定的完整符号库，并在它旁边自动创建 `<输出文件名（不含扩展名）>_symbols` 目录，无需额外设置。GUI 结果显示单符号目录与文件数量，日志也会记录自动生成的目标目录。

例如输出选择 `C:\Libraries\Parts.kicad_sym`，结果布局如下：

```text
C:\Libraries\
  Parts.kicad_sym           完整符号库
  Parts_symbols\
    Resistor.kicad_sym      仅包含 Resistor 符号
    DualOpAmp.kicad_sym     仅包含 DualOpAmp 符号及其全部单元
    ...
```

按顶层符号拆分，多单元符号的全部单元保留在同一文件，不把各单元拆成不同符号。每个文件都是可单独添加到 KiCad 符号库表的 `.kicad_sym` 库。

文件名优先使用符号名；不适合 Windows 文件名的字符、保留设备名（如 `CON`、`NUL`）、末尾空格或点会进行安全处理。过长的名称会截短，大小写不敏感的同名或处理后重名会增加后缀区分。该处理仅改变文件名，不改变库内符号名。

完整库路径和单符号目录必须都不存在；同名文件占用目录位置也会拒绝。需要重新转换时，请选择一个新的输出文件名，或自行整理已有结果。程序不会覆盖或合并已有输出。

## 转换校验与限制

程序通过同目录脚本调用所选 KiCad CLI，从源文件副本转换，执行 KiCad 二次保存、比较顶层符号名、渲染全库 SVG，并导出单符号库、复核源文件哈希。校验完成后才发布结果：先发布单符号目录，最后发布完整库作为完成标志。已有输出不会被覆盖。

强制取消会终止本次 PowerShell/KiCad 进程树。若进程在脚本清理前被终止，输出目录旁可能保留名称含 `.ad2kicadsch-` 的本次暂存目录；若恰在两个目标发布之间取消，也可能仅留下单符号目录。完整库与单符号目录均生成才视为完成。程序不会猜测并递归删除目录。

转换不是无损迁移。KiCad 10 可能忽略 Altium IEEE 图形、嵌入图片和部分实现或参数记录，并可能规范化字体、颜色、线宽、名称和引脚显示属性。校验不能保证电气含义或图形完全等价，请在 KiCad 中复核转换结果。不同 KiCad 版本的支持范围可能不同；若 CLI 报不支持相关命令，请选择合适版本。此版本只支持 Windows，不是 macOS/Linux 应用。

## 从源码重新构建

在完整源码目录中保留同级 `Shared` 目录，然后运行：

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Build.ps1
```

构建脚本使用当前 Windows 系统目录中的 .NET Framework C# 编译器，先检查 Framework64，再检查 Framework；同时编译 `..\Shared\KiCadEnvironment.cs`，并把 `..\Shared\KiCadEnvironment.ps1` 复制到本工具目录。普通使用者只需前述运行文件，无需源码或 `Shared` 目录。

## 便携性自检（维护者）

在源码目录运行 `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Test-Portability.ps1`。该测试编译明确标记的模拟 CLI，检查中文/空格路径、移动后的目录、显式 CLI 选择、工作期间设置锁定、源文件保留、已有输出拒绝覆盖和失败时不发布输出，同时验证受污染的父进程 PSModulePath 不影响 Windows PowerShell 子进程。拆分回归覆盖多单元、引脚与字符串内容完整保留、库元数据、特殊字符、保留名、大小写冲突、超长名称，以及解析/继承/渲染失败时不发布部分结果。它不会读取或修改当前用户保存的 CLI 配置，也不会自动执行已安装的 KiCad。

测试证据保留在本目录 `test-runs`，不要把测试目录分发给同事。2026-09-29 已在 Windows PowerShell 5.1 下完成模拟回归（83 项通过，0 项失败），并用真实 KiCad 10.0.4 完成以下验证：

- 官方 KiCad 源码镜像的 `qa/data/eeschema/plugins/altium/issue22943/mounting_holes.SchLib`：完整转换生成含 2 个符号的总库及 2 个独立库；每个独立库均可再次重存并导出非空 SVG，源文件哈希不变。样本 git blob 为 `6b5c6f8d04804302c4441ba944942d3f89593a01`，来源与许可证保存在 `test-runs/format-review-inheritance/official-qa-d385ec5a`。
- 原生多单元样例：双单元、4 引脚的 `DualGate` 和单单元、2 引脚的 `Resistor`，拆分后逐个重存与 SVG 导出成功，完整符号块保持一致。

真实测试的复现脚本为 `test-runs/format-review-inheritance/Verify-OfficialQA.ps1` 与 `Verify-NativeSplit.ps1`。以上实测版本为 KiCad 10.0.4；不能据此保证所有 SchLib 内容或其他 KiCad 版本等价迁移。
