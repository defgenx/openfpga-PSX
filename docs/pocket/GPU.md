# GPU for the Pocket (`rtl/gpu_pocket*.vhd`)

`gpu_pocket` replaces `rtl/gpu.vhd` for the Pocket build. This document owns its design: the RTL
comments point here. Phase 2 gate and project context: [ROADMAP.md](ROADMAP.md).

The golden model is `gpu.vhd` and everything it instantiates, frozen. `gpu_pocket` must write
exactly the golden's VRAM contents, in the same order, and return the same data on every GPUREAD
and GPUSTAT read (busy/ready bits excepted, see [Timing](#timing)). `sim/gpu_diff` proves it.
One exception: a polygon that keeps the poly unit busy for more than 2^20 clk2x is drawn
completely, where the golden's watchdog aborts it part-way (see the Removed item below). The
harness cannot run a primitive that long.

## Contract

- Same entity ports as `gpu`. Inputs that the Pocket build ties off are ignored and their logic
  removed: savestates (`SS_*`, `loading_savestate`, `savestate_busy`), light guns and crosshairs,
  overlays (fps, CD, error, LBA, debug text), `REPRODUCIBLEGPUTIMING`, texture filter, `render24`,
  `dither24`, `oldGPU`, `drawSlow`, `debugmodeOn`, `rotate180`, crop and the 480p hack.
  `gpu_pocket` behaves as `gpu` with the values `sizing/psx_min_wrap.vhd:97-131` ties them to
  (`syncVideoOut = '1'`, every other option `'0'`/`"00"`). Removed outputs are driven to constants.
  Kept as live inputs: `ditherOff`, `noTexture`, `pal60`, `syncInterlace`, `fixedVBlank`, `videoout_on`.
- Units other than the polygon and line units are the golden's, unchanged: `gpu_rect`,
  `gpu_pixelpipeline`, `gpu_fillVram`, `gpu_cpu2vram`, `gpu_vram2vram`, `gpu_vram2cpu`,
  `gpu_videoout`.

## Baseline (5CEBA4F23C8, fitter "ALMs needed")

`sizing/gpu_golden.qsf` (wrapper `sizing/gpu_size_wrap.vhd`, options tied as in `psx_min_wrap`):

| Entity | ALMs needed | DSP |
|---|---|---|
| `gpu` total | **5,481.4** | 32 |
| `gpu` own logic | 556.9 | |
| 6 × `divider` | 684.7 | |
| `gpu_poly` | 2,117.0 | 29 |
| `gpu_pixelpipeline` | 697.5 | 3 |
| `gpu_line` | 478.2 | |
| `gpu_rect` | 295.6 | |
| `gpu_videoout` (+ `_sync`) | 275.6 | |
| `gpu_vram2vram` / `vram2cpu` / `cpu2vram` | 121.2 / 110.0 / 52.2 | |

Setup slack: clk2x +0.556 ns slow 85 °C, +0.040 ns slow 0 °C; clk1x +7.066 ns. Hold ≥ +0.068 ns.
The light-gun multiplies (`gpu_videoout.vhd:510-511`) fold away with the guns tied off, so the
golden here has 32 DSP, not the stripped build's 34.

## Dividers: six to two

The golden has six identical radix-2 dividers (`divider.vhd`, 45-bit dividend, 25-bit divisor),
shared by OR between `gpu_poly` and `gpu_line` (`gpu.vhd:1446-1471`). Latency is 49 clk2x from
`start` to `done` whatever the operands. Every use, with its real range:

| Use | Dividend magnitude | Divisor magnitude | Quotient bits |
|---|---|---|---|
| poly edges 0-2, 0-1, 1-2 (`gpu_poly.vhd:695-714`) | `|dx|·2^32 + dy-1`, < 2^42 | dy ≤ 511 | 43 |
| poly colour/UV gradients (`:757-851`) | `|ΔC·Δ − ΔC·Δ|·2^12` < 2^31 | denom < 2^21 | 31 |
| line dx, dy (`gpu_line.vhd:436-447`) | < 2^42 | points 1..1023 | 44 |
| line colours (`:449-459`) | < 255·2^12 + 2^10 | points | 20 |
| line pixels per row (`:462-465`) | points | `|dy|` or 1 | 10 |

`points` is 0 only for single-pixel lines, which skip the divides (`gpu_line.vhd` PROCCALC1);
lines with |dx| ≥ 1024 or |dy| ≥ 512 are dropped before dividing. Culled polygons never start
their divides (`gpu_poly.vhd:685-689` clears `start` in the same cycle).

`gpu_pocket` has two dividers (`rtl/gpu_pocket_div.vhd`), each told per request how many quotient
bits to compute, starting at that bit. The requester guarantees |dividend| < 2^qbits, so the
skipped high quotient bits are zero and the result is the golden's. Latency from the edge that
samples `start` to `done` is `ceil(min(qbits, G_DIVIDEND_BITS) / bits per cycle) + 2` clk2x
(golden: 47 on the same count).

| Divider | Divisor | Dividend kept | Bits/clk2x | Latency at 43 / 31 / 20 bits | ALMs (standalone) | clk2x slack |
|---|---|---|---|---|---|---|
| edge (`idivE`) | ≤ 1023 | 43 bits | 4 | 13 / — / 7 | 195 | +3.106 ns |
| gradient (`idivG`) | < 2^21 | 31 bits | 2 | — / 18 / 12 | 171 | +6.184 ns |

Both follow the golden's sign rule (`quotient = ±|a| div |b|`, sign = sign(a) xor sign(b)) and its
divide-by-zero result, which is not all ones: with a 25-bit accumulator, magnitude bits 44..20
are ones and bits 19..0 are the complement of dividend bits 44..25. No reachable request divides
by zero on slot 0. The remainder is unused by poly and line and is not produced.
`make -C sim/gpu_divtest` compares both against `divider.vhd`: every poly edge (dx × dy), every
line dx/dy, colour and pixels-per-row case, and 2.2M gradient and random cases, 6,918,248 in all,
0 mismatches.

**Stale quotient bit.** In `CALCBOUNDARY2` the golden computes `vo_diff·baseStep` and
`vp_diff·baseStep` from `baseStep` latched one clk2x before `done` (`gpu_poly.vhd:715-724`). At
that edge the golden divider's `quotient` still holds the previous division's magnitude bit 0
(`divider.vhd:88-104`: `quotient_u(0)` is written on the last iteration, `quotient` follows one
edge later). So `vo_diff_base` and `vp_diff_base` use `±(|q| with bit 0 from the previous division
on golden divider slot 0)`. Slot 0 runs poly edge 0-2, poly `dxR` and `dxU`, and line `dx`.
`gpu_pocket` keeps that bit in one register, updated whenever a division the golden would run on
slot 0 completes (initially 0, never reset, like `quotient_u`), and the poly unit uses it to form
the same stale `baseStep`. `xStart`/`xEnd` themselves use the final quotient.

## Polygon unit (`rtl/gpu_poly_pocket.vhd`)

Same states and per-pixel output as `gpu_poly`; the differences are all exact:
- **20-bit interpolators.** Pixels use only `work_R/G/B/U/V(19 downto 12)` (`gpu_poly.vhd`
  PROCPIXELS), and every operation feeding them is an add or a product taken mod 2^32. Bits below
  20 of a sum or product depend only on bits below 20 of its operands, so the pocket unit's
  channel registers (`dxC`, `dyC`, `rowAcc`, `rowAux`, `tacc`) are 20 bits wide.
- **Interpolator per pixel, not per step.** The golden loads `work_*` per line from ten products
  in PREPARELINE (`:978-998`, 20 DSP) and adds `dx*` per pixel. `gpu_poly_pocket` computes each
  pixel's value directly as `rowAcc + dxC·x` (`workv`, five 20 × 10 multipliers, x ≤ 1023 for
  every output pixel). `rowAcc` is the channel's value at x = 0 on the current row: loaded in setup
  for each half (`rowAux` holds the second half's), then stepped by ±`dyC` on every PREPARELINE
  pass, drawn and skipped lines alike, as yCoord steps by ±1. A line costs the golden's cycles.
- **Setup products** (edges, `denom`, the gradient numerators, `vo/vp_diff·baseStep`) run on two
  setup multipliers, `pr = mA·mB` (24 × 13) and `prod2 = mA2·mB2` (20 × 13), plus shift-add for
  `baseStep`, inside the setup time the dividers already take.
- Removed: `REPRODUCIBLEGPUTIMING`/`targetTiming` padding and the golden's 2^20-cycle watchdog,
  which forces the unit back to IDLE (`gpu_poly.vhd:446-456`); `error` is driven '0'. The line
  unit keeps its watchdog. The texture-filter outputs are still computed but `gpu_pocket` leaves
  them open, so synthesis removes them; the poly unit's filter and dither inputs are unused.

## DSP allocation

| Block | DSP | Use |
|---|---|---|
| `gpu_poly_pocket` | 7 | five per-pixel `dxC·x`, two setup multipliers |
| `gpu_pixelpipeline` (golden) | 3 | texture × colour, 8×8 |
| **Total** | **10** | gate: ≤ 10 |

## Timing

No hardware measurement of polygon setup time exists (psx-spx documents video timing only). The
reference is DuckStation's `s_setup_time` (`src/core/gpu.cpp`, clk2x units: 2 ticks per CPU clock),
the model the emulator community treats as closest to hardware:

| Primitive | DuckStation | Golden (this core) |
|---|---|---|
| triangle flat / textured / gouraud / gouraud+textured | 46 / 226 / 334 / 496 | 53 / 113 / 117 / 177 |
| quad (whole command) | 82 / 262 / 370 / 532 | 106 / 226 / 234 / 354 |
| line segment | 16 | 53 |

The golden is already slower than the reference for flat triangles and quads, and for lines. The
gate is therefore: for every class, `gpu_pocket`'s setup is ≤ max(reference, golden). Setup is
counted in clk2x from ISSUE (line: PROCCALC1) to the first PREPARELINE (line: first pixel
state), measured by `sim/gpu_diff` on every primitive it runs.

Because the setup time changes, the CPU can see different GPUSTAT busy/ready timing than with the
golden; `sim/gpu_diff` compares those bits as timing, not data. With `REPRODUCIBLEGPUTIMING` tied
off (as in the MiSTer build, `PSX.sv:924`) the core never padded to a target time anyway.

## Gate metric

The fitter's "Resource Utilization by Entity" "ALMs needed" for the `gpu` / `gpu_pocket` instance
in `sizing/gpu_size.qpf` (revisions `gpu_golden`, `gpu_pocket`), the same metric as Phase 1.

## SDRAM bandwidth

`sim/gpu_diff` writes a VRAM access trace of each side (`make trace`: golden `run/trace_sN.txt`,
`gpu_pocket` `run/trace_pocket_sN.txt`). `sim/gpu_diff/bwmodel.py` replays it against a 16-bit
SDRAM (row misses, refresh, video scan-out deadline) through a 64→16-bit adapter, one BL4 burst per
64-bit beat, and reports the peak utilisation over any complete 1 ms window. `make bw` runs the 80%
gate at `BW_MHZ` (default 135.4752, the clock the core uses), then a report at 101.6064 MHz that
never fails; **the worst peak the gating run prints is the gate figure**. There are no game traces
in this repository (no BIOS or game images); the traces are the generator's game-like random suite.

The model is open-loop (each access starts at its traced time) and has one controller model,
which follows the command timing of `pocket/memtest/fpga/core/sdram_ctl.v`:
- Timings come from `sdram_timing.json` (generated from the datasheet table), in ns, converted
  per clock as `max(min_clk, ceil(ns × MHz / 1000))`, so `--mhz` alone changes the clock; the
  rule is checked against the table's own precomputed cycles at both clocks on every run.
  At 135.4752 MHz: tRCD 3, tRP 3, tRAS 6, tRC 9, tWR 2, tRRD 3, tRFC 9, CL 3. At 101.6064 MHz: 3,
  3, 5, 7, 2, 2, 7. The `--trcd` ... `--refresh-us` flags override them for what-if runs.
- One request is decoded while the previous burst is on the bus; open page, four banks, no early
  row open for the next request. Per bank: tRCD (column after ACT), tRAS (PRE after ACT), tRP
  (ACT after PRE), tRC (ACT to ACT); tRRD between ACTs of any bank.
- Column commands are 4 cycles apart (one BL4 burst per 4 cycles). A write follows a read's CAS
  after CL + 6 cycles (the read-to-write turnaround), a read follows a write after 4. PRE is
  allowed 5 cycles after a read's CAS and 4 + tWR after a write's.
- Refresh every 6.9 µs: wait for every bank's PRE, PRE ALL, tRP, REF, tRFC, rows closed.
- **No partial-write cost.** DQM has zero write latency and a 1-beat write is already one BL4
  burst, so a partial `ddr3_BE` (22% of `trace_s1`'s writes) costs nothing. A counter of
  read-modify-write cycles is asserted to be 0 at the end of every run.
- Utilisation is the fraction of cycles from a request's decode to the end of its data slot, plus
  refresh; the SPU's 5 MB/s is added as a uniform load.

Against the previous model (every read paid its full CAS before the next command, no decode
overlap, tRCD/tRP/tRC fixed for 101.6 MHz at both clocks) this is closer to `sdram_ctl`: the
overlap lowers the load, the turnaround, tRAS and tWR from the table raise it. The gate figure
moved to the value in Measurements for that reason and because the 135.4752 MHz run now uses
135.4752 MHz's cycle counts.

**Mixed-random mode** (`bwmodel.py --mixed [--scan] [--rnd-read]`) runs the same controller
model on memtest's closed-loop SDRAM tests: 65,536 single BL4 bursts at random burst addresses
of a 1 MiB region (`sd_traffic.v`, the same xorshift stream and seed as `sim/tb_core.v`), half
reads in `MIXED`, with `--scan` the scan-out stream of 160 bursts per 63.0 µs line alternating
with the test through the round-robin arbiter (`sdram_arb.v`). It prints the bench MB/s as
`memtest_core.v` does (bench bytes only, over the test's cycles). The simulated figures in
`docs/pocket/MEMTEST.md` check it:

| 101.6064 MHz | `memtest` simulation | `bwmodel.py --mixed` | error |
|---|---|---|---|
| random read | 93.0 MB/s | 93.2 | +0.2% |
| mixed | 88.2 | 89.6 | +1.6% |
| mixed under scan-out | 74.6 | 76.0 | +1.9% |

At 135.4752 MHz it predicts 124.0, 119.3 and 105.8 MB/s. The simulation was run with its own
`sdram_ctl` parameters (tRFC 8, tWR 3), not the table's, which accounts for part of the error.
The validated model carries the gate: if it falls outside about 10% of the simulation or the
hardware, a trace-replay check replaces it before the 80% is trusted.

## Verification

- `make -C sim/gpu_diff golden` and `selftest`: the harness is sound.
- `make -C sim/gpu_divtest`: both dividers match `divider.vhd` over every use's range.
- `make -C sim/gpu_diff diff`: 0 VRAM, GPUREAD and GPUSTAT data mismatches, 0 span mismatches,
  setup within the criterion above, every coverage counter non-zero.

## Measurements

Measured 2026-10-08. Gate result: **FAIL**, on area and on SDRAM bandwidth at the 101.6 MHz the gate was
written for. The re-plan (ROADMAP Phase 4) accepted it with the SDRAM at 135.4752 MHz, where the
bandwidth gate figure is 74.7% (pass).

| Criterion | Gate | Golden | `gpu_pocket` | |
|---|---|---|---|---|
| ALMs needed (`gpu` / `gpu_pocket` instance) | ≤ 4,500 | 5,481.4 | **4,785.3** | FAIL (+285) |
| DSP | ≤ 10 | 32 | 10 | pass |
| M10K | — | 27 | 27 | |
| Setup vs reference (per triangle) | ≤ max(golden, reference) | — | 4,094 checked, 0 over | pass |
| Worst trace, peak 1 ms window, SDRAM at 135.4752 MHz (the gate figure `make bw` prints) | ≤ 80% | 74.7% | 74.6% | pass |
| Same, SDRAM at 101.6064 MHz (report only) | ≤ 80% | 99.9% | 99.2% | FAIL |
| Bit-exact (VRAM, GPUREAD, GPUSTAT data, spans) | 0 mismatches | — | 0 over 12,825 commands | pass |

**Area by entity** (`sizing/gpu_size.qpf` revision `gpu_pocket`, ALMs needed): `gpu_poly_pocket`
1,921.7 (golden `gpu_poly` 2,117.0), `gpu_line_pocket` 507.8 (478.2), the two dividers 129.5 +
97.5 (golden six: 684.7), `gpu_pocket` own logic 496.5 (556.9). The golden units are unchanged:
`gpu_pixelpipeline` 698.9, `gpu_rect` 299.7, `gpu_videoout` 260.2, `gpu_vram2vram` 119.2,
`gpu_vram2cpu` 111.1, `gpu_cpu2vram` 52.5, `gpu_fillVram` 46.6. The saving is 696 ALMs, against
the 981 the gate needs.

**Timing**: setup slack clk2x +0.763 ns at slow 85 °C and +0.411 ns at slow 0 °C (golden: +0.556 /
+0.040), clk1x +7.159 ns. Hold slack ≥ +0.079 ns in all four corners.

**Harness**: `make -C sim/gpu_diff -j6 diff SEEDS="1 2 3 4"` (directed, edge, random): 12,825
commands, 1,908,423 VRAM writes, 0 mismatches of any kind, every coverage counter non-zero.
Average setup in clk2x, golden → `gpu_pocket`: flat 62.6 → 57.0, gouraud 129.4 → 143.4, textured
120.3 → 98.3, gouraud-textured 182.7 → 216.7. Gouraud setup is slower than the golden but stays
under the reference (334 / 496).

**Bandwidth** (`make bw SEEDS="1 2 3"`, game-like traces, peak over any 1 ms window, golden /
`gpu_pocket`):

| SDRAM clock | seed 1 | seed 2 | seed 3 |
|---|---|---|---|
| 135.4752 MHz (4 × clk1x, gating) | 74.7% / 74.4% | 74.7% / 74.6% | 71.0% / 71.7% |
| 101.6064 MHz (3 × clk1x, report) | 99.9% / 99.2% | 98.5% / 97.3% | 95.7% / 95.5% |

These replace the earlier hand-run figures (101.6 MHz 98.5% / 98.2%, 98.0% / 96.6%, 93.6% / 94.1%;
135.5 MHz 73.9% / 73.5% at seed 1), which used the old model and, at 135.5 MHz, cycle counts
fixed for 101.6 MHz. Mean utilisation at 135.4752 MHz is 45 to 46% and the SPU load adds 1.8 points.

How far these figures overstate a game:
- The generator issues primitives back to back with no CPU or GTE time between them, so it draws
  at the GPU's full fill rate for the whole trace. A game interleaves other work.
- The model charges every `sdram_ctl` overhead (see above). Seed 1, golden / `gpu_pocket`,
  no tRCD, tRP, tRAS, tRC or tRRD (`--trcd 0 --trp 0 --tras 0 --trc 0 --trrd 0`): 64.0% / 64.1%
  at 135.4752 MHz, 86.9% / 87.0% at 101.6064 MHz. Every overhead off (also `--twr 0 --trfc 0
  --refresh-us 1e9 --cl -2`, which removes the read-to-write turnaround), data beats and the SPU
  load only: 61.6% / 62.0% and 82.3% / 82.6%; without the SPU load (`--spu-mbps 0`) 59.8% / 60.1%
  and 79.9% / 80.1%. At 101.6064 MHz the FAIL holds even for an ideal controller.
- `bwmodel.py` also prints a peak per scanline (`peak/line`). For an open-loop trace it only shows
  that some line-length window is saturated: it reads 100% plus the SPU term at either clock and
  says nothing about how long the GPU would stall.
