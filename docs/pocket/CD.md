# CD controller for the Pocket (`rtl/cd_top.vhd`, `cd_xa.vhd`, `cd_xa_zigzag.vhd`)

This document owns the CD block's size work: contract, levers, baseline and results. Project
context and gates: [ROADMAP.md](ROADMAP.md). Reference format: [GPU.md](GPU.md).

## Contract

The golden model is `cd_top.vhd` with `cd_xa.vhd` and `cd_xa_zigzag.vhd`, frozen. The Pocket CD
block must return the same register reads, IRQ timing and sector data as the golden with the
savestate ports tied; options as `sizing/psx_min_wrap.vhd` ties them (disc present, no seek test,
default speed). Gate: <= 2,100 ALMs for the instance (explorer estimate 2,300-2,600 without further
cuts). Kept: the 8-sector ring and the rare commands. The amputations NO_XA (~450 ALMs),
FIXED_CD_TIMING (~350) and NO_LIBCRYPT (~250) are counted separately, not as levers here.

Sizing wrapper: `sizing/cd_size_wrap.vhd` (all I/O registered on clk1x), project
`sizing/cd_size.qpf`, revision `cd_golden` on 5CEBA4F23C8.

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
