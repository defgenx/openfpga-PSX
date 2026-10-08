// Both PSRAM chips ganged as one 32-bit memory (same control, 16 data bits each).
// Asynchronous single and chained reads, single writes, and an optional synchronous
// burst read at half the system clock. Cycle counts are explained in docs/pocket/MEMTEST.md.
`include "memtest_defs.vh"
module psram32 #(
    parameter ADV_C  = 1,      // ADV# low cycles
    parameter AH     = 1,      // address hold after ADV# rises
    parameter DOFF   = 2,      // cycles from address release to write data
    parameter WR_END = `MT_CYC(780) // write cycle length: 78 ns, 8 cycles at 101.6 MHz (tAW and tWC are 70 ns)
) (
    input  wire        clk,
    input  wire        rst,

    // command, 32-bit word address: [22] selects the die, [21:0] the word in the die
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire        cmd_we,
    input  wire        cmd_cfg,         // write the bus configuration register of the selected die
    input  wire [22:0] cmd_addr,
    input  wire [4:0]  cmd_len,         // words for reads, 1..16
    input  wire [31:0] cmd_wdata,
    input  wire [3:0]  cmd_be,

    input  wire        sync_mode,       // reads use the synchronous burst protocol
    input  wire [4:0]  rd_wait,         // async read: cycles from address to sample
    input  wire [2:0]  sync_lc,         // latency counter code programmed into the device
    input  wire [1:0]  sync_phase,      // sync read: cycles after the clock edge to sample

    output reg         rd_valid,
    output reg  [31:0] rd_data,
    output reg         done,

    // pins (control shared by both chips)
    output reg  [21:16] cram_a,
    inout  wire [15:0] cram0_dq,
    inout  wire [15:0] cram1_dq,
    output reg         cram_clk,
    output reg         cram_adv_n,
    output reg         cram_cre,
    output reg         cram_ce0_n,
    output reg         cram_ce1_n,
    output reg         cram_oe_n,
    output reg         cram_we_n,
    output reg         cram0_ub_n, cram0_lb_n,
    output reg         cram1_ub_n, cram1_lb_n
);
    localparam IDLE = 2'd0, RUN = 2'd1, FIN = 2'd2;

    reg [1:0]  st;
    reg        c_we, c_cfg, c_sync;
    reg [22:0] c_addr;
    reg [4:0]  c_len, c_n;
    reg [31:0] c_wdata;
    reg [3:0]  c_be;
    reg [6:0]  s;
    reg [6:0]  next_sample;
    reg [4:0]  c_wait;
    reg [2:0]  c_lc;
    reg [1:0]  c_ph;
    reg        first;

    reg [15:0] dq0_out, dq1_out;
    reg        dq_oe;
    assign cram0_dq = dq_oe ? dq0_out : 16'hzzzz;
    assign cram1_dq = dq_oe ? dq1_out : 16'hzzzz;

    // Bus configuration register: synchronous, fixed latency, 16-word bursts, no wrap.
    // Bit layout from the CellularRAM register description; see MEMTEST.md.
    wire [15:0] bcr = {1'b0, 1'b1, c_lc, 1'b1, 1'b0, 1'b1, 2'b00, 2'b01, 1'b1, 3'b011};

    assign cmd_ready = (st == IDLE);

    wire [21:0] w_addr = c_addr[21:0];

    // synchronous read schedule (all in cycles from the command edge)
    wire [6:0] s_first = 7'd1 + {3'd0, c_lc, 1'b0} + {5'd0, c_ph};
    wire [5:0] xl      = {3'd0, c_lc} + {1'b0, c_len} - 6'd1;
    wire [6:0] s_lastrise = 7'd1 + {xl, 1'b0};

    always @(posedge clk) begin
        rd_valid <= 1'b0;
        done     <= 1'b0;
        if (rst) begin
            st <= IDLE; cram_clk <= 1'b0; cram_adv_n <= 1'b1; cram_cre <= 1'b0;
            cram_ce0_n <= 1'b1; cram_ce1_n <= 1'b1; cram_oe_n <= 1'b1; cram_we_n <= 1'b1;
            cram0_ub_n <= 1'b1; cram0_lb_n <= 1'b1; cram1_ub_n <= 1'b1; cram1_lb_n <= 1'b1;
            dq_oe <= 1'b0; cram_a <= 6'd0;
        end else begin
            case (st)
                IDLE: begin
                    if (cmd_valid) begin
                        st <= RUN; s <= 7'd0; first <= 1'b1; c_n <= 5'd0;
                        c_we <= cmd_we; c_cfg <= cmd_cfg; c_addr <= cmd_addr; c_len <= cmd_len;
                        c_wdata <= cmd_wdata; c_be <= cmd_be; c_wait <= rd_wait; c_lc <= sync_lc;
                        c_ph <= sync_phase; c_sync <= sync_mode & ~cmd_we & ~cmd_cfg;
                    end
                end

                RUN: begin
                    s <= s + 1'b1;
                    if (c_we || c_cfg) begin
                        // ---------------- asynchronous write ----------------
                        case (s)
                            7'd0: begin
                                if (c_addr[22]) cram_ce1_n <= 1'b0; else cram_ce0_n <= 1'b0;
                                cram_a <= c_cfg ? 6'b001000 : w_addr[21:16];
                                {dq1_out, dq0_out} <= c_cfg ? {bcr, bcr} : {2{w_addr[15:0]}};
                                dq_oe <= 1'b1; cram_adv_n <= 1'b0; cram_we_n <= 1'b0; cram_cre <= c_cfg;
                                cram0_lb_n <= c_cfg ? 1'b0 : ~c_be[0]; cram0_ub_n <= c_cfg ? 1'b0 : ~c_be[1];
                                cram1_lb_n <= c_cfg ? 1'b0 : ~c_be[2]; cram1_ub_n <= c_cfg ? 1'b0 : ~c_be[3];
                            end
                            ADV_C: cram_adv_n <= 1'b1;
                            ADV_C + AH: dq_oe <= 1'b0;
                            ADV_C + AH + DOFF: begin
                                dq0_out <= c_wdata[15:0]; dq1_out <= c_wdata[31:16]; dq_oe <= 1'b1;
                            end
                            WR_END: begin
                                cram_we_n <= 1'b1; cram_ce0_n <= 1'b1; cram_ce1_n <= 1'b1; dq_oe <= 1'b0;
                                cram_cre <= 1'b0;
                                st <= FIN;
                            end
                            default: ;
                        endcase
                    end else if (!c_sync) begin
                        // ---------------- asynchronous read, chained ----------------
                        if (s == 7'd0) begin
                            if (first) begin
                                if (c_addr[22]) cram_ce1_n <= 1'b0; else cram_ce0_n <= 1'b0;
                                cram0_lb_n <= 1'b0; cram0_ub_n <= 1'b0; cram1_lb_n <= 1'b0; cram1_ub_n <= 1'b0;
                            end
                            cram_a <= w_addr[21:16];
                            {dq1_out, dq0_out} <= {2{w_addr[15:0]}};
                            dq_oe <= 1'b1; cram_adv_n <= 1'b0; cram_oe_n <= 1'b1;
                        end
                        if (s == ADV_C) cram_adv_n <= 1'b1;
                        if (s == ADV_C + AH) dq_oe <= 1'b0;
                        if (s == ADV_C + AH + 1) cram_oe_n <= 1'b0;
                        if (s == {2'd0, c_wait}) begin
                            rd_valid <= 1'b1; rd_data <= {cram1_dq, cram0_dq};
                            cram_oe_n <= 1'b1;
                            c_n <= c_n + 1'b1;
                            if (c_n + 1'b1 == c_len) begin
                                cram_ce0_n <= 1'b1; cram_ce1_n <= 1'b1;
                                st <= FIN;
                            end else begin
                                c_addr <= c_addr + 1'b1; first <= 1'b0; s <= 7'd0;
                            end
                        end
                    end else begin
                        // ---------------- synchronous burst read ----------------
                        // rising clock edges at odd cycles; word n is sampled at s_first + 2n
                        if (s == 7'd0) begin
                            if (c_addr[22]) cram_ce1_n <= 1'b0; else cram_ce0_n <= 1'b0;
                            cram0_lb_n <= 1'b0; cram0_ub_n <= 1'b0; cram1_lb_n <= 1'b0; cram1_ub_n <= 1'b0;
                            cram_a <= w_addr[21:16];
                            {dq1_out, dq0_out} <= {2{w_addr[15:0]}};
                            dq_oe <= 1'b1; cram_adv_n <= 1'b0; cram_oe_n <= 1'b1;
                            next_sample <= s_first;
                        end
                        cram_clk <= s[0] && (s <= s_lastrise);
                        if (s == 7'd2) begin cram_adv_n <= 1'b1; dq_oe <= 1'b0; cram_oe_n <= 1'b0; end
                        if (s == next_sample) begin
                            rd_valid <= 1'b1; rd_data <= {cram1_dq, cram0_dq};
                            next_sample <= next_sample + 7'd2;
                            c_n <= c_n + 1'b1;
                            if (c_n + 1'b1 == c_len) begin
                                cram_ce0_n <= 1'b1; cram_ce1_n <= 1'b1; cram_oe_n <= 1'b1; cram_clk <= 1'b0;
                                st <= FIN;
                            end
                        end
                    end
                end

                FIN: begin
                    // byte enables are released after WE# / CE# have risen
                    cram0_ub_n <= 1'b1; cram0_lb_n <= 1'b1; cram1_ub_n <= 1'b1; cram1_lb_n <= 1'b1;
                    done <= 1'b1;
                    st <= IDLE;
                end
                default: st <= IDLE;
            endcase
        end
    end
endmodule
