<#
.SYNOPSIS
    Launch The Firemen Recomp interactively (normal window + audio) with Tier-2
    coverage capture enabled for manual playthroughs (1F Boss -> 6F -> Ending).
.DESCRIPTION
    - Locks TMP/TEMP/TMPDIR inside project-local .tmp/
    - Saves each session's Tier-2 manifest to .tmp\manual_captures\run_YYYYMMDD_HHMMSS.json
    - On exit, prints newly discovered ROM entry points not yet in recomp\symbols.toml
      and a ready-to-run tier2_ingest.py command.
#>
[CmdletBinding()]
param(
    [string]$RomPath = "",
    [switch]$ShowLauncher
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$TmpDir      = Join-Path $ProjectRoot ".tmp"
$CapDir      = Join-Path $TmpDir "manual_captures"
$DataDir     = Join-Path $CapDir "data"
$ExePath     = Join-Path $ProjectRoot "build\TheFiremenSNESRecomp.exe"
$SymbolsPath = Join-Path $ProjectRoot "recomp\symbols.toml"
$ProgManPath = Join-Path $ProjectRoot "src\gen\program_manifest.json"
$IngestPy    = Join-Path $ProjectRoot "snesrecomp\tools\tier2_ingest.py"
$RomSha256   = "97206402d1cacc3187a600a5f3a7ebd73ddba0c7e09a5a688efeca47cc46b604"

if ([string]::IsNullOrWhiteSpace($RomPath)) {
    $RomPath = Join-Path $ProjectRoot "Firemen, The (J).smc"
}

if (-not (Test-Path -LiteralPath $ExePath)) {
    throw "Host executable not found: $ExePath. Build TheFiremenSNESRecomp first."
}
if (-not (Test-Path -LiteralPath $RomPath)) {
    throw "ROM not found: $RomPath"
}

New-Item -ItemType Directory -Force -Path $TmpDir, $CapDir, $DataDir | Out-Null

$Stamp        = Get-Date -Format "yyyyMMdd_HHmmss"
$ManifestPath = Join-Path $CapDir "run_$Stamp.json"
$SessionDir   = Join-Path $CapDir "session_$Stamp"
New-Item -ItemType Directory -Force -Path $SessionDir | Out-Null

# Lock temporary directories inside project .tmp/ and ensure real window + audio (no dummy drivers)
$env:TMP    = $TmpDir
$env:TEMP   = $TmpDir
$env:TMPDIR = $TmpDir
$env:PYTHONDONTWRITEBYTECODE = "1"
Remove-Item Env:SDL_VIDEODRIVER   -ErrorAction SilentlyContinue
Remove-Item Env:SDL_AUDIODRIVER   -ErrorAction SilentlyContinue
Remove-Item Env:SDL_RENDER_DRIVER -ErrorAction SilentlyContinue

$env:SNESRECOMP_TIER2_CAPTURE  = "1"
$env:SNESRECOMP_TIER2_MANIFEST = $ManifestPath
$env:SNESRECOMP_COVERAGE_DIR   = $SessionDir
$env:SNESRECOMP_DATA_DIR       = $DataDir
$env:SNESRECOMP_DUMP_DIR       = $SessionDir

$ArgsList = @(
    "--rom", $RomPath,
    "--coverage-capture=on"
)
if (-not $ShowLauncher) {
    $env:SNESRECOMP_NO_LAUNCHER = "1"
    $ArgsList = @("--no-launcher") + $ArgsList
} else {
    Remove-Item Env:SNESRECOMP_NO_LAUNCHER -ErrorAction SilentlyContinue
}

Write-Host "=== The Firemen Recomp — Manual Playthrough Coverage Capture ===" -ForegroundColor Cyan
Write-Host "  Host     : $ExePath"
Write-Host "  ROM      : $RomPath"
Write-Host "  Manifest : $ManifestPath"
Write-Host "  TMP/TEMP : $TmpDir"
Write-Host "Close the game window when finished to summarize new Tier-2 entries." -ForegroundColor Yellow

Push-Location $SessionDir
try {
    & $ExePath @ArgsList
    $ExitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "=== Session Ended (exit code: $ExitCode) ===" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    Write-Warning "No Tier-2 manifest was written to $ManifestPath."
    exit $ExitCode
}

$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$AllDisc  = @($Manifest.discoveries)

# Load existing 24-bit addresses from recomp\symbols.toml (bank + addr)
$KnownPcs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $SymbolsPath) {
    $CurAddr = $null
    $CurBank = $null
    foreach ($Line in Get-Content -LiteralPath $SymbolsPath) {
        if ($Line -match '^\s*\[\[func\]\]') {
            $CurAddr = $null; $CurBank = $null
        } elseif ($Line -match '^\s*addr\s*=\s*"([0-9a-fA-F]{4})"') {
            $CurAddr = $Matches[1].ToUpperInvariant()
        } elseif ($Line -match '^\s*bank\s*=\s*0x([0-9a-fA-F]{2})') {
            $CurBank = $Matches[1].ToUpperInvariant()
        }
        if ($CurAddr -and $CurBank) {
            [void]$KnownPcs.Add("$CurBank$CurAddr")
            $CurAddr = $null; $CurBank = $null
        }
    }
}

$NewRomEntries = [System.Collections.Generic.List[object]]::new()
$NewBanks      = [System.Collections.Generic.HashSet[string]]::new()
$SeenNew       = [System.Collections.Generic.HashSet[string]]::new()
$NewIrqs       = [System.Collections.Generic.List[string]]::new()

foreach ($d in $AllDisc) {
    $RawPc = $d.target_pc24
    $PcInt = if ($RawPc -is [string]) { [Convert]::ToInt32($RawPc, 16) } else { [int]$RawPc }
    $Bank  = ($PcInt -shr 16) -band 0xFF
    $Addr  = $PcInt -band 0xFFFF
    if ($Addr -lt 0x8000 -or $Bank -eq 0x7E -or $Bank -eq 0x7F) { continue }
    $Hex6 = "{0:X6}" -f $PcInt
    if (-not $KnownPcs.Contains($Hex6) -and $SeenNew.Add($Hex6)) {
        $RawSite = $d.site_pc24
        $SiteInt = if ($RawSite -is [string]) { [Convert]::ToInt32($RawSite, 16) } else { [int]$RawSite }
        $SiteHex = "{0:X6}" -f $SiteInt
        [void]$NewBanks.Add(("{0:X2}" -f $Bank))
        $NewRomEntries.Add([PSCustomObject]@{
            Target = "`$$($Hex6.Substring(0,2)):$($Hex6.Substring(2,4))"
            Site   = "`$$($SiteHex.Substring(0,2)):$($SiteHex.Substring(2,4))"
            MX     = $d.entry_mx
            Kind   = $d.site_kind
            Reason = $d.fallback_reason
            Hits   = $d.observed_hits
        })
        if ($SiteInt -eq 0x8000CA) {
            $NewIrqs.Add("`$$($Hex6.Substring(0,2)):$($Hex6.Substring(2,4))")
        }
    }
}

Write-Host ("  Total discoveries in manifest : {0}" -f $AllDisc.Count)
Write-Host ("  NEW unmapped ROM entry points : {0}" -f $NewRomEntries.Count) -ForegroundColor Green
if ($NewRomEntries.Count -gt 0) {
    Write-Host ("  Banks touched by new entries  : {0}" -f (($NewBanks | Sort-Object | ForEach-Object { "`$$_" }) -join ", "))
    $NewRomEntries | Sort-Object -Property Hits -Descending | Select-Object -First 20 | Format-Table -AutoSize
    if ($NewIrqs.Count -gt 0) {
        Write-Host ("  [!] New IRQ targets via `$80:00CA detected ({0}) — check for mid-frame PPU raster writes & set emit=false if needed:" -f ($NewIrqs -join ", ")) -ForegroundColor Yellow
    }
}

Write-Host "Ready-to-run Tier-2 ingest command:" -ForegroundColor Cyan
$ProgManArg = if (Test-Path -LiteralPath $ProgManPath) { " --program-manifest `"$ProgManPath`"" } else { "" }
Write-Host ("  python `"$IngestPy`" `"$ManifestPath`" --cfg-dir `"$ProjectRoot\recomp`" --rom-sha256 $RomSha256$ProgManArg")
Write-Host "Or append filtered ROM seeds directly via project helper:" -ForegroundColor DarkCyan
Write-Host ("  python `"$TmpDir\ingest_to_symbols.py`" `"$ManifestPath`" `"manual_$Stamp`"")
