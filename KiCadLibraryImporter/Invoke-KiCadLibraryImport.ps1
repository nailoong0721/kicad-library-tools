#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Operation,

    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [string]$LibraryName,

    [switch]$ReuseExistingFootprints,

    [string]$ExpectedFingerprint,

    [Parameter(Mandatory = $true)]
    [string]$ResultPath,

    [string]$KiCadCliPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
$global:OutputEncoding = $utf8
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8

$result = [ordered]@{
    success = $false
    applied = $false
    operation = $Operation
    mode = $Operation
    fingerprint = $null
    libraryName = $LibraryName
    symbols = [string[]]@()
    footprints = [string[]]@()
    reusedFootprints = [string[]]@()
    models = [string[]]@()
    reusedModels = [string[]]@()
    backupDirectory = $null
    finalValidation = $false
    stateVerified = $false
    error = $null
    errorCode = $null
    errorMessage = $null
    warnings = [string[]]@()
}

$resolvedResultPath = $null
$projectDirectory = $null
$sourceDirectory = $null
$enginePath = $null
$inventory = $null
$preTargetSymbolHash = $null
$backupNamesBefore = [string[]]@()
$stagingNamesBefore = $null
$verificationDirectory = $null
$operationStarted = $false
$mainCompleted = $false
$failure = $null
$warningList = New-Object 'System.Collections.Generic.List[string]'

function Write-ImportEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $safeStage = $Stage.Replace('|', '/').Replace("`r", ' ').Replace("`n", ' ')
    $safeMessage = $Message.Replace('|', '/').Replace("`r", ' ').Replace("`n", ' ')
    [Console]::Out.WriteLine('KICADIMPORT_EVENT|' + $safeStage + '|' + $safeMessage)
}

function New-ImportException {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $exception = New-Object System.InvalidOperationException -ArgumentList $Message
    $exception.Data['ErrorCode'] = $Code
    return $exception
}

function Throw-ImportFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    throw (New-ImportException -Code $Code -Message $Message)
}

function Resolve-ExistingDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        Throw-ImportFailure -Code 'INVALID_ARGUMENT' -Message "$Label cannot be empty."
    }

    $item = Get-Item -LiteralPath $LiteralPath
    if (-not $item.PSIsContainer) {
        Throw-ImportFailure -Code 'INVALID_PATH' -Message "$Label is not a directory: $LiteralPath"
    }

    return [System.IO.Path]::GetFullPath($item.FullName)
}

function Resolve-OutputFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        Throw-ImportFailure -Code 'INVALID_RESULT_PATH' -Message 'ResultPath cannot be empty.'
    }

    $fullPath = [System.IO.Path]::GetFullPath($LiteralPath)
    if ([System.IO.Directory]::Exists($fullPath)) {
        Throw-ImportFailure -Code 'INVALID_RESULT_PATH' -Message "ResultPath points to a directory: $fullPath"
    }

    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrEmpty($parent)) {
        Throw-ImportFailure -Code 'INVALID_RESULT_PATH' -Message "ResultPath has no parent directory: $fullPath"
    }
    [void][System.IO.Directory]::CreateDirectory($parent)
    return $fullPath
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Value,

        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    $json = $Value | ConvertTo-Json -Depth 8
    $parent = [System.IO.Path]::GetDirectoryName($LiteralPath)
    $leaf = [System.IO.Path]::GetFileName($LiteralPath)
    $temporaryPath = [System.IO.Path]::Combine(
        $parent,
        '.' + $leaf + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )

    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, $script:utf8)
        if ([System.IO.File]::Exists($LiteralPath)) {
            [System.IO.File]::Replace($temporaryPath, $LiteralPath, $null, $true)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $LiteralPath)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Test-ContainedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Candidate
    )

    $trimCharacters = [char[]]@([char]92, [char]47)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd($trimCharacters)
    $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd($trimCharacters)
    $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    return $candidateFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-ContainedDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Candidate
    )

    if (-not [System.IO.Directory]::Exists($Candidate)) {
        return
    }
    if (-not (Test-ContainedPath -Root $Root -Candidate $Candidate)) {
        Throw-ImportFailure -Code 'UNSAFE_CLEANUP_PATH' -Message "Cleanup path is outside the intended root: $Candidate"
    }

    $item = Get-Item -LiteralPath $Candidate
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-ImportFailure -Code 'UNSAFE_CLEANUP_PATH' -Message "Cleanup path is a reparse point: $Candidate"
    }
    [System.IO.Directory]::Delete([System.IO.Path]::GetFullPath($Candidate), $true)
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-SortedStrings {
    param(
        [AllowEmptyCollection()]
        [object[]]$Values
    )

    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in @($Values)) {
        if ($null -ne $value) {
            [void]$list.Add([string]$value)
        }
    }
    $list.Sort([System.StringComparer]::Ordinal)
    return [string[]]$list.ToArray()
}

function Get-SourceInventory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $symbolLibraries = @(Get-ChildItem -LiteralPath $Directory -File -Filter '*.kicad_sym')
    if ($symbolLibraries.Count -ne 1) {
        Throw-ImportFailure -Code 'INVALID_SOURCE_PACKAGE' -Message "Expected exactly one *.kicad_sym file; found $($symbolLibraries.Count)."
    }

    $footprintLibraries = @(Get-ChildItem -LiteralPath $Directory -Directory -Filter '*.pretty')
    if ($footprintLibraries.Count -ne 1) {
        Throw-ImportFailure -Code 'INVALID_SOURCE_PACKAGE' -Message "Expected exactly one *.pretty directory; found $($footprintLibraries.Count)."
    }

    $modelLibraries = @(Get-ChildItem -LiteralPath $Directory -Directory -Filter '*.3dmodels')
    if ($modelLibraries.Count -gt 1) {
        Throw-ImportFailure -Code 'INVALID_SOURCE_PACKAGE' -Message "Expected zero or one *.3dmodels directory; found $($modelLibraries.Count)."
    }

    $footprints = @(Get-ChildItem -LiteralPath $footprintLibraries[0].FullName -File -Filter '*.kicad_mod')
    if ($footprints.Count -eq 0) {
        Throw-ImportFailure -Code 'INVALID_SOURCE_PACKAGE' -Message 'The source footprint library contains no *.kicad_mod files.'
    }

    $modelLibrary = if ($modelLibraries.Count -eq 1) { $modelLibraries[0] } else { $null }
    $models = @()
    if ($null -ne $modelLibrary) {
        $models = @(
            Get-ChildItem -LiteralPath $modelLibrary.FullName -File |
                Where-Object { $_.Extension -in @('.step', '.stp', '.wrl') }
        )
    }

    return [PSCustomObject]@{
        SymbolLibrary = $symbolLibraries[0]
        FootprintLibrary = $footprintLibraries[0]
        ModelLibrary = $modelLibrary
        Footprints = [object[]]$footprints
        Models = [object[]]$models
    }
}

function Add-FingerprintRecord {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Records,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $encodedKey = [Convert]::ToBase64String($script:utf8.GetBytes($Key))
    [void]$Records.Add($encodedKey + '|' + $Value)
}

function Get-ImportFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$ProjectDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Library,

        [Parameter(Mandatory = $true)]
        [object]$SourceInventory,

        [Parameter(Mandatory = $true)]
        [bool]$ReuseFootprints
    )

    $records = New-Object 'System.Collections.Generic.List[string]'
    Add-FingerprintRecord -Records $records -Key 'option:library' -Value $Library
    Add-FingerprintRecord -Records $records -Key 'option:reuseExistingFootprints' -Value $ReuseFootprints.ToString().ToLowerInvariant()

    $sourcePrefix = $SourceDirectory.TrimEnd([char[]]@([char]92, [char]47)) + [System.IO.Path]::DirectorySeparatorChar
    foreach ($file in @(Get-ChildItem -LiteralPath $SourceDirectory -File -Recurse -Force)) {
        $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
        if (-not $fullPath.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Throw-ImportFailure -Code 'INVALID_SOURCE_PACKAGE' -Message "Source file is outside SourceRoot: $fullPath"
        }
        $relativePath = $fullPath.Substring($sourcePrefix.Length).Replace([char]92, [char]47)
        Add-FingerprintRecord -Records $records -Key ('source:' + $relativePath) -Value (Get-FileSha256 -LiteralPath $fullPath)
    }

    $targetSymbol = [System.IO.Path]::Combine($ProjectDirectory, $Library + '.kicad_sym')
    Add-FingerprintRecord -Records $records -Key 'target:symbol' -Value (Get-FileSha256 -LiteralPath $targetSymbol)

    $targetFootprintDirectory = [System.IO.Path]::Combine($ProjectDirectory, $Library + '.pretty')
    foreach ($footprint in $SourceInventory.Footprints) {
        $targetPath = [System.IO.Path]::Combine($targetFootprintDirectory, $footprint.Name)
        $value = if ([System.IO.File]::Exists($targetPath)) { Get-FileSha256 -LiteralPath $targetPath } else { 'MISSING' }
        Add-FingerprintRecord -Records $records -Key ('target:footprint:' + $footprint.Name) -Value $value
    }

    $targetModelDirectory = [System.IO.Path]::Combine($ProjectDirectory, $Library + '.3dmodels')
    foreach ($model in $SourceInventory.Models) {
        $targetPath = [System.IO.Path]::Combine($targetModelDirectory, $model.Name)
        $value = if ([System.IO.File]::Exists($targetPath)) { Get-FileSha256 -LiteralPath $targetPath } else { 'MISSING' }
        Add-FingerprintRecord -Records $records -Key ('target:model:' + $model.Name) -Value $value
    }

    $records.Sort([System.StringComparer]::Ordinal)
    $manifest = [System.String]::Join("`n", $records.ToArray()) + "`n"
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($script:utf8.GetBytes($manifest))
    }
    finally {
        $sha256.Dispose()
    }
    return [BitConverter]::ToString($hashBytes).Replace('-', '')
}

function Get-ImmediateDirectoryNames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Parent,

        [Parameter(Mandatory = $true)]
        [string]$Filter
    )

    if (-not [System.IO.Directory]::Exists($Parent)) {
        return [string[]]@()
    }
    return Get-SortedStrings -Values @(
        Get-ChildItem -LiteralPath $Parent -Directory -Filter $Filter |
            ForEach-Object { $_.Name }
    )
}

function Test-SameStringSet {
    param(
        [AllowEmptyCollection()]
        [string[]]$First,

        [AllowEmptyCollection()]
        [string[]]$Second
    )

    $left = @(Get-SortedStrings -Values @($First))
    $right = @(Get-SortedStrings -Values @($Second))
    if ($left.Count -ne $right.Count) {
        return $false
    }
    for ($index = 0; $index -lt $left.Count; $index++) {
        if (-not [string]::Equals($left[$index], $right[$index], [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Get-NewDirectoryNames {
    param(
        [AllowEmptyCollection()]
        [string[]]$Before,

        [AllowEmptyCollection()]
        [string[]]$After
    )

    $known = @{}
    foreach ($name in @($Before)) {
        $known[[string]$name] = $true
    }
    $newNames = @(
        foreach ($name in @($After)) {
            if (-not $known.ContainsKey([string]$name)) {
                [string]$name
            }
        }
    )
    return Get-SortedStrings -Values $newNames
}

function ConvertTo-WindowsCommandLineArgument {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ''
    }
    if ($Value.Length -gt 0 -and -not [System.Text.RegularExpressions.Regex]::IsMatch($Value, '[\s\"]')) {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $backslashCount = 0
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ($character -eq [char]92) {
            $backslashCount++
            continue
        }
        if ($character -eq [char]34) {
            for ($repeat = 0; $repeat -lt (2 * $backslashCount + 1); $repeat++) {
                [void]$builder.Append([char]92)
            }
            [void]$builder.Append([char]34)
            $backslashCount = 0
            continue
        }
        for ($repeat = 0; $repeat -lt $backslashCount; $repeat++) {
            [void]$builder.Append([char]92)
        }
        [void]$builder.Append($character)
        $backslashCount = 0
    }
    for ($repeat = 0; $repeat -lt (2 * $backslashCount); $repeat++) {
        [void]$builder.Append([char]92)
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function Invoke-KiCadCliProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $quotedArguments = @(
        $Arguments | ForEach-Object {
            ConvertTo-WindowsCommandLineArgument -Value ([string]$_)
        }
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = [System.String]::Join(' ', $quotedArguments)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $script:utf8
    $startInfo.StandardErrorEncoding = $script:utf8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $stdoutText = ''
    $stderrText = ''
    $exitCode = -1
    try {
        if (-not $process.Start()) {
            Throw-ImportFailure -Code 'KICAD_CLI_FAILED' -Message "Could not start KiCad CLI: $Executable"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdoutText = $stdoutTask.GetAwaiter().GetResult()
        $stderrText = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
        [Console]::Out.WriteLine($stdoutText.TrimEnd())
    }
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        [Console]::Error.WriteLine($stderrText.TrimEnd())
    }
    if ($exitCode -ne 0) {
        Throw-ImportFailure -Code 'KICAD_CLI_FAILED' -Message "KiCad CLI failed with exit code $exitCode."
    }
}

function Get-EngineArray {
    param(
        [Parameter(Mandatory = $true)]
        [object]$EngineResult,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    $property = $EngineResult.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        Throw-ImportFailure -Code 'ENGINE_CONTRACT_ERROR' -Message "Import engine result is missing '$PropertyName'."
    }
    return Get-SortedStrings -Values @($property.Value)
}

function Set-ResultFromEngine {
    param(
        [Parameter(Mandatory = $true)]
        [object]$EngineResult
    )

    $script:result.symbols = [string[]]@(Get-EngineArray -EngineResult $EngineResult -PropertyName 'SymbolNames')
    $script:result.footprints = [string[]]@(Get-EngineArray -EngineResult $EngineResult -PropertyName 'FootprintNames')
    $script:result.reusedFootprints = [string[]]@(Get-EngineArray -EngineResult $EngineResult -PropertyName 'ReusedFootprintNames')
    $script:result.models = [string[]]@(Get-EngineArray -EngineResult $EngineResult -PropertyName 'ModelNames')
    $script:result.reusedModels = [string[]]@(Get-EngineArray -EngineResult $EngineResult -PropertyName 'ReusedModelNames')
    $script:result.applied = [bool]$EngineResult.Applied
    if ($null -ne $EngineResult.BackupDirectory) {
        $script:result.backupDirectory = [string]$EngineResult.BackupDirectory
    }
}

function Invoke-ImportEngine {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$DryRun
    )

    $engineParameters = @{
        SourceRoot = $script:sourceDirectory
        ProjectRoot = $script:projectDirectory
        LibraryName = $script:LibraryName
        KiCadCliPath = $script:KiCadCliPath
        ErrorAction = 'Stop'
        WarningVariable = 'engineWarnings'
    }
    if ($script:ReuseExistingFootprints) {
        $engineParameters['ReuseExistingFootprints'] = $true
    }
    if ($DryRun) {
        $engineParameters['WhatIf'] = $true
    }

    $engineWarnings = @()
    try {
        $output = @(& $script:enginePath @engineParameters)
    }
    catch {
        Throw-ImportFailure -Code 'ENGINE_FAILED' -Message ('Import engine failed: ' + $_.Exception.Message)
    }
    foreach ($engineWarning in @($engineWarnings)) {
        [void]$script:warningList.Add([string]$engineWarning)
    }

    $resultObjects = @(
        $output | Where-Object {
            $null -ne $_ -and $null -ne $_.PSObject.Properties['Applied']
        }
    )
    if ($resultObjects.Count -ne 1) {
        Throw-ImportFailure -Code 'ENGINE_CONTRACT_ERROR' -Message "Expected one import engine result object; found $($resultObjects.Count)."
    }
    return $resultObjects[0]
}

function Assert-TargetAssets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Library,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$FootprintNames,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ModelNames
    )

    $footprintDirectory = [System.IO.Path]::Combine($ProjectDirectory, $Library + '.pretty')
    foreach ($name in $FootprintNames) {
        $path = [System.IO.Path]::Combine($footprintDirectory, $name + '.kicad_mod')
        if (-not [System.IO.File]::Exists($path)) {
            Throw-ImportFailure -Code 'POST_APPLY_ASSET_MISSING' -Message "Imported footprint was not found: $path"
        }
    }

    $modelDirectory = [System.IO.Path]::Combine($ProjectDirectory, $Library + '.3dmodels')
    foreach ($name in $ModelNames) {
        $path = [System.IO.Path]::Combine($modelDirectory, $name)
        if (-not [System.IO.File]::Exists($path)) {
            Throw-ImportFailure -Code 'POST_APPLY_ASSET_MISSING' -Message "Imported model was not found: $path"
        }
    }
}

function Get-ExistingAssetHashes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Files
    )

    $hashes = @{}
    foreach ($file in $Files) {
        $targetPath = [System.IO.Path]::Combine($Directory, $file.Name)
        if ([System.IO.File]::Exists($targetPath)) {
            $hashes[$file.BaseName] = Get-FileSha256 -LiteralPath $targetPath
            $hashes[$file.Name] = Get-FileSha256 -LiteralPath $targetPath
        }
    }
    return $hashes
}

function Assert-ReusedHashesUnchanged {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [hashtable]$BeforeHashes,

        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Names,

        [Parameter(Mandatory = $true)]
        [bool]$AppendFootprintExtension
    )

    foreach ($name in $Names) {
        $fileName = if ($AppendFootprintExtension) { $name + '.kicad_mod' } else { $name }
        if (-not $BeforeHashes.ContainsKey($name)) {
            Throw-ImportFailure -Code 'REUSED_ASSET_CHANGED' -Message "No pre-import hash was captured for reused asset: $name"
        }
        $path = [System.IO.Path]::Combine($Directory, $fileName)
        if (-not [System.IO.File]::Exists($path)) {
            Throw-ImportFailure -Code 'REUSED_ASSET_CHANGED' -Message "Reused asset is missing after import: $path"
        }
        $afterHash = Get-FileSha256 -LiteralPath $path
        if ($afterHash -ne $BeforeHashes[$name]) {
            Throw-ImportFailure -Code 'REUSED_ASSET_CHANGED' -Message "Reused asset content changed: $path"
        }
    }
}

try {
    $resolvedResultPath = Resolve-OutputFilePath -LiteralPath $ResultPath
    Write-ImportEvent -Stage 'validate' -Message 'Validating request and package'

    if ($Operation -notin @('DryRun', 'Apply')) {
        Throw-ImportFailure -Code 'INVALID_OPERATION' -Message "Operation must be DryRun or Apply: $Operation"
    }
    $Operation = if ($Operation -eq 'DryRun') { 'DryRun' } else { 'Apply' }
    $result.operation = $Operation
    $result.mode = $Operation

    $sourceDirectory = Resolve-ExistingDirectory -LiteralPath $SourceRoot -Label 'SourceRoot'
    $projectDirectory = Resolve-ExistingDirectory -LiteralPath $ProjectRoot -Label 'ProjectRoot'
    if ([string]::IsNullOrWhiteSpace($LibraryName) -or
        $LibraryName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $LibraryName.IndexOf(':') -ge 0 -or
        $LibraryName.IndexOf([char]34) -ge 0) {
        Throw-ImportFailure -Code 'INVALID_LIBRARY_NAME' -Message "LibraryName cannot be used safely: $LibraryName"
    }

    try {
        . ([System.IO.Path]::Combine($PSScriptRoot, 'KiCadEnvironment.ps1'))
        $KiCadCliPath = Resolve-KiCadCliPath -Path $KiCadCliPath
    }
    catch {
        Throw-ImportFailure -Code 'KICAD_CLI_NOT_FOUND' -Message $_.Exception.Message
    }
    $enginePath = [System.IO.Path]::Combine($PSScriptRoot, 'Import-KiCadLibraryAssets.ps1')
    if (-not [System.IO.File]::Exists($enginePath)) {
        Throw-ImportFailure -Code 'ENGINE_NOT_FOUND' -Message "Import engine was not found: $enginePath"
    }

    $inventory = Get-SourceInventory -Directory $sourceDirectory
    $targetSymbolPath = [System.IO.Path]::Combine($projectDirectory, $LibraryName + '.kicad_sym')
    $targetFootprintDirectory = [System.IO.Path]::Combine($projectDirectory, $LibraryName + '.pretty')
    if (-not [System.IO.File]::Exists($targetSymbolPath)) {
        Throw-ImportFailure -Code 'TARGET_LIBRARY_NOT_FOUND' -Message "Target symbol library was not found: $targetSymbolPath"
    }
    if (-not [System.IO.Directory]::Exists($targetFootprintDirectory)) {
        Throw-ImportFailure -Code 'TARGET_LIBRARY_NOT_FOUND' -Message "Target footprint library was not found: $targetFootprintDirectory"
    }

    Write-ImportEvent -Stage 'fingerprint' -Message 'Calculating import state fingerprint'
    $fingerprint = Get-ImportFingerprint `
        -SourceDirectory $sourceDirectory `
        -ProjectDirectory $projectDirectory `
        -Library $LibraryName `
        -SourceInventory $inventory `
        -ReuseFootprints ([bool]$ReuseExistingFootprints)
    $result.fingerprint = $fingerprint

    $backupNamesBefore = @(Get-ImmediateDirectoryNames -Parent $projectDirectory -Filter '.library_import_backup_*')
    $stagingParent = [System.IO.Path]::Combine($projectDirectory, 'tmp')
    $stagingNamesBefore = @(Get-ImmediateDirectoryNames -Parent $stagingParent -Filter '.kicad-library-import-*')
    $preTargetSymbolHash = Get-FileSha256 -LiteralPath $targetSymbolPath

    if ($Operation -eq 'DryRun') {
        Write-ImportEvent -Stage 'dryrun' -Message 'Validating the import without applying changes'
        $operationStarted = $true
        $engineResult = Invoke-ImportEngine -DryRun $true
        Set-ResultFromEngine -EngineResult $engineResult
        if ($result.applied) {
            Throw-ImportFailure -Code 'DRYRUN_APPLIED' -Message 'The import engine reported Applied=True during DryRun.'
        }

        $postFingerprint = Get-ImportFingerprint `
            -SourceDirectory $sourceDirectory `
            -ProjectDirectory $projectDirectory `
            -Library $LibraryName `
            -SourceInventory $inventory `
            -ReuseFootprints ([bool]$ReuseExistingFootprints)
        if ($postFingerprint -ne $fingerprint) {
            Throw-ImportFailure -Code 'DRYRUN_STATE_CHANGED' -Message 'Relevant source or project state changed during DryRun.'
        }

        $backupNamesAfter = @(Get-ImmediateDirectoryNames -Parent $projectDirectory -Filter '.library_import_backup_*')
        if (-not (Test-SameStringSet -First $backupNamesBefore -Second $backupNamesAfter)) {
            Throw-ImportFailure -Code 'DRYRUN_BACKUP_CHANGED' -Message 'Backup directories changed during DryRun.'
        }
        $result.finalValidation = $true
    }
    else {
        if ([string]::IsNullOrWhiteSpace($ExpectedFingerprint)) {
            Throw-ImportFailure -Code 'FINGERPRINT_REQUIRED' -Message 'ExpectedFingerprint is required for Apply.'
        }
        if ($ExpectedFingerprint -notmatch '^[0-9A-Fa-f]{64}$') {
            Throw-ImportFailure -Code 'INVALID_FINGERPRINT' -Message 'ExpectedFingerprint must be a 64-character SHA-256 value.'
        }
        if (-not [string]::Equals($ExpectedFingerprint, $fingerprint, [System.StringComparison]::OrdinalIgnoreCase)) {
            Throw-ImportFailure -Code 'FINGERPRINT_MISMATCH' -Message 'Source or project state changed after DryRun. Run DryRun again.'
        }

        $targetModelDirectory = [System.IO.Path]::Combine($projectDirectory, $LibraryName + '.3dmodels')
        $preFootprintHashes = Get-ExistingAssetHashes -Directory $targetFootprintDirectory -Files $inventory.Footprints
        $preModelHashes = Get-ExistingAssetHashes -Directory $targetModelDirectory -Files $inventory.Models

        Write-ImportEvent -Stage 'apply' -Message 'Applying validated library assets'
        $operationStarted = $true
        $engineResult = Invoke-ImportEngine -DryRun $false
        Set-ResultFromEngine -EngineResult $engineResult
        if (-not $result.applied) {
            Throw-ImportFailure -Code 'APPLY_NOT_CONFIRMED' -Message 'The import engine did not report Applied=True.'
        }

        $backupDirectory = [string]$result.backupDirectory
        if ([string]::IsNullOrWhiteSpace($backupDirectory) -or
            -not [System.IO.Directory]::Exists($backupDirectory) -or
            -not (Test-ContainedPath -Root $projectDirectory -Candidate $backupDirectory)) {
            Throw-ImportFailure -Code 'BACKUP_VERIFICATION_FAILED' -Message "Backup directory is missing or outside ProjectRoot: $backupDirectory"
        }
        $backupItem = Get-Item -LiteralPath $backupDirectory
        if (($backupItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [string]::Equals($backupItem.Parent.FullName, $projectDirectory, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not $backupItem.Name.StartsWith('.library_import_backup_', [System.StringComparison]::Ordinal)) {
            Throw-ImportFailure -Code 'BACKUP_VERIFICATION_FAILED' -Message "Backup directory is not an immediate trusted backup: $backupDirectory"
        }
        if (@($backupNamesBefore | Where-Object { $_ -eq $backupItem.Name }).Count -ne 0) {
            Throw-ImportFailure -Code 'BACKUP_VERIFICATION_FAILED' -Message "Backup directory was not created by this Apply operation: $backupDirectory"
        }
        $backupSymbolPath = [System.IO.Path]::Combine($backupDirectory, $LibraryName + '.kicad_sym')
        if (-not [System.IO.File]::Exists($backupSymbolPath) -or
            (Get-FileSha256 -LiteralPath $backupSymbolPath) -ne $preTargetSymbolHash) {
            Throw-ImportFailure -Code 'BACKUP_VERIFICATION_FAILED' -Message 'Backup symbol hash does not match the pre-import target symbol hash.'
        }

        Write-ImportEvent -Stage 'verify-assets' -Message 'Verifying imported and reused assets'
        Assert-TargetAssets `
            -ProjectDirectory $projectDirectory `
            -Library $LibraryName `
            -FootprintNames $result.footprints `
            -ModelNames $result.models
        Assert-ReusedHashesUnchanged `
            -BeforeHashes $preFootprintHashes `
            -Directory $targetFootprintDirectory `
            -Names $result.reusedFootprints `
            -AppendFootprintExtension $true
        Assert-ReusedHashesUnchanged `
            -BeforeHashes $preModelHashes `
            -Directory $targetModelDirectory `
            -Names $result.reusedModels `
            -AppendFootprintExtension $false

        Write-ImportEvent -Stage 'final-validation' -Message 'Running final KiCad library validation'
        $verificationParent = [System.IO.Path]::Combine($projectDirectory, 'tmp')
        [void][System.IO.Directory]::CreateDirectory($verificationParent)
        $verificationDirectory = [System.IO.Path]::Combine(
            $verificationParent,
            '.kicad-library-import-verify-' + [Guid]::NewGuid().ToString('N')
        )
        [void][System.IO.Directory]::CreateDirectory($verificationDirectory)
        $validatedSymbolPath = [System.IO.Path]::Combine($verificationDirectory, 'validated.kicad_sym')
        $validatedFootprintPath = [System.IO.Path]::Combine($verificationDirectory, 'validated.pretty')
        Invoke-KiCadCliProcess -Executable $KiCadCliPath -Arguments @(
            'sym', 'upgrade', $targetSymbolPath,
            '--output', $validatedSymbolPath,
            '--force'
        )
        Invoke-KiCadCliProcess -Executable $KiCadCliPath -Arguments @(
            'fp', 'upgrade', $targetFootprintDirectory,
            '--output', $validatedFootprintPath,
            '--force'
        )
        $result.finalValidation = $true
    }

    $mainCompleted = $true
}
catch {
    $failure = $_.Exception
}

if ($null -ne $verificationDirectory) {
    try {
        Remove-ContainedDirectory -Root $projectDirectory -Candidate $verificationDirectory
    }
    catch {
        if ($null -eq $failure) {
            $failure = New-ImportException -Code 'VERIFICATION_CLEANUP_FAILED' -Message $_.Exception.Message
        }
        else {
            [void]$warningList.Add('Verification cleanup failed: ' + $_.Exception.Message)
        }
    }
}

if ($null -ne $stagingNamesBefore -and $null -ne $projectDirectory) {
    $stagingParent = [System.IO.Path]::Combine($projectDirectory, 'tmp')
    $stagingNamesAfter = @(Get-ImmediateDirectoryNames -Parent $stagingParent -Filter '.kicad-library-import-*')
    $newStagingNames = @(Get-NewDirectoryNames -Before $stagingNamesBefore -After $stagingNamesAfter)
    if ($newStagingNames.Count -gt 0) {
        foreach ($stagingName in $newStagingNames) {
            $stagingPath = [System.IO.Path]::Combine($stagingParent, $stagingName)
            try {
                Remove-ContainedDirectory -Root $stagingParent -Candidate $stagingPath
            }
            catch {
                [void]$warningList.Add('Staging cleanup failed: ' + $_.Exception.Message)
            }
        }
        if ($null -eq $failure) {
            $failure = New-ImportException -Code 'STAGING_LEAK' -Message 'The import left a new staging directory; it was cleaned up.'
        }
        else {
            [void]$warningList.Add('The import left a new staging directory; cleanup was attempted.')
        }
    }

    $remainingStagingNames = @(Get-ImmediateDirectoryNames -Parent $stagingParent -Filter '.kicad-library-import-*')
    $remainingNewNames = @(Get-NewDirectoryNames -Before $stagingNamesBefore -After $remainingStagingNames)
    if ($remainingNewNames.Count -gt 0 -and $null -eq $failure) {
        $failure = New-ImportException -Code 'STAGING_CLEANUP_FAILED' -Message 'A new import staging directory remains after cleanup.'
    }
}

if ($null -ne $failure -and $Operation -eq 'Apply' -and $operationStarted -and $null -ne $projectDirectory) {
    if ([string]::IsNullOrWhiteSpace([string]$result.backupDirectory)) {
        $backupNamesAfterFailure = @(Get-ImmediateDirectoryNames -Parent $projectDirectory -Filter '.library_import_backup_*')
        $newBackupNames = @(Get-NewDirectoryNames -Before $backupNamesBefore -After $backupNamesAfterFailure)
        if ($newBackupNames.Count -eq 1) {
            $result.backupDirectory = [System.IO.Path]::Combine($projectDirectory, $newBackupNames[0])
        }
    }
    $targetSymbolPath = [System.IO.Path]::Combine($projectDirectory, $LibraryName + '.kicad_sym')
    if (-not $result.applied -and $null -ne $preTargetSymbolHash -and [System.IO.File]::Exists($targetSymbolPath)) {
        $result.applied = (Get-FileSha256 -LiteralPath $targetSymbolPath) -ne $preTargetSymbolHash
    }
}

if ($null -eq $failure -and $mainCompleted) {
    $result.success = $true
    $result.stateVerified = $true
    Write-ImportEvent -Stage 'complete' -Message 'Import operation completed successfully'
}
else {
    if ($null -eq $failure) {
        $failure = New-ImportException -Code 'UNKNOWN_FAILURE' -Message 'The import operation did not complete.'
    }
    $errorCode = 'IMPORT_FAILED'
    if ($failure.Data.Contains('ErrorCode')) {
        $errorCode = [string]$failure.Data['ErrorCode']
    }
    $result.errorCode = $errorCode
    $result.errorMessage = $failure.Message
    $result.error = $failure.Message
    [Console]::Error.WriteLine('KICADIMPORT_ERROR|' + $errorCode + '|' + $failure.Message.Replace("`r", ' ').Replace("`n", ' '))
}

$result.warnings = [string[]]@(Get-SortedStrings -Values $warningList.ToArray())

if ($null -eq $resolvedResultPath) {
    try {
        $resolvedResultPath = Resolve-OutputFilePath -LiteralPath $ResultPath
    }
    catch {
        [Console]::Error.WriteLine('KICADIMPORT_ERROR|RESULT_WRITE_FAILED|' + $_.Exception.Message)
        exit 1
    }
}

try {
    Write-AtomicJson -Value $result -LiteralPath $resolvedResultPath
}
catch {
    [Console]::Error.WriteLine('KICADIMPORT_ERROR|RESULT_WRITE_FAILED|' + $_.Exception.Message)
    exit 1
}

if (-not $result.success) {
    exit 1
}
exit 0
