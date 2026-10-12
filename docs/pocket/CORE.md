# DMA, bus and peripherals for the Pocket

This document covers the DMA controller, the bus (memory mux, memory control, timers, interrupts) and the
peripherals (joypad, memory card, SIO) of the Pocket core. Area targets and gates: [ROADMAP.md](ROADMAP.md).
Each section is filled by the unit that rewrites that block.

## DMA

`rtl/dma_pocket.vhd` replaces `rtl/dma.vhd` (`G_DMA_IMPL => "pocket"`). It has the golden's entity ports and the
golden's cycle-by-cycle behaviour. `sim/dma_diff` proves it. This document owns the design; the RTL comments point here.

### Contract

Every output equals the golden's on every clk1x/clk3x cycle for any input sequence, with these exceptions:

- **Savestates.** `SS_wren`/`SS_rden`/`SS_reset`/`loading_savestate` are ignored and `SS_DataRead` is 0 (the Pocket top ties
  them off). `SS_idle` is the golden's.
- **Write data buses.** `DMA_GPU_write` and `DMA_MDEC_write` are the same register (`dma_data` of the previous clock-enabled
  cycle) and are only defined while the matching `*_writeEna` is high. The GPU, SPU and MDEC gate on the enable; the harness
  masks both buses while it is low.
- **Bus writes while a transfer runs.** The golden flags any bus access with `dmaState /= OFF` as `errorDMACPU`; reads
  stay exact. A bus write in the exact cycle a transfer or pause writes its working copy back loses to the write-back (one
  MLAB write port). The top never does this: the CPU is paused while `dmaOn` is high. The harness issues bus writes only
  while the golden is off, including the cycle it starts.
- **Reset.** `reset` must last 8 or more clk1x cycles: a counter clears the MLAB words one channel per cycle. The Pocket
  top holds it for 61. Bus accesses during reset are not defined.
- Unchanged and kept: the REP_* reproducible-timing logic. With `TURBO = 0` (the Pocket's value) it decides when `dmaOn`
  falls, so it is observable and stays, including its 20-bit counters.

### Design

| Golden (`dmaRecord`, per channel) | Pocket |
|---|---|
| `D_MADR`, `D_BCR`, `D_CHCR` | three MLAB arrays of 8 words (24, 32 and 13 bits: CHCR keeps only its bus-writable bits) |
| CHCR bits 24, 28, `channelOn` | flip-flops: the trigger logic reads all seven every cycle |
| `chopwaiting`, `chopwaitcount` (8 bits x 7) | one flag per channel plus a 7-bit expiry stamp each, and one shared 7-bit tick counter |
| `request`, `requestsPending`, `timeupPending`, `isOn`, `paused`, `gpupaused` | removed (only read by the savestate image) |
| `dmaSettings` | kept, the single working copy; loaded in the cycle before the start, written back at the end |

- **One read port.** The bus read, else the channel the arbitration selects this cycle. While off, the working copy is
  reloaded from that channel every cycle except the start cycle, which uses what the previous cycle loaded: the trigger
  only fires after a cycle without a bus access, so the array cannot have changed. A bus write in the start cycle is
  therefore overwritten at the end of the transfer, as in the golden.
- **One write port.** The bus write, the write-back and the reset sweep share it.
- **Chop waits.** A wait of n cycles stores tick counter + n; it ends on the tick that makes the counter equal the stamp. A tick is a
  clock-enabled cycle with `cpuPaused` low. A GPU CHCR write with linked-list sync starts a wait unless a running wait ticks
  in the same cycle; the state machine's start overrides both.
- **Shared registers.** The CD/SPU read accumulator doubles as the linked list's next pointer (a list only runs to a device,
  the accumulator only from one). The request-mode block counter is `BCR(31:16) - 1`, so `blocksleft` is gone. The chopping
  slice uses one subtraction for its three cases.
- Unchanged: both FIFOs, the arbitration order, `ram_cnt`, the timing counters.

### Harness (`sim/dma_diff`)

`make diff` (golden `rtl/dma.vhd` against `dma_pocket`), `make -j8 gate`, `make selftest`, `make golden` (golden against golden).
Both sides see the same inputs; the device models answer the golden's outputs. Every output is compared three times per
clk1x cycle.

- Environment: `ram_*`/`dma_*` protocol of `ram_adapter.v` (random latencies, `1+ram_cnt` consecutive beats), DMA FIFO
  drained on clk3x at random rates, random request and data lines, `cpuPaused` and `ce` as the top's switch, random
  `canDMA`, bus strobes from the vector file.
- Suites: `directed` (every channel x direction x sync mode x step x chop, chop edges, register file, IRQ flags, write at the
  start cycle), `random`, `wild` (`G_MODE=1`: cpuPaused glitches, random `ce` drops while idle, reads during transfers),
  `boundary` (1 KB page edges, all `ram_cnt` values), `turbo` (TURBO, TURBO_CACHE, ram8mb, ignoreCDTiming), `reset`,
  `contention` (several channels armed, requests raised together).
- The golden is simulated through `build/dma_sim.vhd`, `rtl/dma.vhd` with two sed patches that give nvc the synthesised
  widths: `REP_refresh` wraps at 128, `requestedDwords`/`requiredDwords` are 17 bits.
- `make selftest`: one flipped output sample must give exactly one mismatch (9 outputs), and each of the injected bugs in a
  copy of `dma_pocket.vhd` (address step, tie rule, every chop wait, refresh timing, `ram_cnt`, CHCR read, DPCR reset,
  write-back, OTC terminator, block count, `channelOn`, SPU pacing, accumulator, IRQ flag, reload in the start cycle) must be
  reported.

### Area and timing

`sizing/psx_pocket_a6_dma.qsf` (5CSEBA6, `G_DMA_IMPL = pocket`, fitter hierarchy, ALMs needed):

| | ALMs | Registers |
|---|---|---|
| golden `dma` in context | 1,318.9 | 1,150 |
| `dma_pocket` in context | **824.8** | |
| `dma_pocket` standalone (`dma_size_wrap`, Pocket ties, SDC: clk1x 29.526 ns, clk3x 9.842 ns) | 813 placed | 558 |

Gate (<= 900): met, 75 ALMs under. In the standalone fit the MLAB arrays take 50 ALMs. The chop-wait stamps replaced counters that cost
about 95 ALMs. The in-context sizing revisions carry no SDC, so their slack figures are not meaningful; standalone with the
SDC: setup slack clk1x +1.39 ns and clk3x +0.68 ns (slow 100 C), hold >= +0.25 ns, Fmax 61 MHz (clk1x) and 161 MHz (clk3x).

Results of `make gate` (6 seeds x 7 suites): 545 M output compares over 6.27 M clk1x cycles, 0 mismatches; 32,847
transfers over all channels and directions; `make selftest` passes (9 flipped-sample faults, 20 injected bugs).

## Bus

To be written by its rewrite.

## Peripherals

To be written by its rewrite.
