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

Each phase is one clash Workflow item (project `PSX_MiSTer`), created when the previous gate
passes. Phase 3 needs only a Pocket, so it can run in parallel with phases 1–2.

### Phase 1 — GTE gate (`pocket-gte-gate`)

Rewrite the GTE (`rtl/gte.vhd`) as `rtl/gte_serial.vhd`: one 32×18 MAC time-multiplexed at
4× clk1x (135.4752 MHz), a microcoded sequencer, and the COP2 register file in RAM.
The current GTE is the golden model: the two run side by side in nvc on the same command streams.

**Gate:** bit-exact on every register and FLAG · per-command busy cycles equal to the current GTE's ·
≤ 3,000 ALMs · ≤ 4 DSP · timing met at its clocks on 5CEBA4F23C8 (slow 85 °C corner).
Projection: 4,200 → 2,700 ALMs.

### Phase 2 — GPU gate

Serialize `gpu_poly`'s per-scanline multiplies (29 DSP → ≤ 8) and go from 6 dividers to 2.
Measure triangle setup cycles against the current GPU, using command traces from games run in
`sim/gpu`. Build a VRAM-on-SDRAM bandwidth model from the same traces: 16-bit at 101.6 MHz,
including row misses, refresh and video scan-out.

**Gate:** GPU (raster + video out) ≤ 4,500 ALMs · ≤ 10 DSP · worst trace ≤ 80% of SDRAM bandwidth ·
setup no slower than real hardware. Projection: 6,060 → 4,000–4,900.

### Phase 3 — Pocket memory test core (hardware, parallel)

A small Pocket core with no PSX logic. It exercises the memory plan on the real device:
- SDRAM driven with a VRAM-like pattern (64-bit bursts, scan-out deadline).
- Both PSRAMs ganged as one 32-bit main RAM, async page mode and, if it works, synchronous burst
  (`cram*_clk`/`adv_n`/`wait`).
- SRAM used as a byte-wide store.

It reports measured MB/s and latency on screen.

**Gate:** SDRAM sustains the Phase 2 worst trace · ganged PSRAM ≤ 180 ns per random 32-bit read
(original console: ~177 ns) · DMA path ≥ 100 MB/s, or a measured slowdown judged acceptable.

### Phase 4 — Strip the rest

Remove everything the minimal core does not ship, one block at a time, re-synthesizing after each:
- Savestates everywhere, replaced by a small reset/pause sequencer (`savestates.vhd` owns both today).
- CPU: turbo data cache, COP0 debug, merge the two multipliers.
- SPU: reverb engine, savestate, single-phase ADSR, time-sliced multipliers.
- CD: 8→2 sector ring, smaller XA FIFOs, rare commands.
- DMA: debug and turbo paths.
- Peripherals: one digital/analog pad per port, no multitap/guns/mouse/SNAC.
- One lightweight 128 KB memory card (byte responder, SRAM-backed).

**Gate:** `psx_top` ≤ 13,550 ALMs. If it lands between 13,550 and 15,000, pick from the
amputation list in FEASIBILITY.md (MDEC, XA, CD timing model, analog, libcrypt). The game cost
is written next to each one. Above 15,000: stop.

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
