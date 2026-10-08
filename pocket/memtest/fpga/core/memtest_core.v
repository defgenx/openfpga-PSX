// Memory test core: controllers, test engines and the sequencer that runs them in order and
// stores the results. The test list and what each number means: docs/pocket/MEMTEST.md.
`include "memtest_defs.vh"
module memtest_core #(
    parameter SD_REG_BITS    = 17,    // SDRAM region: 2^17 bursts = 1 MiB
    parameter SD_RND_LOG2    = 16,    // random / mixed SDRAM operations
    parameter SC_LINES       = 96,    // scan-out lines measured alone
    parameter SC_Y_WRAP      = 480,
    parameter SC_LINE_NUM    = `MT_LINE_NUM,   // scan-out line period = SC_LINE_NUM / SC_LINE_DEN cycles
    parameter SC_LINE_DEN    = `MT_LINE_DEN,   // (400 pixels at 6.3504 MHz)
    parameter PS_REG_BITS    = 19,    // PSRAM words per die filled and read at random: 2^19 = 2 MiB
    parameter PS_SEQ_LOG2    = 16,    // chained-read words
    parameter PS_RND_LOG2    = 14,
    parameter PS_SWEEP_LOG2  = 11,
    parameter DMA_LOG2       = 16,    // DMA length in 32-bit words
    parameter SR_SWEEP_LOG2  = 10,
    parameter SR_N_LOG2      = 16,
    parameter SD_INIT_CYCLES = `MT_SD_INIT,
    parameter WD_BITS        = 26     // per-step watchdog, 2^26 cycles
) (
    input  wire        clk,           // system clock: 101.6064 MHz, 135.4752 MHz in the SDRAM_135 variant
    input  wire        clk_cap,       // clk delayed by half a period (SDRAM read data capture)
    input  wire        rst,
    input  wire [31:0] seed_in,

    // settings (already in the clk domain)
    input  wire        cfg_sync_en,   // also run the PSRAM synchronous burst tests
    input  wire [2:0]  cfg_lc,        // latency counter code for the burst tests
    input  wire [1:0]  cfg_phase,     // sync read sample phase
    input  wire        cfg_loop,      // run again when done (not after a sync run)

    // result store read ports
    input  wire [6:0]  res_ra,
    output wire [32:0] res_rq,
    input  wire        res_clk_b,
    input  wire [6:0]  res_rb,
    output wire [32:0] res_rq_b,
    // writes from the clk_74a domain (slot_bench.v): a change of slot_tog announces one, slot_wa / slot_wd are held stable
    input  wire        slot_tog,
    input  wire [6:0]  slot_wa,
    input  wire [32:0] slot_wd,
    output reg  [1:0]  run_state,     // 0 init, 1 running, 2 done

    // SDRAM
    output wire [12:0] dram_a,
    output wire [1:0]  dram_ba,
    inout  wire [15:0] dram_dq,
    output wire [1:0]  dram_dqm,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_we_n,

    // PSRAM (both chips)
    output wire [21:16] cram_a,
    inout  wire [15:0] cram0_dq,
    inout  wire [15:0] cram1_dq,
    output wire        cram_clk,
    output wire        cram_adv_n,
    output wire        cram_cre,
    output wire        cram_ce0_n,
    output wire        cram_ce1_n,
    output wire        cram_oe_n,
    output wire        cram_we_n,
    output wire        cram0_ub_n, cram0_lb_n,
    output wire        cram1_ub_n, cram1_lb_n,

    // SRAM
    output wire [16:0] sram_a,
    inout  wire [15:0] sram_dq,
    output wire        sram_oe_n,
    output wire        sram_we_n,
    output wire        sram_ub_n,
    output wire        sram_lb_n
);
    `include "memtest_fn.vh"

    localparam [24:0] DST_A = 25'h100000;     // DMA destination, asynchronous run
    localparam [24:0] DST_S = 25'h180000;     // DMA destination, synchronous run
    localparam [24:0] BE_BASE = 25'h080000;   // byte-enable test region, between the main region and the DMA targets
    localparam [31:0] DMA_WORDS = 32'd1 << DMA_LOG2;

    // Waits and windows that are times, not protocol cycle counts, are written in ns (MT_CYC): the same
    // PSRAM and SRAM figures hold at either clock. 5-bit PSRAM and 4-bit SRAM wait fields hold them.
    localparam [4:0] PS_WAIT0 = `MT_CYC(885);    // 88.5 ns: 9 cycles at 101.6 MHz
    localparam [4:0] PS_W_LO  = `MT_CYC(490);    // sweep window 49 ns ...
    localparam [4:0] PS_W_HI  = `MT_CYC(1968);   // ... 197 ns: 5 ... 20 cycles at 101.6 MHz
    localparam [3:0] SR_WAIT0 = `MT_CYC(787);    // 78.7 ns: 8 cycles at 101.6 MHz (sram_test SAFE_W)
    localparam [3:0] SR_W_LO  = `MT_CYC(98);     // 9.8 ns: 1 cycle at 101.6 MHz
    localparam [3:0] SR_W_HI  = `MT_CYC(787);

    // report scaling for this clock, Q20 (the job runner multiplies by them)
    localparam [63:0] K_MBPS = (64'd1048576 * `MT_CLK_HZ + 64'd50000) / 64'd100000;                   // MB/s x10 per byte/cycle
    localparam [63:0] K_NS10 = (64'd10000000000 * 64'd1048576 + `MT_CLK_HZ / 2) / `MT_CLK_HZ;          // ns x10 per cycle
    localparam [63:0] K_US10 = (64'd10000000 * 64'd1048576 + `MT_CLK_HZ / 2) / `MT_CLK_HZ;             // us x10 per cycle

    // ------------------------------------------------------------------ controllers
    reg  rst_eng;                      // engine reset: the sequencer's reset or a step abort, registered

    // SDRAM: arbiter -> controller
    wire        sd_init_done;
    wire        c_valid, c_ready, c_we, c_tag;
    wire [24:0] c_addr;
    wire [63:0] c_wdata;
    wire [7:0]  c_be;
    wire        c_rvalid, c_rtag;
    wire [63:0] c_rdata;

    // port A (selected between the traffic engine and the DMA)
    reg         asel;
    wire        t_req_valid, t_req_we;
    wire [24:0] t_req_addr;
    wire [63:0] t_req_wdata;
    wire [7:0]  t_req_be;
    wire        d_req_valid;
    wire [24:0] d_req_addr;
    wire [63:0] d_req_wdata;
    wire        a_ready;
    wire        a_valid = asel ? d_req_valid : t_req_valid;
    wire        a_we    = asel ? 1'b1 : t_req_we;
    wire [24:0] a_addr  = asel ? d_req_addr : t_req_addr;
    wire [63:0] a_wdata = asel ? d_req_wdata : t_req_wdata;
    wire [7:0]  a_be    = asel ? 8'hFF : t_req_be;
    wire        a_rvalid, b_rvalid;
    wire [63:0] r_data;
    wire        b_valid, b_ready;
    wire [24:0] b_addr;

    sdram_arb arb (
        .clk(clk), .rst(rst_eng),
        .a_valid(a_valid), .a_ready(a_ready), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata), .a_be(a_be),
        .b_valid(b_valid), .b_ready(b_ready), .b_addr(b_addr),
        .a_rvalid(a_rvalid), .b_rvalid(b_rvalid), .r_data(r_data),
        .c_valid(c_valid), .c_ready(c_ready), .c_we(c_we), .c_addr(c_addr), .c_wdata(c_wdata), .c_be(c_be), .c_tag(c_tag),
        .c_rvalid(c_rvalid), .c_rdata(c_rdata), .c_rtag(c_rtag)
    );

    sdram_ctl #(.INIT_CYCLES(SD_INIT_CYCLES)) sdram (
        .clk(clk), .clk_cap(clk_cap), .rst(rst_eng), .init_done(sd_init_done),
        .req_valid(c_valid), .req_ready(c_ready), .req_we(c_we), .req_addr(c_addr),
        .req_wdata(c_wdata), .req_be(c_be), .req_tag(c_tag),
        .rd_valid(c_rvalid), .rd_data(c_rdata), .rd_tag(c_rtag),
        .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n)
    );

    // SDRAM test engine and scan-out
    reg         sd_start, pat_rel;
    reg  [2:0]  sd_mode;
    reg  [31:0] sd_n;
    reg  [24:0] sd_base;
    wire        sd_busy, sd_done;
    wire [31:0] sd_cycles, sd_errors;
    reg  [31:0] seed;

    sd_traffic #(.REG_BITS(SD_REG_BITS)) sdt (
        .clk(clk), .rst(rst_eng), .start(sd_start), .mode(sd_mode), .n_ops(sd_n), .seed(seed),
        .base(sd_base), .pat_rel(pat_rel), .busy(sd_busy), .done(sd_done), .cycles(sd_cycles),
        .errors(sd_errors),
        .req_valid(t_req_valid), .req_ready(a_ready & ~asel), .req_we(t_req_we), .req_addr(t_req_addr),
        .req_wdata(t_req_wdata), .req_be(t_req_be), .rvalid(a_rvalid & ~asel), .rdata(r_data)
    );

    reg         sc_clear, sc_en;
    wire [31:0] sc_lines, sc_late, sc_worst, sc_errors;
    wire        sc_active;
    sd_scan #(.Y_WRAP(SC_Y_WRAP), .LINE_NUM(SC_LINE_NUM), .LINE_DEN(SC_LINE_DEN)) scan (
        .clk(clk), .rst(rst_eng), .clear(sc_clear), .en(sc_en), .seed(seed), .base(25'd0),
        .lines(sc_lines), .late(sc_late), .worst(sc_worst), .errors(sc_errors), .active(sc_active),
        .req_valid(b_valid), .req_ready(b_ready), .req_addr(b_addr),
        .rvalid(b_rvalid), .rdata(r_data)
    );

    // PSRAM
    reg  [1:0]  psel;                         // 0 traffic engine, 1 DMA, 2 configuration
    reg         sync_on;
    wire        pc_valid, pc_ready, pc_we, pc_cfg;
    wire [22:0] pc_addr;
    wire [4:0]  pc_len;
    wire [31:0] pc_wdata;
    wire [3:0]  pc_be;
    wire        pr_valid, pr_done;
    wire [31:0] pr_data;

    wire        pt_valid, pt_we;
    wire [22:0] pt_addr;
    wire [4:0]  pt_len;
    wire [31:0] pt_wdata;
    wire [3:0]  pt_be;
    wire [4:0]  pt_wait;
    wire        pd_valid;
    wire [22:0] pd_addr;
    reg         pcfg_valid;
    reg         pcfg_die;

    assign pc_valid = (psel == 2'd0) ? pt_valid : (psel == 2'd1) ? pd_valid : pcfg_valid;
    assign pc_we    = (psel == 2'd0) ? pt_we : 1'b0;
    assign pc_cfg   = (psel == 2'd2);
    assign pc_addr  = (psel == 2'd0) ? pt_addr : (psel == 2'd1) ? pd_addr : {pcfg_die, 22'd0};
    assign pc_len   = (psel == 2'd0) ? pt_len : (psel == 2'd1) ? 5'd16 : 5'd1;
    assign pc_wdata = pt_wdata;
    assign pc_be    = 4'hF;

    reg  [4:0]  ps_run_wait;
    reg         ps_start;
    reg  [2:0]  ps_mode;
    reg  [31:0] ps_n;
    wire        ps_busy, ps_done, ps_timeout;
    wire [31:0] ps_cycles, ps_bcyc, ps_errors;
    wire [4:0]  ps_min_ok;

    psram32 psram (
        .clk(clk), .rst(rst_eng),
        .cmd_valid(pc_valid), .cmd_ready(pc_ready), .cmd_we(pc_we), .cmd_cfg(pc_cfg), .cmd_addr(pc_addr),
        .cmd_len(pc_len), .cmd_wdata(pc_wdata), .cmd_be(pc_be),
        .sync_mode(sync_on), .rd_wait(pt_wait), .sync_lc(cfg_lc), .sync_phase(cfg_phase),
        .rd_valid(pr_valid), .rd_data(pr_data), .done(pr_done),
        .cram_a(cram_a), .cram0_dq(cram0_dq), .cram1_dq(cram1_dq), .cram_clk(cram_clk),
        .cram_adv_n(cram_adv_n), .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n), .cram_ce1_n(cram_ce1_n),
        .cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n),
        .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n), .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n)
    );

    ps_traffic #(.REG_BITS(PS_REG_BITS)) pst (
        .clk(clk), .rst(rst_eng), .start(ps_start), .mode(ps_mode), .n_ops(ps_n), .seed(seed),
        .run_wait(ps_run_wait), .w_lo(PS_W_LO), .w_hi(PS_W_HI),
        .busy(ps_busy), .done(ps_done), .cycles(ps_cycles), .bcyc(ps_bcyc), .errors(ps_errors), .min_ok(ps_min_ok),
        .timeout(ps_timeout),
        .cmd_valid(pt_valid), .cmd_ready(pc_ready & (psel == 2'd0)), .cmd_we(pt_we), .cmd_addr(pt_addr),
        .cmd_len(pt_len), .cmd_wdata(pt_wdata), .cmd_be(pt_be), .rd_wait(pt_wait),
        .rd_valid(pr_valid), .rd_data(pr_data), .rd_done(pr_done)
    );

    reg         dma_start;
    wire        dma_busy, dma_done, dma_timeout;
    wire [31:0] dma_cycles;
    reg  [24:0] dma_dst;
    dma_eng dma (
        .clk(clk), .rst(rst_eng), .start(dma_start), .n_words(DMA_WORDS), .dst(dma_dst),
        .busy(dma_busy), .done(dma_done), .cycles(dma_cycles), .timeout(dma_timeout),
        .pcmd_valid(pd_valid), .pcmd_ready(pc_ready & (psel == 2'd1)), .pcmd_addr(pd_addr),
        .prd_valid(pr_valid), .prd_data(pr_data), .pdone(pr_done),
        .req_valid(d_req_valid), .req_ready(a_ready & asel), .req_addr(d_req_addr), .req_wdata(d_req_wdata)
    );

    // SRAM
    reg         sr_start;
    reg  [1:0]  sr_mode;
    reg  [31:0] sr_n;
    reg  [3:0]  sr_run_wait;
    wire        sr_busy, sr_done;
    wire [31:0] sr_cycles, sr_bcyc, sr_errors;
    wire [3:0]  sr_min_ok;
    wire        sc_start, sc_we;
    wire [17:0] sc_addr;
    wire [7:0]  sc_wdata, sc_rdata;
    wire [3:0]  sc_wait;
    wire        sc_done;

    sram_test #(.SAFE_W(SR_WAIT0)) srt (
        .clk(clk), .rst(rst_eng), .start(sr_start), .mode(sr_mode), .n_ops(sr_n), .seed(seed),
        .run_wait(sr_run_wait), .w_lo(SR_W_LO), .w_hi(SR_W_HI),
        .busy(sr_busy), .done(sr_done), .cycles(sr_cycles), .bcyc(sr_bcyc), .errors(sr_errors), .min_ok(sr_min_ok),
        .c_start(sc_start), .c_we(sc_we), .c_addr(sc_addr), .c_wdata(sc_wdata), .c_wait(sc_wait),
        .c_done(sc_done), .c_rdata(sc_rdata)
    );
    sram_ctl srm (
        .clk(clk), .rst(rst_eng), .start(sc_start), .we(sc_we), .addr(sc_addr), .wdata(sc_wdata),
        .wait_c(sc_wait), .busy(), .done(sc_done), .rdata(sc_rdata),
        .sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    // ------------------------------------------------------------------ results and divider
    reg         res_we;
    reg  [6:0]  res_wa;
    reg  [32:0] res_wd;
    // slot_bench writes wait for a cycle in which the sequencer does not write
    reg  [2:0]  slot_s = 3'd0;
    reg         slot_pend = 1'b0;
    reg  [6:0]  slot_pa;
    reg  [32:0] slot_pd;
    always @(posedge clk) begin
        slot_s <= {slot_s[1:0], slot_tog};
        if (slot_s[2] != slot_s[1]) begin slot_pend <= 1'b1; slot_pa <= slot_wa; slot_pd <= slot_wd; end
        else if (slot_pend && !res_we) slot_pend <= 1'b0;
    end
    wire slot_wr = slot_pend && !res_we;
    res_ram rres (
        .clk(clk), .we(res_we | slot_wr), .wa(res_we ? res_wa : slot_pa), .wd(res_we ? res_wd : slot_pd), .ra(res_ra), .rq(res_rq),
        .clk_b(res_clk_b), .rb(res_rb), .rq_b(res_rq_b)
    );

    reg         div_start;
    reg  [31:0] div_num, div_den;
    wire        div_done;
    wire [31:0] div_q;
    div32 divider (.clk(clk), .start(div_start), .num(div_num), .den(div_den), .done(div_done), .q(div_q));

    // ------------------------------------------------------------------ sequencer
    localparam ST_INIT = 6'd0, ST_SDSW = 6'd1, ST_SDSR = 6'd2, ST_SDRR = 6'd3, ST_SDMX = 6'd4,
               ST_SCAL = 6'd5, ST_SCMX = 6'd6, ST_PSFILL = 6'd7, ST_PSSWEEP = 6'd8, ST_PSWALK = 6'd9,
               ST_PSRR = 6'd10, ST_PSSR = 6'd11, ST_DMAA = 6'd12, ST_DMAAV = 6'd13, ST_SRSWR = 6'd14,
               ST_SRSWW = 6'd15, ST_SRWR = 6'd16, ST_SRRD = 6'd17, ST_CFG = 6'd18, ST_PSSYR = 6'd19,
               ST_PSSYN = 6'd20, ST_DMAS = 6'd21, ST_DMASV = 6'd22, ST_BEFILL = 6'd23, ST_BEWR = 6'd24,
               ST_BERD = 6'd25, ST_FINAL = 6'd26, ST_END = 6'd27;

    localparam P_WINIT = 4'd0, P_ENTER = 4'd1, P_RUN = 4'd2, P_FILL = 4'd3, P_JOB = 4'd4,
               P_JDIV = 4'd5, P_JWR = 4'd6, P_NEXT = 4'd7, P_END = 4'd8, P_ABORT = 4'd9, P_JCALC = 4'd10,
               P_JGO = 4'd11, P_JMUL = 4'd12, P_SUM = 4'd13;

    localparam JK_RAW = 3'd0, JK_MBPS = 3'd1, JK_NS10 = 3'd2, JK_US10 = 3'd3;

    reg [5:0]  step;
    reg [31:0] so;                      // one-hot copy of step: the decodes are registers, not comparators
    reg [3:0]  ph;
    reg [2:0]  sub;
    reg [WD_BITS:0] swd;
    reg [6:0]  cnt;
    reg [6:0]  clr;
    reg [1:0]  abort_cnt;

    reg [6:0]  j_idx [0:7];
    reg [2:0]  j_kind [0:7];
    reg [31:0] j_a [0:7];
    reg [31:0] j_b [0:7];
    reg [3:0]  jn, ji;
    reg [31:0] value;

    reg        c_sync_en, c_loop;
    reg [31:0] run_count;
    reg [31:0] to_flags;                // bit n: step n did not finish (bits 8 to 10 also flag PSRAM fill and DMA timeouts)

    // shadows used by later steps and the gates
    reg [31:0] dma_cyc_a, dma_cyc_s, dma_to_a, dma_to_s;
    reg [3:0]  sr_min_rd;
    reg [31:0] sr_err1;
    reg [31:0] g_rr_ns, g_rr_err, g_aw_err, g_dma_a, g_dma_ae, g_dma_s, g_dma_se, g_late_a, g_late_m, g_scerr, g_sderr;
    reg        g_rr_v, g_dma_av, g_dma_sv, g_sc_v;

    // sums of engine counters, registered before the job table is filled
    reg  [31:0] s_sderr, s_scerr, s_sr, s_dmaa, s_dmas, s_rc1;

    // job arithmetic: the job table entry is registered, then multiplied by the clock constant (shift-add,
    // 32 cycles), then divided for MB/s and ns
    reg  [2:0]  jk;
    reg  [6:0]  jidx;
    reg  [31:0] ja, jb;
    reg  [63:0] m_a, macc;
    reg  [31:0] m_k;
    reg  [5:0]  m_n;
    wire [43:0] mprod = macc[63:20];

    function [5:0] next_step;
        input [5:0] s;
        input       sync_en;
        begin
            case (s)
                ST_SRRD: next_step = sync_en ? ST_CFG : ST_BEFILL;
                ST_DMASV: next_step = ST_BEFILL;
                ST_BERD: next_step = ST_FINAL;
                ST_FINAL: next_step = ST_END;
                default: next_step = s + 6'd1;
            endcase
        end
    endfunction

    // The job table is filled one slot per cycle through shared registers (jj_*), so the selection by step
    // is one multiplexer per field instead of one per table entry: slot fp is selected in cycle fp and
    // written to the table in the next one.
    reg  [3:0]  fp;
    reg  [6:0]  fk;                     // one-hot slot being selected
    // two such sets, one per group of steps, merged when the slot is written
    reg  [6:0]  jj_idx, jj2_idx;
    reg  [2:0]  jj_kind, jj2_kind;
    reg  [31:0] jj_a, jj_b, jj2_a, jj2_b;
    task setj;
        input [2:0] k;
        input [6:0] idx;
        input [2:0] kind;
        input [31:0] a;
        input [31:0] b;
        begin
            if (fk[k]) begin jj_idx <= idx; jj_kind <= kind; jj_a <= a; jj_b <= b; end
        end
    endtask
    task setj2;
        input [2:0] k;
        input [6:0] idx;
        input [2:0] kind;
        input [31:0] a;
        input [31:0] b;
        begin
            if (fk[k]) begin jj2_idx <= idx; jj2_kind <= kind; jj2_a <= a; jj2_b <= b; end
        end
    endtask

    wire step_sd   = (so[ST_SDSW]) || (so[ST_SDSR]) || (so[ST_SDRR]) || (so[ST_SDMX]) ||
                     (so[ST_DMAAV]) || (so[ST_DMASV]) || (so[ST_BEFILL]) || (so[ST_BEWR]) || (so[ST_BERD]);
    wire step_ps   = (so[ST_PSFILL]) || (so[ST_PSSWEEP]) || (so[ST_PSWALK]) || (so[ST_PSRR]) || (so[ST_PSSR]) ||
                     (so[ST_PSSYR]) || (so[ST_PSSYN]);
    wire step_dma  = (so[ST_DMAA]) || (so[ST_DMAS]);
    wire step_sr   = (so[ST_SRSWR]) || (so[ST_SRSWW]) || (so[ST_SRWR]) || (so[ST_SRRD]);

    // done condition of the running step
    reg step_done;
    always @(*) begin
        step_done = 1'b0;
        if (step_sd)  step_done = sd_done;
        if (step_ps)  step_done = ps_done;
        if (step_dma) step_done = dma_done;
        if (step_sr)  step_done = sr_done;
        if (so[ST_SCAL] || so[ST_SCMX]) step_done = (sub == 3'd2) && !sc_active;
        if (so[ST_CFG]) step_done = (sub == 3'd4);
        if (so[ST_INIT]) step_done = (sub == 3'd1) && sd_init_done;
        if (so[ST_FINAL]) step_done = 1'b1;
    end

    always @(posedge clk) begin
        sd_start <= 1'b0; ps_start <= 1'b0; dma_start <= 1'b0; sr_start <= 1'b0; sc_clear <= 1'b0;
        div_start <= 1'b0; res_we <= 1'b0;
        if (abort_cnt != 0) abort_cnt <= abort_cnt - 1'b1;
        rst_eng <= rst | (abort_cnt != 0);

        if (rst) begin
            step <= ST_INIT; so <= 32'd1 << ST_INIT; ph <= P_ENTER; sub <= 3'd0; run_state <= 2'd0; sc_en <= 1'b0; sync_on <= 1'b0;
            asel <= 1'b0; psel <= 2'd0; pcfg_valid <= 1'b0; pat_rel <= 1'b0; sd_base <= 25'd0;
            ps_run_wait <= PS_WAIT0; sr_run_wait <= SR_WAIT0; run_count <= 32'd0; to_flags <= 32'd0;
            abort_cnt <= 2'd0; seed <= seed_in; c_sync_en <= cfg_sync_en; c_loop <= cfg_loop;
            g_rr_v <= 1'b0; g_dma_av <= 1'b0; g_dma_sv <= 1'b0; g_sc_v <= 1'b0;
            g_rr_ns <= 32'd0; g_rr_err <= 32'd0; g_aw_err <= 32'd0; g_dma_a <= 32'd0; g_dma_ae <= 32'd0; g_dma_s <= 32'd0;
            g_dma_se <= 32'd0; g_late_a <= 32'd0; g_late_m <= 32'd0; g_scerr <= 32'd0; g_sderr <= 32'd0;
        end else begin
            case (ph)
                // ---------------------------------------------------------- start of a step
                P_ENTER: begin
                    swd <= 0; sub <= 3'd0; cnt <= 7'd0; clr <= 7'd0;
                    ph <= P_RUN;
                    sc_en <= 1'b0;
                    case (1'b1)   // synthesis parallel_case
                        so[ST_INIT]: begin
                            c_sync_en <= cfg_sync_en; c_loop <= cfg_loop; sync_on <= 1'b0;
                            ps_run_wait <= PS_WAIT0; sr_run_wait <= SR_WAIT0; to_flags <= 32'd0;
                            g_rr_v <= 1'b0; g_dma_av <= 1'b0; g_dma_sv <= 1'b0; g_sc_v <= 1'b0; g_aw_err <= 32'd0;
                            g_late_a <= 32'd0; g_late_m <= 32'd0; g_scerr <= 32'd0; g_sderr <= 32'd0;
                        end
                        so[ST_SDSW]: begin sd_start <= 1'b1; sd_mode <= `SDM_SEQ_WR; sd_n <= 32'd1 << SD_REG_BITS; asel <= 1'b0; pat_rel <= 1'b0; sd_base <= 25'd0; end
                        so[ST_SDSR]: begin sd_start <= 1'b1; sd_mode <= `SDM_SEQ_RD; sd_n <= 32'd1 << SD_REG_BITS; end
                        so[ST_SDRR]: begin sd_start <= 1'b1; sd_mode <= `SDM_RND_RD; sd_n <= 32'd1 << SD_RND_LOG2; end
                        so[ST_SDMX]: begin sd_start <= 1'b1; sd_mode <= `SDM_MIXED;  sd_n <= 32'd1 << SD_RND_LOG2; end
                        so[ST_SCAL]: sc_clear <= 1'b1;
                        so[ST_SCMX]: begin sc_clear <= 1'b1; sd_start <= 1'b1; sd_mode <= `SDM_MIXED; sd_n <= 32'd1 << SD_RND_LOG2; end
                        so[ST_PSFILL]: begin ps_start <= 1'b1; ps_mode <= `PSM_FILL; ps_n <= 32'd1 << PS_REG_BITS; psel <= 2'd0; end
                        so[ST_PSSWEEP]: begin ps_start <= 1'b1; ps_mode <= `PSM_SWEEP; ps_n <= 32'd1 << PS_SWEEP_LOG2; psel <= 2'd0; end
                        so[ST_PSWALK]: begin ps_start <= 1'b1; ps_mode <= `PSM_WALK; ps_n <= 32'd0; psel <= 2'd0; end
                        so[ST_PSRR], so[ST_PSSYN]: begin ps_start <= 1'b1; ps_mode <= `PSM_RND_RD; ps_n <= 32'd1 << PS_RND_LOG2; psel <= 2'd0; end
                        so[ST_PSSR], so[ST_PSSYR]: begin ps_start <= 1'b1; ps_mode <= `PSM_SEQ_RD; ps_n <= 32'd1 << PS_SEQ_LOG2; psel <= 2'd0; end
                        so[ST_DMAA]: begin dma_start <= 1'b1; dma_dst <= DST_A; asel <= 1'b1; psel <= 2'd1; end
                        so[ST_DMAS]: begin dma_start <= 1'b1; dma_dst <= DST_S; asel <= 1'b1; psel <= 2'd1; end
                        so[ST_DMAAV]: begin sd_start <= 1'b1; sd_mode <= `SDM_SEQ_RD; sd_n <= DMA_WORDS / 2; sd_base <= DST_A; pat_rel <= 1'b1; asel <= 1'b0; psel <= 2'd0; end
                        so[ST_DMASV]: begin sd_start <= 1'b1; sd_mode <= `SDM_SEQ_RD; sd_n <= DMA_WORDS / 2; sd_base <= DST_S; pat_rel <= 1'b1; asel <= 1'b0; psel <= 2'd0; end
                        so[ST_BEFILL]: begin sd_start <= 1'b1; sd_mode <= `SDM_SEQ_WR; sd_n <= 32'd1 << SD_REG_BITS; sd_base <= BE_BASE; pat_rel <= 1'b0; asel <= 1'b0; psel <= 2'd0; end
                        so[ST_BEWR]:   begin sd_start <= 1'b1; sd_mode <= `SDM_BE_WR;  sd_n <= 32'd1 << SD_REG_BITS; end
                        so[ST_BERD]:   begin sd_start <= 1'b1; sd_mode <= `SDM_BE_RD;  sd_n <= 32'd1 << SD_REG_BITS; end
                        so[ST_SRSWR]: begin sr_start <= 1'b1; sr_mode <= 2'd2; sr_n <= 32'd1 << SR_SWEEP_LOG2; end
                        so[ST_SRSWW]: begin sr_start <= 1'b1; sr_mode <= 2'd3; sr_n <= 32'd1 << SR_SWEEP_LOG2; end
                        so[ST_SRWR]:  begin sr_start <= 1'b1; sr_mode <= 2'd0; sr_n <= 32'd1 << SR_N_LOG2; end
                        so[ST_SRRD]:  begin sr_start <= 1'b1; sr_mode <= 2'd1; sr_n <= 32'd1 << SR_N_LOG2; end
                        so[ST_CFG]: psel <= 2'd2;
                        default: ;
                    endcase
                end

                // ---------------------------------------------------------- wait for the step
                P_RUN: begin
                    swd <= swd + 1'b1;
                    // sub-sequences
                    case (1'b1)   // synthesis parallel_case
                        so[ST_INIT]: begin
                            if (sub == 3'd0) begin
                                // clear the result store, then wait for the SDRAM
                                res_we <= (clr < `R_SL_BASE); res_wa <= clr; res_wd <= 33'd0; clr <= clr + 1'b1;
                                if (clr == 7'd127) sub <= 3'd1;
                                run_state <= 2'd1;
                            end
                        end
                        so[ST_SCAL]: begin
                            if (sub == 3'd0) begin sc_en <= 1'b1; sub <= 3'd1; end
                            else if (sub == 3'd1 && sc_lines >= SC_LINES) begin sc_en <= 1'b0; sub <= 3'd2; end
                        end
                        so[ST_SCMX]: begin
                            if (sub == 3'd0) begin sc_en <= 1'b1; sub <= 3'd1; end
                            else if (sub == 3'd1 && sd_done) begin sc_en <= 1'b0; sub <= 3'd2; end
                        end
                        so[ST_CFG]: begin
                            // write the bus configuration register of both dies, then switch to sync reads
                            case (sub)
                                3'd0: begin pcfg_valid <= 1'b1; pcfg_die <= cnt[0]; sub <= 3'd1; end
                                3'd1: if (pcfg_valid && pc_ready) begin pcfg_valid <= 1'b0; sub <= 3'd2; end
                                3'd2: if (pr_done) begin
                                    cnt <= cnt + 1'b1;
                                    sub <= (cnt[0]) ? 3'd3 : 3'd0;
                                end
                                3'd3: begin cnt <= cnt + 1'b1; if (cnt[6]) begin sync_on <= 1'b1; sub <= 3'd4; end end
                                default: ;
                            endcase
                        end
                        default: ;
                    endcase

                    if (step_done) ph <= P_SUM;
                    else if (swd[WD_BITS]) begin
                        // the step did not finish: reset the engines and move on without results
                        to_flags[step[4:0]] <= 1'b1;
                        abort_cnt <= 2'd3; ph <= P_ABORT; cnt <= 7'd0;
                    end
                end

                P_ABORT: begin
                    // wait for the SDRAM controller to initialize again
                    if (abort_cnt == 0 && sd_init_done) begin
                        sc_en <= 1'b0; ph <= P_NEXT;
                    end
                end

                // ---------------------------------------------------------- results of the step
                P_SUM: begin
                    s_sderr <= g_sderr + sd_errors; s_scerr <= g_scerr + sc_errors; s_sr <= sr_err1 + sr_errors;
                    s_dmaa <= sd_errors + dma_to_a; s_dmas <= sd_errors + dma_to_s; s_rc1 <= run_count + 32'd1;
                    fp <= 4'd0; fk <= 7'd1; ph <= P_FILL;
                end
                P_FILL: begin
                    ji <= 4'd0; jn <= 4'd0;
                    fp <= fp + 1'b1; fk <= {fk[5:0], 1'b0};
                    jj_idx <= 7'd0; jj_kind <= 3'd0; jj_a <= 32'd0; jj_b <= 32'd0;       // a group that does not own
                    jj2_idx <= 7'd0; jj2_kind <= 3'd0; jj2_a <= 32'd0; jj2_b <= 32'd0;   // the step leaves zeros
                    if (fp != 4'd0) begin
                        j_idx[fp[2:0] - 1'b1] <= jj_idx | jj2_idx; j_kind[fp[2:0] - 1'b1] <= jj_kind | jj2_kind;
                        j_a[fp[2:0] - 1'b1] <= jj_a | jj2_a; j_b[fp[2:0] - 1'b1] <= jj_b | jj2_b;
                    end
                    if (fp == 4'd7) ph <= P_JOB;
                    case (1'b1)   // synthesis parallel_case
                        so[ST_INIT]: begin
                            if (fp == 4'd0) seed <= (run_count == 0) ? seed_in : xs32(seed);   // once, not once per slot
                            setj(0, `R_STATUS + 0, JK_RAW, 32'd1, 0);
                            setj(1, `R_CFG + 0, JK_RAW, {31'd0, cfg_sync_en}, 0);
                            setj(2, `R_CFG + 1, JK_RAW, {29'd0, cfg_lc}, 0);
                            jn <= 4'd3;
                        end
                        so[ST_SDSW]: begin
                            setj(0, `R_SD_SW + 0, JK_MBPS, 32'd8 << SD_REG_BITS, sd_cycles);
                            setj(1, `R_SD_SW + 2, JK_RAW, sd_cycles, 0);
                            jn <= 4'd2;
                        end
                        so[ST_SDSR]: begin
                            setj(0, `R_SD_SR + 0, JK_MBPS, 32'd8 << SD_REG_BITS, sd_cycles);
                            setj(1, `R_SD_SR + 1, JK_RAW, sd_errors, 0);
                            setj(2, `R_SD_SR + 2, JK_RAW, sd_cycles, 0);
                            jn <= 4'd3; g_sderr <= s_sderr;
                        end
                        so[ST_SDRR]: begin
                            setj(0, `R_SD_RR + 0, JK_MBPS, 32'd8 << SD_RND_LOG2, sd_cycles);
                            setj(1, `R_SD_RR + 1, JK_RAW, sd_errors, 0);
                            setj(2, `R_SD_RR + 2, JK_RAW, sd_cycles, 0);
                            jn <= 4'd3; g_sderr <= s_sderr;
                        end
                        so[ST_SDMX]: begin
                            setj(0, `R_SD_MX + 0, JK_MBPS, 32'd8 << SD_RND_LOG2, sd_cycles);
                            setj(1, `R_SD_MX + 1, JK_RAW, sd_errors, 0);
                            setj(2, `R_SD_MX + 2, JK_RAW, sd_cycles, 0);
                            jn <= 4'd3; g_sderr <= s_sderr;
                        end
                        so[ST_SCAL]: begin
                            setj(0, `R_SC_ALONE + 0, JK_RAW, sc_late, 0);
                            setj(1, `R_SC_ALONE + 1, JK_US10, sc_worst, 0);
                            setj(2, `R_SC_ALONE + 2, JK_RAW, sc_lines, 0);
                            setj(3, `R_SC_ERR + 0, JK_RAW, sc_errors, 0);
                            jn <= 4'd4; g_late_a <= sc_late; g_scerr <= s_scerr; g_sc_v <= 1'b1;
                        end
                        so[ST_SCMX]: begin
                            setj(0, `R_SD_MXS + 0, JK_MBPS, 32'd8 << SD_RND_LOG2, sd_cycles);
                            setj(1, `R_SD_MXS + 1, JK_RAW, sd_errors, 0);
                            setj(2, `R_SD_MXS + 2, JK_RAW, sd_cycles, 0);
                            setj(3, `R_SC_MIX + 0, JK_RAW, sc_late, 0);
                            setj(4, `R_SC_MIX + 1, JK_US10, sc_worst, 0);
                            setj(5, `R_SC_MIX + 2, JK_RAW, sc_lines, 0);
                            setj(6, `R_SC_ERR + 1, JK_RAW, sc_errors, 0);
                            jn <= 4'd7; g_late_m <= sc_late; g_scerr <= s_scerr; g_sderr <= s_sderr;
                        end
                        so[ST_DMAAV]: begin
                            setj(0, `R_DMA_A + 0, JK_MBPS, 32'd4 * DMA_WORDS, dma_cyc_a);
                            setj(1, `R_DMA_A + 1, JK_RAW, s_dmaa, 0);
                            setj(2, `R_DMA_A + 2, JK_RAW, dma_cyc_a, 0);
                            jn <= 4'd3; g_dma_av <= 1'b1; g_dma_ae <= s_dmaa;
                        end
                        so[ST_DMASV]: begin
                            setj(0, `R_DMA_S + 0, JK_MBPS, 32'd4 * DMA_WORDS, dma_cyc_s);
                            setj(1, `R_DMA_S + 1, JK_RAW, s_dmas, 0);
                            setj(2, `R_DMA_S + 2, JK_RAW, dma_cyc_s, 0);
                            jn <= 4'd3; g_dma_sv <= 1'b1; g_dma_se <= s_dmas;
                        end
                        so[ST_BEWR]: begin setj(0, `R_SD_BE + 0, JK_MBPS, 32'd8 << SD_REG_BITS, sd_cycles); jn <= 4'd1; end
                        so[ST_BERD]: begin
                            setj(0, `R_SD_BE + 1, JK_RAW, sd_errors, 0);
                            setj(1, `R_SD_BE + 2, JK_RAW, sd_cycles, 0);
                            jn <= 4'd2; g_sderr <= s_sderr;
                        end
                        default: ;
                    endcase
                    case (1'b1)   // synthesis parallel_case
                        so[ST_PSFILL]: begin
                            setj2(0, `R_PS_WR + 0, JK_NS10, ps_bcyc, 32'd2 << PS_REG_BITS);
                            setj2(1, `R_PS_WR + 2, JK_MBPS, 32'd8 << PS_REG_BITS, ps_bcyc);
                            jn <= 4'd2;
                            if (ps_timeout) to_flags[8] <= 1'b1;
                        end
                        so[ST_PSSWEEP]: begin
                            setj2(0, `R_PS_SWEEP + 0, JK_RAW, {27'd0, ps_min_ok}, 0);
                            setj2(1, `R_PS_SWEEP + 1, JK_RAW, ps_errors, 0);
                            setj2(2, `R_PS_SWEEP + 2, JK_RAW, {27'd0, ps_min_ok} + 32'd1, 0);
                            jn <= 4'd3;
                            ps_run_wait <= ps_min_ok + 5'd1;
                        end
                        so[ST_PSWALK]: begin
                            setj2(0, `R_PS_AW + 1, JK_RAW, ps_errors, 0);
                            jn <= 4'd1; g_aw_err <= ps_errors;
                        end
                        so[ST_PSRR]: begin
                            setj2(0, `R_PS_RR + 0, JK_NS10, ps_bcyc, 32'd1 << PS_RND_LOG2);
                            setj2(1, `R_PS_RR + 1, JK_RAW, ps_errors, 0);
                            setj2(2, `R_PS_RR + 2, JK_MBPS, 32'd4 << PS_RND_LOG2, ps_bcyc);
                            setj2(3, `R_PS_RW + 0, JK_NS10, ps_cycles, 32'd1 << PS_RND_LOG2);
                            setj2(4, `R_PS_RW + 2, JK_MBPS, 32'd4 << PS_RND_LOG2, ps_cycles);
                            jn <= 4'd5;
                            g_rr_v <= 1'b1; g_rr_err <= ps_errors; g_rr_ns <= 32'd0; // ns set by the job writer
                        end
                        so[ST_PSSR]: begin
                            setj2(0, `R_PS_SR + 0, JK_NS10, ps_bcyc, 32'd1 << PS_SEQ_LOG2);
                            setj2(1, `R_PS_SR + 1, JK_RAW, ps_errors, 0);
                            setj2(2, `R_PS_SR + 2, JK_MBPS, 32'd4 << PS_SEQ_LOG2, ps_bcyc);
                            jn <= 4'd3;
                        end
                        so[ST_PSSYR]: begin
                            setj2(0, `R_PS_SYR + 0, JK_NS10, ps_bcyc, 32'd1 << PS_SEQ_LOG2);
                            setj2(1, `R_PS_SYR + 1, JK_RAW, ps_errors, 0);
                            setj2(2, `R_PS_SYR + 2, JK_MBPS, 32'd4 << PS_SEQ_LOG2, ps_bcyc);
                            jn <= 4'd3;
                        end
                        so[ST_PSSYN]: begin
                            setj2(0, `R_PS_SYN + 0, JK_NS10, ps_bcyc, 32'd1 << PS_RND_LOG2);
                            setj2(1, `R_PS_SYN + 1, JK_RAW, ps_errors, 0);
                            setj2(2, `R_PS_SYN + 2, JK_MBPS, 32'd4 << PS_RND_LOG2, ps_bcyc);
                            jn <= 4'd3;
                        end
                        so[ST_DMAA]: begin dma_cyc_a <= dma_cycles; dma_to_a <= {31'd0, dma_timeout}; if (dma_timeout) to_flags[9] <= 1'b1; end
                        so[ST_DMAS]: begin dma_cyc_s <= dma_cycles; dma_to_s <= {31'd0, dma_timeout}; if (dma_timeout) to_flags[10] <= 1'b1; end
                        so[ST_SRSWR]: begin sr_min_rd <= sr_min_ok; sr_err1 <= sr_errors; end
                        so[ST_SRSWW]: begin
                            setj2(0, `R_SR_SWEEP + 0, JK_RAW, {28'd0, sr_min_rd}, 0);
                            setj2(1, `R_SR_SWEEP + 1, JK_RAW, {28'd0, sr_min_ok}, 0);
                            setj2(2, `R_SR_SWEEP + 2, JK_RAW, s_sr, 0);
                            jn <= 4'd3;
                            sr_run_wait <= sr_min_ok + 4'd1;   // used by the write test; the read test sets its own
                        end
                        so[ST_SRWR]: begin
                            setj2(0, `R_SR_WR + 0, JK_NS10, sr_bcyc, 32'd1 << SR_N_LOG2);
                            setj2(1, `R_SR_WR + 2, JK_RAW, sr_cycles, 0);
                            jn <= 4'd2;
                            sr_run_wait <= sr_min_rd + 4'd1;
                        end
                        so[ST_SRRD]: begin
                            setj2(0, `R_SR_RD + 0, JK_NS10, sr_bcyc, 32'd1 << SR_N_LOG2);
                            setj2(1, `R_SR_RD + 1, JK_RAW, sr_errors, 0);
                            setj2(2, `R_SR_RD + 2, JK_RAW, sr_cycles, 0);
                            jn <= 4'd3;
                        end
                        so[ST_FINAL]: begin
                            // gates: 0 pending, 1 pass, 2 fail
                            setj2(0, `R_GATE + 0, JK_RAW,
                                 !g_rr_v ? 32'd0 : (g_rr_err == 0 && g_aw_err == 0 && g_rr_ns <= 32'd1800) ? 32'd1 : 32'd2, 0);
                            setj2(1, `R_GATE + 1, JK_RAW,
                                 (!g_dma_av && !g_dma_sv) ? 32'd0 :
                                 ((g_dma_av && g_dma_ae == 0 && g_dma_a >= 32'd1000) ||
                                  (g_dma_sv && g_dma_se == 0 && g_dma_s >= 32'd1000)) ? 32'd1 : 32'd2, 0);
                            setj2(2, `R_GATE + 2, JK_RAW,
                                 !g_sc_v ? 32'd0 :
                                 (g_late_a == 0 && g_late_m == 0 && g_scerr == 0 && g_sderr == 0) ? 32'd1 : 32'd2, 0);
                            setj2(3, `R_STATUS + 0, JK_RAW, 32'd2, 0);
                            setj2(4, `R_STATUS + 2, JK_RAW, s_rc1, 0);
                            setj2(5, `R_CFG + 2, JK_RAW, to_flags, 0);
                            jn <= 4'd6;
                            run_state <= 2'd2;
                        end
                        default: ;
                    endcase
                end

                // ---------------------------------------------------------- job runner
                P_JOB: begin
                    if (ji == jn) ph <= P_NEXT;
                    else begin
                        jk <= j_kind[ji]; ja <= j_a[ji]; jb <= j_b[ji]; jidx <= j_idx[ji]; ph <= P_JCALC;
                    end
                end
                P_JCALC: begin
                    m_a <= {32'd0, ja}; macc <= 64'd0; m_n <= 6'd0;
                    case (jk)
                        JK_MBPS: begin m_k <= K_MBPS[31:0]; ph <= P_JMUL; end
                        JK_US10: begin m_k <= K_US10[31:0]; ph <= P_JMUL; end
                        JK_NS10: begin m_k <= K_NS10[31:0]; ph <= P_JMUL; end
                        default: begin value <= ja; ph <= P_JWR; end
                    endcase
                end
                P_JMUL: begin
                    if (m_k[0]) macc <= macc + m_a;
                    m_a <= {m_a[62:0], 1'b0}; m_k <= {1'b0, m_k[31:1]};
                    m_n <= m_n + 1'b1;
                    if (m_n == 6'd31) ph <= P_JGO;
                end
                P_JGO: begin
                    if (jk == JK_US10) begin value <= mprod[31:0]; ph <= P_JWR; end
                    else begin
                        div_num <= (mprod[43:32] != 0) ? 32'hFFFFFFFF : mprod[31:0];
                        div_den <= jb; div_start <= 1'b1; ph <= P_JDIV;
                    end
                end
                P_JDIV: if (div_done) begin value <= div_q; ph <= P_JWR; end
                P_JWR: begin
                    res_we <= 1'b1; res_wa <= jidx; res_wd <= {1'b1, value};
                    ji <= ji + 1'b1; ph <= P_JOB;
                    case (jidx)
                        `R_PS_RW + 0: g_rr_ns <= value;
                        `R_DMA_A + 0: g_dma_a <= value;
                        `R_DMA_S + 0: g_dma_s <= value;
                        default: ;
                    endcase
                end

                P_NEXT: begin
                    // status: number of the last finished step
                    res_we <= 1'b1; res_wa <= `R_STATUS + 1; res_wd <= {1'b1, 26'd0, step};
                    if (so[ST_FINAL]) begin
                        step <= ST_END; so <= 32'd1 << ST_END; ph <= P_END;
                    end else begin
                        step <= next_step(step, c_sync_en); so <= 32'd1 << next_step(step, c_sync_en); ph <= P_ENTER;
                    end
                end

                P_END: begin
                    // finished: loop when asked to and the PSRAM is still asynchronous
                    sc_en <= 1'b0;
                    if (c_loop && !sync_on) begin
                        run_count <= run_count + 1'b1;
                        step <= ST_INIT; so <= 32'd1 << ST_INIT; ph <= P_ENTER;
                    end
                end
                default: ph <= P_ENTER;
            endcase
        end
    end

endmodule
