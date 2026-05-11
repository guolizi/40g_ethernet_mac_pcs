module eth_mac_tx_fifo (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         wr_en,
    input  wire [127:0] wr_data,
    input  wire [15:0]  wr_tkeep,
    input  wire         wr_tlast,
    output wire         full,
    output wire         almost_full,

    input  wire         rd_en,
    output wire [127:0] rd_data,
    output wire [15:0]  rd_tkeep,
    output wire         rd_tlast,
    output wire         rd_valid,
    output wire         empty
);

    localparam FIFO_DATA_WIDTH = 1 + 16 + 128;
    localparam FIFO_DEPTH      = 128;
    localparam ALMOST_FULL     = 112;

    wire [FIFO_DATA_WIDTH-1:0] fifo_wr_data;
    wire [FIFO_DATA_WIDTH-1:0] fifo_rd_data;
    wire fifo_full;
    wire fifo_empty;
    wire fifo_almost_full;

    assign fifo_wr_data = {wr_tlast, wr_tkeep, wr_data};

    sync_fifo #(
        .DATA_WIDTH           (FIFO_DATA_WIDTH),
        .DEPTH                (FIFO_DEPTH),
        .ALMOST_FULL_THRESH   (ALMOST_FULL),
        .ALMOST_EMPTY_THRESH  (0)
    ) u_tx_fifo (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr_en        (wr_en),
        .wr_data      (fifo_wr_data),
        .full         (fifo_full),
        .rd_en        (rd_en),
        .rd_data      (fifo_rd_data),
        .empty        (fifo_empty),
        .almost_full  (fifo_almost_full),
        .almost_empty ()
    );

    assign rd_data     = rd_valid ? fifo_rd_data[127:0] : 128'h0;
    assign rd_tkeep    = rd_valid ? fifo_rd_data[143:128] : 16'h0;
    assign rd_tlast    = rd_valid ? fifo_rd_data[144] : 1'b0;
    assign rd_valid    = ~fifo_empty;
    assign full        = fifo_full;
    assign almost_full = fifo_almost_full;
    assign empty       = fifo_empty;

endmodule
