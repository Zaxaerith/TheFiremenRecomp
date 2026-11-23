<#
.SYNOPSIS
    Ingest one or more manual playthrough Tier-2 manifests (.tmp/manual_captures/*.json)
    into recomp/symbols.toml with raster-IRQ protection and jump-table deduplication.
.DESCRIPTION
    1. Scans all provided manifests for unmapped ROM targets.
    2. Pre-highlights targets reached via $80:00CA (IRQ trampoline) and defaults them
       to `emit = false` (`force_lle`) to protect zero-deviation raster timing
       (pass -EmitNewIrqs to leave them `emit = true` instead).
    3. Filters out internal jump-table targets already covered by `indirect_dispatch`
       directives in recomp/bank*.cfg so large shards (e.g. bank80_part0e) don't bloat.
    4. Runs snesrecomp/tools/tier2_ingest.py for validation, appends clean `[[func]]`
       blocks to recomp/symbols.toml, and optionally runs -Rebuild (generate + Ninja).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$ManifestPaths,

    [switch]$EmitNewIrqs,
    [switch]$Rebuild,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$TmpDir      = Join-Path $ProjectRoot ".tmp"
$M8Tmp       = Join-Path $TmpDir "m8"
$SymbolsPath = Join-Path $ProjectRoot "recomp\symbols.toml"
$RecompDir   = Join-Path $ProjectRoot "recomp"
$RomPath     = Join-Path $ProjectRoot "Firemen, The (J).smc"
$ProgManPath = Join-Path $ProjectRoot "src\gen\program_manifest.json"
$IngestPy    = Join-Path $ProjectRoot "snesrecomp\tools\tier2_ingest.py"
$CliExe      = Join-Path $TmpDir "cli-v0.4.6-alpha\snesrecomp-cli-windows-x86_64\snesrecomp.exe"
$AnalyzerExe = Join-Path $TmpDir "cli-v0.4.6-alpha\snesrecomp-cli-windows-x86_64\_internal\recompiler-rs\target\release\snesrecomp-analyze.exe"
$RomSha256   = "97206402d1cacc3187a600a5f3a7ebd73ddba0c7e09a5a688efeca47cc46b604"
$RomCrc32    = "15f2271d"

New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
$env:TMP    = $TmpDir
$env:TEMP   = $TmpDir
$env:TMPDIR = $TmpDir
$env:PYTHONDONTWRITEBYTECODE = "1"

# Resolve glob patterns & relative paths
$ResolvedManifests = [System.Collections.Generic.List[string]]::new()
foreach ($P in $ManifestPaths) {
    $Items = Get-Item -Path $P -ErrorAction SilentlyContinue
    if (-not $Items -and -not [System.IO.Path]::IsPathRooted($P)) {
        $Items = Get-Item -Path (Join-Path $ProjectRoot $P) -ErrorAction SilentlyContinue
    }
    if (-not $Items) {
        throw "Manifest not found: $P"
    }
    foreach ($It in $Items) {
        [void]$ResolvedManifests.Add($It.FullName)
    }
}

# Build helper Python script inside .tmp/ so quoting stays clean and workspace stays isolated
$HelperPy = Join-Path $TmpDir "ingest_manual_helper.py"
$HelperSrc = @'
import hashlib, json, pathlib, re, subprocess, sys, tomllib

root = pathlib.Path(sys.argv[1])
emit_new_irqs = sys.argv[2] == '1'
dry_run = sys.argv[3] == '1'
manifests = [pathlib.Path(p) for p in sys.argv[4:]]

rom = (root / 'Firemen, The (J).smc').read_bytes()
sym_p = root / 'recomp' / 'symbols.toml'
ingest_py = root / 'snesrecomp' / 'tools' / 'tier2_ingest.py'
pm_p = root / 'src' / 'gen' / 'program_manifest.json'
rom_sha256 = '97206402d1cacc3187a600a5f3a7ebd73ddba0c7e09a5a688efeca47cc46b604'
pm_bytes = pm_p.read_bytes() if pm_p.is_file() else None
pm_sha = hashlib.sha256(pm_bytes).hexdigest() if pm_bytes else None
cur_lle_pcs = set()
if pm_bytes:
    pm_json = json.loads(pm_bytes.decode('utf-8'))
    for node in pm_json.get('nodes', {}).values():
        if node.get('disposition') == 'lle_only':
            cur_lle_pcs.add(int(node['key']['pc24']))

# 1. Load all indirect_dispatch jump-table targets from recomp/bank*.cfg
jt_targets = set()
jt_map = {}
for cfg_p in sorted((root / 'recomp').glob('bank*.cfg')):
    txt = cfg_p.read_text(encoding='utf-8')
    m_bk = re.search(r'^\s*bank\s*=\s*([0-9a-fA-F]+)', txt, re.M)
    if not m_bk:
        continue
    bank = int(m_bk.group(1), 16)
    for m in re.finditer(r'^\s*indirect_dispatch\s+([0-9a-fA-F]+)\s+(\d+)', txt, re.M):
        site_addr = int(m.group(1), 16)
        count = int(m.group(2))
        tbl_addr = site_addr + 3
        off = ((bank & 0x7F) * 0x8000) + (tbl_addr - 0x8000)
        for i in range(count):
            t_addr = rom[off + i * 2] | (rom[off + i * 2 + 1] << 8)
            pc24 = (bank << 16) | t_addr
            jt_targets.add(pc24)
            jt_map.setdefault(pc24, set()).add(f'${bank:02X}:{site_addr:04X}')

# 2. Load existing symbols.toml entries
cur_text = sym_p.read_text(encoding='utf-8')
cur_data = tomllib.loads(cur_text)
existing_pcs = set()
existing_names = set()
for f in cur_data.get('func', []):
    b = int(f['bank'], 16) if isinstance(f['bank'], str) else int(f['bank'])
    a = int(f['addr'], 16) if isinstance(f['addr'], str) else int(f['addr'])
    existing_pcs.add((b << 16) | a)
    existing_names.add(f['name'])

# 3. Validate each manifest via tier2_ingest.py and aggregate discoveries
best_by_pc = {}
all_irq_sites = set()
filtered_jt = set()
skipped_lle = set()
skipped_wram = set()

for mp in manifests:
    mp_data = json.loads(mp.read_text(encoding='utf-8'))
    mp_prog_digest = (mp_data.get('identity') or {}).get('program_digest') or mp_data.get('program_digest')
    cmd = [
        sys.executable, str(ingest_py), str(mp),
        '--cfg-dir', str(root / 'recomp'),
        '--rom-sha256', rom_sha256,
        '--json',
    ]
    if pm_sha and (not mp_prog_digest or mp_prog_digest == pm_sha):
        cmd.extend(['--program-manifest', str(pm_p)])
    elif pm_sha:
        print(f'[i] {mp.name}: program_manifest digest differs from current build; auditing without --program-manifest')
    r = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'tier2_ingest failed on {mp.name} ({r.returncode}): {r.stderr}\n{r.stdout}')
    rep = json.loads(r.stdout)
    for row in rep['discoveries']:
        tgt_raw = row['target_pc24']
        pc24 = int(tgt_raw, 16) if isinstance(tgt_raw, str) else int(tgt_raw)
        bank = (pc24 >> 16) & 0xFF
        addr = pc24 & 0xFFFF
        if addr < 0x8000 or bank in (0x7E, 0x7F):
            skipped_wram.add(f'${pc24:06X}')
            continue
        if row.get('emulation', 0) != 0 or row.get('bail_hits', 0) > 0:
            continue
        if row.get('analysis_disposition') == 'lle_only' or pc24 in cur_lle_pcs:
            skipped_lle.add(f'${pc24:06X}')
            continue
        if pc24 in existing_pcs:
            continue
        site_raw = row.get('site_pc24', '0x000000')
        site24 = int(site_raw, 16) if isinstance(site_raw, str) else int(site_raw)
        is_irq = (site24 & 0xFFFFFF) == 0x8000CA
        # Filter internal jump-table targets unless called externally
        if pc24 in jt_targets and row.get('site_kind') == 'goto_gap':
            filtered_jt.add((f'${pc24:06X}', f'${site24:06X}'))
            continue
        mx_str = row.get('entry_mx', 'M0X0')
        m_match = re.fullmatch(r'M([01])X([01])', mx_str)
        if not m_match:
            continue
        em, ex = int(m_match[1]), int(m_match[2])
        hits = sum(row.get(k, 0) for k in ('observed_hits', 'completed_hits', 'yielded_hits'))
        if is_irq:
            all_irq_sites.add(pc24)
        prev = best_by_pc.get(pc24)
        if prev is None:
            best_by_pc[pc24] = {
                'bank': bank, 'addr': addr, 'm': em, 'x': ex, 'hits': hits,
                'sites': {f'0x{site24:06X}'}, 'tags': {mp.stem}, 'is_irq': is_irq,
            }
        else:
            prev['hits'] += hits
            prev['sites'].add(f'0x{site24:06X}')
            prev['tags'].add(mp.stem)
            prev['is_irq'] = prev['is_irq'] or is_irq

if all_irq_sites:
    mode_lbl = 'emit=true (-EmitNewIrqs)' if emit_new_irqs else 'emit=false (force_lle default)'
    print(f'[!] New $80:00CA IRQ target(s) detected ({len(all_irq_sites)}) -> {mode_lbl}:')
    for pc24 in sorted(all_irq_sites):
        print(f'    - ${pc24:06X} (hits={best_by_pc[pc24]["hits"]})')

if filtered_jt:
    print(f'[i] Filtered {len(filtered_jt)} internal indirect_dispatch jump-table target(s):')
    for t_s, s_s in sorted(filtered_jt):
        print(f'    - {t_s} via {s_s}')

additions = []
for pc24 in sorted(best_by_pc):
    info = best_by_pc[pc24]
    name = f'T2_{pc24:06X}'
    if name in existing_names:
        continue
    emit_val = 'true' if (not info['is_irq'] or emit_new_irqs) else 'false'
    sites_str = ', '.join(sorted(info['sites'])[:3])
    tag_str = ', '.join(sorted(info['tags'])[:2])
    irq_note = ' [IRQ force_lle]' if (info['is_irq'] and not emit_new_irqs) else ''
    blk = (
        f'\n[[func]]\n'
        f'name = "{name}"\n'
        f'addr = "{info["addr"]:04x}"\n'
        f'bank = 0x{info["bank"]:02x}\n'
        f'entry_m = {info["m"]}\n'
        f'entry_x = {info["x"]}\n'
        f'emit = {emit_val}\n'
        f'note = "{tag_str}: from {sites_str} (hits={info["hits"]}){irq_note}"\n'
    )
    additions.append(blk)

print(f'[+] New ROM seeds ready: {len(additions)} (AOT={sum(1 for p in best_by_pc if not best_by_pc[p]["is_irq"] or emit_new_irqs)}, force_lle={sum(1 for p in best_by_pc if best_by_pc[p]["is_irq"] and not emit_new_irqs)})')
if dry_run:
    for blk in additions:
        print(blk.strip())
    print('[DryRun] symbols.toml not modified.')
elif additions:
    with sym_p.open('a', encoding='utf-8', newline='\n') as f:
        for blk in additions:
            f.write(blk)
    print(f'[+] Appended {len(additions)} [[func]] entries to {sym_p}')
else:
    print('[i] No new ROM seeds to append.')
'@
Set-Content -LiteralPath $HelperPy -Value $HelperSrc -Encoding UTF8

$EmitFlag = if ($EmitNewIrqs) { "1" } else { "0" }
$DryFlag  = if ($DryRun) { "1" } else { "0" }

Write-Host "=== Ingesting $($ResolvedManifests.Count) manual capture manifest(s) ===" -ForegroundColor Cyan
& python $HelperPy $ProjectRoot $EmitFlag $DryFlag @ResolvedManifests
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($Rebuild -and -not $DryRun) {
    if (-not (Test-Path -LiteralPath $CliExe)) { throw "Precompiled CLI not found: $CliExe" }
    if (-not (Test-Path -LiteralPath $AnalyzerExe)) { throw "Precompiled analyzer not found: $AnalyzerExe" }
    $env:SNESRECOMP_NATIVE_ANALYZER = $AnalyzerExe
    Write-Host "`n=== Regenerating C sources (v0.4.6-alpha) ===" -ForegroundColor Cyan
    & $CliExe generate `
        --rom $RomPath `
        --cfg-dir $RecompDir `
        --out-dir (Join-Path $ProjectRoot "src\gen") `
        --funcs-h (Join-Path $RecompDir "funcs.h") `
        --project-root $ProjectRoot `
        --expected-crc32 $RomCrc32 `
        --expected-sha256 $RomSha256 `
        --instruction-blocks --region-paced
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host "`n=== Building TheFiremenSNESRecomp (Ninja) ===" -ForegroundColor Cyan
    & cmake --build (Join-Path $ProjectRoot "build") --target TheFiremenSNESRecomp -j
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} elseif (-not $DryRun) {
    Write-Host "`nNext steps (regenerate & incremental build):" -ForegroundColor Yellow
    Write-Host "  `$env:TMP='$TmpDir'; `$env:TEMP='$TmpDir'; `$env:TMPDIR='$TmpDir'"
    Write-Host "  `$env:SNESRECOMP_NATIVE_ANALYZER='$AnalyzerExe'"
    Write-Host "  & '$CliExe' generate --rom '$RomPath' --cfg-dir '$RecompDir' --out-dir '$ProjectRoot\src\gen' --funcs-h '$RecompDir\funcs.h' --project-root '$ProjectRoot' --expected-crc32 $RomCrc32 --expected-sha256 $RomSha256 --instruction-blocks --region-paced"
    Write-Host "  cmake --build '$ProjectRoot\build' --target TheFiremenSNESRecomp -j"
}
