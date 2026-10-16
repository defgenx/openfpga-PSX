# Pocket top level (`rtl/psx_top_pocket.vhd`)

`psx_top_pocket` instantiates the core's blocks and owns reset, pause and idle sequencing. This
document owns the init/idle contract every `*_pocket` block must keep, and the per-block
implementation generics. Project context: [ROADMAP.md](ROADMAP.md).

## Per-block implementation generics

Each block instance sits in an `if G_<BLK>_IMPL = "..." generate` pair: `"golden"` instantiates the
golden entity (`entity work.<blk>`), `"pocket"` instantiates the `*_pocket` entity through a component
declared inside the untaken branch. The `*_pocket` entities need not exist for the default build:
neither Quartus nor nvc elaborates the untaken branch. Values are exact lowercase strings; any other
value fails elaboration (an assertion at the top of the architecture).

The generics are set per Quartus revision with `set_parameter -name <G_..> <value>`; they reach the top
through the same-named generics of `sizing/psx_pocket_wrap.vhd`. Strings were chosen over booleans because
GPU needs two named implementations and a block can later add a third value without touching the wrapper.

| Block | Generic (default) | Golden entity -> pocket entity | Instance (top line) | Revision |
|---|---|---|---|---|
| SPU | `G_SPU_IMPL` ("golden") | `spu` -> `spu_pocket` / `spu_none` | `ispu`, 2459 | `psx_pocket_a6_spu` |
| CD | `G_CD_IMPL` ("golden") | `cd_top` -> `cd_pocket` / `cd_none` | `icd_top`, 1761 | `psx_pocket_a6_cd` |
| CPU | `G_CPU_IMPL` ("golden") | `cpu` -> `cpu_pocket` | `icpu`, 3285 | `psx_pocket_a6_cpu` |
| DMA | `G_DMA_IMPL` ("golden") | `dma` -> `dma_pocket` | `idma`, 1445 | `psx_pocket_a6_dma` |
| Bus | `G_BUS_IMPL` ("golden") | `memorymux` -> `memorymux_pocket` | `imemorymux`, 2844 | `psx_pocket_a6_bus` |
| Joypad | `G_JOYPAD_IMPL` ("golden") | `joypad` -> `joypad_pocket` | `ijoypad`, 1067 | set in the bus revision |
| Memcard | `G_MEMCARD_IMPL` ("golden") | `memcard` -> `memcard_pocket` | `imemcard1`, 3555; `imemcard2`, 3675 | set in the bus revision |
| MDEC | `G_MDEC_IMPL` ("golden") | `mdec` -> `mdec_pocket` | `imdec`, 2350 (inside `NO_MDEC` generate) | `psx_pocket_a6_mdec` |
| GPU | `G_GPU_IMPL` ("pocket") | `gpu_pocket` (default) / `gpu` | `igpu`, 2065 | `psx_pocket_a6_gpu` (golden `gpu`) |

- The CPU, SPU, CD, DMA, memorymux, joypad, memcard, MDEC and GPU are all instantiated directly in
  `psx_top_pocket.vhd`; none is nested elsewhere. `memcard` is a separate instance from `joypad`
  (two instances, one generic). `gte_serial` (`igte`, 3509) is not switchable.
- The `*_pocket` entity must have the golden's exact port list (the component declaration in the
  top is the golden's ports); port or generic changes belong in the golden-compatible entity, not in the top.
- `G_SPU_IMPL` and `G_CD_IMPL` also accept `"none"` (`rtl/spu_none.vhd`, `rtl/cd_none.vhd`, instantiated through a
  component like `*_pocket`; golden port lists, so `gen_ports` outputs do not change; a `"none"` revision adds the files
  to its source list). It ties off
  IRQ, sound, memory and savestate outputs and reports idle. `spu_none` keeps behaviours the BIOS polls: every SPU
  register reads back the last value written, SPUSTAT (0x1AE) reads SPUCNT(5:0) with all other bits 0,
  `spu_dmaRequest` = SPUCNT bit 5 (DMA4 finishes: writes dropped, reads 0) and `spu_tick` keeps its 768-clk1x
  period for the CD. `cd_none` reads 0x18 | index at 0x1800 (parameter FIFO empty and not full, response and data
  FIFOs empty, not busy), 0xE0 at 0x1803 and 0 elsewhere; no command ever completes and no IRQ is raised.
  Smoke and unit tests: `sim/none_smoke/run.sh`.
- `NO_MDEC` (wrapper `G_NO_MDEC`) is orthogonal: when true neither MDEC branch is elaborated.
- `psx_pocket_a6_<blk>.qsf` does `source psx_pocket_a6.qsf`, then overrides
  `PROJECT_OUTPUT_DIRECTORY` and sets its generic. Each block unit adds its `*_pocket` source lines
  in its own revision (the commented placeholder) and edits nothing else. **Block units never edit
  `psx_top_pocket.vhd` or `psx_pocket_wrap.vhd`.** Until the block's file exists, its revision fails
  analysis with the missing `*_pocket` entity; the default revision is unaffected.
- The "Shell skeleton" section is below; "CD loader" and "Memory map and boot" sections are added by later units.

## Reset sequence

`reset_in <= reset or reset_exe` (top 708-711). The sequencer (top 3546-3577) runs on clk1x:

| Phase | `reset_intern` | `SS_reset` | Length |
|---|---|---|---|
| `reset_in` high | 1 | 0 | while held |
| `reset_in` falls (first cycle) | 0 | 1 | 1 clk1x |
| `rst_cnt` = 0 | 0 | 1 | 1 clk1x (so `SS_reset` is 2 clk1x in total) |
| `rst_cnt` 1..62 | 1 from `rst_cnt` 2 | 0 | `reset_intern` high 61 clk1x |
| `rst_cnt` = 62 | 0 | 0 | released |

`SS_reset` never overlaps `reset_intern`. This mirrors the golden `savestates.vhd` on `reset_in`
falling.

The two-step protocol every block follows:

1. **`SS_reset = '1'` loads power-on defaults into the block's savestate input image** (`ss_in`
   registers, or the block's own state-defaults) and starts any RAM-clear that needs clocks.
2. **`reset = '1'` (`reset_intern`) applies them**: the golden reset branches load their state from
   that image (CD: the image is `cd_top.vhd:3235-3249`, the reset branch reading it starts at `:1783`).

A `*_pocket` block that drops savestates must still reach the same post-reset state: either keep the
`SS_reset` load and the `reset` consumption, or fold the defaults directly into its `reset` branch. If
the defaults live only in the `reset` branch, it still must hold them for 61 cycles. A clear that needs
clocks started by `SS_reset` must finish before the block's first use after reset, not within the 61
`reset_intern` cycles: the golden SPU's voice-register clear (`spu.vhd:837-848`) runs 192 clk1x cycles and
continues after `reset_intern` releases; the CPU register file needs 32.

Other blocks that ignore `SS_reset` and clear on `reset` alone: `dma`, `memorymux`, `timer`, `sio`,
`gte_serial` declare the port but do not use it (`dma.vhd:84`, `memorymux.vhd:154`).

## Idle and pause contract

The top's pause FSM (top 774-831) pauses `ce` only when the blocks are quiescent:

- `SS_idle` (top 765) = AND of `SS_Idle_{gpu,mdec,cd,spu,pad,irq,cpu,gte,dma}`. It gates a user, savestate
  or memcard pause (`pause`, `savestate_pause`, `memcard*_pause`; top 810-814): `ce` stops only
  when `SS_idle = 1`, `cpuPaused = 0`, `dmaRequest = 0`, `canDMA = 1` (`memMuxIdle`) and `stallNext = 0`.
- `Pause_Idle` (top 767) is the same AND with `Pause_idle_cd` in place of `SS_Idle_cd`. It gates the
  CD slow-data pause (`pauseCD = 1`, top 806-809).
- `pauseCD` (CD -> top) asks the top to stop `ce` while the CD is waiting for sector data from the
  host. It is a request, not a level that must hold: the top stays paused while it is 1
  (`pauseCD = '0'` is required to unpause, top 789).
- A block's idle output means "my state is fully described by my registers/RAMs, nothing in flight":
  pausing `ce` (freezing the block) while idle must not lose a transaction.
- An idle output that sticks at 0 hangs a pause forever, so the golden SPU, CD and MDEC fall back to
  a timeout (`ss_timeout(23)`, about 8.4 M clk1x) and force idle high. A `*_pocket` block may do the
  same, but its normal idle condition must be reachable within a few thousand cycles.
- `isIdle` of `memorymux` is `canDMA` for the DMA/CPU switch (`memorymux.vhd:311`); it is not
  part of `SS_idle`.

The Pocket top ties `savestate_pause` to 0 (top 3530) and `pause` is the Pocket's own pause
command, so in practice `SS_idle` and `Pause_Idle` gate the user pause and the CD pause only.

### Per-block table

`reset` is `reset_intern` for every block (instance port maps in the top).

| Block | Reset inputs | State initialised | Idle / pause outputs it must drive |
|---|---|---|---|
| `cpu` (`cpu.vhd`) | `SS_reset` (2745), `reset` | `SS_reset` sets `ss_in` to zero except PC `0xBFC00000` and cop0 PRID `2` then clears the 32 GPRs over 32 cycles (`ss_regs_loading`, 2745-2770) | `SS_idle` (2777-2780): no GTE/hi-lo wait, no blocked/pending IRQ, no late read/write in flight |
| `spu` (`spu.vhd`) | `SS_reset` (837), `reset` | `SS_reset` runs a 192-step loop clearing the voice RAM, voice volumes, envelope counters and record RAM (838-868); the sample RAM (`spuram_*`, external) is not cleared | `SS_idle` (2558-2565): FIFOs empty (or timeout), `state = IDLE`, between samples |
| `cd_top` (`cd_top.vhd`) | `SS_reset` (3235, 1776), `reset` | `SS_reset` zeroes `ss_in` with CD defaults (3235-3249) and sets `startMotorReset` (1776-1780); the `reset` branch applies the image | `SS_idle` (3260-3265), `Pause_idle_cd` (3269), `pauseCD` (2476-2481). Golden `Pause_idle_cd` is set to 1 every clock; `pauseCD` = `pauseOnCDSlow` and sector fetch pending and `driveDelay < 32768` |
| `dma` (`dma.vhd`) | `reset` only (`SS_reset` unused, 84) | all state cleared by `reset` | `SS_idle` (1001-1004): `dmaOn = 0` and `dmaRequest = 0` |
| `memorymux` (`memorymux.vhd`) | `reset` only (`SS_reset` unused, 154) | all state cleared by `reset` | `isIdle` (311): `state = IDLE`, no RAM read/write/FIFO write pending; feeds `canDMA` |
| `joypad` (`joypad.vhd`) | `SS_reset` (618), `reset` | `SS_reset` zeroes the 8-word image (618-623); `reset` applies it | `SS_idle` (628-631): not transmitting/waiting for ACK, no pad active |
| `memcard` (`memcard.vhd`) | `reset` | card state cleared by `reset` | `pause` (15): requests a system pause around a card save/load; consumes `system_paused` (16). Not part of `SS_idle` |
| `mdec` (`mdec.vhd`) | `SS_reset` (1351), `reset` | `SS_reset` zeroes the 2-word image (1351-1353) | `SS_Idle` (1357-1366): FIFOs empty and all four stage FSMs idle, or timeout |
| `gpu_pocket` (`gpu_pocket.vhd`) | `reset` (power-up defaults inline, 541; `SS_reset` declared at 136) | register defaults (`hDisplayRange = 0xC60260`, `vDisplayRange = 0x3FC10`, rest 0) | `SS_Idle` (1699-1702), consumes `system_paused` (21) |
| `gte_serial` | `reset` | as golden, no savestate image | `SS_idle` (1024-1027), same logic as `gte` |

### Rules for a `*_pocket` block

- Drive every output of the golden entity, including `SS_idle` / `Pause_idle_cd` / `pauseCD`. Tying
  `SS_idle` to 1 is legal only if the block can be frozen on any cycle without losing state; tying it
  to 0 blocks every pause forever.
- `Pause_idle_cd` and `SS_idle` may differ only for the CD (the slow-data pause does not need the CD
  to be cmd-idle). Every other block's `SS_idle` is also its pause-idle.
- On `reset_intern` the block must leave every output at its power-on value, including
  `pauseCD = 0` and the bus read data. Do not let `SS_reset` and `reset` overlap: the golden
  `cd_top` reset branch would overwrite `startMotorReset` in the same cycle.
- Savestate ports may be dropped (tied) only if the block's reset state does not depend on the
  image, per step 1/2 above.

## Shell skeleton (`pocket/psx/`)

`pocket/psx/` is the Pocket build of the core. The APF tree and the memory controllers come from
`pocket/common/` (qsf: `SEARCH_PATH ../../common/mem`, `QIP_FILE ../../common/apf/apf.qip`, the shared
`build_id_gen.tcl` pre-flow script). `build.sh` (`compile`, `package`, `timing`, `check`, `sim`) and
`fpga/ap_core.qsf` follow `pocket/memtest/` (STANDARD FIT, the generated PLL's assignments, `sdram_cal.v`); the shell always
builds with `SDRAM_135`.

`fpga/core/core_top.v` holds `core_bridge_cmd` (host commands, data-slot read and write; savestates
reported unsupported), `pll_psx`, `sdram_ctl` (with its calibrated read capture) + `sd_clk_out`, `psram32`, the memory adapters
and the core. Since first light the core is the real `psx_top_pocket` behind its flat wrapper (see [First light](#first-light));
`psx_top_stub.v` (module `psx_top_pocket_flat` with the same ports, every output driven from registered pseudo-random state into
which every input is XOR-folded) stays for `build.sh sim`'s stub bench and the mixed spike.

A Verilog parent cannot connect the `joypad_t` record or the integer `savestate_number`, so
`fpga/core/psx_top_pocket_flat.vhd` flattens them (`joypadN` = the record, first field in the MSB, then
Analog1X..Analog2Y). To build the real core, replace the stub line in the qsf with that file plus the rtl
list. `tools/gen_ports/` regenerates the stub, the flat wrapper and the stub instance from the entity. Boolean generics are
integers 0/1 in the flat wrapper (`NO_MDEC`): Quartus cannot set a VHDL boolean from Verilog.

### Clocks

One PLL, VCO 812.8512 MHz from the 74.25 MHz `clk_74a` (fractional), generated by `tools/gen_pll.sh` into
`fpga/core/pll_psx_dps.v` (Altera PLL with the dynamic phase shift ports, as `memtest/tools/gen_pll.sh`); `pll_psx.v` is a
wrapper that keeps the port names. The fit reports all eight outputs at these frequencies and phases:

| Counter | Clock | Divider | Frequency | Phase |
|---|---|---|---|---|
| C0 | clk_sys (SDRAM system clock) | /6 | 135.4752 MHz | 0 |
| C1 | clk_sd (SDRAM pin) | /6 | 135.4752 MHz | 217.5° (29 steps, 4,459 ps) |
| C2 | clk_cap (read capture) | /6 | 135.4752 MHz | 0, moved at run time by the calibration (`cntsel` 2) |
| C3 | clk1x, also the calibration scan clock | /24 | 33.8688 MHz | 0 |
| C4 | clk2x | /12 | 67.7376 MHz | 0 |
| C5 | clk3x | /8 | 101.6064 MHz | 0 |
| C6, C7 | clk_vid, clk_vid_90 | /120 | 6.77376 MHz | 0, 90° (clk2x / 10: the GPU's 320-wide dot rate) |

The GPU's sync video path counts its dot clock in clk2x cycles, so no 53.693 MHz clock is needed. In the SDC, clk1x/2x/3x and the
pixel clocks form one timed group and clk_sys/clk_sd/clk_cap another; the APF clocks are asynchronous groups. The handshake
between `sdram_cal` (clk_sys) and the PLL (clk1x) is two-flop synchronised, so it is not timed. The pin to `clk_cap` capture
path is a false path (MEMTEST.md, "Calibration contract"); the `clk_cap` to `clk_sys` transfer carries the swing of the capture
phase (`SDT_CAL_SWING`) as uncertainty. `sdram_timing.py --check` compares outputs 0 to 2 of `pll_psx_dps.v` with the timing
table (frequency and phase), and `build.sh compile` and `build.sh sim` run it.

### SDRAM calibration status window

`sdram_ctl`'s calibration is wired as in memtest: `pll_locked` synchronised to clk_sys, `clk_scan` = clk1x, `ps_en`, `ps_up` and
`ps_done` to the PLL. `cal_tick` comes from a placeholder timer, one pulse per 16 frames at 59.94 Hz (36,162,880 clk_sys cycles);
the core's vertical blank replaces it. `req_ready` is low while a sweep or tracking window runs, and `init_done` includes the
calibration. The results are read-only bridge words at `0x80000100 + 4·i` (the core's own address range; other words of the
window read 0; the values are crossed to `clk_74a` without a handshake, so read twice if they are changing):

| Word | Address | Content |
|---|---|---|
| 0 | `0x80000100` | bit 0 `init_done`, 1 `cal_done`, 2 `cal_ok`, 3 PLL locked, 7:4 `cal_flags`: bit 4 no eye, bit 5 eye touches 0 or 30, bit 6 PLL handshake timeout (calibration stopped), bit 7 tracker re-swept |
| 1 | `0x80000104` | 6:0 `cal_width`, 14:8 `cal_boot` (centre of the boot sweep), 22:16 `cal_centre` (now) |
| 2 | `0x80000108` | 6:0 `cal_min`, 14:8 `cal_max` (lowest and highest centre since boot) |
| 3 | `0x8000010C` | 15:0 `cal_moves` (tracker moves of the centre) |
| 4 | `0x80000110` | 15:0 tracking windows started |

The GPU stall counters the plan also wants readable over the bridge are not here; they belong to the core.

### Debug screen

*Core Settings → Screen → Debug* (bridge word 0x80000008, bit 0) replaces the picture with a 320 × 240 text screen.
`status_screen.v` is memtest's `video_text.v` renderer, with 428 clocks per line (59.95 Hz on the 6.77376 MHz pixel clock) and its own labels (`tools/gen_screen.py` →
`status_text.vh`). `status_fmt.v`, on `clk_74a`, rewrites the values continuously. `build.sh sim` checks them in `tb_status.v`
and renders `sim/out/status.ppm`. The rows:

| Row | Shows |
|---|---|
| SDRAM | `init_done`, `cal_done`, eye OK (green) or FAIL (red), PLL locked, eye width / boot centre / centre now, min / max / moves, `cal_flags` as bits 3..0 (bit 0 no eye, 1 eye touches an end, 2 PLL timeout, 3 re-swept), tracking windows started. The same values as the bridge window above |
| BIOS | bytes written to the BIOS window and the sum of their 32-bit words. `BIOS IS` says OPENBIOS (the sum of the bundled file, read either endian), OWN (another 524,288-byte file), NONE or SIZE?. A write at offset 0 starts a new count |
| PSX core | RUNNING, or HELD in reset (the SDRAM is not calibrated or the BIOS has not arrived) |
| Input | `cont1_key[15:0]` and `cont1_joy`: they change when a button or stick moves |
| PSX bus | main RAM requests, icache fills and DMA words written (`ram_adapter`); GPU VRAM reads and writes accepted (`vram_adapter`); frames sent to the APF |
| Core output | a 64 × 64 box with the live picture's pixels |

The uptime counts seconds of `clk_74a` from configuration. The counters cross to `clk_74a` without a handshake: a moving value can
be read mid-change and is rewritten on the next pass.

### Data slots (`dist/Cores/defgenx.PSX/data.json`)

| id | Slot | Parameters | Size | Bridge address |
|---|---|---|---|---|
| 0 | BIOS `psxbios.bin` | core-specific, required | exactly 524,288 | 0x20000000 |
| 1 | CD image (`.bin`) | user-reloadable, deferload | — | none: read by target command into 0x50000000 |
| 2 | Track table (`.trk`) | user-reloadable, deferload | ≤ 2,048 | none: read by target command into 0x30000000 (the `address` field is not used) |

A deferload slot is never written by the host: the APF only reports its id and size (data table at start-up, `dataslot_update` on a user load), and
the core reads it with target commands. So `cd_loader` fetches both CD slots itself.

Memory card 1 (`memcard1.sav`, nonvolatile, exactly 131,072, 0x40000000) is left out until P1c's memcard store exists: the
host saves a nonvolatile slot by reading it back, and the skeleton's window at 0x40000000 returns placeholder data, so declaring
it would overwrite the user's card. P1c declares card 1 only (FEASIBILITY: port 2 has no card). Settings words: 0x80000000 core, 0x80000004
memory controllers. `tools/check_json.py` validates `dist/`.

### Measured size (5CEBA4F23C8, revision `ap_core`, seed 2)

1,876.5 ALMs (10%), 3,905 registers, 10 M10K (the data table and three `synch_3` shift registers), 1 PLL, 0 DSP. The stub is
389.4 ALMs, so the shell is **1,487.1 ALMs**, part of it placeholders (glue, synchronisers, the status window). Per
entity: APF 198.8, `core_top` own logic 165.1 (frame timer, status window), `core_bridge_cmd` 181.2 (+ the data table),
`sdram_ctl` 312.3 plus `sdram_cal` 366.2, `sdram_arb` 6.3, `psram32` 123.3, `sram_ctl` 24.4, glue 36.4, PLL 21.5, status
synchroniser 17.0 (the calibration is `sdram_cal`'s 366.2). This is a floor: the adapters, the
3-client arbiter, the loaders and the video and audio paths are not in it yet.

Worst setup slack in ns, by clock (counter) and corner; every hold slack is at least +0.09 ns (clk_sys, fast models):

| Clock | slow 85 °C | slow 0 °C | fast 85 °C | fast 0 °C |
|---|---|---|---|---|
| clk_sys (C0) | +0.318 | +0.347 | +1.673 | +1.745 |
| clk_cap (C2) | +1.111 | +1.105 | +4.604 | +4.707 |
| clk1x (C3) | +22.67 | +22.56 | +25.47 | +25.59 |
| clk2x (C4) | +9.65 | +9.54 | +12.52 | +12.69 |
| clk3x (C5) | +4.55 | +4.43 | +7.47 | +7.66 |
| clk_vid (C6) | +151.2 | +151.2 | +154.7 | +154.9 |
| `dram_clk_pin` | +0.891 | +0.992 | +1.872 | +1.910 |
| `clk_74a` | +6.18 | +6.11 | +10.12 | +10.41 |
| `bridge_spiclk` | +11.01 | +11.24 | +12.53 | +12.62 |

All clocks meet timing in all four corners, so `build.sh package` accepts the build. `sdram_cal` counts its tracking
statistics a state after the decision and scans the eye by shifting it, which took its two deep clk_sys paths (`centre` to
`cmin`/`cmax`, `fi` to `best_len`) off the critical list; clk_sys is now limited by placement. Any change to the shell can
move it; the first thing to try is another seed.

### Simulating the whole top

nvc 1.23 analyses Verilog and instantiates it from VHDL (input and output ports only, no `inout`), but a
Verilog parent cannot instantiate a VHDL entity; iverilog and verilator cannot read VHDL, and ghdl and
yosys are not installed. The full top is therefore simulated from a **VHDL testbench top** that holds the
core (through `psx_top_pocket_flat`) beside Verilog leaves with no `inout` ports; the controllers and a
memory model sit behind one Verilog bench module that keeps the `inout` buses inside (`sim/mixed/`). nvc
cannot analyse memtest's `sdram_model.v` (arrays of `real`), so `sim/mixed/sdram_simple.v` replaces it.

`build.sh sim` runs the stub, bridge, status, mixed and CD end-to-end benches; the mixed bench: the stub drives the glue, the
arbiter and `sdram_ctl` for 1,500 µs, the boot sweep runs against `sim/mixed/sdram_simple.v` and a stand-in for the PLL's phase
shift, `init_done` rises with `cal_ok` set (eye 31 steps wide, centre 15: the model's data window is wider than the sweep, so
the eye touches both ends and `cal_flags` is 2, its bit 1 set) and one request is accepted. It proves the wiring, not the controller or the
calibration (memtest's `build.sh sim` does that). The stand-in is `sim/mixed/pll_dps_nvc.v`, not memtest's `pll_dps_model.v`:
nvc evaluates that model's real-valued delay as 0, so `clk_cap` never moves; the same holds for real-valued delays in the
SDRAM model, which therefore delays its read data with a second clock. The bridge status window itself is not simulated. The real core elaborates under nvc but does not
run yet: `cd_top`'s `positionInIndex` (patched in the sim copy), the `Gun1X` expression in the top
(sticks tied to −1) and `gpu_videoout_async.vhd:684` (`lineMax - 1 = -1` at 236 ns) fail range checks at
initialisation.

## First light

The first build with the real core: CPU, GPU, GTE, DMA, timers, pads, the bus and the CD-ROM controller, without the SPU and the
MDEC (`NO_MDEC` 1; `G_CD_IMPL` "pocket", the rewritten `cd_pocket`, CD.md). `core_top.v`'s `PSX_SPU` selects the SPU: "none"
(`spu_none`, the default) or "pocket" (`spu_pocket`, SPU.md, reverb off), which is wired to its RAM and the audio output but does
not fit the 5CEBA4 yet: 20,055 ALMs needed (109%), 19,541 (106%) with every [area lever](#area-levers) on. The CPU and the DMA are the rewritten `cpu_pocket` and `dma_pocket`
(`G_CPU_IMPL`/`G_DMA_IMPL` "pocket"; CPU.md, CORE.md): the system simulation gives the same bus counts and frames as with the
original blocks, except one icache fill of address 0 that the original issues during reset and discards. It boots the BIOS and shows the GPU's picture and reads a disc image loaded in the CD slots ([CD loader](#cd-loader)); with `PSX_SPU` "pocket" it plays the SPU's sound through the I2S ([SPU RAM](#spu-ram), [Audio](#audio)); the default build is silent. The core's other inputs are held at their MiSTer defaults in `core_top.v` (sync video on, NTSC, no savestates or cheats).

**Memory.** VRAM is on the SDRAM: `vram_adapter.v` takes the GPU's `ddr3_*` port (clk2x) through a 32-entry dual-clock command
FIFO (`async_fifo.v`, gray pointers) to `sdram_ctl` (clk_sys), one 4-word burst per 64-bit qword, read bursts of up to 128 split
into single requests, data back through a 256-entry FIFO with credit so it cannot overflow; `BUSY` is registered from the FIFO
level. Main RAM and the BIOS are on the PSRAM: `ram_adapter.v` serves the `ram_*` requests (clk1x), the icache fill stream and
the DMA write FIFO (clk3x) with toggle handshakes into `psram32` (clk_sys), PSRAM word address = `ram_Adr[24:2]` (main RAM at 0,
the BIOS at word 0x200000). Measured in `tb_ram.v`: a plain read takes 8 clk1x cycles, a 4-word fill 20. The PSRAM read wait is
12 cycles (88.5 ns, the memtest default) unless the memory-controller word 0x80000004 sets one. The SRAM is unused.

**BIOS and reset.** `bios_loader.v` byte-swaps the big-endian bridge writes of the BIOS slot into PSRAM through a 512-entry FIFO
(`err` if the bridge outruns the PSRAM). The core is held in reset until the SDRAM is calibrated and all 131,072 BIOS words are
in. The loader and `ram_adapter` reset on PLL lock only, because the host may load the slot while it holds `reset_n` low.

**Video.** `video_fl.v` samples the GPU's RGB once per clk_vid (clk2x / 10, exact for 320-wide modes; other widths are
resampled) into one fixed 320 × 240 scaler slot. The GPU's sync video out holds hblank high on vblank lines and ends vblank at
the line boundary, just before the first active line's pixels; its `hsync` comes once per line, blank lines included, in the
blanking after the pixels. So: HS on every `hsync` rise; VS when vblank ends; the frame starts on the next HS, which means the
GPU's first active line is not shown; 240 lines counted on HS; on each window line a 320-clock DE window from the active
pixels, or, on a blank line, from where they started on the last active line, black outside the GPU's active area. 480i shows
each field as a frame. The GPU's `clkvid` input is clk2x, because `gpu_videoout` reads its line RAM on that clock in sync mode.

**CD.** `cd_loader` (clk_74a and clk1x) sits between the bridge and `cd_pocket`: sector requests go out as `target_dataslot_read` of slot 1,
the track table (slot 2) is fetched by `target_dataslot_read` when the host reports it and replayed into `trackinfo_*`. `hasCD` = `trk_done`, `LIDopen` 0: the core starts and runs the BIOS with no
disc. A table whose header word 3 has bit 18 set (the `cue2pocket.py` default) resets the core once it is replayed. Wiring: [CD loader](#cd-loader).

**Pad.** Pad 1 is a digital pad: Pocket A, B, X, Y on Circle, Cross, Triangle, Square; L/R and the triggers on L1/R1, L2/R2.
Ports 2 to 4 are unplugged.

### SPU RAM

`spu_pocket`'s RAM port (`spuram_*` of `psx_top_pocket`: `sdram_ena` a one-clock pulse with `Adr`, `rnw`, `dataWrite(15:0)` valid and held until
`sdram_done`, a one-clock pulse at least one clock later carrying `dataRead(15:0)`; one request outstanding, `be` always 0011) is served from the SDRAM.
`spu_adapter.v` (clk1x to clk_sys by toggles, data held) makes each access one 4-word burst: a read takes the halfword out of the returned qword, a
write masks the other three words with the byte enables. Reverb is off (`NO_REVERB`, the default): capture and reverb accesses stay inside `spu_pocket`.
`psx_sdram_arb.v` puts it next to `vram_adapter` on the single `sdram_ctl` request port, the SPU first on a tie (one request outstanding, so the GPU is
delayed by one request at most); the 1-bit request tag routes read returns. The calibration still owns the port in its windows.

| Region | SDRAM word address (16-bit words) | Byte address |
|---|---|---|
| VRAM (GPU `ddr3_ADDR[24:0]`: 1 MB at 0; the frame buffers at 0x400000 + frame index × 0x100000) | 0x000000 – 0x07FFFF and 0x200000 – 0x3FFFFF | 0 – 0xFFFFF and 0x400000 – 0x7FFFFF |
| SPU RAM, 512 KB | 0x800000 – 0x83FFFF | 0x1000000 – 0x107FFFF |

Both sit below the 32 MB mark; bit 23 of the word address (byte 16 MB) is clear for every VRAM address and set for SPU RAM.

**Worst-case latency** (`sdram_ctl` at 135.4752 MHz, CL 3, BL 4, tRCD 3, tRP 3, tRAS 6, tRFC 9; clk_sys = 4 × clk1x, so the budget of 23 clk1x is 92
clk_sys cycles). A request waits for the request on the port to reach its CAS (a row miss: tRAS wait, PRECHARGE, ACTIVATE, tRCD: about 16 cycles), for a
refresh if one is due (all banks precharged, tRP, tRFC: about 23), then runs its own row miss (6 after a refresh, 16 otherwise) and the read returns
12 cycles after its CAS (`LAT` 9 + 3 beats). With the toggle crossings (about 3 cycles in, 9 out) the sum is about 72 cycles, 18 clk1x. A GPU burst of 128
beats is 128 separate requests, so it never blocks the SPU for more than one of them. Not included: a calibration tracking window (the port is closed for
about 1,150 cycles, 8.5 µs, once per 16 frames; 8,700 cycles with a re-sweep) delays the SPU by that time once; the SPU then catches up inside the
sample period. The new arbiter adds one 2:1 mux between `vram_adapter` and `sdram_ctl` (`req_*`, `rd_valid` gating by the tag).

`sim/tb_spu_mem.v` runs `vram_adapter` (random writes and read bursts of up to 128 beats, back to back), `spu_adapter` (random 16-bit reads and writes)
and the arbiter against a behavioural controller with these worst-case holds (4 to 16 cycles per request, 23-cycle refresh stalls every 934, read data 12
cycles late); it checks every byte on both sides against shadow memories and asserts the SPU latency from `ena` to `done`: 18 clk1x at most, 10.9 on average
over 6,000 accesses (budget 23). An arbiter that favoured the GPU starves the SPU in it. The system simulation (OpenBIOS, 250 ms) shows the SPU's voice reads, about 265 per ms and no writes, through the adapter and arbiter; the BIOS plays no sound there (`sound_out` stays 0) and the frames and RAM request counts equal the run without the SPU. A core reset while an SPU request is in flight can leave one stale
`done` for the next request (the sequencer resets the SPU first, `SS_reset`, and nothing issues requests in its 192-clock clear).

### Audio

`psx_audio.v` takes `sound_out_left/right` (clk1x; the SPU rewrites them once per sample, at 44.1 kHz) and makes the Pocket's I2S (12.288 MHz MCLK, 3.072 MHz
SCLK, 48 kHz frames, 32-bit slots with the 16-bit sample left-justified, left first). The samples are captured every 768 clk1x cycles into registers and
announced by one toggle to clk_74a (2-FF synchroniser; the registers are stable for 768 cycles around it). There the last two samples are kept with the age of
the newer one in clk_74a cycles, and each output frame is the linear interpolation `s0 + (s1 - s0) × age / 1684` (one 17 × 18 multiplier, L and R in
turn), so the output is the input delayed by one sample and needs no rate matching. At the left slot's start (lrck seen through 2 FFs) the two pairs are
latched and the result held for the frame, so the I2S shifter, which runs on the derived SCLK, reads values that change only right after a slot boundary.
`audio.json` needs nothing beyond the magic. `sim/tb_audio.v` feeds 997 Hz and 3001 Hz sines at 20,000 peak through it and deserialises the I2S: 48 kHz
frame rate, frequency within 0.5%, peak within 3%, and no output step above the sine's slope (a dropped or repeated input sample would exceed it).

### Area levers

`psx_top_pocket` generics (flat wrapper: integers 0/1), all default false, so the netlist is unchanged until a revision sets them:
`G_CD_NO_LIBCRYPT`, `G_CD_FIXED_TIMING`, `G_CD_NO_PEAK` (`cd_pocket`'s `NO_LIBCRYPT`, `FIXED_CD_TIMING`, `NO_CD_PEAK`; `NO_XA` is not passed on) and
`G_CPU_NO_COP0_DEBUG` (`cpu_pocket`'s `NO_COP0_DEBUG`). The joypad has no such generic. `core_top.v` does not set them.
Measured together in the `PSX_SPU` "pocket" build (seed 1, failed fits, the fitter's ALMs needed): 20,055 without them, 19,541
with all four, so they save 514 there. Set apart, they have not been measured.

**Tests.** Unit benches: `tb_vram.v`, `tb_ram.v`, `tb_bios_loader.v`, `tb_video_fl.v`, `tb_status.v`, `tb_spu_mem.v`, `tb_audio.v` (iverilog; commands in
their headers); `sim/cd_e2e/run.sh` for the CD path ([CD loader](#cd-loader)). The system simulation `sim/system/run.sh [BIOS] [ms]` runs the real core with `vram_adapter`, `ram_adapter`
and `video_fl` (and `cd_pocket` with no disc and `spu_pocket` with its RAM through `spu_adapter` and `psx_sdram_arb`, the hardware build with `PSX_SPU` "pocket") against behavioural PSRAM and SDRAM request ports (the controllers are proven in their own benches), with the BIOS
preloaded. It writes every frame the APF would get to `sim/system/out/frame_<n>.ppm` and traces the RAM bus to `ram_trace.txt`;
about 2 s of wall time per emulated millisecond.

**Fit** (5CEBA4F23C8, seed 1, `PSX_SPU` "none"): 17,428 ALMs (94%), 135 of 308 M10K, 21 DSP; every clock meets timing (worst
slack +0.003 ns, hold). Before the SPU RAM arbiter and the audio path: 17,404, worst +0.033 ns; `cd_pocket` 2,077.2 and `cd_loader`
254.5 of it, the core (`psx_top_pocket`) 14,694.4. Without the CD (seed 5) it was
14,823 ALMs (80%) and 82 M10K; with the original CPU and DMA 16,600 and 146. The SDRAM capture transfer `dq_cap3` → `dq_r` depends
on where the fitter puts `dq_r` (with the CD: seed 5 −0.102 ns, seed 2 −0.213, seed 3 −0.028, seed 1 met), and Quartus Lite has
no LogicLock regions to pin it: after a change, try another seed first.

## CD loader

`pocket/psx/fpga/core/cd_loader.v` serves `cd_top`'s sector requests from the CD image slot (id 1) with `target_dataslot_read`, and
reads the track table slot (id 2, into bridge window 0x30000000) and replays it into `trackinfo_*`. `pocket/psx/tools/cue2pocket.py` makes both files
from a CUE/BIN. Test: `iverilog -g2005 -o sim/out/cd_loader.vvp sim/tb_cd_loader.v fpga/core/cd_loader.v && vvp sim/out/cd_loader.vvp`
(from `pocket/psx`); `cue2pocket.py --selftest`.

### Core protocol (`cd_top.vhd`)

| Signal | Behaviour |
|---|---|
| `cd_hps_req`, `cd_hps_lba` | `SFETCH_START` (2594-2606) sets `lba` (an absolute disc LBA, 32 bits) and `req` on the same edge; `req` stays high until ack (2637-2643), or drops at once with `hasCD = 0` (2632-2635). A request is made only when `lba` differs from the last one (2595) |
| `cd_hps_ack` | Must be 0 before a new request (2578). The core takes the state change on seeing `ack = 1` (`SFETCH_HPSACK`, 2637); the first word may come one cycle later, not in the same cycle |
| `cd_hps_write`, `cd_hps_data` | Exactly 1,176 pulses, 16-bit words, consecutive pulses allowed (`SFETCH_HPSWORD` / `HPSDATA`, 2646-2685; `fetchCount` 0..587, low half first). Words are the sector's raw 2,352 bytes, little-endian: file bytes 0,1 are `[7:0]`, `[15:8]` of the first word. This is what the MiSTer HPS sent (`git show 47a82ef^:PSX.sv`, 1003-1007) |
| `trackinfo_*` | One 32-bit word per pulse, `addr` = word index (9 bits); the old top fed `ioctl_addr[10:2]` and the little-endian pair of 16-bit `ioctl_dout` (`PSX.sv` 548-553, 999-1001) |

The core zeroes the data itself while `positionInIndex < 0` (2583-2590, the first 150 LBAs of a data track 1), so no data is needed
for LBA < 150.

### `cd_loader` ports and behaviour

Parameters `SLOT_BIN` (1), `SEC_WIN` (0x50000000), `SLOT_TRK` (2), `TRK_ENT` (2, the slot's index in `data.json`) and `TRK_WIN` (0x30000000).
Ports: `rst`, `clk_74a`, `clk_sys` (= `clk1x`); `bridge_wr/addr/wr_data`
(`clk_74a`, big-endian: the first file byte is `[31:24]`, as `bios_loader`); `tgt_read/id/off/baddr/len` out and `tgt_done/err` in
(`core_bridge_cmd`, `clk_74a`; `tgt_ack` is not used); `dataslot_update/_id/_size`, `dataslot_allcomplete` and the data table port
`datatable_addr/q` (`clk_74a`); `core_run` (`clk_sys`, the core is out of reset); the `cd_hps_*` and `trackinfo_*` of `cd_top` (`clk_sys`);
`trk_done` and `err` out (`clk_sys`).

- **Sector.** A request is a toggle `clk_sys` -> `clk_74a`. `lba` < 150 (and an invalid `lba` >= 2^20) read nothing and answer zeros.
  Otherwise file sector = `lba - 150`, byte offset = that × 2,352 (four shifted adds), one `target_dataslot_read` of 2,352 bytes to
  0x50000000, `read` held 4 cycles, `done` ignored for 8 (the stale level, as `slot_bench`). The 588 bridge words go to a 588-word RAM
  written in `clk_74a`; 16 cycles after `done` a toggle hands the sector to `clk_sys`, which raises `ack`, waits 3 cycles, streams the
  1,176 words from the RAM and drops `ack` 3 cycles after the last. The latency added after `done` is 70 µs in the testbench (3 `clk_sys`
  cycles per half-word); the deadline is the host's read time, 6.67 ms per sector at 2×.
- **Failure.** `tgt_err` nonzero, fewer than 588 words received, or no `done` within 2^27 `clk_74a` cycles (1.8 s): the sector is delivered
  as zeros, so the core never hangs, and `err` goes high (sticky until `rst`). A missing file shows as this (the APF is assumed to
  return an error code for a slot without a file; unverified).
- **Track table.** One `target_dataslot_read` of slot 2 (offset 0, length = the size, capped at 2,048) to 0x30000000; the bridge writes fill a
  512-word RAM, byte-swapped to the little-endian words of the file. The read shares the `tgt_*` port with the sector reads: a table read waits for a
  sector read in flight, a sector request that arrives meanwhile is latched and served first. Triggers (all `clk_74a`):
  the first `dataslot_allcomplete` (size = data table word 2k+1 of entry k = `TRK_ENT`, word 2k must hold the id; the table layout, entry per
  data.json slot as id then size, is from the APF description and not measured); `dataslot_update` of slot 2 (size from the event); `dataslot_update` of
  slot 1 (a new image: the table is read again, so the core restarts on the new disc whichever of the two files was loaded last). Size 0 reads
  nothing (no table, `trk_done` stays low, no error). An error code, a short read or a timeout (as for sectors) leaves no table, sets `err` and
  keeps the previous table in the core. A read waits while the previous table is still waiting for its replay.
  A fetched table is handed to `clk_sys` by a toggle and replayed only after `core_run` has been high for 31 cycles (`cd_pocket` drops writes in reset):
  words 0..n-1 in order to `trackinfo_*`, one pulse per 4 cycles; `trk_done` falls when the replay starts and rises at its end. The core marks a new
  disc from the writes (`newCDCounter`, 3139-3141) and drops its cached sector. The table is replayed once, not on every core reset: `cd_pocket` keeps it.
- **Integration (`core_top.v`, `cdl`).** `bridge_wr/addr/wr_data` go to the loader beside `bios_loader` (address decode: BIOS
  `0x2xxxxxxx` by `bios_loader` and the status counters, track table `0x30000000..0x300007FF`, sector window `0x50000xxx`, settings
  `0x8000000x`; the windows do not overlap and no bridge read is decoded for them). `tgt_*` are `core_bridge_cmd`'s `target_dataslot_read/id/slotoffset/
  bridgeaddr/length/done/err` (`ack` unused; `target_dataslot_write` stays 0). `cd_hps_*` and `trackinfo_*` connect `cd_pocket` and the loader
  on `clk1x` (the loader's `clk_sys`), so no crossing is added beyond the loader's own toggles. The loader resets with `rst_mem` (PLL lock):
  the host may load the slots while it holds `reset_n` low. `dataslot_update*`, `dataslot_allcomplete` and `datatable_addr/q` (port A of the data
  table, no longer tied to 0) connect to `core_bridge_cmd`; `core_run` = `~psx_reset`. `hasCD` = `trk_done`; `LIDopen` 0. The core's reset
  (`psx_reset`) gains a 32-cycle pulse once `trk_done` follows a table whose word 3 has bit 18 set (decoded from the `trackinfo_*` write, since
  `resetFromCD` stays high). The core does not wait for a disc to leave reset. The order of loading the two files does not matter: either
  event fetches the table, which starts the new disc (`cd_pocket` raises a drive error and opens and closes the lid, about 0.4 s of drive time).
  The loader does not know whether slot 1 holds a file: the image read of a missing file fails and its sectors read as zeros.
- **Bench** `sim/cd_e2e/run.sh` (nvc, about 50 s, part of `build.sh sim`): `gen_disc.py` makes a synthetic disc (100 MODE2 data sectors with distinct data, then an audio track with its 150-sector pregap) and runs
  it through `cue2pocket.py`; `tb_cd_e2e.vhd` holds `cd_pocket` + `cd_loader` (as `core_top.v` wires them), the core reset after a table, and a model of the host: it answers each
  `target_dataslot_read` of slot 1 and slot 2 with big-endian bridge writes (it never writes unasked), sends `dataslot_allcomplete` and
  `dataslot_update` and holds the data table. Cases: no table (size 0, then a read error) leaves `trk_done` low; the start-up fetch; a second `.trk` by
  `dataslot_update` changes the disc (GetTN 1..2 becomes 1..1). It drives registers 0x1F801800-3: GetTN and
  GetTD against the CUE, after Init, ReadN at LBA 150 (file sector 0) and after a Setloc seek, 2,048-byte and whole-sector modes, comparing every byte with the
  `.bin` (disc LBA = file sector + 150). The bench resets `cd_pocket` after the table, as `core_top.v` does, and sets `INSTANTSEEK` to 1 (the
  hardware has 0); it prints PASS.

Size of the loader: by count, about 190 registers on `clk_74a` and 100 on `clk_sys`, five adders of 19-32 bits: 200-250 ALMs and
6 M10K (588 × 32 and 512 × 32 bits, two of each rounded up). Fitted: 254.5 ALMs (seed 1, see [First light](#first-light)).

### `.trk` format (derived from `cd_top.vhd:3139-3180`, `3199-3204`, `1030`, `2583`, `2698-2710`)

Little-endian 32-bit words, at most 512 (2,048 bytes). Word *n* is written to `trackinfo_addr = n`.

| Word | Bits | Meaning |
|---|---|---|
| 0 | `[7:0]`, `[15:8]` | track count, binary and BCD (the BCD byte is what `GetTN` answers, 1563) |
| 1 | `[18:0]` | total LBAs (not used by the core, 3149) |
| 2 | `[7:0]`, `[15:8]` | lead-out seconds and minutes, BCD (`GetTD 0`, 1574) |
| 3 | `[15:0]`, `[17:16]`, `[18]` | libcrypt key (bit 15 = first pair at 14105/14110, 2612-2628), region (0 unknown, 1 JP, 2 US, 3 EU: `region_out`), reset the core when the table is loaded |
| 4*n | `[18:0]` | track n (1..99): `lbaStart` |
| 4*n+1 | `[18:0]` | `lbaEnd` (inclusive) |
| 4*n+2 | `[7:0]`, `[15:8]`, `[16]` | minutes and seconds BCD of the track's INDEX 01 as a disc time (`GetTD n`), isAudio |
| 4*n+3 | | unused, but the write of this word stores the entry (3179-3181), so it must be present |

Track 1 is at words 4..7 (the track search starts at entry 1, 3111, and `isAudioCD` is word 6). The track containing an LBA is the first
entry with `lbaStart <= lba <= lbaEnd` (3119).

The layout the core implies, and `cue2pocket.py` builds: the file is the disc from INDEX 01 of track 1 at file sector 0, and
disc LBA = file sector + 150. A track's INDEX 01 is at LBA `s + 150` (`s` its file sector), and the core takes `lbaStart + 150` as INDEX 01
(`playLBA` 1030) and treats the 150 LBAs before it as index 0 (2701-2710), so `lbaStart = s`, `lbaEnd` = next `lbaStart` - 1, and for the last
track `lbaEnd` = file sectors + 149. The time of track *n* is that of LBA `s + 150`, the lead-out that of file sectors + 150.

`cue2pocket.py game.cue [-o PREFIX] [--sbi game.sbi] [--region auto|jp|us|eu|none] [--no-reset] [--trk-only]` takes MODE1/2352,
MODE2/2352 and AUDIO tracks in one or several BIN files, concatenates them (a `PREGAP` becomes zero sectors, sectors before track 1's
INDEX 01 are dropped) and writes `PREFIX.bin` and `PREFIX.trk`. The region is read from the licence text in the system area
(`Sony Computer Entertainment Inc. for Japan / of America / for Europe area`). The SBI key: an entry whose absolute MSF sector is listed
in a libcrypt pair sets that pair's bit. A pregap in the file other than 150 sectors is kept as it is (the core assumes 150).

### Not verified

- The MiSTer HPS's own mapping of `lba` to the file (the Main_MiSTer sources are not in the repository). `file sector = lba - 150` and
  the `.trk` ranges are derived from the VHDL alone; a disc whose pregaps are not 150 sectors, or a gapless audio-to-audio boundary, will
  show index 0 for the 150 sectors before each INDEX 01.
- The SBI entry sizes (14 bytes for type 1, 7 for types 2 and 3) are from memory of the format.
- APF: that `target_dataslot_read` accepts an offset that is not a multiple of 512, delivers the 2,352 bytes before `done`, fails with a
  nonzero code for an unloaded slot, and the `done` / `err` timing are the assumptions of [Bridge throughput bench](MEMTEST.md#bridge-throughput-bench-slot_benchv),
  not measured. The loader tolerates writes trailing `done` by 16 cycles.
- The track table slot is 2,048 bytes at most in `data.json`; the loader's fixed window is 0x30000000 + 2,048. The data table layout
  (id, size per slot, `TRK_ENT` = 2) and that the host fills it, and sends `dataslot_allcomplete`, before the first `dataslot_update`, are assumed, not measured.
