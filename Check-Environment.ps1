#requires -Version 5.1
[CmdletBinding()]
param([string]$KiCadCliPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
$global:OutputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$failures = 0
function Write-Check {
    param([bool]$Success, [string]$Message)
    if ($Success) { Write-Host ('PASS ' + $Message) }
    else { $script:failures++; Write-Host ('FAIL ' + $Message) -ForegroundColor Red }
}
function Invoke-EnvironmentProbe {
    param([string]$Executable, [string[]]$Arguments)
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $Executable @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $probeExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($probeExit -ne 0) { throw ($lines -join [Environment]::NewLine) }
    return ($lines -join [Environment]::NewLine).Trim()
}
Write-Host 'KiCad portable tools - environment check (no library files are changed)'
Write-Check ([Environment]::Is64BitOperatingSystem) '64-bit Windows'
Write-Check ($PSVersionTable.PSVersion -ge [Version]'5.1') ('PowerShell ' + $PSVersionTable.PSVersion.ToString())
try {
    $release = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release).Release
    Write-Check ($release -ge 528040) ('.NET Framework 4.8 or later; Release=' + $release)
} catch { Write-Check $false '.NET Framework 4.8 or later was not detected.' }
$required = @{
    AD2KiCadPCBGUI = @('AD2KiCadPCBGUI.exe', 'AD2KiCadPCBGUI.exe.config', 'AD2KiCadPCB.ps1', 'KiCadEnvironment.ps1');
    AD2KiCadSchGUI = @('AD2KiCadSchGUI.exe', 'AD2KiCadSchGUI.exe.config', 'AD2KiCadSch.ps1', 'KiCadEnvironment.ps1');
    KiCadLibraryImporter = @('KiCadLibraryImporter.exe', 'KiCadLibraryImporter.exe.config', 'Invoke-KiCadLibraryImport.ps1', 'Import-KiCadLibraryAssets.ps1', 'KiCadEnvironment.ps1')
}
foreach ($directory in @('AD2KiCadPCBGUI', 'AD2KiCadSchGUI', 'KiCadLibraryImporter')) {
    foreach ($file in $required[$directory]) {
        Write-Check ([System.IO.File]::Exists([System.IO.Path]::Combine($PSScriptRoot, $directory, $file))) ($directory + '/' + $file)
    }
}
try {
    . ([System.IO.Path]::Combine($PSScriptRoot, 'AD2KiCadSchGUI', 'KiCadEnvironment.ps1'))
    $resolved = Resolve-KiCadCliPath -Path $KiCadCliPath
    $version = Invoke-EnvironmentProbe -Executable $resolved -Arguments @('--version')
    Write-Check $true ('KiCad CLI ' + $version + ' at ' + $resolved)
    if ($version -notmatch '^10\.') { Write-Host 'WARN This release is verified with KiCad 10.x. Other versions require your own conversion checks.' -ForegroundColor Yellow }
    foreach ($argsList in @(@('sym', 'upgrade', '--help'), @('sym', 'export', 'svg', '--help'), @('fp', 'upgrade', '--help'))) {
        try {
            $null = Invoke-EnvironmentProbe -Executable $resolved -Arguments $argsList
            Write-Check $true ('CLI command: ' + ($argsList -join ' '))
        } catch { Write-Check $false ('CLI command unavailable: ' + ($argsList -join ' ') + ' - ' + $_.Exception.Message) }
    }
    $pythonPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($resolved), 'python.exe')
    if (-not [System.IO.File]::Exists($pythonPath)) { throw 'The PCB converter needs python.exe from the selected complete KiCad installation.' }
    $pythonProbe = 'import os, sys, pcbnew; root=os.path.normcase(os.path.abspath(sys.argv[1])); module=os.path.normcase(os.path.abspath(pcbnew.__file__)); assert os.path.commonpath([root,module]) == root, ''pcbnew came from another installation''; assert pcbnew.Version().strip() == sys.argv[2].strip(), ''CLI/pcbnew version mismatch''; assert hasattr(pcbnew,''PCB_IO_MGR''), ''PCB_IO_MGR unavailable''; print(pcbnew.Version()); print(pcbnew.__file__)'
    $result = Invoke-EnvironmentProbe -Executable $pythonPath -Arguments @('-I', '-c', $pythonProbe, [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($resolved)), $version)
    Write-Check $true ('KiCad Python/pcbnew: ' + $result)
} catch { Write-Check $false $_.Exception.Message }
Write-Host ('FAIL=' + $failures)
if ($failures -ne 0) { exit 1 }
exit 0
