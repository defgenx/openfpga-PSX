// PSX memory test core: shared constants and the data pattern. See docs/pocket/MEMTEST.md.
`ifndef MEMTEST_DEFS_VH
`define MEMTEST_DEFS_VH

// Clock variant, SDRAM cycle counts and MT_CYC: ../../common/mem/mem_defs.vh.
`include "mem_defs.vh"
`ifdef SDRAM_135
  `define MT_LINE_NUM   25600         // scan-out line = 400 pixels at 6.3504 MHz = 25600 / 3 cycles
  `define MT_LINE_DEN   3
`else
  `define MT_LINE_NUM   6400          // 400 pixels at 6.3504 MHz
  `define MT_LINE_DEN   1
`endif

// ---- result slots (3 per test: primary value, errors, auxiliary) ----
// SDRAM
`define R_SD_SW      7'd0   // seq write: MB/s x10, -, cycles
`define R_SD_SR      7'd3   // seq read:  MB/s x10, errors, cycles
`define R_SD_RR      7'd6   // random read
`define R_SD_MX      7'd9   // mixed random read/write
`define R_SC_ALONE  7'd12   // scan-out alone: missed lines, worst line us x10, lines
`define R_SC_MIX    7'd15   // scan-out under mixed traffic: same
`define R_SD_MXS    7'd18   // mixed traffic under scan-out: MB/s x10, errors, cycles
`define R_SC_ERR    7'd21   // scan-out data errors (alone, under mixed)
`define R_SD_BE     7'd72   // byte-enable test: write pass MB/s x10, readback errors, readback cycles
// PSRAM (ganged 32-bit)
`define R_PS_WR     7'd24   // write: ns x10 per word, -, MB/s x10
`define R_PS_RR     7'd27   // random read: ns x10, errors, MB/s x10
`define R_PS_SR     7'd30   // sequential (chained) read
`define R_PS_SWEEP  7'd33   // read wait sweep: minimum safe wait cycles, errors summed, wait used
`define R_PS_SYR    7'd36   // sync burst read (16 words)
`define R_PS_SYN    7'd39   // sync single-word read
`define R_PS_RW     7'd66   // random read wall clock (command to next command): ns x10, -, MB/s x10
`define R_PS_AW     7'd69   // address-line walk: -, errors, -
// SRAM
`define R_SR_SWEEP  7'd42   // wait sweep: minimum safe wait cycles, errors summed, wait used
`define R_SR_WR     7'd45   // random byte write: ns x10, -, cycles
`define R_SR_RD     7'd48   // random byte read:  ns x10, errors, cycles
// DMA PSRAM -> SDRAM
`define R_DMA_A     7'd51   // async: MB/s x10, errors, cycles
`define R_DMA_S     7'd54   // sync burst
// gates and status
`define R_GATE      7'd57   // PSRAM random read wall clock <= 180 ns and no PSRAM address errors, DMA >= 100 MB/s, scan-out never late (0 pending, 1 pass, 2 fail)
`define R_STATUS    7'd60   // state (0 init, 1 running, 2 done), step number, run count
`define R_CFG       7'd63   // sync enabled, sync latency, timeout flags (63..65)
// APF bridge throughput bench (slot_bench.v, written from the clk_74a domain; the INIT clear leaves these alone)
`define R_SL_BASE   7'd75   // first slot-bench result
`define R_SL_SEQ    7'd75   // sequential: kB/s (FFFFFFFF = no file), worst issue-to-last-byte us, bad requests
`define R_SL_RND    7'd78   // random: same
`define R_SL_SEQX   7'd81   // sequential: worst issue-to-done us, requests done, bytes received
`define R_SL_RNDX   7'd84   // random: same
`define R_SL_FILE   7'd87   // file size in bytes, state (0 idle, 1 running, 2 done, 3 no file, 4 timeout), expected bytes per mode
// SDRAM read-capture calibration (sdram_cal.v, written by memtest_core)
`define R_CAL       7'd90   // eye width (steps), boot centre, flags (bit 0 no eye, 1 eye touches the sweep range, 2 PLL timeout, 3 re-swept)
`define R_CAL_T     7'd93   // tracker: lowest centre, highest centre, centre moves
`define R_COUNT     7'd128

// engine mode codes
`define SDM_SEQ_WR  3'd0
`define SDM_SEQ_RD  3'd1
`define SDM_RND_RD  3'd2
`define SDM_MIXED   3'd3
`define SDM_BE_WR   3'd4   // byte-masked writes in bijective random order over a filled region
`define SDM_BE_RD   3'd5   // sequential read of that region, every byte checked against its mask

`define PSM_FILL    3'd0   // sequential single writes, both dies
`define PSM_RND_RD  3'd1   // random single-word reads, both dies
`define PSM_SEQ_RD  3'd2   // 16-word bursts, die 0
`define PSM_SWEEP   3'd3   // random reads for every wait value
`define PSM_WALK    3'd4   // address-line walk, both dies

`endif
