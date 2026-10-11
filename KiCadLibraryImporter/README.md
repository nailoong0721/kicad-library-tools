# KiCad 库导入器

双击 `KiCadLibraryImporter.exe`，确认“KiCad CLI”是本机安装的 `kicad-cli.exe`，选择转换后的库包目录和 KiCad 项目目录，确认目标库后先点击“检查并试运行”。试运行通过后，“执行导入”才会启用。

运行环境：Windows 10/11、Windows PowerShell 5.1、.NET Framework 4.8，以及支持 `kicad-cli sym upgrade` 和 `kicad-cli fp upgrade` 的 KiCad。建议同事使用与项目匹配的 KiCad 版本；本工具不会安装 KiCad。

程序会完成以下检查：

- 源包顶层恰有一个 `.kicad_sym`、一个 `.pretty`，以及最多一个 `.3dmodels`。
- 目标项目已存在同名 `.kicad_sym` 和 `.pretty`，并检查项目库表。
- 同名符号会阻止导入；同名 3D 模型仅在 SHA-256 相同时复用。
- 同名封装默认阻止导入。只有确认兼容并勾选“复用目标库中的同名封装”后才按名称复用，目标封装不会被覆盖。
- 试运行期间目标文件和备份数量保持不变，并记录输入指纹。正式导入前会重新核对该指纹。
- 正式导入会创建 `.library_import_backup_<时间戳>`，随后用 KiCad CLI 再次验证最终符号库和封装库。

程序不依赖 Codex、Python 或全局 skill 目录，也不要求特定盘符。启动时按 `KICAD_CLI` 环境变量、当前用户已保存路径、`PATH`、常见 KiCad 安装目录查找 CLI；没有找到时，点击“浏览...”选择本机的 `kicad-cli.exe`。路径必须是存在的文件的绝对路径。

检查和导入前会验证并保存所选路径，配置位于 `%LOCALAPPDATA%\KiCadPortableTools\kicad-cli.txt`，与同套工具共享。配置不写入工具目录，不需要管理员权限；发给同事时无需复制个人配置。修改路径会使已有试运行失效，必须重新检查。

移动或分享软件时，请把以下四个运行文件放在同一目录，并保持完整：

```text
KiCadLibraryImporter.exe
Invoke-KiCadLibraryImport.ps1
Import-KiCadLibraryAssets.ps1
KiCadEnvironment.ps1
```

直接运行 PowerShell 后端时可传入 `-KiCadCliPath`；显式参数优先于自动查找结果。

重新构建时保留源码包中的 `KiCadLibraryImporter` 与 `Shared` 同级目录。构建会自动寻找 Windows 的 .NET Framework 编译器，并复制共享路径脚本：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1
```

运行测试（先构建；后端测试自动生成临时样例，不需要个人工程文件）。下面的 KiCad 路径只是示例，应改为测试电脑实际安装路径：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Core.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Ui.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Backend.ps1 -KiCadCliPath 'C:\Program Files\KiCad\10.0\bin\kicad-cli.exe'
```

正式提交阶段不会提供强制取消；中途终止 PowerShell 或 KiCad 进程可能绕过清理并留下部分资产。
