<#
.SYNOPSIS
Converts an Altium Designer SchLib into a native KiCad symbol library and
exports each symbol into a separate library in <output-name>_symbols.

.PARAMETER SourceSchLib
Path to the source .SchLib file.

.PARAMETER OutputKicadSym
Optional destination .kicad_sym path. Defaults beside the source.

.PARAMETER KicadCliPath
Optional path to kicad-cli.exe. Uses the saved setting or installed KiCad when omitted.

.EXAMPLE
.\AD2KiCadSch.ps1 -SourceSchLib 'C:\Libraries\Parts.SchLib'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceSchLib,

    [Parameter()]
    [string]$OutputKicadSym,

    [Parameter()]
    [string]$KicadCliPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
$global:OutputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom

$environmentScript = [System.IO.Path]::Combine($PSScriptRoot, 'KiCadEnvironment.ps1')
if (-not [System.IO.File]::Exists($environmentScript)) {
    throw "Bundled environment helper was not found: $environmentScript"
}
. $environmentScript

function Get-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    try {
        return [System.IO.Path]::GetFullPath($Value)
    }
    catch {
        throw "$Label is not a valid path: $Value"
    }
}

function Assert-ContainedDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target,

        [Parameter(Mandatory = $true)]
        [string]$IntendedRoot
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($IntendedRoot).TrimEnd([char]92)
    $resolvedTarget = [System.IO.Path]::GetFullPath($Target).TrimEnd([char]92)
    $rootPrefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTarget.StartsWith(
            $rootPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Temporary directory is outside the intended root: $resolvedTarget"
    }

    # Staging moves and cleanup must never follow a junction or symbolic link.
    $ancestor = New-Object System.IO.DirectoryInfo -ArgumentList $resolvedTarget
    while ($null -ne $ancestor) {
        if (($ancestor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to follow a reparse point: $($ancestor.FullName)"
        }
        $ancestor = $ancestor.Parent
    }
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($resolvedTarget)
    while ($pending.Count -gt 0) {
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($pending.Pop())) {
            $attributes = [System.IO.File]::GetAttributes($entry)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to follow a reparse point: $entry"
            }
            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $pending.Push($entry)
            }
        }
    }
}

function Remove-TemporaryDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target,

        [Parameter(Mandatory = $true)]
        [string]$IntendedRoot
    )

    if (-not [System.IO.Directory]::Exists($Target)) {
        return
    }

    Assert-ContainedDirectory -Target $Target -IntendedRoot $IntendedRoot
    Remove-Item -LiteralPath $Target -Recurse -Force
}

function Invoke-KiCadCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [Parameter()]
        [switch]$Quiet
    )

    Write-Host "Running: $Operation"
    $nativeOutput = @(& $Executable @Arguments 2>&1)
    $nativeExitCode = $LASTEXITCODE
    if (-not $Quiet -or $nativeExitCode -ne 0) {
        foreach ($line in $nativeOutput) {
            Write-Host ([string]$line)
        }
    }
    if ($nativeExitCode -ne 0) {
        throw "$Operation failed with exit code $nativeExitCode"
    }
}

function Read-KiCadSymbolLibrary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $content = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    if ($content -notmatch '^\s*\(kicad_symbol_lib(?:\s|\()') {
        throw "Output is not a native KiCad symbol library: $FilePath"
    }

    $symbolPattern = New-Object System.Text.RegularExpressions.Regex -ArgumentList '\G\(symbol\s+"((?:\\.|[^"\\])*)"'
    $symbols = New-Object 'System.Collections.Generic.List[object]'
    $metadata = New-Object System.Text.StringBuilder
    $symbolStart = -1
    $symbolName = $null
    $previousEnd = 0
    $rootEnd = -1
    $depth = 0
    $inString = $false
    $isEscaped = $false
    $inLineComment = $false

    for ($index = 0; $index -lt $content.Length; $index++) {
        $current = $content[$index]

        if ($inLineComment) {
            if ($current -eq "`n") {
                $inLineComment = $false
            }
            continue
        }

        if ($inString) {
            if ($isEscaped) {
                $isEscaped = $false
            }
            elseif ($current -eq '\') {
                $isEscaped = $true
            }
            elseif ($current -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($current -eq ';') {
            $inLineComment = $true
            continue
        }
        if ($current -eq '"') {
            $inString = $true
            continue
        }
        if ($current -eq '(') {
            if ($rootEnd -ge 0) {
                throw "Multiple root expressions in KiCad library: $FilePath"
            }
            if ($depth -eq 1) {
                $match = $symbolPattern.Match($content, $index)
                if ($match.Success -and $match.Index -eq $index) {
                    $symbolStart = $index
                    $symbolName = $match.Groups[1].Value
                    [void]$metadata.Append($content.Substring($previousEnd, $index - $previousEnd))
                }
            }
            elseif ($depth -eq 2 -and $symbolStart -ge 0 -and
                [regex]::IsMatch($content.Substring($index, [Math]::Min(16, $content.Length - $index)), '^\(extends(?:\s|\))')) {
                throw "Cannot export an inherited symbol independently: $symbolName"
            }
            $depth++
            continue
        }
        if ($current -eq ')') {
            $depth--
            if ($depth -lt 0) {
                throw "Unbalanced closing parenthesis in KiCad library: $FilePath"
            }
            if ($depth -eq 1 -and $symbolStart -ge 0) {
                [void]$symbols.Add([pscustomobject]@{
                    Name = $symbolName
                    Text = $content.Substring($symbolStart, $index - $symbolStart + 1)
                })
                $previousEnd = $index + 1
                $symbolStart = -1
            }
            if ($depth -eq 0) {
                $rootEnd = $index
            }
        }
    }

    if ($inString -or $depth -ne 0) {
        throw "Unbalanced KiCad symbol library: $FilePath"
    }
    if ($symbols.Count -eq 0) {
        throw "Converted library contains no top-level symbols: $FilePath"
    }

    [void]$metadata.Append($content.Substring($previousEnd, $rootEnd - $previousEnd))
    return [pscustomobject]@{
        Symbols = $symbols.ToArray()
        Header = $metadata.ToString().TrimEnd()
        Footer = $content.Substring($rootEnd)
    }
}

function Export-KiCadIndividualSymbols {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Library,

        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    [void][System.IO.Directory]::CreateDirectory($Directory)
    $usedNames = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $fileNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($symbol in $Library.Symbols) {
        # Decode KiCad escapes only for the filename; keep the symbol verbatim.
        $decoded = [regex]::Replace($symbol.Name, '\\([\\"nr])', {
            param($match)
            switch ($match.Groups[1].Value) {
                'n' { return "`n" }
                'r' { return "`r" }
                default { return $match.Groups[1].Value }
            }
        })
        $baseName = [regex]::Replace($decoded, '[<>:"/\\|?*\x00-\x1F]', '_').TrimEnd([char[]]' .')
        # Reserve space for the extension and collision suffix on Windows.
        $nameLimit = [Math]::Min(120, 240 - $Directory.Length - 24)
        if ($nameLimit -lt 8) { throw "The individual-symbol output path is too long: $Directory" }
        if ($baseName.Length -gt $nameLimit) {
            if ([char]::IsHighSurrogate($baseName[$nameLimit - 1])) { $nameLimit-- }
            $baseName = $baseName.Substring(0, $nameLimit).TrimEnd([char[]]' .')
        }
        if ([string]::IsNullOrWhiteSpace($baseName)) { $baseName = 'symbol' }
        if ($baseName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9\u00B9\u00B2\u00B3]|LPT[1-9\u00B9\u00B2\u00B3]|CONIN\$|CONOUT\$)(?:\.|$)') {
            $baseName = '_' + $baseName
        }
        $fileName = $baseName + '.kicad_sym'
        $suffix = 2
        while (-not $usedNames.Add($fileName)) {
            $fileName = $baseName + '_' + $suffix + '.kicad_sym'
            $suffix++
        }
        $destination = [System.IO.Path]::Combine($Directory, $fileName)
        $text = $Library.Header + "`n`t" + $symbol.Text + "`n" + $Library.Footer
        [System.IO.File]::WriteAllText($destination, $text, $utf8NoBom)
        [void]$fileNames.Add($fileName)
    }
    return $fileNames.ToArray()
}

$resolvedCli = Resolve-KiCadCliPath -Path $KicadCliPath

$resolvedSource = Get-AbsolutePath -Value $SourceSchLib -Label 'SourceSchLib'
if (-not [System.IO.File]::Exists($resolvedSource)) {
    throw "Source SchLib was not found: $resolvedSource"
}
if ([System.IO.Path]::GetExtension($resolvedSource) -ine '.SchLib') {
    throw "SourceSchLib must have the .SchLib extension: $resolvedSource"
}

if ([string]::IsNullOrWhiteSpace($OutputKicadSym)) {
    $sourceDirectory = [System.IO.Path]::GetDirectoryName($resolvedSource)
    $sourceBaseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedSource)
    $OutputKicadSym = [System.IO.Path]::Combine(
        $sourceDirectory,
        $sourceBaseName + '.kicad_sym'
    )
}

$resolvedOutput = Get-AbsolutePath -Value $OutputKicadSym -Label 'OutputKicadSym'
if ([System.IO.Path]::GetExtension($resolvedOutput) -ine '.kicad_sym') {
    throw "OutputKicadSym must have the .kicad_sym extension: $resolvedOutput"
}
if ([System.IO.File]::Exists($resolvedOutput) -or
    [System.IO.Directory]::Exists($resolvedOutput)) {
    throw "OutputKicadSym already exists; choose a new path: $resolvedOutput"
}

$outputParent = [System.IO.Path]::GetDirectoryName($resolvedOutput)
if (-not [System.IO.Directory]::Exists($outputParent)) {
    throw "The output parent directory does not exist: $outputParent"
}

$individualSymbolsDirectory = [System.IO.Path]::Combine(
    $outputParent, [System.IO.Path]::GetFileNameWithoutExtension($resolvedOutput) + '_symbols'
)
if ([System.IO.Directory]::Exists($individualSymbolsDirectory) -or
    [System.IO.File]::Exists($individualSymbolsDirectory)) {
    throw "Individual-symbol output already exists; choose a new output path: $individualSymbolsDirectory"
}

$versionOutput = @(& $resolvedCli --version 2>&1)
$versionExitCode = $LASTEXITCODE
$versionLines = @(
    $versionOutput |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
foreach ($versionLine in $versionLines) {
    Write-Host $versionLine
}
if ($versionExitCode -ne 0 -or $versionLines.Count -eq 0) {
    throw "Unable to read the KiCad CLI version from: $resolvedCli"
}
$kicadVersion = $versionLines[-1]

$sourceHashBefore = (Get-FileHash -LiteralPath $resolvedSource -Algorithm SHA256).Hash
$stagingDirectory = [System.IO.Path]::Combine(
    $outputParent,
    '.' + [System.IO.Path]::GetFileName($resolvedOutput) +
        '.ad2kicadsch-' + [System.Guid]::NewGuid().ToString('N') + '.tmp'
)
[void][System.IO.Directory]::CreateDirectory($stagingDirectory)
Assert-ContainedDirectory -Target $stagingDirectory -IntendedRoot $outputParent

$sourceCopy = [System.IO.Path]::Combine(
    $stagingDirectory,
    [System.IO.Path]::GetFileName($resolvedSource)
)
$stagingOutput = [System.IO.Path]::Combine(
    $stagingDirectory,
    [System.IO.Path]::GetFileName($resolvedOutput)
)
$roundTripOutput = [System.IO.Path]::Combine(
    $stagingDirectory,
    '.roundtrip-' + [System.Guid]::NewGuid().ToString('N') + '.kicad_sym'
)
$renderDirectory = [System.IO.Path]::Combine($stagingDirectory, 'svg-check')
$stagingSymbolsDirectory = [System.IO.Path]::Combine($stagingDirectory, 'symbols')
$cleanupFailure = $null

try {
    [System.IO.File]::Copy($resolvedSource, $sourceCopy, $false)
    $sourceCopyHash = (Get-FileHash -LiteralPath $sourceCopy -Algorithm SHA256).Hash
    if ($sourceCopyHash -cne $sourceHashBefore) {
        throw 'The staged source copy does not match the original source hash'
    }

    Invoke-KiCadCommand -Executable $resolvedCli -Operation 'Altium SchLib conversion' -Arguments @(
        'sym', 'upgrade', '--output', $stagingOutput, $sourceCopy
    )
    if (-not [System.IO.File]::Exists($stagingOutput)) {
        throw "KiCad did not create the converted library: $stagingOutput"
    }

    $convertedLibrary = Read-KiCadSymbolLibrary -FilePath $stagingOutput
    $convertedNames = @($convertedLibrary.Symbols | ForEach-Object { $_.Name })
    Invoke-KiCadCommand -Executable $resolvedCli -Operation 'KiCad round-trip save' -Arguments @(
        'sym', 'upgrade', '--force', '--output', $roundTripOutput, $stagingOutput
    )
    $roundTripLibrary = Read-KiCadSymbolLibrary -FilePath $roundTripOutput
    $roundTripNames = @($roundTripLibrary.Symbols | ForEach-Object { $_.Name })

    if ($convertedNames.Count -ne $roundTripNames.Count) {
        throw 'Top-level symbol count changed during the KiCad round-trip save'
    }
    $nameDifferences = @(
        Compare-Object `
            -ReferenceObject $convertedNames `
            -DifferenceObject $roundTripNames `
            -CaseSensitive
    )
    if ($nameDifferences.Count -ne 0) {
        $differencePreview = @(
            $nameDifferences |
                Select-Object -First 10 |
                ForEach-Object { "$(($_.SideIndicator)): $(($_.InputObject))" }
        ) -join '; '
        throw "Top-level symbol names changed during the KiCad round-trip save: $differencePreview"
    }

    [void][System.IO.Directory]::CreateDirectory($renderDirectory)
    Invoke-KiCadCommand -Executable $resolvedCli -Operation 'Full-library SVG render' -Quiet -Arguments @(
        'sym', 'export', 'svg',
        '--output', $renderDirectory,
        '--include-hidden-pins',
        '--include-hidden-fields',
        $roundTripOutput
    )

    $renderedSvgFiles = @(
        [System.IO.Directory]::EnumerateFiles(
            $renderDirectory,
            '*.svg',
            [System.IO.SearchOption]::AllDirectories
        )
    )
    if ($renderedSvgFiles.Count -eq 0) {
        throw 'KiCad rendered no SVG files from the converted library'
    }
    foreach ($renderedSvgFile in $renderedSvgFiles) {
        if ((Get-Item -LiteralPath $renderedSvgFile).Length -le 0) {
            throw "KiCad rendered an empty SVG file: $renderedSvgFile"
        }
    }

    Write-Host 'Running: Individual-symbol library export'
    $individualFileNames = @(Export-KiCadIndividualSymbols -Library $roundTripLibrary -Directory $stagingSymbolsDirectory)
    Write-Host ("Exported {0} individual symbol libraries" -f $individualFileNames.Count)

    $sourceHashAfter = (Get-FileHash -LiteralPath $resolvedSource -Algorithm SHA256).Hash
    if ($sourceHashAfter -cne $sourceHashBefore) {
        throw 'The source SchLib changed during conversion'
    }
    if ([System.IO.File]::Exists($resolvedOutput) -or
        [System.IO.Directory]::Exists($resolvedOutput)) {
        throw "Output appeared during conversion; refusing to overwrite it: $resolvedOutput"
    }

    $outputHash = (Get-FileHash -LiteralPath $roundTripOutput -Algorithm SHA256).Hash
    # Publish the complete folder first; the whole library is the completion marker.
    Assert-ContainedDirectory -Target $stagingSymbolsDirectory -IntendedRoot $outputParent
    [System.IO.Directory]::Move($stagingSymbolsDirectory, $individualSymbolsDirectory)
    try {
        [System.IO.File]::Move($roundTripOutput, $resolvedOutput)
    }
    catch {
        Assert-ContainedDirectory -Target $individualSymbolsDirectory -IntendedRoot $outputParent
        Assert-ContainedDirectory -Target $stagingDirectory -IntendedRoot $outputParent
        [System.IO.Directory]::Move($individualSymbolsDirectory, $stagingSymbolsDirectory)
        throw
    }
}
finally {
    try {
        Remove-TemporaryDirectory -Target $stagingDirectory -IntendedRoot $outputParent
    }
    catch {
        $cleanupFailure = $_.Exception.Message
    }
}

$cleanupSucceeded = [string]::IsNullOrWhiteSpace($cleanupFailure)
if (-not $cleanupSucceeded) {
    Write-Warning "Converted library is valid, but staging cleanup failed: $cleanupFailure"
}

[pscustomobject]@{
    Source = $resolvedSource
    Output = $resolvedOutput
    IndividualSymbolsDirectory = $individualSymbolsDirectory
    IndividualSymbolFiles = @($individualFileNames | ForEach-Object { [System.IO.Path]::Combine($individualSymbolsDirectory, $_) })
    KicadVersion = $kicadVersion
    KicadCliPath = $resolvedCli
    TopLevelSymbols = $convertedNames.Count
    RenderedSvgFiles = $renderedSvgFiles.Count
    SourceSHA256 = $sourceHashBefore
    OutputSHA256 = $outputHash
    SourceUnchanged = $true
    RoundTripSymbolNamesMatch = $true
    StagingCleanupSucceeded = $cleanupSucceeded
}
