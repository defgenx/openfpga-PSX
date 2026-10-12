// CD image and track table loader: cd_top's cd_hps_* sector protocol <-> APF target_dataslot_read of slot SLOT_BIN, and
// the bridge writes of the track table slot -> trackinfo_*. Protocol, mapping and format: docs/pocket/POCKET_TOP.md, "CD loader".
// clk_74a: bridge, target command, two RAMs. clk_sys: the core's clk1x. Crossings: toggles through 2-FF synchronisers
// (data stable while the toggle is in flight); the RAMs are written in clk_74a and read in clk_sys.

module cd_loader #(
    parameter [15:0] SLOT_BIN = 16'd1,          // CD image data slot id
    parameter [31:0] SEC_WIN  = 32'h50000000    // bridge window the sector lands in
) (
    input  wire        rst,                     // asynchronous assert, released synchronously in each domain
    input  wire        clk_74a,
    input  wire        clk_sys,

    // APF bridge, clk_74a, big-endian: the first file byte is bridge_wr_data[31:24]
    input  wire        bridge_wr,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,

    // core_bridge_cmd target interface, clk_74a
    output reg         tgt_read = 1'b0,
    output reg  [15:0] tgt_id,
    output reg  [31:0] tgt_off,
    output reg  [31:0] tgt_baddr,
    output reg  [31:0] tgt_len,
    input  wire        tgt_done,
    input  wire [2:0]  tgt_err,

    // cd_top, clk_sys
    input  wire        cd_hps_req,
    input  wire [31:0] cd_hps_lba,
    output reg         cd_hps_ack,
    output reg         cd_hps_write,
    output reg  [15:0] cd_hps_data,
    output reg  [31:0] trackinfo_data,
    output reg  [8:0]  trackinfo_addr,
    output reg         trackinfo_write,

    output reg         trk_done,                // clk_sys: the track table was written to the core (cleared while a new one is replayed)
    output wire        err                      // clk_sys, sticky: a sector read failed or came up short and was delivered as zeros
);
    localparam [31:0] SEC_BYTES = 32'd2352;
    localparam [9:0]  SEC_WORDS = 10'd588;      // 32-bit words per sector
    localparam [19:0] PREGAP    = 20'd150;      // disc LBA 150 is file sector 0

    reg [1:0] rra = 2'b11, rrs = 2'b11;
    always @(posedge clk_74a or posedge rst) if (rst) rra <= 2'b11; else rra <= {rra[0], 1'b0};
    always @(posedge clk_sys or posedge rst) if (rst) rrs <= 2'b11; else rrs <= {rrs[0], 1'b0};
    wire rsta = rra[1], rsts = rrs[1];

    // ---------------------------------------------------------------- toggles
    reg req_t = 1'b0;                           // clk_sys -> clk_74a: a sector was requested
    reg rdy_t = 1'b0;                           // clk_74a -> clk_sys: the sector RAM holds the answer
    reg trk_t = 1'b0;                           // clk_74a -> clk_sys: the track table RAM is complete
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg req_s1 = 1'b0, rdy_s1 = 1'b0, trk_s1 = 1'b0, err_s1 = 1'b0;
    reg req_s2 = 1'b0, rdy_s2 = 1'b0, trk_s2 = 1'b0, err_s2 = 1'b0;
    reg req_p = 1'b0, rdy_p = 1'b0, trk_p = 1'b0;
    reg err_a = 1'b0;
    always @(posedge clk_74a) begin req_s1 <= req_t; req_s2 <= req_s1; req_p <= req_s2; end
    always @(posedge clk_sys) begin
        rdy_s1 <= rdy_t; rdy_s2 <= rdy_s1; rdy_p <= rdy_s2;
        trk_s1 <= trk_t; trk_s2 <= trk_s1; trk_p <= trk_s2;
        err_s1 <= err_a; err_s2 <= err_s1;
    end
    assign err = err_s2;
    wire req_edge = req_s2 ^ req_p;
    wire rdy_edge = rdy_s2 ^ rdy_p;
    wire trk_edge = trk_s2 ^ trk_p;

    // ---------------------------------------------------------------- sector RAM and track table RAM
    reg [31:0] sec_mem [0:1023];
    reg [31:0] trk_mem [0:511];
    reg [9:0]  sec_ra = 10'd0;
    reg [8:0]  trk_ra = 9'd0;
    reg [31:0] sec_q, trk_q;

    wire        hit_s = bridge_wr && (bridge_addr[31:12] == SEC_WIN[31:12]);
    wire [9:0]  idx_s = bridge_addr[11:2];
    wire        hit_t = bridge_wr && (bridge_addr[31:11] == 21'h060000);        // 0x30000000, 2,048 bytes
    wire [8:0]  idx_t = bridge_addr[10:2];

    always @(posedge clk_74a) if (hit_s && idx_s < SEC_WORDS) sec_mem[idx_s] <= bridge_wr_data;
    // track table words are little-endian in the file: store them swapped
    always @(posedge clk_74a) if (hit_t) trk_mem[idx_t] <= {bridge_wr_data[7:0], bridge_wr_data[15:8], bridge_wr_data[23:16], bridge_wr_data[31:24]};
    always @(posedge clk_sys) begin sec_q <= sec_mem[sec_ra]; trk_q <= trk_mem[trk_ra]; end

    // ---------------------------------------------------------------- clk_74a: track table completion
    // Complete after word 511, or 2^19 idle cycles (7 ms) after the last write; a write after that starts a new table.
    reg        trk_act = 1'b0;
    reg [18:0] trk_idle = 19'd0;
    reg [9:0]  trk_len = 10'd0;                 // words written, stable while trk_t is in flight
    always @(posedge clk_74a) begin
        if (rsta) begin trk_act <= 1'b0; trk_len <= 10'd0; end
        else begin
            if (hit_t) begin
                trk_idle <= 19'd0;
                trk_act  <= 1'b1;
                if (!trk_act) trk_len <= {1'b0, idx_t} + 10'd1;
                else if ({1'b0, idx_t} + 10'd1 > trk_len) trk_len <= {1'b0, idx_t} + 10'd1;
                if (idx_t == 9'd511) begin trk_act <= 1'b0; trk_t <= ~trk_t; end
            end else if (trk_act) begin
                trk_idle <= trk_idle + 19'd1;
                if (&trk_idle) begin trk_act <= 1'b0; trk_t <= ~trk_t; end
            end
        end
    end

    // ---------------------------------------------------------------- clk_74a: sector read
    localparam [3:0] A_IDLE = 0, A_CALC = 1, A_ISSUE = 2, A_HOLD = 3, A_WAIT = 4, A_GUARD = 5, A_RDY = 6;
    reg [3:0]  as = A_IDLE;
    reg [31:0] lba_a;
    reg [31:0] acc;
    reg [2:0]  cnt;
    reg [4:0]  hc;
    reg [26:0] tmo;
    reg [9:0]  wcnt;
    reg        zero_a = 1'b0;                   // deliver zeros: no file data for this LBA, or the read failed
    reg        bad_a;
    wire [19:0] fsec = lba_a[19:0] - PREGAP;
    wire [4:0]  shv  = (cnt == 3'd0) ? 5'd11 : (cnt == 3'd1) ? 5'd8 : (cnt == 3'd2) ? 5'd5 : 5'd4;   // x * 2352 = x<<11 + x<<8 + x<<5 + x<<4

    always @(posedge clk_74a) begin
        if (hit_s && idx_s < SEC_WORDS && (as == A_HOLD || as == A_WAIT || as == A_GUARD)) wcnt <= wcnt + 10'd1;
        if (rsta) begin as <= A_IDLE; tgt_read <= 1'b0; err_a <= 1'b0; end
        else case (as)
            A_IDLE: if (req_edge) begin
                lba_a <= cd_hps_lba; bad_a <= 1'b0;
                if (cd_hps_lba[31:20] != 12'd0) begin zero_a <= 1'b1; bad_a <= 1'b1; as <= A_RDY; end
                else if (cd_hps_lba[19:0] < PREGAP) begin zero_a <= 1'b1; as <= A_RDY; end
                else begin zero_a <= 1'b0; acc <= 32'd0; cnt <= 3'd0; as <= A_CALC; end
            end
            A_CALC: begin
                acc <= acc + ({12'd0, fsec} << shv);
                cnt <= cnt + 3'd1;
                if (cnt == 3'd3) as <= A_ISSUE;
            end
            A_ISSUE: begin
                tgt_id <= SLOT_BIN; tgt_off <= acc; tgt_baddr <= SEC_WIN; tgt_len <= SEC_BYTES;
                tgt_read <= 1'b1; hc <= 5'd0; tmo <= 27'd0; wcnt <= 10'd0; as <= A_HOLD;
            end
            A_HOLD: begin                       // read high for 4 cycles; done is a stale level for the first 8
                hc <= hc + 5'd1;
                if (hc == 5'd3) tgt_read <= 1'b0;
                if (hc == 5'd7) as <= A_WAIT;
            end
            A_WAIT: begin
                tmo <= tmo + 27'd1;
                if (tgt_done) begin bad_a <= (tgt_err != 3'd0); hc <= 5'd0; as <= A_GUARD; end
                else if (&tmo) begin bad_a <= 1'b1; hc <= 5'd0; as <= A_GUARD; end
            end
            A_GUARD: begin                      // writes may trail done
                hc <= hc + 5'd1;
                if (hc == 5'd15) begin
                    if (wcnt != SEC_WORDS) bad_a <= 1'b1;
                    as <= A_RDY;
                end
            end
            A_RDY: begin
                if (bad_a) begin zero_a <= 1'b1; err_a <= 1'b1; end
                rdy_t <= ~rdy_t;
                as <= A_IDLE;
            end
            default: as <= A_IDLE;
        endcase
    end

    // ---------------------------------------------------------------- clk_sys: sector streaming and track table replay
    localparam [3:0] S_IDLE = 0, S_WRDY = 1, S_PRE = 2, S_ADDR = 3, S_LAT = 4, S_LO = 5, S_HI = 6, S_TAIL = 7;
    reg [3:0] ss = S_IDLE;
    reg [2:0] sc;
    reg       zero_s;

    // zero_a is stable from rdy_t until the next request, which cannot start before this stream ends
    always @(posedge clk_sys) begin
        cd_hps_write <= 1'b0;
        if (rsts) begin ss <= S_IDLE; cd_hps_ack <= 1'b0; end
        else case (ss)
            S_IDLE: if (cd_hps_req) begin req_t <= ~req_t; ss <= S_WRDY; end
            S_WRDY: if (rdy_edge) begin
                if (cd_hps_req) begin cd_hps_ack <= 1'b1; zero_s <= zero_a; sc <= 3'd0; sec_ra <= 10'd0; ss <= S_PRE; end
                else ss <= S_IDLE;              // the core gave the request up
            end
            S_PRE: begin                        // the core must see ack before the first word
                sc <= sc + 3'd1;
                if (sc == 3'd2) ss <= S_ADDR;
            end
            S_ADDR: ss <= S_LAT;
            S_LAT:  ss <= S_LO;
            S_LO: begin
                cd_hps_data  <= zero_s ? 16'd0 : {sec_q[23:16], sec_q[31:24]};
                cd_hps_write <= 1'b1;
                ss <= S_HI;
            end
            S_HI: begin
                cd_hps_data  <= zero_s ? 16'd0 : {sec_q[7:0], sec_q[15:8]};
                cd_hps_write <= 1'b1;
                sec_ra <= sec_ra + 10'd1;
                ss <= (sec_ra == SEC_WORDS - 10'd1) ? S_TAIL : S_ADDR;
                sc <= 3'd0;
            end
            S_TAIL: begin
                sc <= sc + 3'd1;
                if (sc == 3'd2) begin cd_hps_ack <= 1'b0; ss <= S_IDLE; end
            end
            default: ss <= S_IDLE;
        endcase
    end

    // track table replay: 4 cycles per word
    reg        rp = 1'b0;
    reg [1:0]  rph = 2'd0;
    reg [9:0]  rn;
    reg [9:0]  rlen;
    always @(posedge clk_sys) begin
        trackinfo_write <= 1'b0;
        if (rsts) begin rp <= 1'b0; trk_done <= 1'b0; end
        else if (!rp) begin
            if (trk_edge) begin rp <= 1'b1; trk_done <= 1'b0; rn <= 10'd0; rph <= 2'd0; rlen <= trk_len; end
        end else begin
            rph <= rph + 2'd1;
            case (rph)
                2'd0: trk_ra <= rn[8:0];
                2'd2: begin trackinfo_data <= trk_q; trackinfo_addr <= rn[8:0]; trackinfo_write <= 1'b1; end
                2'd3: begin
                    rn <= rn + 10'd1;
                    if (rn + 10'd1 >= rlen) begin rp <= 1'b0; trk_done <= 1'b1; end
                end
                default: ;
            endcase
        end
    end
endmodule
