# SPU for the Pocket (`rtl/spu.vhd`, `spu_ram.vhd`, `spu_gauss.vhd`; Pocket build `spu_pocket*.vhd`)

This document owns the SPU's size work: contract, levers, baseline and results, the Pocket
implementation `spu_pocket` and its differential harness. Project context and
gates: [ROADMAP.md](ROADMAP.md). Reference format: [GPU.md](GPU.md).

## Contract

The golden model is `spu.vhd` with `spu_ram.vhd` and `spu_gauss.vhd`, frozen. The Pocket SPU must
produce the same `sound_out_*`, the same CPU-visible register reads and the same IRQ and DMA
handshakes as the golden with these ties: `useSDRAM = '1'`, `REPRODUCIBLESPUIRQ = '1'`,
`SPUon = '1'`, `SPUIRQTrigger = '0'`, `REPRODUCIBLESPUDMA = '0'` (MiSTer defaults), `REVERBOFF = '1'`
for the gating revision, savestate (`SS_*`, `loading_savestate`, `SS_RAM_*`) and DDR3 (`mem_*`)
ports tied off. Gate for `spu_pocket` (unit B1): <= 1,350 ALMs in context (`sizing/psx_pocket_a6_spu.qsf`), bit-exact,
timing met; the standalone figure (`sizing/spu_pocket.qsf`) is a diagnostic. The earlier baseline gate of the golden
(<= 1,400, explorer estimate 1,400-1,800) is kept below as history. Kept: the reverb registers (CPU-readable), the READ2/PROCIN/END address skeleton that
sets the voice timing, the 64 KB on-chip RAM, the capture buffers.

Sizing wrappers: `sizing/spu_size_wrap.vhd` (golden, all I/O registered on clk1x, generic `G_REVERBOFF`
selects the revision) and `sizing/spu_pocket_size_wrap.vhd` (`spu_pocket`, same registered ports, generics
`G_NO_REVERB`, `G_L1_CACHE`), project `sizing/spu_size.qpf`, revisions `spu_golden` (reverb engine
present), `spu_golden_revoff` (`REVERBOFF = '1'`) and `spu_pocket`, all on 5CEBA4F23C8.

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

### In context: `psx_top_pocket` (savestates removed)

`sizing/psx_pocket_a6.qpf` revision `psx_pocket_a6` on 5CSEBA6U23I7, the device of `psx_min_a6`:
`psx_top_pocket` with `gte_serial`, `gpu_pocket` and every savestate driver tied inactive
(`rtl/psx_top_pocket.vhd`). `spu:ispu`: **3,172.7** ALMs needed (3,529.6 placed), 78 M10K, 13 DSP
(`sizing/output_files_psx_pocket_a6/psx_pocket_a6.fit.rpt:3922`), against 4,028.1 in `psx_min_a6`.
The savestate lever in context is therefore 855.4 ALMs. The standalone `spu_golden` is 93 ALMs above the in-context `psx_top_pocket` figure (different device and packing): the standalone figure is the gate metric.
The levers above other than the savestate removal apply to both figures alike; only the savestate lever is
measured in context.

## `spu_pocket` (unit B1)

Files: `rtl/spu_pocket.vhd` (the SPU), `rtl/spu_pocket_ram.vhd` (SPU RAM port: capture buffers, reverb area, L1 cache),
`rtl/spu_pocket_sdp.vhd` (simple dual-port RAM), `rtl/spu_pocket_fifo.vhd` (transfer FIFOs), `rtl/spu_pocket_gauss.vhd` (the
interpolation table of `spu_gauss`, read in the same rotation). The entity has exactly the ports of `spu` (checked against the
component in `psx_top_pocket.vhd`, which needs no change) and two generics with defaults for the gating configuration.
`G_SPU_IMPL => "pocket"` selects it.

| Generic | Default | Effect | Golden tie in the harness |
|---|---|---|---|
| `NO_REVERB` | true | no reverb arithmetic and no reverb writes; the register file, the READ2/PROCIN/END skeleton (its SPU RAM reads, its clocks) and the CPU-visible reverb registers stay. `REVERBOFF` is ignored. false: the golden engine, `REVERBOFF` as the port | `REVERBOFF = '1'` (`G_NO_REVERB`); false against `REVERBOFF = '0'` and `'1'` |
| `L1_CACHE` | true | the voice read cache (below); the SDRAM request trace changes, the outputs do not | none: runs at fixed one-clock latency, reads not compared (`G_L1`) |

Ties inside the entity: `useSDRAM = '1'`, `SPUon = '1'` and `REPRODUCIBLESPUDMA = '0'` are not read (their ports stay);
`REPRODUCIBLESPUIRQ` and `SPUIRQTrigger` are used as in the golden; `SS_wren`, `SS_rden`, `loading_savestate`, `SS_Adr`,
`SS_DataWrite` and the `SS_RAM_*` inputs are not read, `SS_DataRead`, `SS_RAM_dataRead`, `SS_RAM_done` and every `mem_*` output are
driven 0. `SS_reset` and `SS_idle` are kept (below). `clk2x` and `clk2xIndex` are not used.

### What differs from the golden

Everything below is invisible at the compared ports, or is one of the generics or a listed exception.

- **Savestates:** the image, its read-out and the SS write branch are gone. `SS_reset` still starts the 192-clock clear of the
  voice registers, volumes, envelope counters, voice records, sample RAM and the first 64 words of the global registers.
  `SS_idle` is the golden condition; its timeout counts samples (8,192 samples, about 6.3 M clk1x, against 2^23 clocks).
- **Reset contract:** the CPU-written registers that moved into RAM (below) are zeroed by that clear, not by `reset` (a RAM has
  no reset). The top always sends `SS_reset` before `reset` (`docs/pocket/POCKET_TOP.md`, "Reset sequence"), and the CPU does not
  touch the SPU in the 192 clocks after it; the harness resets only that way. A `reset` without `SS_reset` leaves those
  registers as they were.
- **Registers in RAM** (`global_regs`, 64 words, three copies: the bus copy and two copies the engine reads): TRANSFERADDR,
  TRANSFER_CNT, EXT_VOL, PITCHMODENA, NOISEMODE, and with `NO_REVERB` REVERBON and every reverb register; the flip-flop registers
  the engine reads (volumes, CNT, IRQ_ADDR, CD volumes, mBASE) are mirrored so the bus read has one input. KEYON, KEYOFF, ENDX,
  CURVOL and STAT stay flip-flops.
- **Voice registers, volumes, records and envelope counters** are M10K RAMs read through registered ports. The engine has one
  copy per voice register and per volume word, addressed one clock ahead (the voice the next `VOICE_START` loads); a copy is
  written in the clock of the write, one clock before the golden's registered write, which cancels the registered read, and a
  copy whose word the golden latches into a register at the start of the slot holds its output instead (`adsrSetting`,
  `adsrVolume`, `volLeft`, `volRight`). The bus copies are written from the golden's registered write signals and read on a bus
  read; `bus_dataRead` takes their output while `brd_sel` names them.
- **ADSR:** one phase parameter set (rate, step, ticks, exponential and decrease flags) selected by the phase the state needs,
  instead of five registered sets.
- **Sweep engine:** `env_step` is combinational; the counters are 21 bits (24 in the golden: the largest reload is 2^20).
- **ADPCM:** the decode result is combinational and written to the sample RAMs in its own clock (no write registers); the four
  samples of the interpolation window are kept in RAM-column order and the coefficients are rotated into that order when they are
  loaded (`spu_pocket_gauss`), which removes the sample rotation.
- **Removed or merged registers:** `FifoOut_Cnt`, the second copies of the volumes (`envVolLeft`, `envVolRight`), `sampleIndex`,
  the filter coefficients, `voice_lastVolume` (a clamp of `volume`), the record and counter RAM write registers, the clear of
  `chanLeft/chanRight` at the voice start (they are rewritten before use); `chanLeft`/`chanRight` are combinational.
- **FIFOs:** `spu_pocket_fifo` has no fill counter; its Full, Empty, NearFull and Dout match `SyncFifoFallThrough` clock for clock
  (checked by the full-FIFO runs of the harness).
- **L1 block cache** (`L1_CACHE`): `spu_pocket_ram` keeps, per voice, the tag of one 16-byte block and a valid bit per 16-bit
  word in front of the `sdram_*` port, below the IRQ compare and the `ram_request` / `ram_Adr` timing. A voice read that hits
  returns the word one clock after the request and issues no SDRAM request; a miss is the golden request and fills the word on
  its response. A write to SPU RAM (the transfer) invalidates every line (24 clocks, lookups miss meanwhile); reset invalidates
  too. Capture, reverb and transfer accesses do not use the cache. The hit answers one clock after the request, as the golden
  does at the shortest SDRAM latency, so with a fixed one-clock latency the outputs are cycle-exact; at longer latencies only the
  clock of the events inside a voice slot moves (`bw4s`, `bw1s`: `sound_out` at `spu_tick` equals the golden at latencies of 1 to 8).

### Results

Fits on 5CEBA4F23C8, `raetro/quartus:21.1`, `sizing/spu_size.qpf` revision `spu_pocket` (fitter seed 3; seed 1 leaves 0.061 ns
of hold violation on the gauss table to multiplier path in the fast 0 C corner, seeds 2 and 3 meet), reports in
`sizing/output_files_spu_pocket*/`, not committed. ALMs are "ALMs needed" for `spu_pocket:ispu`.

| | golden `spu_golden` | golden `spu_golden_revoff` | `spu_pocket` NO_REVERB | `spu_pocket` NO_REVERB, no L1 | `spu_pocket` reverb on |
|---|---|---|---|---|---|
| ALMs needed (standalone) | 3,265.9 | 3,079.6 | **1,556.2** | 1,505.2 | 2,555.0 |
| ALMs used in final placement | 3,545.9 | 3,331.4 | 1,628.5 | 1,571.6 | 2,724.4 |
| Map estimate (whole wrapper) | 3,435 | 3,258 | 1,782 | 1,739 | 2,831 |
| ALUT / registers | | | 2,431 / 1,272 | 2,385 / 1,256 | 4,185 / 2,480 |
| M10K / DSP / MLAB ALMs | 75 / 13 / 300 | 75 / 13 / 300 | 93 / 13 / 50 | 92 / 13 / 30 | 93 / 13 / 30 |
| Setup slack clk1x, slow 85 C / slow 0 C, ns | +11.407 | +12.662 | +7.830 / +7.369 | +7.924 / +7.686 | +8.393 / +8.106 |
| Hold slack clk1x, slow 85 C / slow 0 C / fast 85 C / fast 0 C, ns | +0.294 / +0.267 / +0.133 / +0.073 | +0.304 / +0.295 / +0.122 / +0.050 | +0.282 / +0.275 / +0.090 / +0.063 | +0.288 / +0.279 / +0.135 / +0.122 | +0.385 / +0.370 / +0.074 / +0.005 |
| Fmax clk1x, slow 85 C | 55.19 MHz | 59.30 MHz | 46.09 MHz | 46.29 MHz | 47.32 MHz |

The gate (1,350 ALMs) is **not met**: 1,556.2 standalone, 206 above. In context (`psx_pocket_a6_spu`):
**1,680.4** ALMs needed (1,767.4 placed), 93 M10K, 13 DSP, 2,709 ALUT, 1,325 registers (`sizing/output_files_psx_pocket_a6_spu/psx_pocket_a6_spu.fit.rpt:3590`),
124 above the standalone figure and 330 above the gate. The whole top fails timing in that fit (clk1x setup -20.9 ns at slow 100 C, from other blocks, not attributed to the SPU), so the fitter
duplicates registers there; the standalone fit is the timing reference for the SPU. The golden in `psx_pocket_a6` is 3,172.7 (above).

Reverb decision, measured: the reverb engine costs 998.8 ALMs (2,555.0 against 1,556.2) and `REVERBOFF` alone saves 186.3 ALMs
of the golden; `NO_REVERB` is the gating configuration and the default. Reverb-on is bit-exact (REV runs) and builds, but cannot
fit the budget.

Fit noise: 1,557.9 / 1,560.9 / 1,556.2 ALMs for seeds 1 / 2 / 3.

### Where the area is

Map-estimate build-up of the standalone wrapper (ALMs): golden `REVERBOFF = 1` 3,258; no reverb arithmetic and single-phase
ADSR 2,568; global registers, L1 and the record and ADPCM write registers combinational ~2,164; merges 2,134; per-voice
registers, volumes, records and envelope counters in M10K 1,932; bus copies in M10K 1,826; combinational `env_step`, 21-bit ticks,
mirrors of the global registers, own FIFOs, sample-counted timeout, held-q snapshots, rotated gauss table 1,749; shared pipelined
multiplier kept (exact when a reset hits its 4-clock stage) 1,782.

Ablations on that 1,749 baseline (map ALMs removed by deleting the function; each one breaks exactness, measured to see where
the area is): ADSR new-volume path ~190, sweep engine ~210, bus write decode with its dependent registers ~349 (an
overestimate), bus read mux ~110, noise ~96, ADPCM decode ~82, L1 cache ~40 (52.7 in the fit), reverb address chain about 9,
`DIRECT_MUL` 33.

Options not taken, for the lead:
- `DIRECT_MUL` (constant in `spu_pocket.vhd`): the output and CD stages use direct multipliers, about 33 map ALMs less; not
  exact when a reset arrives in the 4-clock stage of the golden's shared multiplier.
- `L1_CACHE = false`: 51 ALMs less, loses the bandwidth reduction below.
- clk2x time-sharing of the ADSR and sweep arithmetic: estimated 70 ALMs, not done.
- Not issuing the 12 SPU RAM reads of the reverb skeleton per sample when the reverb buffer lies outside the internal 64 KB:
  saves only about 9 ALMs but 12 SDRAM reads per sample; not done because the contract keeps the skeleton.

### SDRAM bandwidth

`make -C sim/spu_diff bw`: 400 samples, 24 voices on, SDRAM reads counted per 1 ms window, fixed one-clock latency, L1 on.

| Pitch | golden reads/ms (peak) | `spu_pocket` reads/ms (peak) | change |
|---|---|---|---|
| 4x on all voices | 1,238 (1,530) | 655 (848) | -47 % |
| 1x on all voices | 884 (1,982) | 200 (426) | -77 % |

At random latency 1 to 8 (`bw4s`, `bw1s`) the golden's 1,675 and 1,800 reads/ms become 755 and about 400. Each 16-bit word has
its own valid bit, so at 4x pitch only the block header reads are saved and the data word is read each sample; a write to SPU
RAM invalidates every line, so during a transfer the traffic returns to the golden's.

### Integration for the Pocket shell

- One request outstanding. `sdram_ena` is a one-clock pulse with `sdram_Adr`, `sdram_rnw` and `sdram_dataWrite` (`sdram_be` =
  0011) valid and held until `sdram_done`; `sdram_done` is a one-clock pulse at least one clock after `sdram_ena` with
  `sdram_dataRead(15:0)` the halfword at the byte address (the L1 fill takes it; a done in the clock `sdram_ena` falls still
  returns the data). Latency at most 23 clk1x per voice slot.
- `SS_reset` must precede `reset` (the sequencer of the top does); the RAM clear takes 192 clocks.
- Capture and reverb-area accesses stay on-chip (answered one clock later); only reverb bases below the 64 KB region and voice
  and transfer accesses reach `sdram_*`.
- 93 M10K (golden 75), 13 DSP. `psx_top_pocket` instantiates `spu` without generics, so the defaults (`NO_REVERB`, `L1_CACHE`)
  apply.

## Differential harness (`sim/spu_diff/`)

The golden `spu` (patched copy, see below) and `spu_pocket` run side by side under nvc 1.23 on the same stimulus; every compared
output is checked on every clk1x clock. Each side has its own SPU RAM model on `sdram_*`.

```
make -C sim/spu_diff golden     # the patched golden against a renamed copy of itself (harness check)
make -C sim/spu_diff diff       # golden vs spu_pocket: SEEDS, SCENS, WSEEDS, RSEEDS of COUNT samples each, coverage required
make -C sim/spu_diff diff REV=1 L1=1   # plus the reverb-on build, the L1 cache and the golden REVERBOFF = 1 runs
make -C sim/spu_diff gate       # GATE_SEEDS x GATE_COUNT samples of every suite incl. REV and L1 runs, coverage and minimums required
make -C sim/spu_diff bw         # SDRAM requests per 1 ms window, golden against spu_pocket, 4x and 1x pitch on all 24 voices
make -C sim/spu_diff selftest   # fault injection (see below)
```

**Compared outputs** (every clk1x clock): `sound_out_left`, `sound_out_right`, `bus_dataRead` (from the first bus read on, so the
hold between reads is compared too), `irqOut`, `spu_tick`, `sound_timeout`, `spu_dmaRequest`, `dma_readdata`, `SS_idle`,
`sdram_ena` and, while the golden requests, `sdram_Adr`, `sdram_rnw`, `sdram_be` and (writes) `sdram_dataWrite`, and the seven `mem_*`
outputs (constant 0). Not compared: `SS_DataRead`, `SS_RAM_dataRead`, `SS_RAM_done` (savestate ports, driven 0). Inputs the harness
drives: every port of the entity; `SS_reset` and `reset` as the top's reset sequencer does (`reset`, `SS_reset` for two clocks,
`reset` for 61 clocks), nothing else of the savestate and DDR3 ports.

**Stimulus** (`tb_diff.vhd`, one CPU/DMA process plus models):
- register writes and reads at random cycles with gaps from 0 to 700 clocks: voice registers (volume modes, sweeps, pitch,
  start and repeat addresses in RAM, in the capture buffers and in the reverb area, every ADSR mode), KEYON and KEYOFF, pitch
  modulation, noise, reverb enable, the reverb registers (written and read back), CNT (enable, mute, noise rate, reverb,
  IRQ enable, transfer mode, CD and external audio), IRQ address at the blocks the voices play, main and CD volumes; a
  write immediately followed by a read of the same register;
- ADPCM blocks into SPU RAM through the transfer FIFO by DMA bursts, bursts of 120 to 170 words (FIFO overflow), manual FIFO
  writes (register 0x1A8), and DMA reads back through the output FIFO, with STAT read during the transfer;
- CD audio per `spu_tick` (silence, noise, full scale, a random walk);
- SPU RAM model: 512 KB image of ADPCM-like blocks (shift and filter values inside and outside their legal range, end, repeat and
  start flags), request latency drawn per request between `G_LATMIN` and `G_LATMAX` clk1x (default 1 to 4; the `slow` run
  3 to 12 so that samples overrun and `sound_timeout` fires), one request outstanding;
- `wild`: dense random writes to any register address, `ce` low for 1 to 40 clocks whenever the golden's `SS_idle` is high (the
  top stops `ce` only then), `cpuPaused` random;
- `reset`: power-up sequences in the middle of a run.

**Suites** (`G_SUITE`, `G_SCEN`): `random`; `directed` scenario 0 mixed, 1 many key-ons, 2 transfers (DMA, FIFO, STAT), 3 IRQ
addresses on the voices' blocks and acknowledges, 4 reverb on, 5 writes into blocks being played (coherence of the L1 cache),
6 exponential sweeps and envelopes around their thresholds; `wild`; `reset`; `bw` (all voices on, no register traffic).

**Options of the run**: `G_NO_REVERB` (the DUT generic; the golden is tied `REVERBOFF = G_NO_REVERB`), `G_REVOFF` (`REVERBOFF = 1`
for both sides with the reverb build), `G_L1` (DUT generic `L1_CACHE`; the reads on `sdram_*` are not compared, the writes are,
the latency is fixed at one clock because a cache hit answers in one clock), `G_SAMPLE_ONLY` (only `sound_out` at `spu_tick`; with
`bw` the cache runs against the golden at variable latency).

**Golden patches** (`prep_golden.py`, each pattern asserted to exist once; no synthesised behaviour changes): the `translate_off`
debug output is removed, and `cov_flags`, a vector of 55 conditions over golden internals (ADSR phases and exponential branches, loop
and key events, decode clamps and filters, sweeps, transfers, reverb states, capture, IRQ cases), is added; the testbench counts
it through an external name. The coverage counters are summed over the runs; `--require-coverage` fails a run set in which one is
zero (the reverb-engine states, `timeout` and a few stimulus counters are optional because they need a build or run option).

**Self-test** (`selftest.py`): the golden renamed to `spu_pocket` must pass (base); one inverted clock on each of the 15 compared
outputs must give exactly one mismatch on that output; and 45 single-edit mutants of the renamed golden (filter table, clamps,
interpolation, ADSR and sweep thresholds, loop, key-on and repeat addresses, noise, mute, CD volume, output clamp, transfer step,
IRQ compare and acknowledge, capture data, STAT, bus read value, reverb registers and address, FIFO and timeout limits) must each
fail a run.
