module async_fifo #(
    parameter DATA_WIDTH = 64,
    parameter DEPTH      = 16,
    parameter PROG_FULL  = 0,
    parameter PROG_EMPTY = 0
) (
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output wire                  full,
    output wire                  prog_full,

    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire                  empty,
    output wire                  prog_empty
);

    localparam ADDR_WIDTH = $clog2(DEPTH);

    function automatic [ADDR_WIDTH:0] bin2gray(input [ADDR_WIDTH:0] bin);
        bin2gray = bin ^ (bin >> 1);
    endfunction

    function automatic [ADDR_WIDTH:0] gray2bin(input [ADDR_WIDTH:0] gray);
        integer i;
        reg [ADDR_WIDTH:0] bin;
        begin
            bin[ADDR_WIDTH] = gray[ADDR_WIDTH];
            for (i = ADDR_WIDTH-1; i >= 0; i = i - 1) begin
                bin[i] = gray[i] ^ bin[i+1];
            end
            gray2bin = bin;
        end
    endfunction

    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg [ADDR_WIDTH:0] wr_ptr_bin;
    reg [ADDR_WIDTH:0] wr_ptr_gray;
    reg [ADDR_WIDTH:0] rd_ptr_gray_sync0;
    reg [ADDR_WIDTH:0] rd_ptr_gray_sync1;

    wire [ADDR_WIDTH:0] rd_ptr_gray_sync = rd_ptr_gray_sync1;
    wire [ADDR_WIDTH:0] rd_ptr_bin_sync = gray2bin(rd_ptr_gray_sync);

    wire [ADDR_WIDTH:0] wr_ptr_bin_next = wr_ptr_bin + 1'b1;
    wire [ADDR_WIDTH:0] wr_ptr_gray_next = bin2gray(wr_ptr_bin_next);

    wire full_comb = (wr_ptr_bin_next[ADDR_WIDTH] != rd_ptr_bin_sync[ADDR_WIDTH]) &&
                     (wr_ptr_bin_next[ADDR_WIDTH-1:0] == rd_ptr_bin_sync[ADDR_WIDTH-1:0]);
    assign full = full_comb;

    wire wr_valid = wr_en && !full;

    always @(posedge wr_clk) begin
        if (!wr_rst_n) begin
            wr_ptr_bin        <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray       <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray_sync0 <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray_sync1 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            if (wr_valid) begin
                wr_ptr_bin  <= wr_ptr_bin_next;
                wr_ptr_gray <= wr_ptr_gray_next;
            end
            rd_ptr_gray_sync0 <= rd_ptr_gray;
            rd_ptr_gray_sync1 <= rd_ptr_gray_sync0;
        end
    end

    always @(posedge wr_clk) begin
        if (wr_valid) begin
            mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
        end
    end

    reg [ADDR_WIDTH:0] rd_ptr_bin;
    reg [ADDR_WIDTH:0] rd_ptr_gray;
    reg [ADDR_WIDTH:0] wr_ptr_gray_sync0;
    reg [ADDR_WIDTH:0] wr_ptr_gray_sync1;

    wire [ADDR_WIDTH:0] wr_ptr_gray_sync = wr_ptr_gray_sync1;
    wire [ADDR_WIDTH:0] wr_ptr_bin_sync = gray2bin(wr_ptr_gray_sync);

    wire [ADDR_WIDTH:0] rd_ptr_bin_next = rd_ptr_bin + 1'b1;
    wire [ADDR_WIDTH:0] rd_ptr_gray_next = bin2gray(rd_ptr_bin_next);

    assign empty = (rd_ptr_bin == wr_ptr_bin_sync);
    wire rd_valid = rd_en && !empty;

    always @(posedge rd_clk) begin
        if (!rd_rst_n) begin
            rd_ptr_bin        <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray       <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray_sync0 <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray_sync1 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            if (rd_valid) begin
                rd_ptr_bin  <= rd_ptr_bin_next;
                rd_ptr_gray <= rd_ptr_gray_next;
            end
            wr_ptr_gray_sync0 <= wr_ptr_gray;
            wr_ptr_gray_sync1 <= wr_ptr_gray_sync0;
        end
    end

    assign rd_data = mem[rd_ptr_bin[ADDR_WIDTH-1:0]];

    generate
        if (PROG_FULL > 0) begin : gen_prog_full
            wire [ADDR_WIDTH:0] wr_count = wr_ptr_bin - rd_ptr_bin_sync;
            assign prog_full = (wr_count >= PROG_FULL);
        end else begin
            assign prog_full = 1'b0;
        end

        if (PROG_EMPTY > 0) begin : gen_prog_empty
            wire [ADDR_WIDTH:0] rd_count = wr_ptr_bin_sync - rd_ptr_bin;
            assign prog_empty = (rd_count <= PROG_EMPTY);
        end else begin
            assign prog_empty = 1'b0;
        end
    endgenerate

endmodule
