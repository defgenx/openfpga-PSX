// Dual-clock FIFO: gray-code pointers through 2-FF synchronizers, RAM inferred (Cyclone V M10K/MLAB).
// Show-ahead: rdata is the head entry whenever rempty is low; ren pops it. Used by vram_adapter.v (docs/pocket/POCKET_TOP.md).
// Only the gray pointers cross clock domains. The synchronized pointers lag, so wfull/wlevel/rempty are conservative.
module async_fifo #(
    parameter WIDTH = 8,
    parameter AW    = 4                 // log2 of the depth, AW >= 2
) (
    input  wire             wclk,
    input  wire             wen,        // push; ignored while wfull
    input  wire [WIDTH-1:0] wdata,
    output wire             wfull,
    output wire [AW:0]      wlevel,     // entries held, as seen from the write side (never below the true count)

    input  wire             rclk,
    input  wire             ren,        // pop the head; ignored while rempty
    output wire [WIDTH-1:0] rdata,
    output wire             rempty
);
    reg [WIDTH-1:0] mem [0:(1<<AW)-1];

    function [AW:0] g2b(input [AW:0] g);
        integer i;
        begin
            g2b[AW] = g[AW];
            for (i = AW-1; i >= 0; i = i - 1) g2b[i] = g2b[i+1] ^ g[i];
        end
    endfunction

    reg [AW:0] wbin = 0, wgray = 0, rg2 = 0;
    reg [AW:0] rbin = 0, rgray = 0, wg2 = 0;
    reg        wfull_r = 0, rempty_r = 1;
    reg [WIDTH-1:0] q;

    // synchronizers: keep them as plain register chains
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [AW:0] rg1_s = 0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [AW:0] wg1_s = 0;

    // write side
    wire       wpush   = wen & ~wfull_r;
    wire [AW:0] wbin_n = wbin + {{AW{1'b0}}, wpush};
    wire [AW:0] wgray_n = wbin_n ^ (wbin_n >> 1);
    always @(posedge wclk) begin
        if (wpush) mem[wbin[AW-1:0]] <= wdata;
        wbin    <= wbin_n;
        wgray   <= wgray_n;
        rg1_s   <= rgray;
        rg2     <= rg1_s;
        wfull_r <= (wgray_n == {~rg2[AW:AW-1], rg2[AW-2:0]});
    end
    assign wfull  = wfull_r;
    assign wlevel = wbin - g2b(rg2);

    // read side: q is re-read every cycle from the entry that is the head after this edge
    wire       rpop    = ren & ~rempty_r;
    wire [AW:0] rbin_n = rbin + {{AW{1'b0}}, rpop};
    wire [AW:0] rgray_n = rbin_n ^ (rbin_n >> 1);
    always @(posedge rclk) begin
        rbin     <= rbin_n;
        rgray    <= rgray_n;
        wg1_s    <= wgray;
        wg2      <= wg1_s;
        rempty_r <= (rgray_n == wg2);
        q        <= mem[rbin_n[AW-1:0]];
    end
    assign rdata  = q;
    assign rempty = rempty_r;

    // synthesis translate_off
    always @(posedge wclk) if (wen & wfull_r) $display("ERROR async_fifo: write while full (%m)");
    // synthesis translate_on
endmodule
