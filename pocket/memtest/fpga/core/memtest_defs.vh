// PSX memory test core: shared constants and the data pattern. See docs/pocket/MEMTEST.md.
`ifndef MEMTEST_DEFS_VH
`define MEMTEST_DEFS_VH

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
// PSRAM (ganged 32-bit)
`define R_PS_WR     7'd24   // write: ns x10 per word, -, MB/s x10
`define R_PS_RR     7'd27   // random read: ns x10, errors, MB/s x10
`define R_PS_SR     7'd30   // sequential (chained) read
`define R_PS_SWEEP  7'd33   // read wait sweep: minimum safe wait cycles, errors summed, wait used
`define R_PS_SYR    7'd36   // sync burst read (16 words)
`define R_PS_SYN    7'd39   // sync single-word read
// SRAM
`define R_SR_SWEEP  7'd42   // wait sweep: minimum safe wait cycles, errors summed, wait used
`define R_SR_WR     7'd45   // random byte write: ns x10, -, cycles
`define R_SR_RD     7'd48   // random byte read:  ns x10, errors, cycles
// DMA PSRAM -> SDRAM
`define R_DMA_A     7'd51   // async: MB/s x10, errors, cycles
`define R_DMA_S     7'd54   // sync burst
// gates and status
`define R_GATE      7'd57   // PSRAM random read <= 180 ns, DMA >= 100 MB/s, scan-out never late (0 pending, 1 pass, 2 fail)
`define R_STATUS    7'd60   // state (0 init, 1 running, 2 done), step number, run count
`define R_CFG       7'd63   // sync enabled, sync latency, timeout flags (63..65)
`define R_COUNT     7'd128

// engine mode codes
`define SDM_SEQ_WR  3'd0
`define SDM_SEQ_RD  3'd1
`define SDM_RND_RD  3'd2
`define SDM_MIXED   3'd3

`define PSM_FILL    3'd0   // sequential single writes, both dies
`define PSM_RND_RD  3'd1   // random single-word reads, both dies
`define PSM_SEQ_RD  3'd2   // 16-word bursts, die 0
`define PSM_SWEEP   3'd3   // random reads for every wait value

`endif
