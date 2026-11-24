# The Firemen Recomp

A native recompilation of **The Firemen** (JPN, Human Entertainment, 1994), built on
[snesrecomp](https://github.com/RetroPortingToolKit/snesrecomp).

Top-down action firefighting game for Super Famicom (`FastROM LoROM`, no coprocessor, password save system).



> **You must legally own a copy of the game.** No ROM data is distributed with
> this project, in the repository or in any release. The recompiled C is
> generated locally from your own copy and is never committed.

## Status

Playable alpha recompilation (`0.1.0-alpha`):

- **Engine & Verified AOT Coverage**: `337` AOT-eligible / `8` LLE-only exact variants across banks `$00/$80/$81/$82/$9F` (`recomp/generate.toml`: `instruction_blocks = true`, `region_paced = true`).
- **Pure LLE Equivalence**: Verified across 5 headless regression scenarios (`15,399` total frames) with `unresolved_abandons = 0` — `0` master-clock / `0`-pixel divergence on `stage1`, `m6_config`, `m6_stage1_deep`, and `m7_gameover` (note: `m7_expert` shows a transient `+26` CPU-cycle / `29 px` dialogue-only boundary diff at frame `2442` inside `$81:8DB1` that recovers to `0 px` in gameplay).
- **Full Playthrough via Unified Launcher**: Select your verified Japanese ROM in the `recomp-ui` launcher to play through the entire game seamlessly — uncovered later-floor routines (2F–6F) automatically execute through the integrated LLE fallback.

## ROM identity

| | |
|---|---|
| File | `Firemen, The (J).smc` |
| Publisher | Human Entertainment |
| Developer | Human Entertainment |
| Year | 1994 |
| Mapping | lorom (FastROM) |
| Region | JPN (Japan) |
| Coprocessor | none |
| CRC32 | `15f2271d` |
| SHA-256 | `97206402d1cacc3187a600a5f3a7ebd73ddba0c7e09a5a688efeca47cc46b604` |

`tools/regen.sh` refuses to run against anything else, so a mismatched
revision fails immediately instead of producing subtly wrong output.

## Build

```sh
git submodule update --init --recursive
bash tools/regen.sh --rom "/path/to/Firemen, The (J).smc"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

The ROM does not have to live in the repository — keeping it on your own
drive is the better habit, and `SNESRECOMP_ROM` sets the path once for a
shell. Without either, `tools/regen.sh` finds `Firemen, The (J).smc` at the repo root,
then the path the setup wizard recorded in `rom.cfg`; `.gitignore` blocks
both from ever being committed.

`tools/regen.sh` verifies the ROM, generates `src/gen/*.c`, and re-syncs
`recomp/funcs.h`. Re-run it whenever you change anything under `recomp/`.

## Run

```sh
./build/TheFiremenSNESRecomp                               # launcher picks the ROM
./build/TheFiremenSNESRecomp "/path/to/Firemen, The (J).smc" # or name it and skip the launcher
```

With no ROM on the command line the build opens the recomp-ui launcher: a ROM
picker with a verification badge, plus display / audio / input settings. Your
choice is cached in `rom.cfg` beside the executable, so the next launch opens
on it and "Skip launcher on boot" makes it immediate. If the launcher is not
built in (`--no-recomp-ui`), the host falls back to a native file picker.

Either way the ROM is checked against the digests above before anything boots
— a dump that could not have produced this build is refused at the door rather
than mis-executing ten frames in.

## Layout

| Path | What lives there |
|---|---|
| `recomp/` | Analysis input: `bank*.cfg`, `symbols.toml`, generated `funcs.h` |
| `rom_identity.txt` | ROM digests — read by the build, `tools/regen.sh` and CI |
| `src/` | Host code you own: `main.c`, `game_rtl.c` |
| `src/gen/` | Generated C. Never committed — regenerate locally |
| `snesrecomp/` | Framework submodule (owns `lib/recomp-net`, `lib/retcomm-rbengine`) |
| `tools/` | `regen.sh` (ROM → C), `play_capture.ps1` & `ingest_manual.ps1` (2F–6F Tier-2 capture/ingest) |
| `scripts/` | `package_release.sh` — player-facing zip |
| `framework_pins.txt` | Exact framework commits this project was scaffolded against |

## Contributing Coverage (2F–6F)

Players and contributors on Windows can help expand AOT coverage for later floors (2F–6F / Bosses / Ending) using the built-in Tier-2 capture & ingestion workflow:

1. **Record a manual playthrough** with live coverage capture enabled:
   ```powershell
   pwsh -NoProfile -File .\tools\play_capture.ps1
   ```
   This saves discovered entry points to `.tmp\manual_captures\run_YYYYMMDD_HHMMSS.json`.
2. **Ingest and validate discoveries** into `recomp/symbols.toml` (auto-protecting new `$80:00CA` raster IRQs with `emit = false` and filtering `indirect_dispatch` jump-table duplicates):
   ```powershell
   pwsh -NoProfile -File .\tools\ingest_manual.ps1 .tmp\manual_captures\*.json -DryRun
   pwsh -NoProfile -File .\tools\ingest_manual.ps1 .tmp\manual_captures\*.json -Rebuild
   ```
3. **Verify zero divergence**: Always confirm `unresolved_abandons = 0` and verify any new stage scenes against Pure LLE before submitting changes to `recomp/`. Never commit ROM files or `src/gen/*.c`.

## Multiplayer

Single player.

## License

This project's own source is under the license in `LICENSE`. The framework
carries its own terms — see `snesrecomp/LICENSE` and
`snesrecomp/THIRD_PARTY_ATTRIBUTION.md`. Neither covers the game data, which
is not distributed here.
