# PSX_MiSTer → Analogue Pocket: feasibility

Source: PSX_MiSTer `cd17b5a` (2026-08-21). Target: Pocket core FPGA, Cyclone V E **5CEBA4F23C8**:
18,480 ALMs, 308 M10K, 66 DSP blocks. All ALM figures are Quartus 21.1 synthesis estimates
("ALMs needed"). On the C64 port that estimate was within 3% of the fitted result (17,361 vs 16,921).

## Verdict

**No-go as a port, and a marginal maybe as a rewrite.** Even after deleting every optional feature,
the core needs about **22,600 ALMs (122% of the device)** if the existing blocks are only trimmed.
It needs about **19,300 ALMs (104%)** if the GTE, GPU, SPU and CPU are also rewritten into
serialized form. Timing on the C8 speed grade needs ≤ ~16,600 (90%). Closing the remaining
~3,000 ALMs means dropping things games use (FMV, XA music, CD timing model), and the VRAM
bandwidth on one 16-bit SDRAM is still unproven.

## Measured (synthesis of `psx_top`, no MiSTer framework)

| Config | ALMs | Registers | Block RAM bits | DSP |
|---|---|---|---|---|
| Full core, all options live | 31,215 | 29,178 | 2,144,448 | 98 |
| Options tied off (`psx_min_wrap.vhd`) | **26,135** | 25,697 | 1,910,912 | 83 |
| Same, **placed and routed** on 5CSEBA6 (DE10-Nano) | **26,672** | — | 1,910,912 (289 M10K) | 83 |
| Pocket device | 18,480 | — | ~3.08 Mbit (308 M10K) | 66 |

The fitted result is 2% above the synthesis estimate, so the estimates below are not pessimistic.
Tying options to constants only removes ~5K ALMs. Turbo data cache, savestates and the SPU
on-chip reverb RAM are not pruned that way; they need RTL changes.

## Per block (ALMs)

"Stripped" = measured with options tied off (ALUT × 0.707). "Trimmed" = after deleting code
inside the current architecture. "Rewritten" = serialized datapaths at a higher clock.

| Block | Stripped | Trimmed | Rewritten | What gets cut |
|---|---|---|---|---|
| GPU (raster + video out) | 6,060 | 4,900 | 4,000 | 6→2 dividers, tag-valid mux, savestate, overlays/guns |
| GTE | 4,200 | 3,500 | 2,700 | savestate, narrow MAC multipliers; rewrite = 1 MAC @ 4× clk1x (built: 2 lanes @ clk2x, 2,491 fitted, [GTE.md](GTE.md)) |
| SPU | 3,840 | 2,400 | 2,000 | reverb engine, savestate, single-phase ADSR; rewrite = time-sliced mults |
| CD controller + XA | 3,410 | 2,700 | 2,500 | savestate, rare commands, 8→2 sector ring |
| CPU | 2,900 | 1,900 | 1,500 | savestate, turbo data cache, COP0 debug; rewrite = multi-cycle |
| DMA | 1,870 | 1,400 | 1,100 | debug/turbo/reproducible-timing paths |
| Bus, memctrl, timers, IRQ, top | 1,450 | 1,200 | 1,100 | EXE loader, 8 MB, debug |
| Joypad, memcard, SIO | 1,000 | 700 | 600 | one digital/analog pad per port, one lightweight card |
| MDEC | 860 | 800 | 700 | duplicated tables, clk2x domain |
| Savestates/statemanager | 550 | 50 | 50 | replaced by a small reset sequencer |
| **Existing core** | **26,140** | **19,550** | **16,250** | |
| New: SDRAM + PSRAM controllers, 64→16-bit VRAM adapter | | 1,600 | 1,600 | |
| New: CD data-slot loader, 44.1→48 kHz audio | | 450 | 450 | |
| APF framework (measured in openfpga-C64) | | 1,000 | 1,000 | |
| **Total** | | **22,600 (122%)** | **19,300 (104%)** | target ≤ 16,600 (90%) |

DSP (83 → ~35-45 after serializing the 29 DSP in `gpu_poly`) and M10K (~60-110 after removing
the 64 KB turbo cache and 64 KB SPU reverb RAM, and shrinking CD buffers) both fit.
**ALMs are the blocker.**

## What would close the last ~3,000 ALMs (each costs games)

| Cut | ALMs | Cost |
|---|---|---|
| Drop MDEC | ~700 | No FMV; some games wait for MDEC and hang |
| Drop XA-ADPCM | ~450 | No streamed music/voice in many games |
| Fixed-delay CD timing (no physical model) | ~350 | Seek/pause-sensitive loaders break |
| Digital pad only | ~300 | Analog-only games (Ape Escape) unplayable |
| Drop libcrypt | ~250 | ~100 protected PAL titles don't boot |

Even with all of them, the rewritten core lands around 17,200 ALMs (~93%). That's above the
timing target on the slowest speed grade, with 67-135 MHz domains.

## Memory layout (best candidate)

| Pocket memory | Holds | Why |
|---|---|---|
| SDRAM (16-bit) | VRAM 1 MB + SPU RAM 512 KB | VRAM alone loads it 53% (flat fill) to ~93% (textured, at 101.6 MHz); SPU adds < 5 MB/s |
| PSRAM0 + PSRAM1 ganged as 32-bit | Main RAM 2 MB + BIOS 512 KB | ~95-140 ns per access, close to the original console's own RAM (~177 ns) |
| SRAM 256 KB | Memory card 128 KB, CD sector ring, XA buffers | Fast, small, frees M10K |

Risks: DMA from PSRAM is ~60-80 MB/s vs ~135 MB/s on hardware, unless the PSRAM synchronous
burst mode works (`cram*_clk`/`adv_n`/`wait` are wired on the Pocket; unproven). Texture-cache
misses stall the whole pixel pipeline, so SDRAM row misses add directly to GPU time.

## Other blockers

- **Clocks**: 33.8688 MHz must be exact (CD and SPU delays are counted in clk1x), plus 2×/3× related
  clocks and a 53.693 MHz video clock, all from the Pocket's 74.25 MHz reference.
- **Timing closure**: MiSTer closes on a faster -I7 part using aggressive retiming. `gpu_poly`
  does 32×32 + adders unregistered at 67.7 MHz, and the GTE MAC is single-cycle.
- **Video**: 5 widths × 240/480i × NTSC/PAL must fit in 8 APF scaler slots.
- **Audio**: SPU runs at 44.1 kHz, APF I2S at 48 kHz.
- **Removing savestates** touches ~15 files: `savestates.vhd` also owns reset/pause sequencing.

## Lightweight save (replaces memory cards)

One 128 KB card in SRAM. A byte-level memcard protocol responder (~220 ALMs, 0 M10K), loaded
from and flushed to one APF nonvolatile data slot. Port 2 has no card. The byte period is ~52 µs,
so SRAM latency doesn't matter.

## If you still want to try: the go/no-go gate

Rewrite the **GTE as a serialized single-MAC unit** first. It's self-contained, has exact cycle
counts to match, and the projection assumes it drops 4,200 → 2,700. If it doesn't land under
~3,000 ALMs and close at 4× clk1x on C8, stop. The rest of the plan needs bigger savings than that.
Measured result: 2,490.8 ALMs and 3 DSP with two MAC lanes at clk2x. A clk4x MAC does not close on
C8, and two lanes at clk2x give the same issue rate ([GTE.md](GTE.md)).

## Reproduce

```
cd sizing   # from the repo root
docker run --rm --platform linux/amd64 -v "$PWD/..":/build -w /build/sizing raetro/quartus:21.1 \
  quartus_map psx_size -c psx_size --parallel=1   # full core, Pocket device
# same with psx_min (options tied off) and psx_min_a6 (fit on the DE10-Nano device)
```
