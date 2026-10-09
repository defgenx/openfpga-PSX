# CPU for the Pocket (`rtl/cpu.vhd`)

This document owns the CPU's size work: contract, levers, baseline and results. Project context and
gates: [ROADMAP.md](ROADMAP.md). Reference format: [GPU.md](GPU.md).

## Contract

The golden model is `cpu.vhd` with `divider.vhd` and `datacache.vhd`, frozen. The Pocket CPU must
retire the same instruction stream with the same bus transactions, COP0 behaviour and GTE
interface as the golden with `TURBO`, `TURBO_CACHE` and `TURBO_CACHE50` off and the savestate ports
tied. Kept: the asynchronous tag-RAM read, the clk2x scratchpad port, forwarding and load-use stalls.

Gate: **<= 1,900 ALMs for `cpu:icpu` in the `psx_top_pocket` in-context fit** (`sizing/psx_pocket_a6_cpu.qsf`,
see [ROADMAP.md](ROADMAP.md#phase-4--rewrites-area-and-the-core-gate)). The gate is in context because that
is what has to fit; the standalone `cpu_golden` fit stays a diagnostic.

| | ALMs |
|---|---|
| Standalone floor for a cycle-exact R3000A pipeline | 1,500-1,900 |
| In-context gap measured on the golden (2,674.4 vs 2,291.1) | +383 |
| **In-context range** | **1,900-2,300** |
| **Gate** (bottom of the range) | **<= 1,900** |

The projection uses the range, not the gate.

Sizing wrapper: `sizing/cpu_size_wrap.vhd` (all I/O registered on clk1x, clk1x/clk2x/clk3x),
project `sizing/cpu_size.qpf`, revision `cpu_golden` on 5CEBA4F23C8.

## Levers

Estimates of ALMs saved, written before any fit, from reading the RTL. The standalone golden has
the savestate ports tied, so the savestate lever only exists in the in-context figure.

| Lever | Kind | Est. ALMs saved | Basis |
|---|---|---|---|
| Savestate removal (in context only) | ALM | 1,000 | `ss_in` reload branch on every pipeline register (`cpu.vhd:766-1000`, `:1766-1822`), 60:1 x 32 `ss_out` read mux (`:2780-2800`, `ss_out` drivers `:759-970`, `:1716-1760`), third register-file copy `iregisterfileSS` (20 ALMs, `:578`) and its load loop (`:2743-2775`) |
| COP0 breakpoint registers and logic | ALM | 140 | BPC, BDA, DCIC, BDAM, BPCM registers (`:112-118`, writes `:1929-1932`), read mux entries (`:1472-1478`), PC breakpoint compare `EXEBreakpoint` (`:1100`) and the exception path it feeds (`:1179`, `:2663`); BDA/BDAM are stored but never compared |
| Duplicated pipeline registers | ALM | 100 | four copies of one 32-bit address: `executeReadAddress`, `executeMemWriteAddr`, `writebackReadAddress`, `mem4_address` (`:154-156,161,265,282`); `executeCOP0WriteValue` repeats `executeMemWriteData` (`:154,159`); low-confidence estimate |
| One shared multiplier for MULT/MULTU | DSP | 40 ALMs, 3 DSP | `mulResultS`/`mulResultU` are two 32 x 32 products (`:1836-1837`) on 6 DSP in context; a 33-bit signed product covers both and saves the second product's partial-sum adders |
| Unsigned divider variant | ALM | 20 | `divider:idivider` is 152.5 ALMs in context with 33-bit signed operands (`:2722-2733`, `divider.vhd`); the 33rd bit and sign handling go |
| Data-cache memory removal (not in the plan's list) | M10K | 4 ALMs, 64 M10K | with `TURBO_CACHE = '0'` the hit is dead but `dcache_read_data` still reaches `spad_cache_dataread` (`:2110-2111`), so `idatacache` keeps its 16384 x 32 RAM (64 M10K, 3.7 ALMs in context) |
| **Sum of estimates** | | **1,304 ALMs** | 304 without the in-context savestate lever |

The sum of the listed ALM levers leaves the instance well above the explorer's 1,500-1,700 if the
in-context 3,492 ALMs are right; the standalone fit shows how much of the rest is movable.

## Baseline (Unit 4.0)

Fits on 5CEBA4F23C8, `raetro/quartus:21.1`, `sizing/cpu_size.qpf`. ALMs are the fitter's "ALMs
needed" for the `cpu:icpu` instance (Fitter "Resource Utilization by Entity", reports in
`sizing/output_files_cpu_golden/`, not committed). Clocks: clk1x 29.526 ns, clk2x 14.763 ns,
clk3x 9.842 ns (`sizing/cpu.sdc`, exact multiples so coincident edges keep a full-period setup
relationship).

| | `cpu_golden` | in context (`psx_min_a6`, 5CSEBA6) |
|---|---|---|
| ALMs needed (`cpu:icpu`) | **2,291.1** | 3,492.3 |
| ALMs used in final placement | 2,515.4 | 4,157.3 |
| Map estimate (whole wrapper) | 2,579 | |
| M10K | 76 | 75 |
| DSP | 6 | 6 |
| ALMs used for memory (MLAB) | 200 | 220 |
| Registers | 1,877 | 3,536 |

| Slack, ns | clk1x setup | clk2x setup | clk3x setup | clk1x hold | clk2x hold | clk3x hold |
|---|---|---|---|---|---|---|
| Slow 1100 mV 85 C | +4.552 | +6.985 | +5.506 | +0.310 | +1.023 | +0.775 |
| Slow 1100 mV 0 C | +4.767 | +7.264 | +5.747 | +0.291 | +0.967 | +0.703 |
| Fast 1100 mV 85 C | +10.019 | +10.558 | +7.598 | +0.144 | +0.315 | +0.227 |
| Fast 1100 mV 0 C | +10.437 | +11.076 | +7.864 | +0.130 | +0.256 | +0.166 |

Fmax clk1x, slow 85 C: 40.04 MHz. The first fit used 29.525/14.762/9.842 ns and showed clk3x at
-2.724 ns, a 1 ps setup relationship between clk1x and clk3x (3 x 9.842 = 29.526 > 29.525), not a
real path; ALMs moved by 4.7 between the two fits (2,295.8 then 2,291.1), the timing-driven noise
to expect on any one number.

Hierarchy: `idatacache` holds 64 M10K (524,288 bits) at 1.3 ALMs even with `TURBO_CACHE` tied off;
`itagram` (async tag RAM) 218.2 ALMs; `idivider` 151.6; the three register files 20 ALMs each in
context, two standalone.

The standalone golden (savestate ports tied, so already pruned) is 1,201 ALMs below the in-context
figure. That difference mixes the savestate logic with device and context effects; the in-context
savestate measurement is the figure for that lever.

Sources: `sizing/output_files_cpu_golden/cpu_golden.fit.rpt:1469` (instance row), `:1468`
(wrapper), `:1481-1482` (datacache), `.sta.rpt:132` (Fmax), `.map.rpt:272` (map estimate),
`slack_summary.txt`. In context: `sizing/output_files/psx_min_a6.fit.rpt:5700` in the main
checkout.

### In context: `psx_top_pocket` (savestates removed)

`sizing/psx_pocket_a6.qpf` revision `psx_pocket_a6` on 5CSEBA6U23I7, the device of `psx_min_a6`:
`psx_top_pocket` with `gte_serial`, `gpu_pocket` and every savestate driver tied inactive
(`rtl/psx_top_pocket.vhd`). `cpu:icpu`: **2,674.4** ALMs needed (2,813.6 placed), 75 M10K, 6 DSP
(`sizing/output_files_psx_pocket_a6/psx_pocket_a6.fit.rpt:3755`), against 3,492.3 in `psx_min_a6`.
The savestate lever in context is therefore 817.9 ALMs. The in-context figure stays 383 ALMs above the standalone `cpu_golden`. Measured, not explained: in context
the CPU has 151 more combinational ALUTs (3,276 vs 3,125) and 61 fewer registers (1,816 vs 1,877); the rest
is packing (2,813.6 vs 2,515.4 placed, 195.5 vs 297.0 recoverable by dense packing). The standalone fit is
timing-driven with an SDC and `psx_pocket_a6` has none. The in-context figure is the gate metric; the standalone figure is a diagnostic.
The levers above other than the savestate removal apply to both figures alike; only the savestate lever is
measured in context.
