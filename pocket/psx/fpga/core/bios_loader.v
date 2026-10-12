// APF bridge writes of the BIOS data slot (0x20000000, 512 KB) into the ram_adapter loader port. See docs/pocket/POCKET_TOP.md.
// The bridge has no backpressure: a 512-word FIFO absorbs bursts, and a sustained rate above one word per drain time
// (about 111 ns, one PSRAM write) overflows it; a dropped word sets the sticky err.

module bios_loader (
    input  wire        rst,                 // asynchronous assert, released synchronously in each domain
    input  wire        clk_74a,
    input  wire        clk_sys,

    input  wire        bridge_wr,           // one-cycle write strobe
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,      // big-endian bridge: the first file byte is [31:24]

    output wire        ld_valid,            // ram_adapter loader port, clk_sys
    input  wire        ld_ready,
    output wire [22:0] ld_addr,             // word address in the PSRAM
    output wire [31:0] ld_data,             // little-endian PSX word

    output reg  [17:0] words,               // words written since offset 0 was last written, clk_sys
    output wire        err                  // a bridge write was dropped, sticky, clk_sys
);
    reg [1:0] rra = 2'b11, rrs = 2'b11;
    always @(posedge clk_74a or posedge rst) if (rst) rra <= 2'b11; else rra <= {rra[0], 1'b0};
    always @(posedge clk_sys or posedge rst) if (rst) rrs <= 2'b11; else rrs <= {rrs[0], 1'b0};
    wire rsta = rra[1], rsts = rrs[1];

    // ---------------------------------------------------------------- write side, clk_74a
    localparam AW = 9;                      // 512 entries
    reg [48:0]   mem [0:(1<<AW)-1];         // {word index, data}
    reg [AW:0]   wptr, wgray;
    reg [AW:0]   rgray_s1, rgray_s2;        // read pointer, gray, synchronised
    reg          err_a;
    reg [AW:0]   rptr, rgray;           // read side, clk_sys

    wire         hit   = bridge_wr && (bridge_addr[31:19] == 13'h400);
    wire [AW:0]  wnext = wptr + 1'b1;
    wire [AW:0]  wngray = wnext ^ (wnext >> 1);
    wire         full  = (wngray == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});
    wire [31:0]  d     = bridge_wr_data;

    always @(posedge clk_74a) begin
        rgray_s1 <= rgray; rgray_s2 <= rgray_s1;
        if (rsta) begin wptr <= 0; wgray <= 0; err_a <= 1'b0; end
        else if (hit) begin
            if (full) err_a <= 1'b1;
            else begin
                mem[wptr[AW-1:0]] <= {bridge_addr[18:2], d[7:0], d[15:8], d[23:16], d[31:24]};
                wptr <= wnext; wgray <= wngray;
            end
        end
    end

    // ---------------------------------------------------------------- read side, clk_sys
    reg [AW:0]   wgray_s1, wgray_s2;
    reg [48:0]   q;
    reg [1:0]    err_s;

    wire         empty = (rgray == wgray_s2);
    wire         pop   = ld_valid && ld_ready;
    wire [AW:0]  rnext = rptr + 1'b1;
    wire [AW:0]  rngray = rnext ^ (rnext >> 1);
    wire [AW:0]  raddr = pop ? rnext : rptr;

    // the memory is read every cycle, so an entry written while the FIFO was empty is picked up before empty falls
    always @(posedge clk_sys) begin
        wgray_s1 <= wgray; wgray_s2 <= wgray_s1;
        err_s <= {err_s[0], err_a};
        q <= mem[raddr[AW-1:0]];
        if (rsts) begin rptr <= 0; rgray <= 0; words <= 18'd0; end
        else if (pop) begin
            rptr <= rnext; rgray <= rngray;
            words <= (q[48:32] == 17'd0) ? 18'd1 : words + 1'b1;
        end
    end

    assign ld_valid = !empty;
    assign ld_addr  = 23'h200000 + {6'd0, q[48:32]};
    assign ld_data  = q[31:0];
    assign err      = err_s[1];
endmodule
