// Scan-out stream: one 640 x 16-bit line (160 bursts) per line period, with a deadline.
// A line is late when it is still being fetched as the next line period begins.
// See docs/pocket/MEMTEST.md.
module sd_scan #(
    parameter LINE_CYCLES = 6400,      // 400 pixels at 6.3504 MHz, in 101.6064 MHz cycles
    parameter BURSTS      = 160,
    parameter Y_WRAP      = 480,
    parameter LINE_WORDS_LOG2 = 10     // VRAM line pitch: 1024 words
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        clear,          // zero the statistics and restart the line timer
    input  wire        en,             // new lines are started while set
    input  wire [31:0] seed,
    input  wire [24:0] base,

    output reg  [31:0] lines,          // lines completed
    output reg  [31:0] late,           // line periods that began while the previous line was unfinished
    output reg  [31:0] worst,          // longest line, cycles from its start
    output reg  [31:0] errors,
    output wire        active,

    output reg         req_valid,
    input  wire        req_ready,
    output reg  [24:0] req_addr,
    input  wire        rvalid,
    input  wire [63:0] rdata
);
    `include "memtest_fn.vh"

    reg [15:0] timer;
    reg [8:0]  y;
    reg [7:0]  issued, returned;
    reg [31:0] age;
    reg        fetching, cur_late;

    assign active = fetching;

    reg        c_v;
    reg [63:0] c_data;
    reg [24:0] c_addr;
`ifdef ALTERA_RESERVED_QIS
    wire c_x = 1'b0;
`else
    wire c_x = (^c_data) === 1'bx;
`endif

    wire wrap = (timer == LINE_CYCLES - 1);
    wire [24:0] line_base = base | {y, {LINE_WORDS_LOG2{1'b0}}};
    wire line_done = fetching && (returned == BURSTS) && !c_v;

    always @(posedge clk) begin
        c_v <= 1'b0;
        if (rst || clear) begin
            timer <= 16'd0; y <= 9'd0; issued <= 8'd0; returned <= 8'd0;
            age <= 32'd0; fetching <= 1'b0; cur_late <= 1'b0; req_valid <= 1'b0;
            lines <= 32'd0; late <= 32'd0; worst <= 32'd0; errors <= 32'd0;
        end else begin
            timer <= wrap ? 16'd0 : timer + 1'b1;
            if (fetching) age <= age + 1'b1;

            if (wrap && en) begin
                if (fetching) begin
                    if (!cur_late) late <= late + 1'b1;
                    cur_late <= 1'b1;
                end else begin
                    fetching <= 1'b1; issued <= 8'd0; returned <= 8'd0; age <= 32'd1; cur_late <= 1'b0;
                end
            end

            if (req_valid && req_ready) req_valid <= 1'b0;
            if (fetching && issued != BURSTS && (!req_valid || req_ready)) begin
                req_valid <= 1'b1;
                req_addr  <= line_base | {issued, 2'b00};
                issued    <= issued + 1'b1;
            end

            if (rvalid) begin
                returned <= returned + 1'b1;
                c_v <= 1'b1; c_data <= rdata;
                c_addr <= line_base | {returned, 2'b00};
            end
            if (c_v && (c_x || c_data != pat64({7'd0, c_addr}, seed))) errors <= errors + 1'b1;

            if (line_done) begin
                lines <= lines + 1'b1;
                if (age > worst) worst <= age;
                fetching <= 1'b0; cur_late <= 1'b0;
                y <= (y == Y_WRAP - 1) ? 9'd0 : y + 1'b1;
            end
        end
    end
endmodule
