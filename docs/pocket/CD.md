# CD controller for the Pocket (`rtl/cd_top.vhd`, `cd_xa.vhd`, `cd_xa_zigzag.vhd`; Pocket build `cd_pocket*.vhd`)

This document owns the CD block's size work: contract, levers, baseline and results, the Pocket
implementation `cd_pocket` and its differential harness. Project context and gates:
[ROADMAP.md](ROADMAP.md). Reference format: [GPU.md](GPU.md).

## Contract

The golden model is `cd_top.vhd` with `cd_xa.vhd` and `cd_xa_zigzag.vhd`, frozen. `cd_pocket` has the golden's
entity ports exactly and must return the same outputs on every clk1x clock (bit-exact, cycle-exact), with the
savestate ports tied and the options free: `bus_dataRead`, `irqOut`, `dma_readdata`, `cd_left`, `cd_right`, `cd_hps_req`,
`cd_hps_lba`, `pauseCD`, `Pause_idle_cd`, `fullyIdle`, `cdSlow`, `resetFromCD`, `region_out`, `LBAdisplay`, `error`. Exceptions,
each a generic of `cd_pocket` with a golden tie in the harness: `NO_CD_PEAK` (the CD-DA peak bytes of the report response
are 0). Amputations (not bit-exact, measured but not taken by default): `NO_XA`, `FIXED_CD_TIMING`, `NO_LIBCRYPT`. Gate for
`cd_pocket` (unit B2): <= 1,600 ALMs in context (`sizing/psx_pocket_a6_cd.qsf`); the standalone figure
(`sizing/cd_pocket.qsf`) is a diagnostic. The earlier baseline gate of the golden (<= 2,100 standalone, explorer estimate
2,300-2,600) is kept below as history. Kept in `cd_pocket`: the 8-sector ring and the rare commands.

Sizing wrappers: `sizing/cd_size_wrap.vhd` (golden) and `sim/cd_diff/size/cd_pocket_size_wrap.vhd` (`cd_pocket`, the same
registered ports and option ties), project `sizing/cd_size.qpf`, revisions `cd_golden` and `cd_pocket` on 5CEBA4F23C8.

## Levers

Estimates of ALMs saved, written before any fit, from reading the RTL. The standalone golden has
the savestate ports tied, so the savestate lever only exists in the in-context figure.

| Lever | Kind | Est. ALMs saved | Basis |
|---|---|---|---|
| Savestate removal (in context only) | ALM | 600 | `ss_in` 128 x 32 register file and reload branches (`cd_top.vhd:566-885`, `:1778-1807`, `:2509-2543`, `:3089-3091`, `:3238-3251`), 128:1 `ss_out` mux and sector-buffer windows (`:3275-3290`, `:2418-2420`) |
| Divide/mod chains to counters and compares | ALM | 110 | `lpm_divide` Div0/Div1/Mod0/Mod1 total 165 ALMs in context: `lba / FRAMES_PER_MINUTE` (`:473-480`), seek-time divides (`:2112-2123`), subchannel BCD `frameLeft / 10` and `mod 10` (`:2747-2760`) |
| Response chains into a (command, step) ROM | ALM | 180 | per-command response writes and `cmd_delay` chains in the command state machine (`:900-1750`); low-confidence estimate |
| Shared delay counters | ALM | 70 | `cmd_delay`, `workDelay`, `driveDelay`, `driveDelayNext`, `irqTimeout` (`:100,865-869,1788-1789`), one counter pair if provably exclusive |
| ADPCM FSM sequenced | ALM | 110 | `cd_xa` is 378 ALMs and 2 DSP in context (`cd_xa.vhd:151-660`); serialising the per-sample filter steps shrinks it while XA stays |
| Peak-volume removal | ALM | 50 | `peakvolumeL/R` registers, signed compares (`cd_top.vhd:314-315,2641-2670`) and response bytes (`:1666-1670`) |
| **Sum of estimates** | | **1,120** | 520 without the in-context savestate lever |

## Baseline (Unit 4.0)

Fits on 5CEBA4F23C8, `raetro/quartus:21.1`, `sizing/cd_size.qpf`. ALMs are the fitter's "ALMs
needed" for the `cd_top:icd_top` instance (Fitter "Resource Utilization by Entity", reports in
`sizing/output_files_cd_golden/`, not committed). Clock: clk1x 29.526 ns (`sizing/cd.sdc`).

| | `cd_golden` | in context (`psx_min_a6`, 5CSEBA6) |
|---|---|---|
| ALMs needed (`cd_top:icd_top`) | **2,400.1** | 3,265.0 |
| ALMs used in final placement | 2,669.3 | 3,737.3 |
| Map estimate (whole wrapper) | 2,630 | |
| M10K | 71 | 71 |
| DSP | 6 | 6 |
| ALMs used for memory (MLAB) | 0 | 0 |
| Registers | 2,247 | 3,342 |

| Slack, ns | clk1x setup | clk1x hold |
|---|---|---|
| Slow 1100 mV 85 C | +4.971 | +0.292 |
| Slow 1100 mV 0 C | +4.048 | +0.285 |
| Fast 1100 mV 85 C | +19.396 | +0.129 |
| Fast 1100 mV 0 C | +19.920 | +0.113 |

Fmax clk1x, slow 85 C: 40.72 MHz. Fit noise between two runs of the same revision: 2,395.4 then
2,400.1 ALMs (the first run used 29.525 ns).

Hierarchy: `cd_xa` 384.9 ALMs, 26 M10K, 2 DSP; the four `lpm_divide` instances 155.5 ALMs
(`Div0` 99.2, `Div1` 19.8, `Mod0` 15.0, `Mod1` 21.5; 165 in context, `:1310-1322`); top-level FIFOs 64.7.

The standalone golden (savestate ports tied, so already pruned) is 865 ALMs below the in-context
figure. That difference mixes the savestate logic with device and context effects; the in-context
savestate measurement is the figure for that lever.

Sources: `sizing/output_files_cd_golden/cd_golden.fit.rpt:1271` (instance row), `:1270` (wrapper),
`:1281` (`cd_xa`), `.sta.rpt:130` (Fmax), `.map.rpt:291` (map estimate), `slack_summary.txt`. In
context: `sizing/output_files/psx_min_a6.fit.rpt:5645` in the main checkout.

### In context: `psx_top_pocket` (savestates removed)

`sizing/psx_pocket_a6.qpf` revision `psx_pocket_a6` on 5CSEBA6U23I7, the device of `psx_min_a6`:
`psx_top_pocket` with `gte_serial`, `gpu_pocket` and every savestate driver tied inactive
(`rtl/psx_top_pocket.vhd`). `cd_top:icd_top`: **2,632.0** ALMs needed (2,817.8 placed), 71 M10K, 6 DSP
(`sizing/output_files_psx_pocket_a6/psx_pocket_a6.fit.rpt:3700`), against 3,265.0 in `psx_min_a6`.
The savestate lever in context is therefore 633.0 ALMs. The in-context figure stays 232 ALMs above the standalone `cd_golden`; the standalone figure is the gate metric.
The levers above other than the savestate removal apply to both figures alike; only the savestate lever is
measured in context.

## `cd_pocket` (unit B2)

Files: `rtl/cd_pocket.vhd` (controller), `rtl/cd_pocket_xa.vhd` (ADPCM decoder, resampler, CD-DA path), `rtl/cd_pocket_fifo.vhd`
(FIFOs). The entity has exactly the ports of `cd_top` (checked against the component in `psx_top_pocket.vhd`, which needs no
change) and four generics with defaults that keep the golden behaviour. `G_CD_IMPL => "pocket"` selects it. The golden's
`cd_xa_zigzag` (a ROM) is reused.

| Generic | Default | Effect | Golden tie in the harness |
|---|---|---|---|
| `NO_XA` | false | no ADPCM decode and resampling; XA audio sectors are dropped, CD-DA stays | none (smoke run only) |
| `FIXED_CD_TIMING` | false | every seek lasts 14 sector times, Pause always waits its minimum time, 10 sectors per track | none (smoke run only) |
| `NO_LIBCRYPT` | false | the libcrypt sectors always read their subchannel | libcrypt key forced to 0 |
| `NO_CD_PEAK` | false | the CD-DA peak bytes of the report response are 0 | both peak registers forced to 0 |

### What differs from the golden

Everything below is invisible at the compared ports, or is one of the generics.

- **Savestates:** the image, its read-out and the timeout terms are gone; the reset values are written in the reset branches. The reset
  sequence is kept: `SS_reset` sets one flop that makes the first reset after it start the motor. `SS_idle` is "no sector transfer,
  processing or copy in flight" (the golden also waits for empty FIFOs and its timeout); `Pause_idle_cd` is constant 1.
- **Divides:** `lba / 4500` becomes a table by 4096-sector bucket (value below and above the one boundary in the bucket); the BCD of the
  frame count is a table. `(offset + 1) mod sectors-per-track` stays a `lpm_divide`.
- **Long responses** (GetParam, GetLocL, GetLocP, GetTN, GetTD, test; GetID) are one block that selects the byte by command and step,
  with the bytes of GetLocL and GetLocP taken from eight-entry vectors, instead of a chain of 45 prioritised writes.
- **Registers narrowed or re-encoded:** error and reason bytes as codes, `driveDelayNext` as a speed code, `sectorBufferSizes` as two
  bits per ring slot, `procSize` and `copySize` as a flag, `session` as one bit, `workCommand` as two flags, `fastForwardRate` in
  steps of 4, `seekLBA` combinational (the Setloc registers change at least 14,998 clocks before a use), the seek distance computed
  once for the Setloc and the Play target, the sector-per-track product registered as in the golden (a combinational product was larger).
- **One pipeline stage removed:** the HPS-to-sector-buffer write happens in the clock the second half word arrives (the golden
  registers address, data and write enable first). The sector processing reads word k at least 14 clocks before the HPS can
  overwrite it, so one clock earlier is not visible. The same change on the ring-slot write measured 2 ALMs and was not kept: there
  the reader (the data copy) is only 6 clocks behind the writer.
- **XA:** the FIFOs are `cd_pocket_fifo`; `clamped` and the two ring input registers are the same value as a combinational
  or already registered signal; the resampler's two ring RAMs carry `ramstyle = "no_rw_check"` (they are read and written in
  different states), which removes the bypass logic Quartus otherwise adds.
- **FIFOs:** `cd_pocket_fifo` has no fill counter (level = write pointer - read pointer); its equivalence with the library
  FIFOs is `make fifo` (sizes 4096x8, 32x8, 1024x32 fall-through; 4096x16 plain).

### Result (2026-10-16)

Bit-exact: 0 mismatches over every suite of `make diff` (random, directed 0-4, real-time 0-22, reset) and the generic-tie runs.
Self-test: base and the 15 output faults pass; all 30 mutants fail a run. Real-time scenario 8 (single-speed ReadN, then Pause)
ends in a seek error before any sector, so the Pause-during-read target is covered by scenario 22 (the same at double speed).
The `make gate` run (16 × 65,000 commands) has not been run.
**Area gate not met.** Fitter, ALMs needed, default generics:

| Fit | `cd_pocket` | golden `cd_top` | Saved |
|---|---|---|---|
| In context (`psx_pocket_a6_cd`, 5CSEBA6, `psx_top_pocket` 18,726.5) | **2,207.2** (71 M10K, 6 DSP) | 2,521.3 (`psx_pocket_a6`, 19,191.0) | 314 |
| Standalone (`cd_pocket`, 5CEBA4) | 2,173.3 | 2,400.1 (`cd_golden`) | 227 |

The gate is 1,600 in context, 607 below. The table below prices what is left: XA alone is 431 and is the amputation `NO_XA`,
which needs the human's approval; the remaining functions are each under 220.

### Where the area is

Removal experiments, Quartus map estimate of the whole sizing wrapper (the wrapper's registered ports account for about 143 ALMs;
the fitter's figure for the instance is about 3.5% under the estimate minus the wrapper). Each row removes one function from the
savestate-free copy of the golden (2,634 estimated, 2,403.5 fitted) or from `cd_pocket` where stated, and keeps the design
synthesisable; so a row is the cost of the function including the registers only it reads.

| Function | ALMs |
|---|---|
| XA (ADPCM decode, resampling, their FIFOs) | 431 |
| Long responses with the registers only they read (golden chains of 45 writes) | 262 (golden) / 174 (`cd_pocket`) |
| Subchannel path (position search, nextSubdata, subdata, GetLocP, CD-DA report) | 216 |
| Divides (`lpm_divide` Div0, Div1, Mod0, Mod1 in the golden) | 145 |
| Seek time (distance classes, product, cap) | 136 |
| Physical position update | 127 |
| Volume mixer | 49 |
| Libcrypt compare chain (32 constants) | 34 |
| CD-DA peak | 15 |

The libcrypt compare is 34 ALMs, not the ~250 of the estimate: a scan over a 16-entry ROM during the 16-clock fetch delay measured +9 ALMs
(its ROM multiplexer costs as much as the comparators), so the golden structure stays.

## Differential harness (`sim/cd_diff/`)

The golden `cd_top` (patched copy, see below) and `cd_pocket` run side by side under nvc 1.23 on the same stimulus. Every compared output is
checked on every clk1x clock.

```
make -C sim/cd_diff golden     # the patched golden against a renamed copy of itself (harness check)
make -C sim/cd_diff diff       # golden vs cd_pocket: SEEDS x COUNT random commands, directed and real-time suites
make -C sim/cd_diff gate       # GATE_SEEDS x GATE_COUNT random commands, all suites, coverage required
make -C sim/cd_diff selftest   # fault injection (see below)
make -C sim/cd_diff fifo       # cd_pocket_fifo against the library FIFOs
```

**Compared outputs** (15 per clock): `bus_dataRead`, `irqOut`, `dma_readdata`, `cd_left`, `cd_right`, `cd_hps_req`, `cd_hps_lba`,
`pauseCD`, `Pause_idle_cd`, `fullyIdle`, `cdSlow`, `resetFromCD`, `region_out`, `LBAdisplay`, `error`. Not compared: `cd_hps_lba_sim`
(simulation-only), `SS_DataRead`. `SS_idle` is checked as a safety property only: `cd_pocket` may report idle early (it drops the FIFO
and timeout terms), never while a request to the HPS is pending (`idle_viol`). A metavalue on a golden output after the first disc load
fails the run (`gold_meta`).

**Stimulus** (`tb_diff.vhd`, one CPU process plus models):
- a CPU that writes commands with parameters (right and wrong counts, junk), services interrupts (flags, response bytes, acknowledge,
  slow or very slow), requests data and reads it by bus or DMA bursts, and performs chaos accesses on every index and address;
- an HPS model: request latency, ack, 588 words at random gaps, a request that is withdrawn; the sector contents are generated per LBA
  from the disc model (`cd_diff_pkg.vhd`): data sectors of mode 0, 1 and 2, XA audio of files 1 and 2 and channels 0 to 2 or FF, EOF,
  CD-DA of different amplitudes; pregap sectors read as zeros;
- a track table loader (1 to 31 tracks, data, audio and mixed discs, libcrypt key, region, reset-from-CD bit, word orders), disc changes;
- `ce` stalls, `spu_tick`, resets sequenced as the top does (`reset_in`, `SS_reset` for two clocks, `reset_intern` for 61 clocks), the
  options `INSTANTSEEK`, `FORCECDSPEED`, `LIMITREADSPEED`, `fastCD`, `hasCD`, `LIDopen`, `testSeek`, `pauseOnCDSlow`, `region`,
  `mdec_idle`.

**Suites** (`G_SUITE`): `random` (G_COUNT commands per seed; episode mix: single commands, read streams, CD-DA play with fast
forward, chaos, seeks, disc changes, power commands, libcrypt, resets, option changes), `directed` (scenario 0: every command
code x with and without a disc x eight drive states x parameter variants; 1: every register at every index with edge values, the
parameter FIFO, commands behind pending interrupts, the end of the pregap; 2: every `FORCECDSPEED`, `INSTANTSEEK`, `fastCD`;
3: XA with and without filter, CD-DA with loud volumes; 4: the 32 libcrypt sectors, one pair per run, probed with GetLocP right
after the sector event), `realtime` (scenario s: one command or sequence at the real delays, no compression), `reset`.

**Time compression** (`G_SKIP`): at a falling clock edge the testbench forces the golden's long counters through VHDL-2008 external
names and releases them after the next rising edge, so the counter reads the clamp at that edge and runs on from there. The
`cd_pocket` counters of the same name and meaning are forced to the same value: `cmd_delay`, `workDelay`, `driveDelay`, `slow_timeout`,
`newCDCounter` (clamped down to a random K per episode, K from a few clocks to 8,400) and `irqTimeout` (advanced to 10,000 - K). No
port is added: the skip is a force on signals of the architecture, which a synthesis run never sees. These signals keep their names,
widths and meaning in `cd_pocket` (the harness contract). The `realtime` suite runs the delay tables uncompressed.

**Golden patches** (`prep_golden.py`, each pattern asserted to exist once, behaviour of the synthesised design unchanged): the
translate_off debug output, the simulation-only `sectorBuffers` and `cd_hps_lba_sim`, the savestate read-out assignments (slow in
simulation, never read), `positionInIndex` gets an initial value, and the simulation-only override of the pregap is removed
(the harness compares against the synthesised behaviour: track 1 data sectors carry the 150-sector pregap). Range errors that are a
wrap in the 19-bit and 5-bit registers are written as the wrap: `seekLBA`, `readLBA`, `playLBA`, `subchannelSector` (mod 2^19),
`phy_oldOffset` (mod 32). `cd_pocket` carries the same wraps.

**Self-test** (`selftest.py`): the golden renamed to `cd_pocket` must pass; one inverted clock on each of the 15 compared outputs must give
exactly one mismatch on that output; and about 30 single-edit mutants of the renamed golden (a delay constant, a response byte, a
libcrypt sector, an XA filter compare, the volume mixer, the seek table, ...) must each fail a run.
