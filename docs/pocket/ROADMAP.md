# PSX on the Analogue Pocket — roadmap

Goal: a PlayStation core for the Pocket (openFPGA, Cyclone V E 5CEBA4F23C8), derived from
PSX_MiSTer, that plays games **at full original speed**. Accuracy can be traded away; speed cannot.
Why this is hard, with the measured numbers: [FEASIBILITY.md](FEASIBILITY.md).

## Budget every phase is held to

| | Device | Target (90%) | Reserved outside the PSX core | PSX core may use |
|---|---|---|---|---|
| ALMs | 18,480 | 16,600 | APF framework 1,000 · memory controllers 1,600 · CD loader + audio 450 | **13,550** |
| DSP | 66 | 60 | ~4 | 56 |
| M10K | 308 | 280 | ~20 | 260 |

Starting point: 26,135 ALMs with every option tied off (`sizing/psx_min_wrap.vhd`).
The core has to lose **~12,600 ALMs (48%)**. FEASIBILITY.md projects 16,250 with every planned
rewrite, which leaves ~2,700 ALMs to find. Each phase below has a **gate**. If a gate fails, the
measured result is recorded here and the project stops or is re-planned. A later phase never
starts on a failed gate.

## Phases

All phases run in one clash Workflow item (`pocket-gte-gate`, project `PSX_MiSTer`), in order:
a phase starts only when the previous gate passes. Phase 3 needs only a Pocket, so it runs in
parallel with phases 1–2. A gate criterion that can only be measured on a Pocket is recorded as
**pending hardware**, never as passed, and does not hold back the phases that build on it.

### Phase 1 — GTE gate (`pocket-gte-gate`)

Rewrite the GTE (`rtl/gte.vhd`) as `rtl/gte_serial.vhd`: two 18×19 MAC lanes at clk2x driven by
a generated micro-code ROM, and the CPU-written COP2 registers in RAM. The current GTE is the
golden model: the two run side by side in nvc on the same command streams (`sim/gte_diff`).
Design, schedule and measurements: [GTE.md](GTE.md).

**Gate:** bit-exact on every register and FLAG, and `gte_busy` identical at every clk1x edge, on
directed, edge, reset, CPU-timing (pauses included), saturation-boundary and 1,000,000 random
commands (`make -j8 gate`) · ≤ 3,000 ALMs,
measured as the fitter's per-entity "ALMs needed" for the GTE instance · ≤ 4 DSP · setup slack
≥ 10% of the period on the GTE's fastest clock at slow 85 °C (clk2x: ≥ +1.48 ns; a clk4x domain,
if one is added: ≥ +0.7 ns), positive on every other clock, and hold slack positive in all four
corners, on 5CEBA4F23C8. Projection: 4,200 → 2,700 ALMs.

### Phase 2 — GPU gate

Serialize `gpu_poly`'s per-scanline multiplies (29 DSP → ≤ 8) and go from 6 dividers to 2.
Measure triangle setup cycles against the current GPU, using command traces from games run in
`sim/gpu`. Build a VRAM-on-SDRAM bandwidth model from the same traces: 16-bit at 101.6 MHz,
including row misses, refresh and video scan-out.

**Gate:** GPU (raster + video out) ≤ 4,500 ALMs · ≤ 10 DSP · worst trace ≤ 80% of SDRAM bandwidth (peak over a sliding 1 ms window, SPU traffic as random BL4 bursts) ·
setup no slower than real hardware. Projection: 6,060 → 4,000–4,900.

### Phase 3 — Pocket memory test core (hardware, parallel)

A small Pocket core with no PSX logic. It exercises the memory plan on the real device:
- SDRAM driven with a VRAM-like pattern (64-bit bursts, scan-out deadline).
- Both PSRAMs ganged as one 32-bit main RAM, async page mode and, if it works, synchronous burst
  (`cram*_clk`/`adv_n`/`wait`).
- SRAM used as a byte-wide store.

It reports measured MB/s and latency on screen.

**Gate:** SDRAM sustains the Phase 2 worst trace · ganged PSRAM ≤ 180 ns wall-clock per random 32-bit read over the whole main RAM
(original console: ~177 ns) · DMA path ≥ 100 MB/s, or a measured slowdown judged acceptable · **SDRAM at 135.4752 MHz**
(the `SDRAM_135` variant): the fit meets timing on every clock in all four corners, zero data errors on every SDRAM row
(the byte-mask readback included), no late scan-out line, and `sim/gpu_diff/bwmodel.py --mixed --scan` within ~10% of
the MIXED UNDER SCAN MB/s, in simulation and on hardware (MEMTEST.md). If the model misses, a trace replay of the worst
`trace_s1` millisecond through `sdram_ctl` replaces it before the GPU's 80% is trusted.

### Phase 4 — Rewrites, strip, and the core gate

Re-planned after the Phase 2 gate. The GTE pattern for three more blocks, in order SPU → CPU → CD: the
current RTL is the frozen golden, a differential nvc harness proves the new unit, a sizing project measures
it, and each has a gate below its projection. A missed block gate stops the project or re-plans it. Then
the rest is stripped inside the current architecture:
- Savestates everywhere, replaced by a small reset sequencer; the pause/`ce` FSM stays in the top.
- CPU: turbo data cache, COP0 debug (read 0), shared multiplier. SPU: reverb engine (its registers,
  address skeleton and 0x7xxxx on-chip RAM kept), savestate, single-phase ADSR. CD: the sector ring
  stays at 8 and the rare commands stay as the golden has them.
- DMA: debug and turbo paths. Peripherals: one digital/analog pad per port, no multitap/guns/mouse/SNAC,
  one lightweight 128 KB memory card (byte responder).

| Block | Fitted in `psx_min_a6` (ALMs needed) | Projection | **Gate** |
|---|---|---|---|
| SPU | 4,028.1 | 2,000 | **≤ 1,400** |
| CPU | 3,492.3 | 1,500 | **≤ 1,300** |
| CD + XA | 3,265.0 | 2,500 | **≤ 2,100** |

Budget at those gates (the other blocks at FEASIBILITY's Trimmed column): GTE 2,491 + GPU 4,785 + the three
gates = 12,076; DMA 1,400 + bus/memctrl/timers/IRQ/top 1,200 + joypad/memcard/SIO 700 + MDEC 800 + reset
sequencer 50 = 4,150; **16,226 ALMs and ~246 of 260 M10K with no amputation**. Each amputation is a generic
named for what it removes (`true` takes it, default `false` is golden), measured taken and not taken, and
counted once:

| Amputation | ALMs | Generic |
|---|---|---|
| Drop MDEC | −800 (measured −583, below) | `NO_MDEC` on `psx_top_pocket` |
| Drop XA-ADPCM (CDDA stays) | −450 | `NO_XA` on `cd_pocket` |
| Fixed-delay CD timing | −350 | `FIXED_CD_TIMING` on `cd_pocket` |
| Digital pad only | −300 | `DIGITAL_PAD_ONLY` on the joypad block |
| Drop libcrypt | −250 | `NO_LIBCRYPT` on `cd_pocket` |

**Unit 4.0** measures the baselines before any rewrite and decides whether the rewrites start: stop and
re-plan if, for a gated block, (measured after the cheap deletions − gate) exceeds the summed estimates of
its remaining levers (SPU.md, CPU.md, CD.md), if the core projection exceeds 15,000, or if the M10K
projection exceeds 260. Result below.

**Gate:** `psx_top_pocket` ≤ 13,550 ALMs, fitted with every generic at `false`, then taking amputations in
FEASIBILITY's order, only among those accepted, stopping at the first set that fits. With every accepted
amputation taken: 13,550–15,000 is FAIL with a re-plan; above 15,000, stop.

#### Unit 4.0 result (2026-10-08): stop before the SPU rewrite

| | Standalone golden, 5CEBA4F23C8 | In `psx_top_pocket`, 5CSEBA6U23I7 | Gate | Left to find | Remaining lever estimates | |
|---|---|---|---|---|---|---|
| SPU (reverb off, the gate's contract) | 3,079.6 (3,265.9 with reverb) | 3,172.7 (reverb on) | 1,400 | 1,680 | ≤ 1,464 | **fires** |
| CPU | 2,291.1 | 2,674.4 | 1,300 | 991 | 304 | **fires** |
| CD + XA | 2,400.1 | 2,632.0 | 2,100 | 300 | 520 | holds |

The standalone figures, the gates' own metric, already have the savestate logic pruned (their ports are
tied), so the savestate lever is not counted again. `REVERBOFF` saves only 186 ALMs; the rest of the reverb
engine is an estimate. The SPU's remaining-lever sum counts that estimate at its full 814.

`psx_top_pocket` (golden SPU/CPU/CD/DMA/MDEC, `gte_serial`, `gpu_pocket`, every savestate driver tied
inactive) fits in **19,569.8 ALMs and 295 M10K** on 5CSEBA6U23I7, against 26,226.3 and 289 for `psx_min_a6`.
That fit predates the reset sequencer. On reset release the sequencer pulses `SS_reset` for 2 clk1x cycles
with `reset_intern` low, loading every module's power-on defaults, then holds `reset_intern` for 61 cycles.
Unlike `savestates.vhd`, it does not zero-load scratchpad and SPU RAM (`resetMode`, `SS_wren` is tied 0):
after reset they keep whatever they held, as on real hardware. It adds a few registers, unmeasured.
The blocks other than the GTE and GPU shrink by 3,812.7 ALMs in context, the savestate removal: SPU 855, CPU
818, CD 633, DMA 409, the `savestates` module 569, the rest 528.6 (FEASIBILITY priced it at 500). `NO_MDEC`
saves 583 ALMs, 17 M10K and 9 DSP.

- **Core projection.** Basis of each term:
  - SPU, CPU, CD at their gates (standalone, the gate metric).
  - GTE 2,490.8 and GPU 4,785.3, their standalone gate figures.
  - The 4D blocks at min(in-context, FEASIBILITY's Trimmed). DMA 1,338.9, the bus group 1,186.6 and MDEC
    592.0 are already at or below Trimmed in context; only the joypad/memcard/SIO group (794.9 → 700) is
    credited.
  - `NO_MDEC` removes the measured 583, with no Trimmed credit on top.

  Result: 15,893 with no amputation and **≈ 13,960 with all five** (14,010 with FEASIBILITY's 50-ALM reset
  sequencer line), **~410 over 13,550** and under 15,000. In context the CPU runs 383 and the CD 232 above
  standalone (the SPU 93 below). If the rewritten blocks keep those gaps, the all-five figure is
  13,960–14,575. The 15,000 rule holds.
- **M10K projection:** 295 − 64 (the CPU's turbo data cache) = 231 of 260. The rule holds.
- **The CPU and SPU rules fire.** With the rewrites reaching only measured − lever estimates (CPU 1,987, SPU
  1,616, CD 1,880) and every amputation taken, the core projects to **~14,640, ~1,090 over budget**. With the
  in-context gaps it is 14,640–15,260, and the upper end crosses 15,000.

The rewrites do not start until the re-plan. Figures: SPU.md, CPU.md, CD.md.

### Phase 5 — Pocket integration

APF top level modelled on openfpga-C64:
- PLLs: exact 33.8688 MHz plus 2×/3×/4×, and a 53.693 MHz video clock.
- Memory controllers built from Phase 3.
- BIOS from a data slot.
- CD sectors via `target_dataslot_read`, with a host-side cue/bin → track-table converter
  (like the C64 `convert-*` tools).
- 8 APF video modes covering 256/320/368/512/640 × 240/480i, NTSC/PAL.
- 44.1 → 48 kHz audio.
- Controller map.
- Memory card in a nonvolatile slot.

**Gate:** full compile fits ≤ 90% and meets timing · boots the BIOS shell on a Pocket ·
one 2D and one 3D game run at full speed.

### Phase 6 — Compatibility

A test list covering 2D, 3D, FMV, XA music, CDDA, memory-card saves and PAL/NTSC. Each title
is checked for speed against MiSTer, and failures are fixed or documented as known issues.

**Gate:** agreed list passes.

### Phase 7 — Release

Packaging and installers as in openfpga-C64 (`build.sh`, `install.*`, INSTALL.md), plus the
cue/bin converter.

## Results

Record each gate's measured numbers here when its phase ends.

| Phase | Result | ALMs | DSP | M10K | Timing | Date |
|---|---|---|---|---|---|---|
| 0 — sizing | measured | 26,135 (options off) | 83 | ~1.9 Mbit | n/a | 2026-10-07 |
| 1 — GTE | **PASS** | 2,490.8 needed (golden 3,917.6) | 3 (golden 15) | 9 blocks, 49,841 bits | clk2x +2.025 ns slow 85 °C, +1.599 ns slow 0 °C; hold ≥ +0.125 ns | 2026-10-07 |
| 2 — GPU | **FAIL**: area, and worst synthetic trace 99.9% of SDRAM at 101.6 MHz (`make bw`, table-driven model); bit-exact, setup within reference. At the re-plan's 135.5 MHz the gate figure is **91.2%**, FAIL against 80% (sliding 1 ms window, the SPU's 48 voice reads per sample as BL4 bursts; 90.2–91.2% over the three seeds, 75.9% without the SPU). 135.5 MHz also did not close timing in Phase 3. The bandwidth gate fails at both clocks, and the GPU is re-planned before Phase 5 | 4,785.3 needed (golden 5,481.4) | 10 (golden 32) | 27 (golden 27) | clk2x +0.763 ns slow 85 °C, +0.411 ns slow 0 °C; hold ≥ +0.079 ns | 2026-10-08 |
| 3 — memory test core | built, **pending hardware**. 135.5 MHz variant: **timing not met**; simulation passes, and the model matches the simulation (MIXED UNDER SCAN 105.8 MB/s vs 105.8) | 5,635 (101.6 MHz, with the bridge bench of Unit 3B; 4,097 without), whole core | — | — | 101.6 MHz: met on every clock, all four corners. 135.5 MHz: SDRAM read capture −0.42 ns setup, −0.38 ns hold, no phase closes it | 2026-10-08 |
| 4 — 4.0 baselines | **stop before 4A**: the CPU (991 to find vs 304 of levers) and SPU (1,680 vs ≤ 1,464) rules fire | `psx_top_pocket` 19,569.8 (5CSEBA6); SPU 3,079.6 / CPU 2,291.1 / CD 2,400.1 standalone | 47 | 295 | not gating | 2026-10-08 |

Phase 2 failed its gate and was re-planned. Unit 4.0 has measured the baselines, and the rewrites wait for
the next re-plan. Details: [GPU.md](GPU.md#measurements), [MEMTEST.md](MEMTEST.md), [SPU.md](SPU.md),
[CPU.md](CPU.md), [CD.md](CD.md).
