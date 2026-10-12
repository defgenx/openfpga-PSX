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
- The pixel pipeline is the golden's, unchanged (`gpu_pixelpipeline`). The other units are Pocket units:
  `gpu_poly_pocket`, `gpu_line_pocket`, `gpu_rect_pocket`, `gpu_copy_pocket` (fill, upload, VRAM copy and
  download in one engine) and `gpu_videoout_pocket` (the sync path only).

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

## Rectangle unit (`rtl/gpu_rect_pocket.vhd`)

Same states, same cycle counts and the same pixel stream as `gpu_rect`. The clip and loop logic is restated
with limits instead of counters, all exact:
- **Last pixel and last row.** `CHECKPOS` computes the first pixel (`x0 = max(posx, left)`, `y0` the same on
  `top`, plus one row when interlaced drawing and `activeLineLSB` equal its parity) and the last
  (`xLim = min(posx + width - 1, right)`, `yLim = min(y + height - 1, bottom)`, unclipped sums). A row ends
  at `xPos = xLim`, the rectangle at `yPos + yAdd > yLim`. This is the golden's `xCnt + 1 >= sizex or xPos + 1 > right`
  and `yCnt + yAdd >= sizey or ypos + yAdd > bottom`, because `xLim` and `yLim` are the clipped sizes added to
  the clipped start.
- **Nothing to draw** (`x0 > xLim`, `y0 > yLim`, `left > right` or `top > bottom`): done at `CHECKPOS`. The golden
  reaches the same end after `CHECKPOS` (or one row later when interlaced skips the only row), writing nothing; a
  transparent rectangle also reads one line first, which the Pocket unit does not.
- **No area test per pixel**: every pixel of a row lies inside the area by construction (`x0 >= left`,
  `xLim <= right`, rows `top <= y <= yLim <= bottom`).
- The line read of a transparent or mask-checked rectangle asks for the pixels the row draws (`xLim - x0 + 1`),
  the golden for the clipped width. The pixels in between are never used.
- **Removed:** `REPRODUCIBLEGPUTIMING` padding and the 2^20-cycle watchdog. A rectangle that keeps the unit busy
  for more than 2^20 clk2x is drawn completely, where the golden aborts it (as for the polygon unit above). The
  harness cannot run one that long.

## Transfer engine (`rtl/gpu_copy_pocket.vhd`)

One state machine for the fill (`02`), CPU-to-VRAM (`A0`), VRAM-to-VRAM (`80`) and VRAM-to-CPU (`C0`) commands, with
the golden units' states and cycle counts, so the harness reports no timing difference for them. What is shared:
- **Command words.** Source and destination position registers (`srcX/Y`, `dstX/Y`) are loaded from the same words
  as the golden's; width is stored as `width - 1` (`size - 1` mod 1024 gives the golden's 0 means 1024 for free; a fill
  rounds up to 16 pixels first) and the rows left as a down counter.
- **Address steppers.** One `xSrc` (+1 or -1), one `xDst` (+4 fill, +1, -1) and one `xCnt` (+4 or +1) adder, each used
  by every command that needs it. The copy direction (`dir`) is decided in `REQUESTFIRST` from `srcX + width - 1` and
  `dstX + width - 1` (mod 1024, the same sums that start a backwards row), as the golden decides it from the size word.
- **Colour, halfword and FIFO low half share one 16 bit register**: the fill colour, the second halfword of an upload
  word and the low half of a download word are never live together.
- **Download FIFO** (1024 x 32) is the golden's `SyncFifoFallThrough` with the same thresholds.
- `drawer_reset` (GP1 01) stops an upload or a download only, as in the golden; a fill and a copy run on.
- The fill's four-pixel writes leave through `fillWrite` with the other writes' address and colour wires, and `doneWr`
  is `done` of every command except the download (the golden clears the texture cache after the other three).

## Video out (`rtl/gpu_videoout_pocket.vhd`)

`gpu_videoout` with `syncVideoOut = '1'` and the options tied off: `gpu_videoout_sync` and the line fetch in one entity.
The async path, the overlays (fps, CD, error, LBA, debug), the crosshairs and light-gun sensors, the 24-bit mirror
(`render24`) and the savestate ports are gone. Everything the Pocket reads is the golden's, on every clock:
`hsync`, `vsync`, `hblank`, `vblank`, `ce`, `r/g/b`, the display size and offset outputs, `isPal`, `hResMode`, the
timer outputs and `GPUSTAT` bits. Restated arithmetic, all exact:
- The window tests (`vposNew < start`, `>= end`, and the same one line later) come from one subtraction each
  (`rel = vposNew - start`, `toEnd = end - vposNew`), and the line indices (`lineIn`, `lineInNext`) from `rel`.
- The display-start adjustment of the fetch line is one 5 bit subtraction and one addition (threshold 19 on PAL, 16
  otherwise, doubled when interlaced) instead of four adders.
- The vsync line counter saturates at 15: only counts 5 to 7 (480-line) and 10 to 12 are decoded.
- `gpu_videoout`'s `clkvid` input still clocks the line RAM read port. The shell passes clk2x.

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
off (as in the MiSTer build, PSX_MiSTer `PSX.sv:924`) the core never padded to a target time anyway.

## Gate metric

The fitter's "Resource Utilization by Entity" "ALMs needed" for the `gpu` / `gpu_pocket` instance
in `sizing/gpu_size.qpf` (revisions `gpu_golden`, `gpu_pocket`), the same metric as Phase 1.

## SDRAM bandwidth

`sim/gpu_diff` writes a VRAM access trace of each side (`make trace`: golden `run/trace_sN.txt`,
`gpu_pocket` `run/trace_pocket_sN.txt`). `sim/gpu_diff/bwmodel.py` replays it against a 16-bit
SDRAM (row misses, refresh, video scan-out deadline) through a 64→16-bit adapter, one BL4 burst per
64-bit beat, and reports the peak utilisation over any complete 1 ms window, sliding (every start cycle, not
aligned windows). `make bw` runs the 80%
gate at `BW_MHZ` (default 135.4752, the clock the core uses), then a report at 101.6064 MHz that
never fails; **the worst peak the gating run prints is the gate figure**. There are no game traces
in this repository (no BIOS or game images); the traces are the generator's game-like random suite.

The model is open-loop (each access starts at its traced time) and has one controller model,
which follows the command timing of `pocket/common/mem/sdram_ctl.v`:
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
  burst, so a partial `ddr3_BE` (22% of `trace_s1`'s writes) costs nothing. Every run replays each
  trace a second time with every byte enable forced to 0xFF and asserts identical busy intervals;
  the printed line reports the cycle difference (0).
- Utilisation is the fraction of cycles from a request's decode to the end of its data slot, plus
  refresh. The peak is the maximum over all window start cycles (the exact maximum, from prefix sums
  over the busy intervals), complete windows only.
- **SPU traffic is simulated on `spu.vhd`'s own schedule.** With `useSDRAM = '1'` every SPU RAM
  access is one 16-bit halfword (`spu_ram.vhd:220-226`, `sdram_be "0011"`), so each costs one BL4
  burst. Per 44.1 kHz sample (768 clk1x cycles):
  - Each of the 24 voices reads its ADPCM header and one data halfword, whatever its pitch or key
    state (`spu.vhd:1504-1506`, `:1542-1547`, `:1594-1598`): 48 reads. A voice slot lasts at least 23
    clk1x cycles (`:1931`); the two reads are in one 16-byte block.
  - Reverb, when enabled, reads 10 and writes 4 halfwords (`:1985-2221`). Capture writes
    (`:2261-2302`) and every access in the top 64 KiB stay on-chip (`spu_ram.vhd:144`, `:165`). The
    standard reverb presets' work areas (≤ 63,168 bytes) end at the top of SPU RAM, so they are
    on-chip.
  - A RAM transfer takes at most one access per voice slot (`spu.vhd:1884-1896`): 24.
  The gate charges the 48 voice reads: 2.12 M bursts/s, random in a 512 KiB region in the rows above
  VRAM's (same four banks), one outstanding at a time. `--spu-voices`, `--spu-reverb sdram` and
  `--spu-dma` change the charge. The accesses go through the same controller as the trace, so each
  pays its row misses and read-to-write turnarounds and closes rows the GPU had open. Interleaved,
  they add 15.3 to 16.9 points to the peak at 135.4752 MHz.

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

| | simulation, 101.6064 MHz | `bwmodel.py`, 101.6064 MHz | simulation, 135.4752 MHz | `bwmodel.py`, 135.4752 MHz |
|---|---|---|---|---|
| random read | 93.1 MB/s | 93.2 | 124.0 | 124.0 |
| mixed | 89.5 | 89.6 | 119.3 | 119.3 |
| mixed under scan-out | 75.9 | 76.0 | 105.8 | 105.8 |

Under scan-out at 135.4752 MHz the model takes 671,151 cycles against the simulation's 671,241.
The validated model carries the gate: if it falls outside about 10% of the simulation or the
hardware, a trace-replay check replaces it before the 80% is trusted.

### SDRAM bandwidth — re-plan

The model above puts the worst synthetic trace at 91.2% at 135.4752 MHz against the 80% gate. The plan is to
cut traffic with four levers, calibrate the read capture instead of closing it statically, and add closed-loop
and latency criteria. Gates and decisions: [ROADMAP.md](ROADMAP.md#gate-m--vram-bandwidth-replaces-the-phase-2-bandwidth-gate).
Capture mechanics: [MEMTEST.md](MEMTEST.md).

#### Traffic on `trace_s1`

| Traffic | Share of beats | Note |
|---|---|---|
| Pixel writes (single beat) | 72% | already 3.5 pixels per beat; write combining saves 0.4% |
| Texture-cache misses (single beat) | 4.6% | |
| Destination-span and CLUT reads (2–63 beats) | 12.5% | |
| Scan-out | 10% | |

#### Levers

Figures are the worst peak on `trace_s1` at 135.4752 MHz (baseline 91.2%), from `bwmodel.py` replays. **Each
was run alone as a single-lever replay.** No run combines them yet, and the SPU's voice pitch is not modelled
in `bwmodel.py` today. The combined run is the model v2 result below.

| Lever | Where | Single-lever replay |
|---|---|---|
| **L1** SPU per-voice block cache: 24 × 16 B, one block fill per 28 samples instead of 48 reads per sample | SPU rewrite (B1) | 76.9% at 1× pitch, 80.6% at 4× pitch (the gating case) |
| **L2** texture cache from 256 to 1,024 lines (~6 M10K net, partly paid back because the filter ways are gone) | `gpu_pixelpipeline_pocket` (G1) | 74.4% together with L1; about −2.5 points |
| **L3** bank-aware controller: lookahead of one request, early ACT/PRE on another bank during a burst | `sdram_ctl`/`sdram_arb` (M2b) | −3 to −6 points (estimate; 8.5–12 points of row overhead exist); built only if the model shows ≥ 3 points |
| **L4** destination-read gating: skip the span read when no pixel of the primitive can blend or mask-check | GPU (G1, B6) | −1 to −4 points (realistic); the upper bound of removing every 2–63-beat read is −9.6 points; built only if it stays exact on the VRAM write sequence, and only when L1 + L2 at 4× is above 80% or the fallback clock is taken |

Adding the single-lever figures projects ~66–71% after L1–L3 at 135.4752 MHz. That is a projection, not a
measurement.

L1 is exact because:
- every SPU RAM write passes through the SPU itself (CPU and DMA transfers, capture, reverb);
- the IRQ compare keys on the computed address, not on the memory access (`spu.vhd:1087-1097`), so the cache
  sits below it and below the `ram_request`/`ram_Adr` timing;
- with `useSDRAM = '1'` the voice slot length is fixed (`voiceCounter >= 23`, `spu.vhd:1931`), so a faster read
  never shifts its timing. `useSDRAM = '1'` is the contract mode.

L1 holds only conditionally: a slow read stretches the slot (the counter saturates at 31, `spu.vhd:1480`), so a
read returning after the 23rd clk1x breaks exactness; Gate M (c) covers it. A per-voice cache already exists in
`spu_ram.vhd:268-420` (24 voices plus a transfer slot, 8 × 64-bit words each, write update at `:389`), used on
the `useSDRAM = '0'` path; L1 is built from it.

#### Gate M

All five criteria, at the chosen SDRAM clock:

| | Criterion |
|---|---|
| (a) | open loop: worst synthetic trace ≤ 80% over a sliding 1 ms window, the SPU charged as the cached SPU. Gating case: 4× pitch on every voice; 1× reported. "L1 + L2 at 4× ≤ 80%" decides whether L3 and L4 are built |
| (b) | closed loop: the GPU's draw time on the worst trace grows ≤ 5% against a memory with `G_READ_LAT` (8 clk2x cycles, `vram_model.vhd:24`). The traces carry no read dependencies, so the model serialises every read behind its data: a worst-case bound, cross-checked once with the real GPU in nvc |
| (c) | latency, under the P1d arbiter's QoS (SPU and scan-out above GPU draw): zero SPU slot overruns and zero late scan-out lines. The 1 ms peak cannot show either: at 135 MHz the model reports a 27.9 µs scan-out max latency and a 32.1 µs max queue wait, and a 63-beat GPU read (~1.9 µs) outlasts a whole SPU slot (~0.68 µs) |
| (d) | game traces recorded locally also stay ≤ 80% open loop (reported until such traces exist, gating after) |
| (e) | the model stays within 10% of the memtest hardware figures (pending hardware) |

#### SDRAM clock: calibrated 135.4752 MHz primary, 116.12 MHz fallback

| | Primary | Fallback |
|---|---|---|
| Clock | 135.4752 MHz (VCO/6), synchronous to the core | 116.1223 MHz (VCO/7), asynchronous, dual-clock FIFOs |
| Read capture | dynamic phase shift, calibrated at boot and tracked in vblank; excepted from static timing | closes static timing (+0.43 ns) |
| Worst-trace peak before levers | 91.2% | **87.8%** floor, with SPU RAM fully off SDRAM (86.9% on s2, 86.4% on s3) |

At 116.12 MHz with the SPU RAM on PSRAM, L2 and L3 are mandatory and L4 is very likely needed:
87.8 − 2.5 − (3 to 6) = 79.3–82.3% before L4. With SPU RAM left on SDRAM the peaks are 98.7% at 116.12 MHz and
98.2% at 121.9 MHz: the bandwidth lost outweighs the timing gained. The FIFOs change the read latency the GPU
sees, so Gate M (b) and (c) are re-run at 116.12 MHz.

#### Model v2 results

`bwmodel.py` v2 adds options that are all off by default. With them off it prints the same figures as before:
`bwselftest.py`, run by `make bw`, pins 91.2% / 98.7% / 98.2% / 99.9% on s1 at 135.4752 / 116.1223 / 121.9277 /
101.6064 MHz, and 87.8% / 86.9% / 86.4% at 116.1223 MHz with `--spu-voices 0`.

| Option | Lever | Model |
|---|---|---|
| `--spu-cache 1x\|4x\|mixed` | L1 | each voice keeps a phase and a sequential 16-byte block pointer; every 28 / pitch samples it fills the next block (2 BL4 bursts in its slot). Pitch 1× or 4× on every voice, or mixed (1×, 2×, 4× by voice number); phases and start blocks are fixed pseudo-random. Reverb and transfers unchanged |
| `--tex-lines N` | L2 | an LRU of N 8-byte lines behind the trace's 256-line cache; single-beat reads that hit are dropped, a write evicts the lines it covers. Slightly optimistic against N direct-mapped lines |
| `--lookahead` | L3 | the next queued request (one deep) gets its PRE/ACT early under tRP, tRC, tRRD, tRAS. Command-bus collisions are not modelled |
| `--closed-loop` | Gate M (b) | every read blocks the next access until its last beat returns. The traces carry no read dependencies, so this is a worst-case bound. Inflation is the replay time against the same serialisation on a memory with `G_READ_LAT` = 8 clk2x cycles |
| `--qos` | Gate M (c) | beat-level priority: SPU, then scan-out (reads ≥ 64 beats), then draw. Counts SPU reads returning after their slot's 23 clk1x cycles, and scan-out reads returning more than one line period (63.56 µs) after their request |

Results, peak over a 1 ms window, worst of s1/s2/s3:

| At 135.4752 MHz | Peak | Note |
|---|---|---|
| baseline | 91.2% | |
| L1 at 1× / mixed / 4× | 76.4% / 77.4% / 78.4% | the earlier single-lever replay gave 80.6% at 4×; the difference is this model's pitch phase and block pointer |
| L1 + L2 at 4× | 76.2% | ≤ 80%: **L4 is not needed** at this clock |
| L1 + L2 + L3 at 4× | **72.9%** (71.2% at 1×) | replaces the "~66–71%" projection. L3 gains 3.3 points on the worst trace (3.1 / 3.3 / 1.5 on s1 / s2 / s3): **L3 is built** |
| closed-loop inflation, L1 + L2 + L3 at 4× | +3.2% (+3.3% with QoS) | Gate M (b) ≤ 5%: model bound met; the cross-check with the real GPU in nvc against `vram_model` has not run |
| SPU slot overruns / late scan-out lines, `--qos` | 0 / 0 | late lines provisional until P1d's scan-out FIFO deadline (below). Without QoS 13–14% of SPU reads overrun (2,113 of 15,095 on s1). Scan-out max latency falls from 27–38 µs to ~3.5 µs |

| At 116.1223 MHz, SPU RAM off SDRAM | Peak |
|---|---|
| baseline | 87.8% |
| + L2 | 84.8% |
| + L2 + L3 | 81.8% (s2): still above 80%, so L4 is needed on the fallback |
| closed-loop inflation | +5.0% / +4.9% / +4.8%: at the limit |

The late-line criterion is weak as modelled: a whole line period is a generous deadline, and even the plain FIFO
arbiter shows 0 late lines. The real scan-out FIFO depth sets the deadline; P1d replaces it with that figure.

#### Game traces

Real-game load for Gate M (d) comes from GP0/GP1 dumps recorded locally in DuckStation. Dumps, vectors and
traces are game-derived and never committed: outputs go under the gitignored `sim/gpu_diff/run/`.

- **Record** a GPU dump of a few frames in DuckStation (its GPU frame capture; the file is `.psxgpu`, or
  `.psxgpu.zst`/`.psxgpu.xz`). Format `PSXGPUDUMPv1`: DuckStation `src/core/gpu_dump.cpp`, spec ps1dev/standards
  `GPUDUMP.md`.
- **Convert and trace:** `make -C sim/gpu_diff trace-game TRACES="$PWD/a.psxgpu $PWD/b.psxgpu.zst" GAMEARGS="--first-frame 100 --frames 3"`
  (absolute paths: `make -C` changes directory before the paths are read)
  writes `run/game_<name>/vec.txt` and `run/trace_game_<name>.txt` (golden), plus `run/trace_pocket_game_<name>.txt`
  when gpu_pocket is configured. `make bw-game TRACES=...` then runs `bwmodel.py` at 101.6064 MHz (report) and
  `--max-util 0.8` at 135.4752 MHz (report-only unless `GAME_GATE=1`). `gpudump2vec.py --selftest` and
  `make gamevec-selftest` check the converter on a synthetic dump.
- **Conversion:** GP0 is re-split into whole commands (`P`, or `Q` with `--queue`), GP1 becomes `G1`, `0xC0` reads
  become `RD n`, and each VSync becomes `W <tick delta>` in clk1x cycles (about 565,045 per NTSC frame).
- **Limits:**
  - the initial 1 MiB VRAM snapshot is dropped by default (`--vram-init` replays it, but its write burst then
    dominates the peak window), so textures are blank. A blank texel (0x0000) is transparent: textured draws
    write nothing and do no semi-transparent destination reads, so a trace under-reports bandwidth and its
    Gate M (d) figure is a lower bound until the snapshot is replayed with its window kept out of the peak;
  - frames before `--first-frame` keep only state, uploads, fills and copies;
  - GPUREAD data is not in the dump, so reads are replayed but only golden and pocket are compared;
  - commands are serialised unless `--queue`;
  - the layout is checked against the DuckStation source and the spec, not yet against a recorded dump.

## Verification

- `make -C sim/gpu_diff golden` and `selftest`: the harness is sound.
- `make -C sim/gpu_divtest`: both dividers match `divider.vhd` over every use's range.
- `make -C sim/gpu_diff diff`: 0 VRAM, GPUREAD and GPUSTAT data mismatches, 0 span mismatches,
  setup within the criterion above, every coverage counter non-zero.
- `make -C sim/gpu_diff diff SUITES=xfer SEEDS="1 2 3 4 5 6" COUNT=400`: the transfer commands with random sizes,
  overlaps and wraps, and GP1 01 in the middle of an upload or a download (the engine's `drawer_reset` path). The
  transfer commands have no timing difference.
- `make -C sim/gpu_diff video`: one display mode per seed (`VSEEDS`, 16 modes: every width, 240 and 480 lines,
  interlace, NTSC and PAL, 24 bit, display offsets, display range, display off, `videoout_on` low, `pal60`,
  `syncInterlace`, `fixedVBlank`), a painted VRAM, 3 idle frames with mode changes in the middle. `tb_diff` compares
  every video output and the VBLANK IRQ on every clk2x (`VC 1` in the vector file); the run reports `video_mismatches`
  and the number of non-black pixels compared. The other suites do not compare video: with drawing in flight the
  line fetch timing differs between units.

## Measurements

Measured 2026-10-08, bandwidth 2026-10-09. Gate result: **FAIL**, on area and on SDRAM bandwidth at the 101.6 MHz the gate was
written for. The re-plan (ROADMAP Phase 4) accepted it with the SDRAM at 135.4752 MHz, where the
bandwidth gate figure is 91.2% (FAIL against 80%; see Bandwidth). That clock also does not close static
timing on the Pocket's SDRAM read capture (MEMTEST.md), and the bandwidth gate is FAIL at 101.6 MHz
too, so the GPU is re-planned before Phase 5.

| Criterion | Gate | Golden | `gpu_pocket` | |
|---|---|---|---|---|
| ALMs needed (`gpu` / `gpu_pocket` instance) | ≤ 4,500 | 5,481.4 | **4,785.3** | FAIL (+285) |
| DSP | ≤ 10 | 32 | 10 | pass |
| M10K | — | 27 | 27 | |
| Setup vs reference (per triangle) | ≤ max(golden, reference) | — | 4,094 checked, 0 over | pass |
| Worst trace, sliding 1 ms peak with simulated SPU traffic, SDRAM at 135.4752 MHz (the gate figure `make bw` prints) | ≤ 80% | 91.2% | 91.0% | FAIL |
| Same, SDRAM at 101.6064 MHz (report only) | ≤ 80% | 99.9% | 99.9% | FAIL |
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

**Bandwidth** (`make bw SEEDS="1 2 3"`, game-like traces, sliding-window peak over any complete 1 ms
window, the SPU's 48 voice reads per sample interleaved as BL4 bursts, golden / `gpu_pocket`):

| SDRAM clock | seed 1 | seed 2 | seed 3 |
|---|---|---|---|
| 135.4752 MHz (4 × clk1x, gating) | 91.2% / 91.0% | 91.2% / 90.8% | 90.9% / 90.2% |
| 101.6064 MHz (3 × clk1x, report) | 99.9% / 99.9% | 99.9% / 99.9% | 99.9% / 99.9% |

At 135.4752 MHz all six traces are above 80%. The same traces without SPU traffic (`--spu-voices 0`)
peak at 75.4% / 75.1%, 75.9% / 74.7%, 74.0% / 73.4% at 135.4752 MHz and 98.0% / 97.3%, 96.7% / 96.2%,
97.1% / 96.5% at 101.6064 MHz. Mean utilisation at 135.4752 MHz is 57 to 59%. On the same busy
intervals, the peak over aligned, non-overlapping 1 ms windows is 2.0 to 4.8 points lower than the
sliding peak.

Heavier SPU charges, worst trace at 135.4752 MHz: reverb work area in SDRAM (`--spu-reverb sdram`, 2.56 M
reads + 0.18 M writes/s) 95.7%; a RAM transfer in every voice slot (`--spu-dma 24`, 3.18 M reads/s)
98.2%, as writes (`--spu-dma-write`) 97.7%; both 99.1%. With 16 voices in SDRAM (`--spu-voices 16`,
1.41 M reads/s) 86.6%.

How far these figures overstate a game:
- The generator issues primitives back to back with no CPU or GTE time between them, so it draws
  at the GPU's full fill rate for the whole trace. A game interleaves other work.
- The model charges every `sdram_ctl` overhead (see above). Seed 1, golden / `gpu_pocket`,
  no tRCD, tRP, tRAS, tRC or tRRD (`--trcd 0 --trp 0 --tras 0 --trc 0 --trrd 0`): 78.9% / 78.1%
  at 135.4752 MHz, 97.5% / 97.4% at 101.6064 MHz. Every overhead off (also `--twr 0 --trfc 0
  --refresh-us 1e9 --cl -2`, which removes the read-to-write turnaround), data beats and the SPU
  bursts only: 71.1% / 70.7% and 93.7% / 93.1%; without the SPU traffic (`--spu-voices 0`) 64.5% / 64.1%
  and 85.5% / 84.8%. At 101.6064 MHz the FAIL holds even for an ideal controller.
- `bwmodel.py` also prints a peak per scanline (`peak/line`). For an open-loop trace it only shows
  that some line-length window is saturated: it reads 99.9% at either clock and says nothing about
  how long the GPU would stall.

### B6 area v2 (rect, transfer engine, video out)

Fitter "ALMs needed" for `gpu_pocket`. In context is `sizing/psx_pocket_a6_gpu.qsf` (5CSEBA6, whole core); the fitter's noise between
runs is about ±25 ALMs per entity.

| Unit | Before (standalone) | After (standalone) | Saving | After, in context |
|---|---|---|---|---|
| rect (`gpu_rect` / `gpu_rect_pocket`) | 299.7 | 209.6 (rect alone in the tree: 204.8) | 90 to 95 | 216.8 |
| fill + upload + copy + download (4 units / `gpu_copy_pocket`, FIFO included) | 329.4 | 247.0 | 82 | 245.8 |
| video out (`gpu_videoout` + `_sync` / `gpu_videoout_pocket`) | 260.2 | 233.1 | 27 | 199.6 |
| `gpu_pocket` total | 4,785.3 | **4,592.0** | 193 | **4,449.4** (before: 4,620.3) |

DSP 10 of 66 (unchanged). Timing, standalone at clk2x 67.7376 MHz: setup +0.818 ns (slow 85 C), +0.393 ns (slow 0 C), hold +0.281 ns.
In context the sizing revision has no SDC, so its slack is as negative as before (clk2x -11.246 ns against -11.363 ns for
`psx_pocket_a6`): no regression, no verdict.

**Gate (4,000 in context): not met, 4,449.4.** Not done: the rectangle through the polygon unit (would remove the 217 ALMs
of `gpu_rect_pocket` for an estimated 60 to 80 in `gpu_poly_pocket`, but needs a rectangle mode in a copy of that unit, since the
two-triangle route changes the write order), and line-unit width trims (`workx/worky`, `stepDx/Dy`: the 32-bit fractions
are not provably removable).
`psx_pocket_a6.qsf` and `pocket/psx/fpga/ap_core.qsf` list the RTL files and need `gpu_rect_pocket.vhd`, `gpu_copy_pocket.vhd` and
`gpu_videoout_pocket.vhd` added.
