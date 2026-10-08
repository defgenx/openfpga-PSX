# SPU for the Pocket (`rtl/spu.vhd`, `spu_ram.vhd`, `spu_gauss.vhd`)

This document owns the SPU's size work: contract, levers, baseline and results. Project context and
gates: [ROADMAP.md](ROADMAP.md). Reference format: [GPU.md](GPU.md).

## Contract

The golden model is `spu.vhd` with `spu_ram.vhd` and `spu_gauss.vhd`, frozen. The Pocket SPU must
produce the same `sound_out_*`, the same CPU-visible register reads and the same IRQ and DMA
handshakes as the golden with these ties: `useSDRAM = '1'`, `REPRODUCIBLESPUIRQ = '1'`,
`SPUon = '1'`, `SPUIRQTrigger = '0'`, `REPRODUCIBLESPUDMA = '0'` (MiSTer defaults), `REVERBOFF = '1'`
for the gating revision, savestate (`SS_*`, `loading_savestate`, `SS_RAM_*`) and DDR3 (`mem_*`)
ports tied off. Gate: <= 1,400 ALMs for the instance (explorer estimate of the final size
1,400-1,800). Kept: the reverb registers (CPU-readable), the READ2/PROCIN/END address skeleton that
sets the voice timing, the 64 KB on-chip RAM, the capture buffers.

Sizing wrapper: `sizing/spu_size_wrap.vhd` (all I/O registered on clk1x, generic `G_REVERBOFF`
selects the revision), project `sizing/spu_size.qpf`, revisions `spu_golden` (reverb engine
present) and `spu_golden_revoff` (`REVERBOFF = '1'`), both on 5CEBA4F23C8.

## Levers

Estimates of ALMs saved, written before any fit, from reading the RTL. "Basis" is the logic the
lever removes. The standalone golden has the savestate ports tied, so its savestate logic is already
pruned; that lever only exists in the in-context figure.

| Lever | Kind | Est. ALMs saved | Basis |
|---|---|---|---|
| Savestate removal (in context only) | ALM | 600 | `ss_out` 64 x 32 (`spu.vhd:501-503`, `:726-785`), SS write decode (`:972-1064`) and clear loop (`:836-870`), 64:1 + RAM-window read mux (`:2554-2593`), SS address terms on four RAM read ports (`:617,651,678,718`), SS_RAM pass-through (`:2416-2422`) |
| Reverb engine removal | ALM | 1,000 | READ1/PROCOUT/WRITE1/READ2/PROCIN/WRITE2 arithmetic and the soundmul input muxes (`:1960-2260`), address chain (`:2452-2475`), ~500 flops (read values, IIR, comb accumulators, 5-tap low-pass delay line `:1940-1957`). `REVERBOFF` removes only part of it: READ2/PROCIN stay reachable because `REVERB_END` loads `reverbLast*` into the shared multiplier (`:2237-2246`), so the `REVERBOFF` tie is expected to remove about 450 of the 1,000 |
| CPU-only global registers into one MLAB | ALM | 350 | ~45 16-bit registers with reset, write decode and a 16-bit read mux (`:1107-1210`, `:1213-1290`); about 11 stay in flops because the reverb skeleton reads them combinationally (`:2452-2475`) |
| Single-phase ADSR | ALM | 220 | per-phase `adsr_ticks/step/target/rate` for 4 live phases recomputed every cycle with a 16-bit barrel shift and a 24-bit `1 sll n` (`:1415-1455`, `:2428-2447`); only the current phase's set is needed in `VOICE_APPLYADSR` (`:1720-1790`) |
| Per-voice state in RAM, one shared datapath | ALM | 80 | voice registers, volumes, envelope counters and voice records are already MLAB (`:596-720`); what remains in flops is the working `voice` record, `adpcmSamples` and the decode filter (`:301-376`) |
| DDR3 path removal | ALM | 0 | `useSDRAM = '1'` already prunes the `useSDRAM = '0'` state machine, the cache RAM and every `mem_*` output in both golden and in-context builds (`spu_ram.vhd:148-330`) |
| **Sum of estimates** | | **2,250** | 1,650 without the in-context savestate lever; 650 without savestate and reverb |

## Baseline (Unit 4.0)

Fits on 5CEBA4F23C8, `raetro/quartus:21.1`, `sizing/spu_size.qpf`. ALMs are the fitter's "ALMs
needed" for the `spu:ispu` instance (Fitter "Resource Utilization by Entity", reports in
`sizing/output_files_<rev>/`, not committed). Clocks: clk1x 29.526 ns, clk2x 14.763 ns
(`sizing/spu.sdc`). With `useSDRAM = '1'` no register is clocked by clk2x, so it has no paths.

| | `spu_golden` | `spu_golden_revoff` | in context (`psx_min_a6`, 5CSEBA6) |
|---|---|---|---|
| ALMs needed (`spu:ispu`) | **3,265.9** | **3,079.6** | 4,028.1 |
| ALMs used in final placement | 3,545.9 | 3,331.4 | 4,334.9 |
| Map estimate (whole wrapper) | 3,435 | 3,258 | |
| M10K | 75 | 75 | 78 |
| DSP | 13 | 13 | 13 |
| ALMs used for memory (MLAB) | 300 | 300 | 360 |
| Registers | 3,198 | 3,135 | 3,485 |
| Setup slack clk1x, slow 1100 mV 85 C | +11.407 ns | +12.662 ns | |
| Fmax clk1x, slow 85 C | 55.19 MHz | 59.30 MHz | |
| Hold slack clk1x, slow 85 C / slow 0 C / fast 85 C / fast 0 C | +0.294 / +0.267 / +0.133 / +0.073 | +0.304 / +0.295 / +0.122 / +0.050 | |

Reverb-off saving (`spu_golden` - `spu_golden_revoff`): **186.3 ALMs**. `REVERBOFF` alone removes
little because the READ2/PROCIN arithmetic stays reachable (see the reverb lever above); the
full-engine estimate of 1,000 ALMs is therefore unconfirmed and should be re-measured on an RTL
that drops the engine and keeps the skeleton.

The standalone golden (savestate ports tied, so already pruned) is 762 ALMs below the in-context
figure. That difference mixes the savestate logic with device and context effects; the in-context
savestate measurement is the figure for that lever.

Sources: `sizing/output_files_spu_golden/spu_golden.fit.rpt:1476` (instance row, A/B/C and MLAB
columns), `:1475` (wrapper), `.sta.rpt:131` (Fmax), `.map.rpt:297` (map estimate),
`slack_summary.txt` (per-corner slack); `spu_golden_revoff` the same files at `:1494`, `:1493`,
`.sta.rpt:131`, `.map.rpt:298`. In context: `sizing/output_files/psx_min_a6.fit.rpt:5875` in the
main checkout.
