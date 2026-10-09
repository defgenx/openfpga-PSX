`timescale 1ns/1ps
// core_bridge_cmd: host commands (status, reset exit, savestate query, unknown) and a target data slot read.
module mf_datatable (
    input  wire [9:0] address_a, address_b, input wire clock_a, clock_b, input wire [31:0] data_a, data_b,
    input  wire wren_a, wren_b, output reg [31:0] q_a, q_b
);
    reg [31:0] m [0:1023];
    always @(posedge clock_a) begin if (wren_a) m[address_a] <= data_a; q_a <= m[address_a]; end
    always @(posedge clock_b) begin if (wren_b) m[address_b] <= data_b; q_b <= m[address_b]; end
endmodule

module tb_bridge;
    reg clk = 0;
    always #6.7 clk = ~clk;
    reg [31:0] bridge_addr = 0, bridge_wr_data = 0;
    reg bridge_rd = 0, bridge_wr = 0, setup_done = 0, tgt_read = 0;
    wire [31:0] rd_data, host_resp;
    wire reset_n, tgt_ack, tgt_done;
    wire [2:0] tgt_err;
    integer fails = 0;

    core_bridge_cmd dut (
        .clk(clk), .reset_n(reset_n), .bridge_endian_little(1'b0), .bridge_addr(bridge_addr), .bridge_rd(bridge_rd),
        .bridge_rd_data(rd_data), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .status_boot_done(1'b1), .status_setup_done(setup_done), .status_running(reset_n),
        .dataslot_requestread_ack(1'b1), .dataslot_requestread_ok(1'b1),
        .dataslot_requestwrite_ack(1'b1), .dataslot_requestwrite_ok(1'b1),
        .target_dataslot_read(tgt_read), .target_dataslot_write(1'b0),
        .target_dataslot_ack(tgt_ack), .target_dataslot_done(tgt_done), .target_dataslot_err(tgt_err),
        .target_dataslot_id(16'd1), .target_dataslot_slotoffset(32'h1000), .target_dataslot_bridgeaddr(32'h50000000),
        .target_dataslot_length(32'd2048),
        .datatable_addr(10'd0), .datatable_wren(1'b0), .datatable_data(32'd0)
    );

    task wr(input [31:0] a, input [31:0] d);
        begin @(posedge clk); bridge_addr <= a; bridge_wr_data <= d; bridge_wr <= 1; @(posedge clk); bridge_wr <= 0; end
    endtask
    task rd(input [31:0] a, output [31:0] d);
        begin @(posedge clk); bridge_addr <= a; bridge_rd <= 1; @(posedge clk); bridge_rd <= 0; @(posedge clk); @(posedge clk); d = rd_data; end
    endtask
    task host_cmd(input [15:0] cmd, input [31:0] expect_resp);
        reg [31:0] r;
        begin
            wr(32'hF8000000, {16'h434D, cmd});
            repeat (8) @(posedge clk);
            rd(32'hF8000000, r);
            if (r !== expect_resp) begin $display("cmd %h: got %h want %h", cmd, r, expect_resp); fails = fails + 1; end
        end
    endtask
    reg [31:0] v;
    initial begin
        repeat (4) @(posedge clk);
        host_cmd(16'h0000, 32'h4F4B0002);      // boot done, setup not done
        setup_done = 1;
        repeat (8) @(posedge clk);
        host_cmd(16'h0000, 32'h4F4B0003);      // idle
        host_cmd(16'h0011, 32'h4F4B0000);      // reset exit
        if (reset_n !== 1'b1) begin $display("reset_n not released"); fails = fails + 1; end
        host_cmd(16'h0000, 32'h4F4B0003);
        host_cmd(16'h00A0, 32'h4F4B0000);      // savestate query: not supported
        host_cmd(16'h1234, 32'h4F4BFFFF);      // unknown command
        // target: after setup the core announces itself (0x0140), then a data slot read puts 0x0180 in the command word
        rd(32'hF8001000, v);
        if (v[15:0] !== 16'h0140) begin $display("target ready word %h", v); fails = fails + 1; end
        wr(32'hF8001000, 32'h6F6B0000);
        repeat (8) @(posedge clk);
        tgt_read = 1;
        repeat (16) @(posedge clk);
        rd(32'hF8001000, v);
        if (v[15:0] !== 16'h0180) begin $display("target read word %h", v); fails = fails + 1; end
        rd(32'hF8001020, v);
        if (v !== 32'd1) begin $display("target id %h", v); fails = fails + 1; end
        rd(32'hF8001024, v);
        if (v !== 32'h1000) begin $display("target offset %h", v); fails = fails + 1; end
        rd(32'hF8001028, v);
        if (v !== 32'h50000000) begin $display("target bridge address %h", v); fails = fails + 1; end
        rd(32'hF800102C, v);
        if (v !== 32'd2048) begin $display("target length %h", v); fails = fails + 1; end
        wr(32'hF8001000, 32'h6F6B0000);        // the host reports done
        repeat (8) @(posedge clk);
        if (tgt_done !== 1'b1 || tgt_err !== 3'd0) begin $display("target not done: done %b err %d", tgt_done, tgt_err); fails = fails + 1; end
        if (fails == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
