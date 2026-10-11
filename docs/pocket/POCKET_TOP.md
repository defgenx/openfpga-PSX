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
| SPU | `G_SPU_IMPL` ("golden") | `spu` -> `spu_pocket` | `ispu`, 2340 | `psx_pocket_a6_spu` |
| CD | `G_CD_IMPL` ("golden") | `cd_top` -> `cd_pocket` | `icd_top`, 1761 | `psx_pocket_a6_cd` |
| CPU | `G_CPU_IMPL` ("golden") | `cpu` -> `cpu_pocket` | `icpu`, 3020 | `psx_pocket_a6_cpu` |
| DMA | `G_DMA_IMPL` ("golden") | `dma` -> `dma_pocket` | `idma`, 1445 | `psx_pocket_a6_dma` |
| Bus | `G_BUS_IMPL` ("golden") | `memorymux` -> `memorymux_pocket` | `imemorymux`, 2579 | `psx_pocket_a6_bus` |
| Joypad | `G_JOYPAD_IMPL` ("golden") | `joypad` -> `joypad_pocket` | `ijoypad`, 1067 | set in the bus revision |
| Memcard | `G_MEMCARD_IMPL` ("golden") | `memcard` -> `memcard_pocket` | `imemcard1`, 3290; `imemcard2`, 3410 | set in the bus revision |
| MDEC | `G_MDEC_IMPL` ("golden") | `mdec` -> `mdec_pocket` | `imdec`, 2231 (inside `NO_MDEC` generate) | `psx_pocket_a6_mdec` |
| GPU | `G_GPU_IMPL` ("pocket") | `gpu_pocket` (default) / `gpu` | `igpu`, 1946 | `psx_pocket_a6_gpu` (golden `gpu`) |

- The CPU, SPU, CD, DMA, memorymux, joypad, memcard, MDEC and GPU are all instantiated directly in
  `psx_top_pocket.vhd`; none is nested elsewhere. `memcard` is a separate instance from `joypad`
  (two instances, one generic). `gte_serial` (`igte`, 3244) is not switchable.
- The `*_pocket` entity must have the golden's exact port list (the component declaration in the
  top is the golden's ports); port or generic changes belong in the golden-compatible entity, not in the top.
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
reported unsupported), `pll_psx`, `sdram_arb` + `sdram_ctl` (with its calibrated read capture) + `sd_clk_out`, `psram32`, `sram_ctl` and
the core.
Today the core is `psx_top_stub.v`: module `psx_top_pocket_flat` with the ports of `psx_top_pocket`, every
output driven from registered pseudo-random state into which every input is XOR-folded, so nothing behind
it is pruned. `mem_glue_placeholder.v` and the `g_*`/`pool_*` wiring in `core_top.v` stand in for the
adapters, arbiter clients, bridge crossings and video/audio paths; they keep both sides alive and are not
protocol-correct.

A Verilog parent cannot connect the `joypad_t` record or the integer `savestate_number`, so
`fpga/core/psx_top_pocket_flat.vhd` flattens them (`joypadN` = the record, first field in the MSB, then
Analog1X..Analog2Y). To build the real core, replace the stub line in the qsf with that file plus the rtl
list. `tools/gen_ports/` regenerates the stub, the flat wrapper and the stub instance from the entity.

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
| C6, C7 | clk_vid, clk_vid_90 | /128 | 6.3504 MHz | 0, 90° (placeholder pixel clock) |

The 53.693 MHz pixel clock is not an integer division of the VCO and gets its own PLL later. In the SDC, clk1x/2x/3x form one
timed group and clk_sys/clk_sd/clk_cap another; the pixel clocks and the APF clocks are asynchronous groups. The handshake
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

### Data slots (`dist/Cores/defgenx.PSX/data.json`)

| id | Slot | Parameters | Size | Bridge address |
|---|---|---|---|---|
| 0 | BIOS `psxbios.bin` | core-specific, required | exactly 524,288 | 0x20000000 |
| 1 | CD image (`.bin`) | user-reloadable, deferload | — | none: read by target command into 0x50000000 |
| 2 | Track table (`.trk`) | user-reloadable, deferload | ≤ 2,048 | 0x30000000 |

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

`build.sh sim` runs the stub and bridge testbenches and the mixed bench: the stub drives the glue, the
arbiter and `sdram_ctl` for 1,500 µs, the boot sweep runs against `sim/mixed/sdram_simple.v` and a stand-in for the PLL's phase
shift, `init_done` rises with `cal_ok` set (eye 31 steps wide, centre 15: the model's data window is wider than the sweep, so
the eye touches both ends and `cal_flags` is 2, its bit 1 set) and one request is accepted. It proves the wiring, not the controller or the
calibration (memtest's `build.sh sim` does that). The stand-in is `sim/mixed/pll_dps_nvc.v`, not memtest's `pll_dps_model.v`:
nvc evaluates that model's real-valued delay as 0, so `clk_cap` never moves; the same holds for real-valued delays in the
SDRAM model, which therefore delays its read data with a second clock. The bridge status window itself is not simulated. The real core elaborates under nvc but does not
run yet: `cd_top`'s `positionInIndex` (patched in the sim copy), the `Gun1X` expression in the top
(sticks tied to −1) and `gpu_videoout_async.vhd:684` (`lineMax - 1 = -1` at 236 ns) fail range checks at
initialisation.
