// Scan-out stream: one 640 x 16-bit line (160 bursts) per line period, with a deadline.
// A line is late when it is still being fetched as the next line period begins.
// The period is LINE_NUM / LINE_DEN clock cycles (400 pixels at 6.3504 MHz), not necessarily a whole
// number: a fractional accumulator lengthens some lines by one cycle. See docs/pocket/MEMTEST.md.
`include "memtest_defs.vh"
module sd_scan #(
    parameter LINE_NUM    = `MT_LINE_NUM,
    parameter LINE_DEN    = `MT_LINE_DEN,
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

    localparam LINE_INT = LINE_NUM / LINE_DEN;         // whole cycles of a line
    localparam LINE_REM = LINE_NUM % LINE_DEN;         // fraction added per line, in 1/LINE_DEN

    reg [15:0] timer;
    reg [15:0] period;                 // length of the running line period
    reg [7:0]  frac;                   // accumulated fraction, always < LINE_DEN
    wire [8:0] frac_n = {1'b0, frac} + LINE_REM;
    wire       carry  = frac_n >= LINE_DEN;
    reg [8:0]  y;
    reg [7:0]  issued, returned;
    reg [31:0] age;
    reg        fetching, cur_late;

    assign active = fetching;

    // checker pipeline: returned data (c_), expected data (c2_), mismatch flag (c3_), then the count;
    // a line is finished only when the pipeline is empty
    reg        c_v, c2_v, c3_bad;
    reg [63:0] c_data, c2_data, c2_exp;
    reg [24:0] c_addr;
`ifdef ALTERA_RESERVED_QIS
    wire c_x = 1'b0;
`else
    wire c_x = (^c2_data) === 1'bx;
`endif

    wire wrap = (timer == period - 1);
    wire [24:0] line_base = base | {y, {LINE_WORDS_LOG2{1'b0}}};
    wire line_done = fetching && (returned == BURSTS) && !c_v && !c2_v && !c3_bad;

    always @(posedge clk) begin
        c_v <= 1'b0;
        c2_v <= c_v; c2_data <= c_data; c2_exp <= pat64({7'd0, c_addr}, seed);
        c3_bad <= c2_v && (c_x || c2_data != c2_exp);
        if (rst || clear) begin
            timer <= 16'd0; period <= LINE_INT; frac <= 8'd0; y <= 9'd0; issued <= 8'd0; returned <= 8'd0;
            age <= 32'd0; fetching <= 1'b0; cur_late <= 1'b0; req_valid <= 1'b0;
            lines <= 32'd0; late <= 32'd0; worst <= 32'd0; errors <= 32'd0;
        end else begin
            timer <= wrap ? 16'd0 : timer + 1'b1;
            if (wrap) begin
                period <= carry ? LINE_INT + 1 : LINE_INT;
                frac   <= carry ? frac_n - LINE_DEN : frac_n;
            end
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
            if (c3_bad) errors <= errors + 1'b1;

            if (line_done) begin
                lines <= lines + 1'b1;
                if (age > worst) worst <= age;
                fetching <= 1'b0; cur_late <= 1'b0;
                y <= (y == Y_WRAP - 1) ? 9'd0 : y + 1'b1;
            end
        end
    end
endmodule
