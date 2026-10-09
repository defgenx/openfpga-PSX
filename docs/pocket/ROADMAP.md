# PSX on the Analogue Pocket — roadmap

Goal: a PlayStation core for the Pocket (openFPGA, Cyclone V E 5CEBA4F23C8), derived from
PSX_MiSTer, that plays games **at full original speed**. Accuracy can be traded away only through
named generics; speed cannot. Why this is hard, with the measured numbers: [FEASIBILITY.md](FEASIBILITY.md)
(its area projection is superseded by the budget below).

## Budget every phase is held to

| | Device | Gate (90%) | Shell (outside the PSX core) | PSX core may use |
|---|---|---|---|---|
| ALMs | 18,480 | **whole Pocket build ≤ 16,632 and timing met** | ~2,350 (range 1,900–2,800), re-estimated | 16,632 − measured shell (~14,280 today) |
| M10K | 308 | ≤ 277 | ~20 | ~257 projected |
| DSP | 66 | not a constraint | ~4 | 47 used |

The gate is the whole build: APF framework, memory controllers, loaders and the PSX core together. The
core has no fixed budget of its own. It is 16,632 minus the shell, and the shell is measured, not shrunk on
paper.

The shell estimate (~2,350) replaces the earlier reservations (APF 1,000 + controllers 1,600 + loader/audio
450 = 3,050, and 13,550 for the core):

| Part | ALMs | Source |
|---|---|---|
| APF top, bridge, pad and peripheral bridge | ~404 | measured, memtest fit (`apf_top`, `core_bridge_cmd`, `io_bridge_peripheral`, `io_pad_controller`) |
| `sdram_ctl` + arbiter + `psram32` + `sram_ctl` | ~439 | measured, memtest fit |
| VRAM and `ram_*` adapters, 3-client arbiter, calibration | ~500 | estimated (P1d, M2a) |
| CD loader, BIOS loader, reset gate | ~400 | estimated (P1b, P1d) |
| Audio 48 kHz + I2S, video modes, input, memcard store and slot | ~600 | estimated (P1c, P1d) |
| **Shell** | **~2,350 (1,900–2,800)** | the measured ~840 is from `pocket/memtest/fpga/output_files/ap_core.fit.rpt:3806+` |

Units P1a and P1d fit the real shell; the core budget is re-derived from that fit, and this table is updated.

Starting point: 26,135 ALMs with every option tied off (`sizing/psx_min_wrap.vhd`); `psx_top_pocket` with
the savestates removed is 19,569.8 in context at Unit 4.0, 19,191.0 on the current tree (re-fit 2026-10-09). Each phase below has a **gate**. If a gate fails,
the measured result is recorded here and the project stops or is re-planned. A later phase never starts on
a failed gate.

## Phases

Phases 1–3 ran in the clash item `pocket-gte-gate`, project `PSX_MiSTer`. Phases 4–7 run in the clash item
`pocket-port`, project `PSX_MiSTer`, branched from `pocket-gte-gate`. A phase starts only when the previous
gate passes. Phase 3 needs only a Pocket, so it ran in parallel with phases 1–2. A gate criterion that can
only be measured on a Pocket is recorded as **pending hardware**, never as passed, and does not hold back
the phases that build on it.

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


### Phase 4 — Rewrites, area, and the core gate

Re-planned after Unit 4.0 (2026-10-09). Every rewritten block is proven the Phase 1 way: the current RTL is
a frozen golden model, an nvc differential harness proves the new block bit for bit, and a sizing project
measures it. Block gates are in the table below; the work units are listed under [Work units](#work-units).

**Gate metric.** A block gate is the block's "ALMs needed" in the `psx_top_pocket` in-context fit, not the
standalone fit (standalone stays a diagnostic; in context the CPU runs +383 and the CD +232 ALMs above
standalone). The fit runs on 5CSEBA6 (`sizing/psx_pocket_a6`) until the core fits the 5CEBA4, then on
5CEBA4. Each block fits its own revision `sizing/psx_pocket_a6_<blk>.qsf`, which selects the block's
`*_pocket` implementation through a `G_<BLK>_IMPL` generic on `psx_top_pocket`.

**Exactness is the contract.** A rewritten block matches its golden bit for bit, and in cycle timing where
the golden's timing is visible. Documented timing-only exceptions are allowed (the GPU's busy bits).
Accuracy is traded away only through a named generic with its own golden tie or stimulus mask and a written
user-visible effect: the amputations and the cuts under "Contract exceptions".

#### Area targets (in context)

The **target** is the gate each block must meet. The **explorer range** is what reading the RTL supports,
in context ALMs. Several targets sit at or below the bottom of their range, so the projection uses the range.

| Block | Now | **Target** | Explorer range | Design (unit) |
|---|---|---|---|---|
| SPU | 3,172.7 | **1,350** | 1,300–1,650 | micro-sequenced voice slot on one clk2x multiplier; global, voice and reverb-coefficient registers in one RAM with one read port; reverb arithmetic removed under `NO_REVERB` (open decision); L1 block cache (B1) |
| CD + XA | 2,632.0 | **1,600** | 1,650–1,850 | (command, step) response ROM with one shared timer set; divides become shifts or BCD; libcrypt from a ROM compare; peak volume under a generic; XA sequenced (B2) |
| CPU | 2,674.4 | **1,900** | 1,900–2,300 | COP0 debug under a generic; address/value copies merged; one barrel shifter; shared multi-cycle multiplier; one load aligner; smaller divider; tag width only if proven exact; dcache RAM removed (B3). [CPU.md](CPU.md) |
| GPU | 4,615.2 | **4,000** | 4,000–4,100 | rect through the poly pixel path; one copy engine for the 4 transfer units; video out trimmed to the Pocket modes; line-unit trims (B6) |
| DMA | 1,338.9 | **900** | 940–1,090 | field split below; reproducible-timing logic removed (B4) |
| Bus group | 1,184.2 | **850** | 880–1,080 | EXE loader, fastboot patch and `ram8mb` removed (the 2 MB mirror stays); RAM side merged with the PSRAM adapter's handshake (B5) |
| Peripherals | 794.9 | **420** | 420–600 (600 assumed) | one digital/DualShock pad per port, a 128 KB memcard byte responder, SIO stub (B5) |
| MDEC | 592.0 | **520** | 520–592 | savestate remnants, duplicated tables (B7, stretch; 520 only if B7 runs) |
| GTE | 2,563.0 | 2,563 | 2,563 | done (Phase 1) |
| **Core** | **19,567** | **~14,100** | **~14,200–15,800** (midpoint ~15,000) | |

**Re-fit of the current tree (2026-10-09).** The "Now" column is the Unit 4.0 fit. The current tree fits
`psx_top_pocket` in **19,191.0 ALMs** (295 M10K, 47 DSP; the reset sequencer and the commits since that fit
included). Per block: SPU 3,243.3, CD 2,521.3, CPU 2,389.6, GPU 4,620.3, GTE 2,560.2, DMA 1,318.9, memorymux
685.7, joypad 652.3, MDEC 600.3. The CPU's in-context gap over its standalone fit (2,291.1) falls from +383 to
+98, and the CD's (2,400.1) from +232 to +121. The targets are unchanged; the CPU's in-context range, derived
from the +383 gap, is re-checked at its gate.

**B4 field split.** `dmaRecord` (`dma.vhd:108-118`) mixes configuration and per-cycle state. `D_MADR`, `D_BCR`
and `D_CHCR` of the 7 channels go to MLAB. The per-channel flags (`request`, `timeupPending`,
`requestsPending`, `channelOn`, `chopwaiting`) and `chopwaitcount` stay in flip-flops. `dmaSettings` stays as
the single active working copy. What is removed is the per-channel register copies.

M10K: 295 − 64 (the CPU's dcache) + 6 (texture cache) + ~20 (shell) ≈ 257 of 277. The CD sector ring can
move to SRAM (−32) if needed. DSP is not a constraint (47 of 66).

#### Projection cases

| Case | Core | Shell | Whole build | Against 16,632 |
|---|---|---|---|---|
| Every target met | ~14,100 | ~2,350 | ~16,450 | ~180 under |
| Explorer midpoints | ~15,000 | ~2,350 | ~17,350 | ~720 over |
| Explorer high end | ~15,800 | ~2,800 | ~18,600 | ~2,000 over |

At the explorer midpoints the build needs the stretch levers (~420) and about 300 ALMs of set-A
amputations. That is the planning case; the every-target case is the best case.

#### Stretch levers (taken before any amputation)

| Lever | ALMs | Risk |
|---|---|---|
| CPU tag RAM in M10K | ~150 | high |
| Shared SPU/XA ADPCM filter table and multiplier | ~100 | |
| CD loader merged into `cd_pocket`'s fetch FSM | ~100 | |
| GTE in-context recovery | ~70 | |

#### Amputations (fallbacks)

Amputations are taken only at the final fit (Units B8, P2), each with its saving measured again on the
rewritten blocks. Several overlap work already in the rewrites, so the FEASIBILITY figures no longer apply:
- `NO_LIBCRYPT`: B2 already moves libcrypt to a ROM compare, so little is left to save.
- `DIGITAL_PAD_ONLY`: B5 already keeps one pad per port; only the DualShock logic is left to save.
- `NO_MDEC`: saves the MDEC as it stands, 592 without B7 or ~520 with it.

| Set | Amputations | Who decides |
|---|---|---|
| **A** (proposed) | `NO_LIBCRYPT`, `DIGITAL_PAD_ONLY`, `FIXED_CD_TIMING`, in that order (fewest games lost first) | taken at P2 if needed, each recorded with its measured saving; only after the human accepts the set |
| **B** | `NO_XA`, then `NO_MDEC` | never taken without the human's explicit approval |

#### Stop rules

- **After every block gate** the projection is recomputed: measured blocks + the explorer midpoints of the
  remaining blocks + the shell (measured, or ~2,350 until P1a and P1d land). A projection above
  16,632 + the stretch levers + the measured savings of set A is a **stop and re-plan**, and the human is
  asked whether set B is acceptable before anything else.
- **Checkpoint C1, after the SPU (B1) and CD (B2) gates:** if the two together save less than 2,300 of the
  2,855 they target (5,804.7 now → 2,950 at target), stop and re-plan before the CPU.

#### Contract exceptions

| Unit | Cut | Generic | Golden tie or stimulus mask | User-visible effect |
|---|---|---|---|---|
| B1 | reverb arithmetic removed | `NO_REVERB` | golden at `REVERBOFF = '1'` ([SPU.md](SPU.md)); reverb registers still written and read back | **no audible reverb**; open decision |
| B2 | peak-volume report removed | `NO_CD_PEAK` | response bytes of the peak command masked (`cd_top.vhd:2641-2670`) | games that read the CD peak meter get 0 |
| B3 | COP0 debug registers removed | `NO_COP0_DEBUG` | BPC/BDA/DCIC reads masked, breakpoint stimulus excluded (`cpu.vhd:1928-1932`) | reads return 0, no breakpoint exception; debuggers and anti-debug checks only |
| B3 | 18-bit cache tags | none: exact or not done | the golden compares 20 bits (`cpu.vhd:597-647`); kept only if directed aliasing tests show identical hits | none, or the change is dropped |
| B5 | 8 MB RAM option removed | none: not a cut | only `ram8mb` goes; the 2 MB mirror stays (`memorymux.vhd:570,624`) | none for retail games |

#### Open decisions

- **Reverb.** The SPU target of 1,350 needs the reverb arithmetic gone (~1,000 ALMs), so the Pocket SPU has no
  audible reverb. Keeping reverb puts the SPU near ~2,350 and makes a set-B amputation likely. Default:
  `NO_REVERB` on; asked again at the B1 gate with measured numbers (with and without).
- **Acceptable amputations.** Set A as above; set B only on approval.

#### SDRAM clock decision

The SDRAM stays at 4 × clk1x, **135.4752 MHz** (VCO/6), synchronous to the core, with the read-capture clock
**calibrated at runtime** by dynamic PLL phase shift (48 steps per period, 153.8 ps each): an eye sweep at
boot, a tracking check in vblank. Static timing cannot close the read capture above 122.2 MHz (the two
capture slacks sum to T − (tAC − tOH) − 5.28 ns). The data-pin-to-`dq_cap` path is the one path excused from
static timing; every other path must meet timing in all four corners.

| | Primary | Fallback (Unit M4) |
|---|---|---|
| SDRAM clock | 135.4752 MHz, synchronous | 116.1223 MHz (VCO/7), own clock domain with dual-clock FIFOs |
| Read capture | calibrated; excepted from STA | closes static timing (+0.43 ns) |
| Worst-trace peak before levers | 91.2% | 87.8% (SPU RAM fully off SDRAM) |
| Taken when | default | the hardware eye gate fails (M3) |

**Capture gate (hardware):**
- the eye is ≥ 10 steps (1.54 ns) at a cold start and after 30 minutes of the traffic loop;
- the tracker's minimum and maximum centre stay within ±3 steps of the boot centre over an hour;
- every SDRAM row of memtest passes with 0 errors in loop mode for an hour, the byte mask included.

Capture mechanics and the calibration contract: [MEMTEST.md](MEMTEST.md). Bandwidth mechanics and the
levers: [GPU.md](GPU.md#sdram-bandwidth--re-plan).

#### Gate M — VRAM bandwidth (replaces the Phase 2 bandwidth gate)

All five hold at the chosen SDRAM clock. Levers L1–L4 are in [GPU.md](GPU.md#sdram-bandwidth--re-plan).

| | Criterion |
|---|---|
| (a) Open loop | worst synthetic trace ≤ 80% over a sliding 1 ms window, the SPU charged as the cached SPU (model first, then B1's own access trace). **Gating case: 4× pitch on every voice**; 1× is reported. "L1 + L2 at 4× ≤ 80%" decides whether L3 and L4 are built |
| (b) Closed loop | the GPU's draw time on the worst trace grows ≤ 5% against a memory with the harness's `G_READ_LAT` (8 clk2x cycles). A worst-case bound (traces carry no read dependencies), cross-checked once with the real GPU in nvc against `vram_model` at the adapter's latency |
| (c) Latency | under the P1d arbiter's QoS policy, in the closed-loop run: zero SPU slot overruns (a read returning after its slot's 23rd clk1x) and zero late scan-out lines |
| (d) Real traces | game traces recorded locally (G2) also stay ≤ 80% open loop. Reported until such traces exist, gating after |
| (e) Hardware | the model stays within 10% of the memtest hardware figures (M3, pending hardware) |

#### Gate R — main RAM on PSRAM

The CPU stalls on `ram_done`, and icache refills, DMA and CPU data share the PSRAM (~95–140 ns per access).
Unit M5 replays a golden `ram_*` request trace against a `psram32` timing model with the P1d adapter's
latency. **Gate:** the replay finishes within 1% of the golden's cycle count, and no DMA FIFO under- or
overruns.

#### Phase 4 gate

- Every block gate above met in context, bit-exact against its golden, timing met.
- Gate M (a)–(d) and Gate R met in simulation; Gate M (e) and the capture gate are Phase 5 hardware items.
- Whole-core projection from the measured blocks and the measured shell ≤ 16,632 ALMs, taking stretch
  levers first, then set A in order, stopping at the first set that fits. Set B only on explicit approval.

#### Unit 4.0 result (2026-10-08): stop before the SPU rewrite

Historical measurement. The gates it applied (SPU ≤ 1,400, CPU ≤ 1,300, CD ≤ 2,100, core ≤ 13,550 ALMs and the
FEASIBILITY amputation order) are superseded by the re-plan above; the numbers stay as data.

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

A new tree `pocket/psx/` modelled on `pocket/memtest/`, sharing the APF tree and the memory controllers with
memtest through `pocket/common/`. Units:

| Unit | Scope |
|---|---|
| P1a | shell skeleton (APF top, PLL from the 812.8512 MHz VCO, `psx_top_pocket` stub), its measured size, the mixed-language simulation spike |
| P1d | `ram_*` → `psram32` adapter, `ddr3_*` → BL4 VRAM adapter, 3-client SDRAM arbiter with QoS, BIOS loader, reset gate, memcard store, bridge crossing, video PLL |
| P1b | CD loader (`cd_hps_*` ↔ `target_dataslot_read`), `cue2pocket.py` |
| P1c | 44.1 → 48 kHz audio, 8 APF video modes, controller map, memcard slot |
| M2a / M2b | calibrated read capture; bank-aware lookahead (L3, conditional) |
| M3 / M4 / M5 | memtest on hardware; 116.12 MHz fallback (conditional); main-RAM latency replay (Gate R) |
| P2 / P3 | full Pocket build; bring-up on hardware |

PLL clocks from the 812.8512 MHz VCO: clk1x 33.8688 MHz (/24), clk2x 67.7376 MHz (/12), clk3x 101.6064 MHz
(/8), SDRAM 135.4752 MHz (/6). The 53.693 MHz video clock is not an integer division of it and has its own PLL
(P1d).

**Gate:**
- the whole build fits ≤ 16,632 ALMs (90%) and ≤ 277 M10K, and meets timing on every path except the
  documented SDRAM read-capture path;
- the BIOS shell boots on a Pocket;
- one 2D and one 3D game run at full speed: ≤ 1% slower than MiSTer over a scripted 60 s, judged by the
  in-game frame counter, with the GPU stall and SDRAM eye counters readable over the bridge;
- Gate M (e) and the capture gate pass on hardware, and Gate R passes.

If the gate misses on area: stretch levers first, then set A, then set B only on approval. Block designs:
[GPU.md](GPU.md), [SPU.md](SPU.md), [CPU.md](CPU.md), [CD.md](CD.md), [CORE.md](CORE.md); the Pocket top
level and shell: [POCKET_TOP.md](POCKET_TOP.md).

### Phase 6 — Compatibility

A test list covering 2D, 3D, FMV, XA music, CDDA, memory-card saves and PAL/NTSC. Each title
is checked for speed against MiSTer, and failures are fixed or documented as known issues.

**Gate:** agreed list passes.

### Phase 7 — Release

Packaging and installers as in openfpga-C64 (`build.sh`, `install.*`, INSTALL.md), plus the
cue/bin converter.

## Work units

One row per unit of the re-plan; the gates above and the block docs hold the detail. Units in a wave own
disjoint files. "Pending hardware" marks a gate only a Pocket can measure.

| Unit | Wave | Scope | Depends on | Gate |
|---|---|---|---|---|
| R1 | 0 | this re-plan in the docs (ROADMAP, GPU, CPU, FEASIBILITY pointer, CORE stub) | none | docs recorded |
| S0 | 0 | one shared `pocket/common/` tree (APF, memory controllers, timing tool) moved out of memtest | none | memtest sim green, memtest fit unchanged |
| M0 | 0 | human runs the built 101 and 135 memtest cores on a Pocket; early error-rate read | none | pending hardware |
| T1 | 0 | `G_<BLK>_IMPL` generics on `psx_top_pocket`, per-block fit revisions, init/idle contract | none | default revision netlist-neutral (same fit as the tree without the generics) |
| M1 | 1 | bandwidth model v2: SPU cache, texture lines, lookahead, closed loop, QoS; combined L1+L2+L3 run | R1 | self-test pins today's figures; decides L3 and L4 |
| G2 | 1 | game trace path: emulator GPU dump to harness vectors (traces stay local) | none | converter and self-test |
| P1a | 1 | `pocket/psx/` skeleton, PLL, stub top, shell size, mixed-language spike | R1, S0 | skeleton fits; spike decision |
| M2a | 1 | calibrated read capture (dynamic phase shift, boot sweep, vblank tracking) in the shared controller, proven in memtest | R1, S0 | memtest sim green; 135 variant meets timing except the capture path |
| H0 | 1 | shared differential-harness scaffold `sim/common/`; SPU, CD, CPU, DMA, memorymux and joypad goldens run in nvc | none | GTE and GPU gates green on the scaffold |
| M2b | 2 | bank-aware lookahead (L3), only if M1 shows ≥ 3 points | M1, M2a | `tb_be.v` and memtest sim green |
| G1 | 2 | GPU levers: texture cache 1,024 lines (L2), destination-read gating (L4) when needed | M1 | `make diff` 0 mismatches |
| B1 | 2 | SPU rewrite with the L1 block cache | H0, T1 | bit-exact; ≤ 1,350 in context; timing met |
| B2 | 2 | CD rewrite | H0, T1 | bit-exact; ≤ 1,600 in context |
| X1 | 2 | whole-core nvc spike: speed, comparison window, golden `ram_*` trace | H0 | speed measured; B8 window fixed |
| P1d | 2 | memory adapters, 3-client arbiter, BIOS loader, reset gate, memcard store, bridge crossing, video PLL | P1a, M2a | adapter testbenches pass; shell fit re-derives the core budget |
| C1 | 2 | checkpoint after B1 and B2 | B1, B2 | SPU + CD save ≥ 2,300 of 2,855, else stop and re-plan |
| M3 | 3 | memtest on a Pocket: Phase 3 rows, bridge bench, eye width and tracker centres, chip marking | M2a (M2b if built) | closes Gate M (e) and the capture gate; pending hardware |
| M4 | 3 | 116.12 MHz fallback with dual-clock FIFOs, only if the eye fails | M3, P1a, P1d | Gate M (b), (c) re-run at 116.12 MHz |
| M5 | 3 | main-RAM latency replay against a `psram32` model | X1, P1d | Gate R |
| B3 | 3 | CPU rewrite | C1, H0, T1 | bit-exact; ≤ 1,900 in context |
| B4 | 3 | DMA rewrite | H0, T1 | bit-exact; ≤ 900 |
| B5 | 3 | bus and peripherals | H0, T1 | bus ≤ 850; peripherals ≤ 420 |
| B6 | 3 | GPU area v2 | G1 | ≤ 4,000 in context; ≤ 10 DSP; `make diff` 0 mismatches |
| P1b | 3 | CD loader and `cue2pocket.py` | P1a, P1d | loader testbench under the 6.67 ms deadline |
| P1c | 3 | audio 48 kHz, video modes, input map, memcard slot | P1a, P1d | testbench per module |
| B7 | 4 | MDEC trim (stretch, only if the projection needs it) | H0 | bit-exact |
| B8 | 4 | core assembly: every `G_<BLK>_IMPL` on `*_pocket`; system differential; in-context fit on 5CEBA4 | B1–B6, T1, X1 | every block gate re-measured; amputation costs measured |
| P2 | 4 | full Pocket build | B8, P1b, P1c, P1d, M2a, M3 (M2b, M4 if built) | ≤ 16,632 ALMs, ≤ 277 M10K, timing met except the capture path |
| P3 | 5 | bring-up on a Pocket: BIOS shell, then a 2D and a 3D title at full speed | P2, M3, M5 (M4 if triggered) | Phase 5 gate; pending hardware |
| C6 | 5 | compatibility list (Phase 6) | P3 | list passes |
| C7 | 5 | release packaging (Phase 7) | C6 | release |


## Results

Record each gate's measured numbers here when its phase ends. Each work unit edits only its own row.

| Phase | Result | ALMs | DSP | M10K | Timing | Date |
|---|---|---|---|---|---|---|
| 0 — sizing | measured | 26,135 (options off) | 83 | ~1.9 Mbit | n/a | 2026-10-07 |
| 1 — GTE | **PASS** | 2,490.8 needed (golden 3,917.6) | 3 (golden 15) | 9 blocks, 49,841 bits | clk2x +2.025 ns slow 85 °C, +1.599 ns slow 0 °C; hold ≥ +0.125 ns | 2026-10-07 |
| 2 — GPU | **FAIL**: area, and worst synthetic trace 99.9% of SDRAM at 101.6 MHz (`make bw`, table-driven model); bit-exact, setup within reference. At the re-plan's 135.5 MHz the gate figure is **91.2%**, FAIL against 80% (sliding 1 ms window, the SPU's 48 voice reads per sample as BL4 bursts; 90.2–91.2% over the three seeds, 75.9% without the SPU). 135.5 MHz also did not close timing in Phase 3. The bandwidth gate fails at both clocks, and the GPU is re-planned before Phase 5 | 4,785.3 needed (golden 5,481.4) | 10 (golden 32) | 27 (golden 27) | clk2x +0.763 ns slow 85 °C, +0.411 ns slow 0 °C; hold ≥ +0.079 ns | 2026-10-08 |
| 3 — memory test core | built, **pending hardware**. 135.5 MHz variant: **timing not met**; simulation passes, and the model matches the simulation (MIXED UNDER SCAN 105.8 MB/s vs 105.8) | 5,635 (101.6 MHz, with the bridge bench of Unit 3B; 4,097 without), whole core | — | — | 101.6 MHz: met on every clock, all four corners. 135.5 MHz: SDRAM read capture −0.42 ns setup, −0.38 ns hold, no phase closes it | 2026-10-08 |
| 4 — 4.0 baselines | **stop before 4A**: the CPU (991 to find vs 304 of levers) and SPU (1,680 vs ≤ 1,464) rules fire | `psx_top_pocket` 19,569.8 (5CSEBA6); SPU 3,079.6 / CPU 2,291.1 / CD 2,400.1 standalone | 47 | 295 | not gating | 2026-10-08 |
| Unit R1 | re-plan: recorded | — | — | — | — | 2026-10-09 |
| Unit S0 | **done**: memtest builds from `pocket/common/`; `build.sh sim` green | memtest 5,607 (5,635 before; seed noise) | — | 14 | 101.6 MHz met on every clock | 2026-10-09 |
| Unit M0 | pending hardware | — | — | — | — | — |
| Unit T1 | **done**: `G_<BLK>_IMPL` generics, 7 block revisions; netlist-neutral (identical per-entity fit with and without them); a mistyped value fails elaboration | `psx_top_pocket` 19,191.0 (5CSEBA6) | 47 | 295 | fit only | 2026-10-09 |
| Unit M1 | **done**: L1 + L2 + L3 at 4× pitch 72.9% at 135.4752 MHz (worst of s1–s3); L1 + L2 at 4× 76.2%, so L4 not needed at 135.5 MHz; L3 gains 3.3 points, so it is built; closed loop +3.2%; 0 SPU slot overruns and 0 late lines under QoS. At 116.12 MHz with SPU RAM off SDRAM: 81.8% after L2 + L3 (L4 needed) | — | — | — | — | 2026-10-09 |
| Unit G2 | **done**: DuckStation `PSXGPUDUMPv1` dumps convert into harness vectors; synthetic dump passes golden and pocket. No real game trace yet, so Gate M (d) stays report-only | — | — | — | — | 2026-10-09 |
| Unit P1a | **done**: `pocket/psx/` skeleton with the calibrated capture wired (eye readable over the bridge at 0x80000100); nvc mixed-language top chosen (VHDL top, Verilog leaves) | shell 1,452.5 (`sdram_cal` 343.3, ~155 placeholders) + stub 388.0 = 1,840.5 (5CEBA4) | 0 | 10 | met in all four corners with seed 2, capture pin path excepted; `clk_sys` +0.059 ns (thin) | 2026-10-09 |
| Unit M2a | **built, pending hardware**: dynamic-phase capture works on the fractional PLL only when ip-generated; boot sweep and tracker over steps 0–30 (the range where the `clk_cap`→`clk` transfer stays timed); every new sim test passes. The capture gate itself (eye ≥ 10 steps, tracker ±3) needs a Pocket | memtest 5,995 (101) / 6,261 (135) | 2 | 14 | **both variants met in all four corners**, capture pin path excepted; 135 MHz `clk_sys` +0.053 ns (thin) | 2026-10-09 |
| Unit H0 | **done**: `sim/common/` scaffold; GTE gate and GPU diff green on it; SPU, CD, CPU, DMA, memorymux, joypad goldens run in nvc | — | — | — | — | 2026-10-09 |
| Unit M2b | pending (conditional on M1) | — | — | — | — | — |
| Unit G1 | pending | — | — | — | — | — |
| Unit B1 | pending | — | — | — | — | — |
| Unit B2 | pending | — | — | — | — | — |
| Unit X1 | pending | — | — | — | — | — |
| Unit P1d | pending | — | — | — | — | — |
| Unit C1 | pending (checkpoint after B1, B2) | — | — | — | — | — |
| Unit M3 | pending hardware | — | — | — | — | — |
| Unit M4 | pending (conditional on M3) | — | — | — | — | — |
| Unit M5 | pending | — | — | — | — | — |
| Unit B3 | pending | — | — | — | — | — |
| Unit B4 | pending | — | — | — | — | — |
| Unit B5 | pending | — | — | — | — | — |
| Unit B6 | pending | — | — | — | — | — |
| Unit P1b | pending | — | — | — | — | — |
| Unit P1c | pending | — | — | — | — | — |
| Unit B7 | pending (stretch) | — | — | — | — | — |
| Unit B8 | pending | — | — | — | — | — |
| Unit P2 | pending | — | — | — | — | — |
| Unit P3 | pending hardware | — | — | — | — | — |
| Unit C6 | pending | — | — | — | — | — |

Phase 2 failed its gate and was re-planned. Unit 4.0 measured the baselines and stopped before the rewrites;
the re-plan above replaces its gates.

### Can the core run on a Pocket today? No

Nothing of the PSX has run on a Pocket. Four things stand in the way, and the re-plan addresses each:

| Blocker | State | What the re-plan does |
|---|---|---|
| It does not fit | `psx_top_pocket` is 19,191.0 ALMs and 295 M10K in context (5CSEBA6, re-fit 2026-10-09) against a core budget of ~14,280 (16,632 − ~2,350 shell). With every planned lever and amputation the old plan projected ~14,640 against 13,550 | Rewrite targets for every block toward ~14,100 (planning case ~15,000 plus stretch levers and set A), gated in context, with stop rules and checkpoint C1; the shell is measured by P1a and P1d |
| No Pocket top level | `psx_top_pocket` still has MiSTer's interfaces (DDR3 VRAM port, main-RAM bus, `cd_hps_*`, SNAC). A shell skeleton exists (`pocket/psx/`: APF top, PLL, data slots, the shared controllers with the calibrated capture around a stub core, 1,452.5 ALMs) but no adapters, loaders or video modes | Units P1b–P1d complete the shell ([POCKET_TOP.md](POCKET_TOP.md)) |
| Memory plan not proven | VRAM on the 16-bit SDRAM peaks at 91.2% at 135.5 MHz today (gate 80%); the model puts L1 + L2 + L3 at 72.9%, but the levers are not built. The calibrated capture makes 135.5 MHz meet timing in memtest, unproven on hardware | Levers L1 (B1), L2 (G1), L3 (M2b) and Gate M; capture gate on hardware (M3), fallback 116.12 MHz (M4); Gate R for main RAM (M5) |
| Nothing on hardware | the memory test core (Phase 3) is built and pending hardware | M0 (early read), M3 (memtest on hardware), P3 (bring-up) |

The first PSX build that can be loaded on a Pocket is the Phase 5 gate (Unit P3). Details:
[GPU.md](GPU.md#measurements), [MEMTEST.md](MEMTEST.md), [SPU.md](SPU.md), [CPU.md](CPU.md), [CD.md](CD.md).
