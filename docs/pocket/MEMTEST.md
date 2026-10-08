# PSX memory test core (Phase 3)

A small Analogue Pocket core with no PSX logic. It runs the planned memory layout on the real device,
checks every access, and shows measured MB/s, ns per access and error counts on screen.
Roadmap context: [ROADMAP.md](ROADMAP.md) phase 3, [FEASIBILITY.md](FEASIBILITY.md) memory layout.

Source: `pocket/memtest/`. Core id `defgenx.PSXMemTest`, bitstream `memtest.rbf_r`.

## What it tests

One 101.6064 MHz clock (3 × 33.8688 MHz) runs every controller and counter. All times are
measured in clock cycles of that clock (9.842 ns) and converted on chip; the screen shows MB/s × 10 as
`123.4`. Each test fills or writes a pattern derived from the address (xorshift of address and a
per-run seed), reads it back and counts mismatches, including unknown or floating data.

| Test | What it does | Reported |
|---|---|---|
| SDRAM seq write / seq read | 1 MiB as 131,072 bursts of 4 × 16 bit | MB/s, errors |
| SDRAM random read | 65,536 bursts at random burst addresses in the 1 MiB region (row misses) | MB/s, errors |
| SDRAM mixed | 65,536 random bursts, half reads, half writes | MB/s, errors |
| Scan-out alone | One 640 × 16-bit line (160 bursts) per line period of 6,400 cycles, 96 lines | lines late, worst line time (µs), lines |
| Scan-out under mixed traffic | The mixed test above runs while the scan-out stream is active | the same, plus the mixed test's MB/s |
| PSRAM write | 2 × 524,288 single 32-bit writes, both dies: the whole 2 MiB per die | ns per write, MB/s |
| PSRAM random read | 16,384 single 32-bit reads, random die and address over the full 2 MiB per die | busy ns per read, wall-clock ns per read, errors, MB/s |
| PSRAM chained read | 65,536 words as 16-word bursts (CE# held, one address cycle per word) | ns per word, errors, MB/s |
| PSRAM read-wait sweep | random reads with 5 … 20 cycles from address to sample | smallest safe wait (21 = none), summed errors, wait used afterwards (smallest + 1) |
| PSRAM address-line walk | per die, word 0 and the words 2^0 … 2^18 are written, then all read back; runs at the wait found by the sweep | errors |
| PSRAM sync burst (optional) | Programs the bus configuration register of both dies, then 16-word synchronous bursts and single-word synchronous reads | ns per word, errors, MB/s |
| SRAM wait sweep | random byte read and write with 1 … 8 cycles | smallest safe wait for read and for write |
| SRAM random byte write / read | 65,536 byte accesses at the safe wait + 1 | ns per access, errors |
| DMA PSRAM → SDRAM | 65,536 words (256 KB) read as 16-word PSRAM bursts, packed into 64-bit SDRAM bursts, then read back and verified | MB/s, errors |

The scan-out stream shares the SDRAM controller through a round-robin arbiter. A line is **late** when
the next line period starts before the line's 160 bursts have returned; this is the "scan-out missed
its deadline" count.

"ns per access" is the time the controller is busy with an access (command accepted to done), so it
excludes the test engine's own hand-off cycles. It is a cycle time, not a first-data latency: a
random PSRAM read at 9 wait cycles is 12 cycles, 118 ns. The **wall-clock** figure of the PSRAM random read
is the whole test time divided by the number of reads, so it also counts the 2 hand-off cycles between commands
(wait + 5 cycles per read, 138 ns at wait 9). "MB/s" for PSRAM uses the busy time (the wall-clock row has its own),
for SDRAM and DMA the wall-clock time of the whole test.

### Gate criteria this core measures

| Row on screen | Criterion (ROADMAP, phase 3) | How it is judged |
|---|---|---|
| `180NS` (first field) | Ganged PSRAM ≤ 180 ns per random 32-bit read | PSRAM random read **wall-clock** ns ≤ 180.0, no errors in the random reads (full 2 MiB per die) and none in the address-line walk |
| `100M` (second field) | DMA path ≥ 100 MB/s | DMA MB/s ≥ 100.0 with no verify errors; the best of async and sync counts |
| `SCAN` (third field) | Scan-out never misses its deadline | no late line alone or under mixed traffic, no data errors anywhere in SDRAM |
| SDRAM MB/s rows | SDRAM sustains the Phase 2 worst trace | raw MB/s only; the bandwidth figure is supplied by phase 2 |

The 180 ns gate judges wall-clock time because the console's ~177 ns is the time between successive
random accesses as the CPU sees it, and a requester pays the hand-off cycles around each command as well; busy time
alone would let a slow part pass. The test engine's 2 hand-off cycles are part of that figure, so it is a conservative
bound for this controller with the simplest requester. At wait *w* a read takes *w* + 5 cycles: 177.1 ns at *w* = 13
passes, 187.0 ns at *w* = 14 fails. The wait used is the smallest safe wait + 1 (never clamped), so a part whose smallest
safe wait is 13 or more fails the gate; the sweep reaches 20, so such a part shows its real figure on screen.

Each gate shows `---` until its tests have run, `PASS` or `FAIL` after. Nothing on this page is a
hardware result; see [Hardware results](#hardware-results).

## Screen

320 × 240, 40 × 30 characters. Labels are in columns 0–15, three 8-character fields follow.
Numbers are right-aligned, `-` means "not run (yet)", green/red marks error counts and gates.
`DONE` in the state field of row 1 means the sequencer finished.

| Row (from 0) | Label | Field 1 | Field 2 | Field 3 |
|---|---|---|---|---|
| 1 | state step runs | `INIT` / `RUN` / `DONE` | last finished step (23 = all) | runs completed |
| 4 | SDRAM SEQ WRITE | MB/s | | cycles |
| 5–7 | SDRAM SEQ READ, RANDOM READ, MIXED RD/WR | MB/s | errors | cycles |
| 9 | SCAN ALONE | late lines | worst line time µs | lines |
| 10 | SCAN UNDER MIXED | late lines | worst line time µs | lines |
| 11 | MIXED UNDER SCAN | MB/s | errors | cycles |
| 12 | SCAN DATA ERR | alone | under mixed | |
| 14 | PSRAM WRITE 32B | ns | | MB/s |
| 15 | PSRAM RANDOM READ 32B | busy ns | errors | MB/s |
| 16 | WALL CLOCK | wall-clock ns per random read (the 180NS figure) | | MB/s |
| 17 | CHAINED READ | ns | errors | MB/s |
| 18 | RD WAIT MIN/USE | smallest safe wait (21 = none) | sweep errors (expected > 0) | wait used |
| 19–20 | SYNC BURST RD16, SYNC RANDOM RD | ns | errors | MB/s |
| 21 | ADDR LINE WALK | | errors | |
| 23 | SRAM RANDOM WRITE | ns | | cycles |
| 24 | SRAM RANDOM READ | ns | errors | cycles |
| 25 | WAIT MIN RD/WR | smallest safe read wait | smallest safe write wait | sweep errors (expected > 0) |
| 27–28 | DMA ASYNC, SYNC BURST | MB/s | errors | cycles |
| 29 | 180NS 100M SCAN | gate | gate | gate |

![example screen](../../pocket/memtest/screen-example.png)

The picture is rendered by the testbench (`sim/tb_screen.v`) from example numbers, not from hardware.

## Settings (APF menu)

| Setting | Default | Effect |
|---|---|---|
| Restart tests | | Resets the controllers and runs everything again with a new seed |
| PSRAM sync burst | Off | After the asynchronous tests, programs both PSRAM dies into synchronous burst mode and runs the sync and DMA-sync tests |
| Sync latency | 3 clocks | Latency counter code written to the device and used to time the reads |
| Sync sample phase | 2 cycles | Cycles after the PSRAM clock edge at which read data is sampled |
| Loop | Run once | Repeat from the start when done (only while the PSRAM is still asynchronous) |

The PSRAM stays in synchronous mode until the core is reloaded. **After a sync run, reload the core
(Core menu) instead of using Restart**; Restart would run the asynchronous tests against a device
that no longer answers them and show errors.

Results can also be read over the APF bridge: word *i* at `0x10000000 + 4·i` is result *i*,
and `0x10000200 + 4·i` is 1 when it is valid. Result numbers are in `fpga/core/memtest_defs.vh`.

## How the controllers work

### SDRAM (`sdram_ctl.v`)

AS4C32M16SB: 16 bit, 4 banks, 8,192 rows × 1,024 columns. Chip select is tied low on the Pocket, so the
idle command is a NOP. Burst length 4, CL 3, open-page policy. Word address mapping: column `[9:0]`,
bank `[11:10]`, row `[24:12]`, so one 1,024-word VRAM line is one row.

Every timing figure lives in one table, `tools/sdram_timing.py`, which generates `fpga/core/sdram_timing.vh`
(cycle counts per clock for `sdram_ctl`, ns figures for `sim/sdram_model.v`), `fpga/core/sdram_timing.sdc` (the
I/O figures `core_constraints.sdc` sources) and `fpga/core/sdram_timing.json` (read by `sim/gpu_diff/bwmodel.py`).
`build.sh compile` and `build.sh sim` fail when a committed generated file differs from the script's output. A
cycle count is `max(minimum clocks, ceil(ns / tCK))`.

#### SDRAM timing table

**Speed grade: unconfirmed.** The part is named only in the SDC comment, "AS4C32M16SB-7"; no Pocket chip marking
or schematic has been checked. The table therefore holds the -7 column, whose CL 3 minimum tCK is 7 ns:
135.4752 MHz (7.38 ns) is 5% inside it, 101.6064 MHz (9.84 ns) 29%. If the part is a -6 the figures only get
better. "B-die" is the AS4C32M16SB datasheet (figures confirmed from its key-specification and AC tables:
tCK3, tAC3, tRAS, tRC); "A-die" is the AS4C32M16SA Rev 2.0 datasheet (-7), used for the figures not read from the
B-die sheet. Where two sources differ the slower figure is kept.

| Figure | ns | Source | Cycles at 101.6 / 135.5 MHz |
|---|---|---|---|
| tCK (CL 3), min | 7.0 | B-die | |
| tAC (CL 3), max | 5.4 | B-die | |
| tOH, min | 2.5 | A-die | |
| tIS / tIH, min | 1.5 / 0.8 | A-die | |
| tRCD, tRP, min | 20 | A-die 15; 20 kept | 3, 3 / 3, 3 |
| tRAS, min | 42 | B-die (A-die 45) | 5 / 6 |
| tRC, min | 63 | B-die (A-die 65) | 7 / 9 |
| tWR, min | 14 and ≥ 2 CLK | A-die tDPL 2 CLK | 2 / 2 |
| tRRD, min | 15 | A-die | 2 / 3 |
| tRFC (= tRC) | 63 | B-die | 7 / 9 |
| tMRD | 2 CLK | A-die | 2 / 2 |
| tREFI | 7,812.5 (8,192 in 64 ms) | A-die | refresh every 6.9 µs: 701 / 934 cycles |
| power-up wait | 200 µs (203 kept) | datasheet | 20,627 / 27,502 cycles |

The controller's own constants, from its structure rather than the datasheet: CL 3, BL 4, a read → write
command gap of CL + 6 = 9 cycles so the write data never overlaps read data on the bus.

CL 2 needs a clock of 100 MHz or less on a -7 part (A-die tCK at CL 2: 10 ns), so CL 3 is used. A request is decoded while the previous burst is
still on the bus, so back-to-back reads or writes in an open row issue every 4 cycles (full bus rate,
203 MB/s). Row misses precharge and activate before the burst; the controller does not open the next
request's row early, so the random figures are a floor for what a bank-aware controller could do.

`dram_clk` comes out of a DDIO register driven by a second PLL output that leads the system clock by
3.7 ns (225° of the 9.84 ns period, 40 VCO steps of 153.8 ps), so the clock pin has the same pad delay as the data and
command pins. Read data is captured in the I/O cell by a third PLL output, `clk_cap`, 1.08 ns behind the system clock
(7 steps), and moved to the system clock a cycle later, so it is registered CL + 3 clock edges after the command.
Why: the clock reaches the pin about 3.4 ns after it reaches the core's registers (global clock buffer, routing to
the DDIO, DDIO, pad), and that delay varies by 3.3 ns between the slow and fast models. A capture on the system clock
failed setup by 0.98 ns; the two phases above put the read capture edge inside the data window with +0.58 ns setup
and +0.79 hold in the worst models, and the command pins with +2.8 / +2.3 ns. `core_constraints.sdc` times the pins
against the generated pin clock with tAC 6.4 / tOH 3.2 / tIS 1.5 / tIH 0.8 ns, and the read path as a 2-cycle path
to `clk_cap` with the default hold check (the next word must not arrive before this one is captured).
If the SDRAM is unstable on hardware, the phases are the first thing to move: `phase_shift1` (pin clock) and
`phase_shift2` (capture clock) in `pll_mem.v`.

### PSRAM (`psram32.v`)

Two chips, each 2 dies × 64 Mbit, address and data multiplexed: `cram_a[21:16]` plus `cram_dq[15:0]`
carrying `A[15:0]` while ADV# is low. Both chips get the same control signals and each drives 16 of the
32 data bits; the die select (`ce0_n` / `ce1_n`) is address bit 22 of the 32-bit word address.
The asynchronous sequence (ADV# pulse, address hold, OE# or WE# phasing, 70 ns access) follows the
`psram.sv` that Adam Gastineau's Pocket cores use.

| Access | Cycles from command to done | What happens |
|---|---|---|
| Single read | wait + 3 | ADV# 1 cycle, address held 1 more, OE# low after the address is released, data sampled `wait` cycles after the address |
| Chained read | wait + 1 per word after the first | CE# stays low, OE# goes high, the next address is latched with a new ADV# pulse |
| Write | 11 | WE# low from the start, data on the bus for the last 4 cycles (≥ 20 ns before WE# high), byte enables released one cycle after |

`wait` is 9 by default (88 ns for a 70 ns access); the sweep finds the smallest value that reads
correctly and the later tests use that value + 1.

The sweep runs 5 … 20 cycles (5-bit wait field) so that a slow part is seen as slow instead of being clamped.
Address bits 16 … 18 of the 2 MiB main RAM are the pins `cram_a[18:16]`; the fill, the random reads and the address-line
walk (word 0, then one set address bit at a time up to bit 18, both dies) drive them, so an open or stuck pin among
`cram_a[18:16]`, or two shorted address lines, shows as errors in the 180NS gate.

**No page mode is used.** With address and data multiplexed, the low address bits share the data pins, so an
in-page read cannot change only `A[3:0]` while data is out; the device's datasheet was not available to check
whether it offers one anyway. The "chained" read is the closest this bus allows (it saves chip-select setup only):
at 70 ns per access, asynchronous PSRAM stays below 57 MB/s for 4-byte words, short of the 100 MB/s gate.

**Synchronous burst mode** is implemented because the DMA gate needs it. The bus configuration register is
written with CRE high through an asynchronous write whose address carries the register value
(`A[19:18] = 10`): fixed latency, latency counter = the menu setting, 16-word bursts, no wrap
(value `5D1B` for latency 3; layout taken from the CellularRAM register description and **not verified against
this device's datasheet**). Reads then run `cram_clk` at half the system clock, 50.8 MHz: address latched at
the first rising edge, first word after `latency` clocks, then one word per clock. `wait` is ignored
(fixed latency). The half-rate clock is used because the device's maximum clock is not known here. Writes stay
asynchronous (the fill happens before the mode change). If the device ignores or rejects the register write, the sync
tests report errors; they cannot hang the core.

### SRAM (`sram_test.v`)

256 KB as `sram_a[16:0]` × 16 bit, used as bytes through `ub_n` / `lb_n`. A read holds the address for
`wait` cycles; a write sets address and data up one cycle before WE# and holds WE# low for `wait`
cycles. The sweep writes or reads at 1 … 8 cycles against a known-good access at 8 and reports the smallest
wait that has no error above it.

### Clocks and pins

`pll_mem.v` makes 101.6064 MHz (system), the same clock 3.7 ns early for the SDRAM pin, the same clock 1.1 ns
late for SDRAM read capture, 6.3504 MHz (pixel, = system / 16) and its 90° copy from the 74.25 MHz reference with one
fractional VCO. Video is 400 × 264
pixels at 60.1 Hz with 320 × 240 active, one scaler mode, 4:3. One line period is 6,400 system cycles,
which is the scan-out deadline. Pin assignments and I/O standards are the template's.
The APF framework files in `fpga/apf/` and `core_bridge_cmd.v` are unchanged.

## Build

```
pocket/memtest/build.sh            # compile + package
pocket/memtest/build.sh compile    # Quartus only
pocket/memtest/build.sh sim        # simulations only
```

The compile runs Quartus Lite 21.1 in Docker from the repository root:

```
docker run --rm --platform linux/amd64 -v "$PWD":/build -w /build/pocket/memtest/fpga \
    raetro/quartus:21.1 quartus_sh --flow compile ap_core
```

A full compile took 3–8 minutes under x86 emulation on an 11-core Apple-silicon Mac. `build.sh` then reverses the bits of
`fpga/output_files/ap_core.rbf` into `dist/Cores/defgenx.PSXMemTest/memtest.rbf_r`, checks the JSON files against the
APF limits (`tools/check_json.py`) and zips the SD card layout.

Regenerating files that are checked in: `tools/gen_font.py` → `fpga/core/font8x8.hex`,
`tools/gen_screen.py` → `fpga/core/screen_text.vh` (screen labels; the row to result mapping is in `report_fmt.v`).

## Install

1. Run `build.sh` (or take `dist/` if it already holds `memtest.rbf_r`).
2. Copy the contents of `pocket/memtest/dist/` (`Cores/`, `Platforms/`, `Assets/`) to the root of the Pocket's SD card.
3. Start **PSX Memory Test** from the core list. The tests start on their own; the full run takes well under a second,
   after which the first row shows `DONE`.
4. To try the synchronous PSRAM bursts: set *PSRAM sync burst* to *On*, choose *Restart tests*, read the SYNC and DMA SYNC rows,
   then reload the core.

## Compile results

Quartus Prime Lite 21.1.1, `raetro/quartus:21.1`, command above, 3–8 minutes under emulation. Full compilation
successful, no critical warnings, timing met on every clock in all four models (slow 85 °C / 0 °C, fast 85 °C / 0 °C).

| Resource | Used |
|---|---|
| ALMs | 3,070 / 18,480 (17%) — memtest core 2,383 (of which SDRAM controller 252, traffic/scan engines 358, PSRAM 149 + 481 engine, SRAM 22 + 247 engine, DMA 155, divider 88), screen formatter 150, video 58, APF bridge 209, everything else (APF framework, `core_top` glue) 271 |
| Registers | 4,707 |
| Block memory | 45,040 bits in 11 M10K / 308 (font 8 Kb, label ROM 9.6 Kb, text RAM 9 Kb, two result copies 2 × 4.2 Kb, DMA FIFO 1.4 Kb, APF data table 8 Kb) |
| DSP | 0 |
| PLL | 1 fractional, VCO 812.8512 MHz; outputs 101.6064 MHz (0°), 101.6064 MHz (225°, SDRAM pin clock), 101.6064 MHz (39.4°, read capture), 6.3504 MHz (0°), 6.3504 MHz (90°) |
| I/O | 224 / 224 pins; every SDRAM address, command and data register is packed into its I/O cell (the constant `dram_dqm` is not) |

Worst slack per clock, minimum over the four models (the model that produced it in brackets). Setup uses the slow
models, hold the fast ones, as the analyser does.

| Clock | Worst setup | Worst hold |
|---|---|---|
| `clk_sys` 101.6064 MHz | +0.814 ns (slow 85 °C) | +0.100 ns (fast 0 °C) |
| `clk_cap` SDRAM read capture, 101.6064 MHz | +0.575 ns (slow 0 °C), from the SDRAM data pins | +0.785 ns (fast 0 °C) |
| `clk_sd` SDRAM clock source | no register paths; minimum pulse width +3.8 ns | |
| `dram_clk_pin` (SDRAM command, address and write data pins) | +2.775 ns (slow 85 °C) | +2.334 ns (slow 0 °C) |
| `clk_vid` 6.3504 MHz | +149.71 ns | +0.176 ns (fast 0 °C) |
| `clk_vid_90` | no register paths | |
| `clk_74a` | +4.725 ns | +0.168 ns (fast 0 °C) |
| `bridge_spiclk` | +10.275 ns | +0.154 ns (fast 0 °C) |

Minimum pulse width is positive on every clock (smallest +0.615 ns, on the VCO). The SDRAM pins are timed with
tAC 6.4 / tOH 3.2 / tIS 1.5 / tIH 0.8 ns assumptions in `core_constraints.sdc`; the read-capture slacks (+0.58 setup,
+0.79 hold) are the thin ones and the first thing to retune if the SDRAM misbehaves. PSRAM and SRAM pins are false
paths by design. The audio clock dividers from the APF template have no clock assignment (analyser warning, unchanged from the template).

How the SDRAM phases were chosen: the first compile (capture on the system clock) failed setup by 0.98 ns on the
read data; a half-period capture failed the half-cycle path from the I/O cell into the core by 1.37 ns, and a
`-hold 1` multicycle option (as other cores' SDCs use) hid the real read-hold hazard. The final phases and the default
hold check give positive margin on every read, command and internal path.

## Verification

Behavioural models in `sim/` (`sdram_model.v`, `psram_model.v`, `sram_model.v`) check the controllers against the
numbers above and flag every violation: SDRAM tRCD, tRP, tRAS, tRC, tRRD, tRFC, tWR, READ to PRE (≥ BL cycles), PRE during a write burst,
refresh rate (average tREFI 7.8125 µs, at most 8 refreshes postponed), mode register
order, bank state, unknown write data, bus overlap; PSRAM tVP, tAVS, tAVH, tWP, tDW, tAW, access time, die select,
register write and the synchronous burst; SRAM access time and write pulse width. Unknown data read back counts as an error.

| Simulation (`sim/run.sh <mode>`) | What it covers | Result |
|---|---|---|
| `fast` | whole core, reduced sizes (PSRAM fill 256 words per die; the address-line walk always reaches bit 18), async PSRAM | PASS, 139,742 cycles |
| `sync` | same plus the synchronous PSRAM tests and DMA | PASS, 145,622 cycles |
| `late` | scan-out line period shortened below what a line needs: late lines must be counted, the gate must fail | PASS: 4 of 4 lines late, scan gate FAIL |
| `full`, `fullsync` | the sizes the hardware runs (1 MiB SDRAM, 2 MiB per PSRAM die, 65,536 words, …) | both PASS: 21.46 M cycles (211 ms) with sync, 20.74 M (204 ms) without; all errors 0, no model violations; about 5.5 min of Icarus time each |
| `fast` with `-DPS_STUCK_BIT=18` (or 16) | the PSRAM model forces word address bit 18 (16) to 0 (`-DPS_STUCK_HI`: to 1) | PASS = the fault is caught: walk errors 2, 180NS gate FAIL |
| `fast` with `-DPS_BRIDGE_BIT=16` | the PSRAM model shorts word address bits 16 and 17 (wired-OR); only the walk can see it | PASS = the fault is caught by the walk alone: walk errors 2, random-read errors 0, 180NS gate FAIL |
| `fast` with `-DPS_TAA=<ns>` | PSRAM model access time instead of 70 ns; the sweep must find a larger wait | 110: smallest safe wait 12, used 13, wall 177.1 ns, gate PASS (`-DPS_GATE_PASS`); 120: 13 / 14 / 187.0 ns, FAIL; 140: 15 / 16 / 206.6 ns, FAIL; 190: 20 / 21 / 255.8 ns, FAIL |
| `tb_screen.v` | result store → formatter → text RAM → video frame, number formats, a rendered frame | PASS |
| `tb_div.v` | the divider against `/` on 2,000 random operands and divide by zero | PASS |

The `PS_STUCK_BIT`, `PS_STUCK_HI`, `PS_BRIDGE_BIT`, `PS_TAA` and `PS_GATE_PASS` defines go through `EXTRA`, e.g.
`EXTRA="-DPS_STUCK_BIT=18" sim/run.sh fast`. `build.sh sim` runs `fast`, `sync`, `late`, the `PS_TAA` 110 (with
`PS_GATE_PASS`) and 120 variants, `PS_STUCK_BIT` 16 and 18, `PS_BRIDGE_BIT` 16, `tb_div` and `tb_screen` (about 35 s), and
exits non-zero unless every one prints `PASS`. `full` and `fullsync` are run by hand: they are the only runs where the
fill and the random reads span 2 MiB, so a regression in that addressing shows only there.

Simulated times on this page are what the core prints. Its cycle-to-ns constant (98.40625 ns per 10 cycles, against the true
98.4252) reads up to 0.1 ns low: a 13-wait read is 177.2 ns and shows as 177.1. The default random read shows 137.8
in `fast` and 137.7 in `full`, whose longer run spreads the start-up cycles thinner. The 180 ns gate compares the
printed figure.

What the full-size simulation reports (behavioural models at 101.6064 MHz; **not** hardware, shown to make the units
and the expected shape of the results concrete):

| Test | Simulated |
|---|---|
| SDRAM seq write / read | 197.8 / 198.4 MB/s (bus limit 203) |
| SDRAM random read, mixed, mixed under scan-out | 93.0, 88.2, 74.6 MB/s |
| Scan-out line time, alone / under mixed traffic | 6.6 µs / 25.9 µs of 63 µs, no late line |
| PSRAM write / random read (busy) / chained read | 108 ns / 118 ns / 99.6 ns per word (36.9 / 33.8 / 40.1 MB/s); random read wall-clock 137.7 ns |
| PSRAM sync burst (latency 3, 50.8 MHz clock) | 25.8 ns per word, 154.8 MB/s; single-word read 118 ns |
| SRAM random byte write / read | 68.8 / 59.0 ns (model access time 25 ns, smallest safe wait 3 read, 2 write) |
| DMA PSRAM → SDRAM, async / sync | 39.6 / 147.7 MB/s |

The models are mine, written from the same understanding of the datasheets as the controllers, so a shared misreading
would pass both. They do not model pad delays or the SDRAM clock phase; those are covered only by the static timing analysis.

## Hardware results

Every cell needs a Pocket.

| Measurement | Value | Gate |
|---|---|---|
| SDRAM seq write MB/s | pending — needs a Pocket | |
| SDRAM seq read MB/s | pending — needs a Pocket | |
| SDRAM random read MB/s | pending — needs a Pocket | worst trace ≤ 80% of this (figure from phase 2) |
| SDRAM mixed MB/s | pending — needs a Pocket | |
| Scan-out late lines, alone / under mixed | pending — needs a Pocket | 0 |
| Scan-out worst line time µs | pending — needs a Pocket | < 63 |
| SDRAM errors | pending — needs a Pocket | 0 |
| PSRAM random read ns, busy / wall-clock | pending — needs a Pocket | wall-clock ≤ 180 |
| PSRAM address-line walk errors | pending — needs a Pocket | 0 |
| PSRAM chained read ns per word, MB/s | pending — needs a Pocket | |
| PSRAM smallest safe read wait (cycles) | pending — needs a Pocket | |
| PSRAM write ns | pending — needs a Pocket | |
| PSRAM sync burst ns per word, MB/s (works at all?) | pending — needs a Pocket | |
| SRAM smallest safe wait, read / write (cycles) | pending — needs a Pocket | |
| SRAM random byte read / write ns | pending — needs a Pocket | |
| DMA async MB/s | pending — needs a Pocket | ≥ 100, or a slowdown judged acceptable |
| DMA sync MB/s | pending — needs a Pocket | ≥ 100 |

## Not verified

- Everything above on real hardware, in particular SDRAM clock phase and CL 3 at 101.6 MHz, PSRAM access time
  and the 5 … 20 cycle sweep window, SRAM speed.
- The PSRAM bus configuration register layout, the maximum synchronous clock, and whether fixed-latency burst reads work at all.
- The SDRAM speed grade (see the SDRAM timing table): the Pocket's chip marking was not checked, so the -7 column
  is assumed. PSRAM datasheet figures are from memory of the usual part family; its exact part number was not
  looked up.
- `cram*_wait` is not used.
- `cram_a[21:19]` are never driven (2 MiB needs only `cram_a[18:16]`), and a swapped pair of address pins is a
  consistent remap that no memory test, and no console, can see.

## Sources and licences

| Source | What was taken | Licence |
|---|---|---|
| Analogue openFPGA core template v1.3.0 (`open-fpga/core-template`, commit `da3a021`) | `fpga/apf/*` (via the C64 port, identical except line endings), `core_bridge_cmd.v`, the `core_top.v` port list, bridge and audio blocks, `icon.bin`, JSON layout | No licence file. Each source file carries Analogue's Software License Agreement header (use under the Pocket EULA, `analogue.link/pocket-eula`; the MIT or GPL prevails where it applies) |
| `defgenx/openfpga-C64` | `ap_core.qsf` pin and I/O assignments and fast-register assignments, `build.sh` structure, `tools/check_json.py`, `tools/reverse_bits.py`, `tools/font8x8_basic.h` | No licence file; its README states GPL v2 or later for the Pocket-specific code |
| `defgenx/openfpga-AtariST` | the direct `altera_pll` instantiation style, the DDIO SDRAM clock and the SDC pin timing pattern were read and re-written, not copied | No licence file; same author |
| `defgenx/openfpga-SNES` | read for the SDRAM clock handling; nothing copied | GPL v3 |
| `apf-ref-*` | read only | `apf-ref-amiga`: GPL v3; `apf-ref-utils`: MIT |
| `agg23/analogue-pocket-utils` `psram.sv` (Adam Gastineau) | the asynchronous PSRAM access sequence and timing figures were followed in a new implementation (`psram32.v`) | MIT, © 2022 Adam Gastineau |
| font8x8 (Daniel Hepper) | `tools/font8x8_basic.h`, `fpga/core/font8x8.hex` | public domain |

This directory's own code is part of PSX_MiSTer and follows the repository licence (GPL v2).
