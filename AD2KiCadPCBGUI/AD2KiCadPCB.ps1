<#
.SYNOPSIS
Converts an Altium Designer PcbLib into a KiCad .pretty footprint library.

.PARAMETER KicadCliPath
Optional absolute path to kicad-cli.exe. When omitted, use the saved setting or discover a local installation.

.PARAMETER SourcePcbLib
Path to the source .PcbLib file.

.PARAMETER OutputPretty
Optional destination .pretty path. Defaults to <source-name>.pretty beside the source.

.EXAMPLE
.\AD2KiCadPCB.ps1 -SourcePcbLib 'C:\Libraries\Parts.PcbLib'
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$KicadCliPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePcbLib,

    [Parameter()]
    [string]$OutputPretty
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
$global:OutputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom

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

$environmentScript = [System.IO.Path]::Combine($PSScriptRoot, 'KiCadEnvironment.ps1')
if (-not [System.IO.File]::Exists($environmentScript)) {
    throw "The bundled environment script was not found: $environmentScript"
}
. $environmentScript
$resolvedCli = Resolve-KiCadCliPath -Path $KicadCliPath

$resolvedSource = Get-AbsolutePath -Value $SourcePcbLib -Label 'SourcePcbLib'
if (-not [System.IO.File]::Exists($resolvedSource)) {
    throw "Source PcbLib was not found: $resolvedSource"
}
if ([System.IO.Path]::GetExtension($resolvedSource) -ine '.PcbLib') {
    throw "SourcePcbLib must have the .PcbLib extension: $resolvedSource"
}

if ([string]::IsNullOrWhiteSpace($OutputPretty)) {
    $sourceDirectory = [System.IO.Path]::GetDirectoryName($resolvedSource)
    $sourceBaseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedSource)
    $OutputPretty = [System.IO.Path]::Combine($sourceDirectory, $sourceBaseName + '.pretty')
}

$resolvedOutput = Get-AbsolutePath -Value $OutputPretty -Label 'OutputPretty'
if ([System.IO.Path]::GetExtension($resolvedOutput) -ine '.pretty') {
    throw "OutputPretty must have the .pretty extension: $resolvedOutput"
}
if ([System.IO.File]::Exists($resolvedOutput) -or [System.IO.Directory]::Exists($resolvedOutput)) {
    throw "OutputPretty already exists; choose a new path to avoid overwriting: $resolvedOutput"
}

$outputParent = [System.IO.Path]::GetDirectoryName($resolvedOutput)
if (-not [System.IO.Directory]::Exists($outputParent)) {
    throw "The OutputPretty parent directory does not exist: $outputParent"
}
$stagingDirectory = [System.IO.Path]::Combine(
    $outputParent,
    '.' + [System.IO.Path]::GetFileName($resolvedOutput) +
        '.ad2kicadpcb-' + [System.Guid]::NewGuid().ToString('N') + '.tmp'
)

$kicadBin = [System.IO.Path]::GetDirectoryName($resolvedCli)
$kicadPython = [System.IO.Path]::Combine($kicadBin, 'python.exe')
if (-not [System.IO.File]::Exists($kicadPython)) {
    throw "KiCad's bundled python.exe was not found beside kicad-cli.exe: $kicadPython"
}

Write-Output "Validating KiCad CLI: $resolvedCli"
$cliOutput = @(& $resolvedCli --version 2>&1)
$cliExitCode = $LASTEXITCODE
$cliLines = @(
    $cliOutput |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
$cliLines | ForEach-Object { Write-Output $_ }
if ($cliExitCode -ne 0) {
    throw "kicad-cli.exe --version failed with exit code $cliExitCode"
}
if ($cliLines.Count -eq 0) {
    throw 'kicad-cli.exe --version returned no version text'
}
$expectedKicadVersion = $cliLines[-1]

$converterSource = @'
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import pcbnew
except Exception as exc:
    raise RuntimeError(
        "KiCad's bundled Python could not import pcbnew. "
        "Use kicad-cli.exe from a complete KiCad installation."
    ) from exc


INVALID_FILENAME_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
WINDOWS_RESERVED_NAMES = {
    "CON",
    "PRN",
    "AUX",
    "NUL",
    *(f"COM{number}" for number in range(1, 10)),
    *(f"LPT{number}" for number in range(1, 10)),
}
MAX_ITEM_NAME_LENGTH = 120
POSITION_TOLERANCE_NM = 1000
POSITION_GETTERS = {
    "GetPosition",
    "GetStart",
    "GetEnd",
    "GetCenter",
    "GetTextPos",
    "GetOffset",
    "GetDelta",
    "GetPolyPoints",
    "GetBezierC1",
    "GetBezierC2",
    "GetBezierPoints",
}

PAD_GETTERS = (
    "GetNumber",
    "GetPinFunction",
    "GetPinType",
    "GetAttribute",
    "GetProperty",
    "GetShape",
    "GetPosition",
    "GetSize",
    "GetDrillShape",
    "GetDrillSize",
    "GetOrientationDegrees",
    "GetOffset",
    "GetDelta",
    "GetLayerSet",
    "GetRoundRectRadiusRatio",
    "GetChamferRectRatio",
    "GetChamferPositions",
    "GetCustomShapeInZoneOpt",
    "GetLocalClearance",
    "GetLocalSolderMaskMargin",
    "GetLocalSolderPasteMargin",
    "GetLocalSolderPasteMarginRatio",
    "GetLocalThermalGapOverride",
    "GetLocalThermalSpokeWidthOverride",
    "GetLocalZoneConnection",
    "GetRemoveUnconnected",
    "GetKeepTopBottom",
    "GetPadToDieLength",
    "GetPadToDieDelay",
)

GRAPHIC_GETTERS = (
    "GetLayer",
    "GetShape",
    "GetPosition",
    "GetStart",
    "GetEnd",
    "GetCenter",
    "GetWidth",
    "GetFillMode",
    "GetCornerRadius",
    "GetText",
    "GetTextPos",
    "GetTextSize",
    "GetTextThickness",
    "GetTextAngleDegrees",
    "GetHorizJustify",
    "GetVertJustify",
)

GRAPHIC_FLAGS = (
    "IsBold",
    "IsItalic",
    "IsMirrored",
    "IsVisible",
    "IsKnockout",
)

FIELD_GETTERS = (
    "GetId",
    "GetName",
    "GetCanonicalName",
)

def sanitize_item_name(source_name: str) -> str:
    name = INVALID_FILENAME_CHARS.sub("_", source_name).rstrip(" .")
    if not name:
        name = "unnamed"
    if name.split(".", 1)[0].upper() in WINDOWS_RESERVED_NAMES:
        name = "_" + name
    return name[:MAX_ITEM_NAME_LENGTH].rstrip(" .") or "unnamed"


def allocate_item_name(source_name: str, used_names: set[str]) -> str:
    base_name = sanitize_item_name(source_name)
    candidate = base_name
    suffix_number = 2
    while candidate.casefold() in used_names:
        suffix = f"__{suffix_number}"
        prefix_length = MAX_ITEM_NAME_LENGTH - len(suffix)
        candidate = base_name[:prefix_length].rstrip(" .") + suffix
        suffix_number += 1
    used_names.add(candidate.casefold())
    return candidate


def freeze(value):
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        return round(value, 9)
    if hasattr(value, "AsDegrees"):
        return round(float(value.AsDegrees()), 9)
    if (
        hasattr(value, "x")
        and hasattr(value, "y")
        and hasattr(value, "z")
    ):
        return [
            round(float(value.x), 9),
            round(float(value.y), 9),
            round(float(value.z), 9),
        ]
    if hasattr(value, "x") and hasattr(value, "y"):
        return [
            int(value.x),
            int(value.y),
        ]
    if hasattr(value, "Seq"):
        return sorted(int(item) for item in value.Seq())
    if all(
        hasattr(value, name)
        for name in ("GetX", "GetY", "GetWidth", "GetHeight")
    ):
        return [
            int(value.GetX()),
            int(value.GetY()),
            int(value.GetWidth()),
            int(value.GetHeight()),
        ]
    try:
        return [freeze(item) for item in value]
    except TypeError:
        try:
            return int(value)
        except (TypeError, ValueError):
            return {"type": type(value).__name__}


def get_values(item, getters: tuple[str, ...]) -> dict:
    result = {}
    for getter_name in getters:
        getter = getattr(item, getter_name, None)
        if getter is None:
            continue
        try:
            value = freeze(getter())
            if getter_name in (
                "GetOrientationDegrees",
                "GetTextAngleDegrees",
            ):
                value = round(float(value) % 360.0, 2)
                if value == 360.0:
                    value = 0.0
            elif getter_name == "GetArcAngleStart":
                # Altium arc import can move the start angle by a few
                # hundredths of a degree when quantizing to KiCad geometry.
                value = round((float(value) % 360.0) * 2.0) / 2.0
                if value == 360.0:
                    value = 0.0
            elif getter_name == "GetArcAngle":
                value = round(float(value), 1)
            elif getter_name == "GetSize" and isinstance(value, list):
                value = [max(1000, int(component)) for component in value]
            result[getter_name] = value
        except Exception as exc:
            result[getter_name] = {"error": type(exc).__name__}
    return result


def graphic_fingerprint(item) -> dict:
    result = {
        "class": item.__class__.__name__,
        "values": get_values(item, GRAPHIC_GETTERS),
    }
    flags = get_values(item, GRAPHIC_FLAGS)
    if flags:
        result["flags"] = flags

    shape_getter = getattr(item, "GetShape", None)
    if shape_getter is not None:
        shape = int(shape_getter())
        if shape == int(pcbnew.SHAPE_T_ARC):
            result["shape_values"] = get_values(
                item, ("GetArcAngle", "GetArcAngleStart")
            )
        elif shape == int(pcbnew.SHAPE_T_BEZIER):
            result["shape_values"] = get_values(
                item,
                ("GetBezierC1", "GetBezierC2", "GetBezierPoints"),
            )
        elif shape == int(pcbnew.SHAPE_T_POLY):
            result["shape_values"] = get_values(item, ("GetPolyPoints",))
    return result


def canonical_rows(rows) -> list[str]:
    return sorted(
        json.dumps(
            row,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        for row in rows
    )


def values_equal(left, right, getter_name: str | None = None) -> bool:
    """Compare fingerprint data while allowing importer coordinate quantization."""
    if isinstance(left, bool) or isinstance(right, bool):
        return left is right
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        if getter_name in POSITION_GETTERS:
            return abs(float(left) - float(right)) <= POSITION_TOLERANCE_NM
        return left == right
    if isinstance(left, dict) and isinstance(right, dict):
        if set(left) != set(right):
            return False
        return all(
            values_equal(left[key], right[key], key)
            for key in left
        )
    if isinstance(left, list) and isinstance(right, list):
        if len(left) != len(right):
            return False
        return all(
            values_equal(left_item, right_item, getter_name)
            for left_item, right_item in zip(left, right)
        )
    return left == right


def rows_equal(left_rows: list[str], right_rows: list[str]) -> bool:
    if len(left_rows) != len(right_rows):
        return False
    remaining = [json.loads(row) for row in right_rows]
    for left_row in left_rows:
        left_value = json.loads(left_row)
        match_index = next(
            (
                index
                for index, right_value in enumerate(remaining)
                if values_equal(left_value, right_value)
            ),
            None,
        )
        if match_index is None:
            return False
        remaining.pop(match_index)
    return not remaining


def fingerprints_equal(left: dict, right: dict) -> bool:
    if set(left) != set(right):
        return False
    for key in left:
        left_value = left[key]
        right_value = right[key]
        if isinstance(left_value, list) and all(
            isinstance(row, str) for row in left_value
        ):
            if not isinstance(right_value, list) or not rows_equal(
                left_value, right_value
            ):
                return False
        elif not values_equal(left_value, right_value):
            return False
    return True


def pad_fingerprint(pad) -> dict:
    result = get_values(pad, PAD_GETTERS)
    primitives = {}
    if int(pad.GetShape()) == int(pcbnew.PAD_SHAPE_CUSTOM):
        for layer in pad.GetLayerSet().Seq():
            try:
                layer_primitives = list(pad.GetPrimitives(layer))
            except Exception:
                continue
            if layer_primitives:
                primitives[str(int(layer))] = canonical_rows(
                    graphic_fingerprint(item) for item in layer_primitives
                )
    result["custom_primitives"] = primitives
    return result


def field_fingerprint(field) -> dict:
    result = graphic_fingerprint(field)
    result["field_values"] = get_values(field, FIELD_GETTERS)
    return result


def zone_fingerprint(zone) -> dict:
    return {"class": zone.__class__.__name__}


def model_fingerprint(model) -> dict:
    return {
        attribute: freeze(getattr(model, attribute))
        for attribute in (
            "m_Filename",
            "m_Offset",
            "m_Opacity",
            "m_Rotation",
            "m_Scale",
            "m_Show",
        )
    }


def footprint_fingerprint(footprint) -> dict:
    return {
        "pads": canonical_rows(
            pad_fingerprint(item) for item in list(footprint.Pads())
        ),
        "graphics": canonical_rows(
            graphic_fingerprint(item)
            for item in list(footprint.GraphicalItems())
        ),
        "fields": canonical_rows(
            field_fingerprint(item) for item in list(footprint.GetFields())
        ),
        "zones": canonical_rows(
            zone_fingerprint(item) for item in list(footprint.Zones())
        ),
        "models": canonical_rows(
            model_fingerprint(item) for item in list(footprint.Models())
        ),
    }


def footprint_metrics(footprint) -> dict[str, int]:
    return {
        "pads": len(list(footprint.Pads())),
        "graphics": len(list(footprint.GraphicalItems())),
    }


def worker_convert(
    source: Path,
    staging: Path,
    source_names: list[str],
    target_names: list[str],
    start_index: int,
    total: int,
) -> None:
    """Write a small group in a fresh KiCad process.

    KiCad 10 can crash in its native footprint writer after a particular
    sequence of Altium footprints.  A worker process keeps that native state
    isolated without changing the generated footprint data.
    """
    if len(source_names) != len(target_names):
        raise RuntimeError("Worker source/target name count mismatch")
    if staging.exists():
        raise RuntimeError(f"Worker staging path already exists: {staging}")
    staging.mkdir(parents=True)
    writer = pcbnew.PCB_IO_MGR.FindPlugin(pcbnew.PCB_IO_MGR.KICAD_SEXP)
    if writer is None:
        raise RuntimeError("KiCad's s-expression footprint writer is unavailable")

    for offset, source_name in enumerate(source_names):
        source_index = start_index + offset
        target_name = target_names[offset]
        print(
            "AD2KICADPCB_EVENT\tFOOTPRINT\t"
            + str(source_index)
            + "\t"
            + str(total)
            + "\t"
            + json.dumps(source_name, ensure_ascii=False),
            flush=True,
        )
        footprint = pcbnew.FootprintLoad(str(source), source_name)
        if footprint is None:
            raise RuntimeError(f"Failed to load source footprint: {source_name}")
        footprint.SetFPID(pcbnew.LIB_ID("", target_name))
        if target_name != source_name:
            footprint.SetValue(target_name)
        writer.FootprintSave(str(staging), footprint)

    print("AD2KICADPCB_WORKER_OK", flush=True)


def run_isolated_worker(
    source: Path,
    chunk: Path,
    source_names: list[str],
    target_names: list[str],
    start_index: int,
    total: int,
) -> tuple[int, list[str]]:
    worker_script = Path(__file__).resolve()
    arguments = [
        sys.executable,
        "-I",
        str(worker_script),
        "--worker",
        "--source",
        str(source),
        "--staging",
        str(chunk),
        "--start-index",
        str(start_index),
        "--total",
        str(total),
    ]
    for source_name, target_name in zip(source_names, target_names):
        arguments.extend(("--name", source_name, "--target-name", target_name))

    try:
        process = subprocess.Popen(
            arguments,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except OSError as exc:
        raise RuntimeError(f"Could not start isolated KiCad worker: {exc}") from exc

    output_lines: list[str] = []
    assert process.stdout is not None
    for line in process.stdout:
        normalized = line.rstrip("\r\n")
        output_lines.append(normalized)
        print(normalized, flush=True)
    return process.wait(), output_lines


def save_isolated_chunks(
    source: Path,
    staging: Path,
    source_names: list[str],
    target_names: list[str],
    marker_path: Path,
) -> None:
    """Write footprints in restartable chunks and bisect a crashing chunk."""
    total = len(source_names)
    initial_chunk_size = 32

    def save_range(first: int, last: int) -> None:
        names = source_names[first:last]
        targets = target_names[first:last]
        if not names:
            return

        marker_path.write_text(names[0], encoding="utf-8")
        chunk = staging.parent / (
            "." + staging.name + ".worker-" + os.urandom(8).hex() + ".tmp"
        )
        try:
            exit_code, output_lines = run_isolated_worker(
                source,
                chunk,
                names,
                targets,
                first + 1,
                total,
            )
            worker_ok = "AD2KICADPCB_WORKER_OK" in output_lines
            if exit_code == 0 and worker_ok:
                for output_file in chunk.glob("*.kicad_mod"):
                    shutil.move(str(output_file), str(staging / output_file.name))
                return

            if len(names) == 1:
                details = next(
                    (line for line in reversed(output_lines) if line.strip()),
                    "no worker diagnostics",
                )
                raise RuntimeError(
                    "Isolated KiCad worker failed while writing footprint "
                    f"{names[0]} (exit code {exit_code}): {details}"
                )
        finally:
            if chunk.exists():
                shutil.rmtree(chunk, ignore_errors=True)

        middle = first + len(names) // 2
        save_range(first, middle)
        save_range(middle, last)

    for first in range(0, total, initial_chunk_size):
        save_range(first, min(first + initial_chunk_size, total))


def validate_runtime(expected_root: Path, expected_version: str) -> dict:
    module_path = Path(pcbnew.__file__).resolve()
    resolved_root = expected_root.resolve()
    try:
        common_path = os.path.commonpath(
            (str(module_path), str(resolved_root))
        )
    except ValueError as exc:
        raise RuntimeError(
            f"pcbnew was loaded outside the selected KiCad installation: "
            f"{module_path}"
        ) from exc

    if os.path.normcase(common_path) != os.path.normcase(str(resolved_root)):
        raise RuntimeError(
            f"pcbnew was loaded outside the selected KiCad installation: "
            f"{module_path}"
        )

    actual_version = str(pcbnew.GetBuildVersion()).strip()
    if actual_version != expected_version.strip():
        raise RuntimeError(
            "KiCad CLI and pcbnew versions do not match: "
            f"cli={expected_version!r}, pcbnew={actual_version!r}"
        )

    return {
        "kicad_version": actual_version,
        "pcbnew_module": str(module_path),
    }


def convert(
    source: Path,
    target: Path,
    staging: Path,
    runtime: dict,
) -> dict:
    if target.exists():
        raise RuntimeError(f"Output already exists: {target}")

    source_names = [str(name) for name in pcbnew.FootprintEnumerate(str(source))]
    if not source_names:
        raise RuntimeError(f"KiCad found no footprints in: {source}")

    print(
        "AD2KICADPCB_EVENT\tSTART\t"
        + str(len(source_names)),
        flush=True,
    )

    if staging.exists():
        raise RuntimeError(f"Staging path already exists: {staging}")
    staging.mkdir()

    used_names: set[str] = set()
    target_names = [
        allocate_item_name(source_name, used_names)
        for source_name in source_names
    ]
    records: list[dict] = []
    marker_path = staging / ".ad2kicadpcb-current"

    try:
        save_isolated_chunks(
            source,
            staging,
            source_names,
            target_names,
            marker_path,
        )

        embedded_model_count = 0
        for source_index, source_name in enumerate(source_names, start=1):
            target_name = target_names[source_index - 1]
            footprint = pcbnew.FootprintLoad(str(source), source_name)
            if footprint is None:
                raise RuntimeError(f"Failed to load source footprint: {source_name}")

            embedded_model_count += sum(
                1
                for model in list(footprint.Models())
                if str(model.m_Filename).lower().startswith("kicad-embed://")
            )

            metrics = footprint_metrics(footprint)
            footprint.SetFPID(pcbnew.LIB_ID("", target_name))
            if target_name != source_name:
                footprint.SetValue(target_name)
            reloaded = pcbnew.FootprintLoad(str(staging), target_name)
            if reloaded is None:
                raise RuntimeError(
                    f"Failed to reload converted footprint: {target_name}"
                )
            source_fingerprint = footprint_fingerprint(footprint)
            output_fingerprint = footprint_fingerprint(reloaded)
            if not fingerprints_equal(source_fingerprint, output_fingerprint):
                changed_collections = sorted(
                    key
                    for key in source_fingerprint
                    if source_fingerprint[key] != output_fingerprint.get(key)
                )
                difference_details = {}
                for collection in changed_collections:
                    source_rows = set(source_fingerprint[collection])
                    output_rows = set(output_fingerprint.get(collection, []))
                    difference_details[collection] = {
                        "source_only": sorted(source_rows - output_rows)[:1],
                        "output_only": sorted(output_rows - source_rows)[:1],
                    }
                raise RuntimeError(
                    f"Footprint structure changed after reload for "
                    f"{target_name}; details="
                    + json.dumps(difference_details, ensure_ascii=False)
                )

            records.append(
                {
                    "source": source_name,
                    "target": target_name,
                    "renamed": target_name != source_name,
                    **metrics,
                }
            )

        expected_names = {record["target"] for record in records}
        suffix = ".kicad_mod"
        actual_names = {
            output_file.name[: -len(suffix)]
            for output_file in staging.glob("*" + suffix)
        }
        if actual_names != expected_names:
            raise RuntimeError(
                "Output enumeration mismatch: "
                + json.dumps(
                    {
                        "missing": sorted(expected_names - actual_names),
                        "extra": sorted(actual_names - expected_names),
                    },
                    ensure_ascii=False,
                )
            )

        output_files = list(staging.glob("*.kicad_mod"))
        if len(output_files) != len(expected_names):
            raise RuntimeError(
                f"Expected {len(expected_names)} .kicad_mod files, "
                f"found {len(output_files)}"
            )

        report = {
            "format_version": 1,
            **runtime,
            "source": str(source),
            "output": str(target),
            "source_count": len(source_names),
            "output_count": len(expected_names),
            "renamed_count": sum(record["renamed"] for record in records),
            "embedded_model_count": embedded_model_count,
            "embedded_model_strategy": "isolated-kicad-worker",
            "validation": {
                "method": "footprint-structural-fingerprint",
                "position_tolerance_nm": 1000,
                "angle_tolerance_degrees": 0.25,
                "minimum_pad_size_nm": 1000,
                "zone_validation": "collection-count-and-type",
            },
            "footprints": records,
        }
        report_path = staging / "ad2kicadpcb-report.json"
        report_path.write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        marker_path.unlink()

        staging.rename(target)
        return report
    except Exception:
        if staging.exists():
            shutil.rmtree(staging)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=False, type=Path)
    parser.add_argument("--staging", required=True, type=Path)
    parser.add_argument("--expected-kicad-root", required=False, type=Path)
    parser.add_argument("--expected-kicad-version", required=False)
    parser.add_argument("--start-index", required=False, type=int)
    parser.add_argument("--total", required=False, type=int)
    parser.add_argument("--name", action="append", default=[])
    parser.add_argument("--target-name", action="append", default=[])
    args = parser.parse_args()

    try:
        if args.worker:
            if args.start_index is None or args.total is None:
                raise RuntimeError("Worker start index and total are required")
            worker_convert(
                args.source.resolve(),
                args.staging.resolve(),
                list(args.name),
                list(args.target_name),
                args.start_index,
                args.total,
            )
            return 0
        if args.output is None or args.expected_kicad_root is None or args.expected_kicad_version is None:
            raise RuntimeError("Output and KiCad runtime validation arguments are required")
        runtime = validate_runtime(
            args.expected_kicad_root,
            args.expected_kicad_version,
        )
        report = convert(
            args.source.resolve(),
            args.output.resolve(),
            args.staging.resolve(),
            runtime,
        )
    except Exception as exc:
        print(f"AD2KiCadPCB conversion failed: {exc}", file=sys.stderr)
        return 1

    print(
        json.dumps(
            {
                "status": "ok",
                "kicad_version": report["kicad_version"],
                "pcbnew_module": report["pcbnew_module"],
                "source_count": report["source_count"],
                "output_count": report["output_count"],
                "renamed_count": report["renamed_count"],
                "output": report["output"],
                "report": str(
                    Path(report["output"]) / "ad2kicadpcb-report.json"
                ),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

$temporaryScript = [System.IO.Path]::Combine(
    [System.IO.Path]::GetTempPath(),
    'ad2kicadpcb-' + [System.Guid]::NewGuid().ToString('N') + '.py'
)

try {
    [System.IO.File]::WriteAllText($temporaryScript, $converterSource, $utf8NoBom)
    Write-Output "Converting with KiCad's official Altium importer..."
    $converterLines = New-Object 'System.Collections.Generic.List[string]'
    & $kicadPython -I $temporaryScript --source $resolvedSource --output $resolvedOutput --staging $stagingDirectory --expected-kicad-root $kicadBin --expected-kicad-version $expectedKicadVersion 2>&1 |
        ForEach-Object {
            $converterLine = [string]$_
            $converterLines.Add($converterLine)
            Write-Output $converterLine
        }
    $converterExitCode = $LASTEXITCODE
    if ($converterExitCode -ne 0) {
        $markerPath = [System.IO.Path]::Combine(
            $stagingDirectory,
            '.ad2kicadpcb-current'
        )
        if ([System.IO.File]::Exists($markerPath)) {
            $failedFootprint = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8
            throw "Conversion failed with exit code $converterExitCode while processing footprint: $failedFootprint"
        }
        $errorLines = @(
            $converterLines |
                Where-Object { $_ -like 'AD2KiCadPCB conversion failed:*' }
        )
        if ($errorLines.Count -gt 0) {
            throw "$($errorLines[-1]) (exit code $converterExitCode)"
        }
        throw "Conversion failed with exit code $converterExitCode"
    }
}
finally {
    if ([System.IO.File]::Exists($temporaryScript)) {
        try {
            Remove-Item -LiteralPath $temporaryScript -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not remove temporary converter script: $temporaryScript"
        }
    }
    if ([System.IO.Directory]::Exists($stagingDirectory)) {
        $resolvedParent = [System.IO.Path]::GetFullPath($outputParent).TrimEnd([char]92)
        $resolvedStaging = [System.IO.Path]::GetFullPath($stagingDirectory).TrimEnd([char]92)
        $parentPrefix = $resolvedParent + [System.IO.Path]::DirectorySeparatorChar
        if ($resolvedStaging.StartsWith(
            $parentPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            try {
                Remove-Item -LiteralPath $resolvedStaging -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not remove staging directory: $resolvedStaging"
            }
        }
        else {
            Write-Warning "Refused to remove staging directory outside output parent: $resolvedStaging"
        }
    }
}

Write-Output "Conversion completed: $resolvedOutput"
