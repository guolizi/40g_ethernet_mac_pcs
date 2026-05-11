module sync_fifo #(
    parameter DATA_WIDTH            = 128,
    parameter DEPTH                 = 256,
    parameter ALMOST_FULL_THRESH    = 0,
    parameter ALMOST_EMPTY_THRESH   = 0
) (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     wr_en,
    input  wire [DATA_WIDTH-1:0]    wr_data,
    output wire                     full,

    input  wire                     rd_en,
    output wire [DATA_WIDTH-1:0]    rd_data,
    output wire                     empty,

    output wire                     almost_full,
    output wire                     almost_empty
);

    localparam PTR_WIDTH = $clog2(DEPTH);

    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg [PTR_WIDTH:0]   data_count;

    wire wr_valid = wr_en && !full;
    wire rd_valid = rd_en && !empty;

    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg [DATA_WIDTH-1:0] rd_data_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= {PTR_WIDTH{1'b0}};
        end else if (wr_valid) begin
            mem[wr_ptr] <= wr_data;
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_ptr <= {PTR_WIDTH{1'b0}};
        end else if (rd_valid) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_data_reg <= {DATA_WIDTH{1'b0}};
        end else if (wr_valid && (data_count == 0)) begin
            rd_data_reg <= wr_data;
        end else if (rd_valid) begin
            if (wr_valid && (data_count == 1)) begin
                rd_data_reg <= wr_data;
            end else if (data_count > 0) begin
                rd_data_reg <= mem[rd_ptr];
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            data_count <= {(PTR_WIDTH+1){1'b0}};
        end else begin
            case ({wr_valid, rd_valid})
                2'b10:   data_count <= data_count + 1'b1;
                2'b01:   data_count <= data_count - 1'b1;
                default: data_count <= data_count;
            endcase
        end
    end

    assign full  = (data_count == DEPTH);
    assign empty = (data_count == 0);

    generate
        if (ALMOST_FULL_THRESH > 0) begin : gen_af
            assign almost_full = (data_count >= ALMOST_FULL_THRESH);
        end else begin : gen_af_disabled
            assign almost_full = 1'b0;
        end

        if (ALMOST_EMPTY_THRESH > 0) begin : gen_ae
            assign almost_empty = (data_count <= ALMOST_EMPTY_THRESH);
        end else begin : gen_ae_disabled
            assign almost_empty = 1'b0;
        end
    endgenerate

    assign rd_data = rd_data_reg;

endmodule
