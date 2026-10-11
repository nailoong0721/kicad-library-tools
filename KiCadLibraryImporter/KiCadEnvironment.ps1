#requires -Version 5.1
# Portable runtime discovery. Dot-sourcing this file has no machine-wide effects.

function Get-KiCadSettingsPath {
    return [System.IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'KiCadPortableTools', 'kicad-cli.txt')
}

function ConvertTo-KiCadCliPath {
    param([string]$Path)
    $value = [Environment]::ExpandEnvironmentVariables(([string]$Path).Trim().Trim([char]34))
    if ($value -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/]+[^\\/]+[\\/])') {
        throw 'Choose an absolute path to kicad-cli.exe.'
    }
    $fullPath = [System.IO.Path]::GetFullPath($value)
    if ([System.IO.Path]::GetFileName($fullPath) -ine 'kicad-cli.exe') {
        throw 'Select kicad-cli.exe from the KiCad bin folder.'
    }
    if (-not [System.IO.File]::Exists($fullPath)) { throw "KiCad CLI was not found: $fullPath" }
    return $fullPath
}

function Test-KiCadCliCandidate {
    param([string]$Path)
    try { $null = ConvertTo-KiCadCliPath -Path $Path; return $true } catch { return $false }
}

function Resolve-KiCadCliPath {
    [CmdletBinding()]
    param([string]$Path, [string]$SettingsPath = (Get-KiCadSettingsPath))
    if (-not [string]::IsNullOrWhiteSpace($Path)) { return ConvertTo-KiCadCliPath -Path $Path }
    if (-not [string]::IsNullOrWhiteSpace($env:KICAD_CLI)) { return ConvertTo-KiCadCliPath -Path $env:KICAD_CLI }
    try {
        if ([System.IO.File]::Exists($SettingsPath)) {
            $saved = [System.IO.File]::ReadAllText($SettingsPath, [System.Text.Encoding]::UTF8)
            if (Test-KiCadCliCandidate -Path $saved) { return ConvertTo-KiCadCliPath -Path $saved }
        }
    } catch [System.IO.IOException] { } catch [System.UnauthorizedAccessException] { }
    foreach ($directory in ([string]$env:PATH -split ';')) {
        $directory = [Environment]::ExpandEnvironmentVariables($directory.Trim().Trim([char]34))
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        try { $candidate = [System.IO.Path]::Combine($directory, 'kicad-cli.exe') } catch { continue }
        if (Test-KiCadCliCandidate -Path $candidate) { return ConvertTo-KiCadCliPath -Path $candidate }
    }
    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('ProgramW6432', 'ProgramFiles', 'ProgramFiles(x86)')) {
        $directory = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($directory)) { $roots.Add([System.IO.Path]::Combine($directory, 'KiCad')) }
    }
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not [string]::IsNullOrWhiteSpace($local)) { $roots.Add([System.IO.Path]::Combine($local, 'Programs', 'KiCad')) }
    foreach ($root in $roots) {
        $candidate = [System.IO.Path]::Combine($root, 'bin', 'kicad-cli.exe')
        if (Test-KiCadCliCandidate -Path $candidate) { return ConvertTo-KiCadCliPath -Path $candidate }
        try {
            if (-not [System.IO.Directory]::Exists($root)) { continue }
            $versions = @([System.IO.Directory]::GetDirectories($root) | Sort-Object -Property @{Expression={
                $parsedVersion = $null
                if ([Version]::TryParse([System.IO.Path]::GetFileName($_), [ref]$parsedVersion)) { $parsedVersion } else { [Version]'0.0' }
            }; Descending=$true}, @{Expression={$_}; Descending=$true})
        } catch [System.IO.IOException] { continue } catch [System.UnauthorizedAccessException] { continue }
        foreach ($directory in $versions) {
            $candidate = [System.IO.Path]::Combine($directory, 'bin', 'kicad-cli.exe')
            if (Test-KiCadCliCandidate -Path $candidate) { return ConvertTo-KiCadCliPath -Path $candidate }
        }
    }
    throw 'KiCad CLI was not found. Choose kicad-cli.exe in the GUI, pass -KiCadCliPath, or set KICAD_CLI.'
}
