module eth_mac_tx_preamble (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         in_valid,
    input  wire [127:0] in_data,
    input  wire [15:0]  in_tkeep,
    input  wire         in_tlast,
    output wire         in_ready,

    output wire         out_valid,
    output wire [127:0] out_data,
    output wire [15:0]  out_tkeep,
    output wire         out_tlast,
    input  wire         out_ready
);

    localparam PREAMBLE_SFD = 64'hD555555555555555;

    reg [63:0] data_buf;
    reg        buf_valid;
    reg        buf_tlast;
    reg [7:0]  buf_tkeep_high;
    reg        in_pkt;

    wire sop = in_valid && in_ready && !in_pkt;
    wire in_fire = in_valid && in_ready;
    wire out_fire = out_valid && out_ready;

    assign in_ready = !buf_valid || (out_ready && !buf_tlast);
    assign out_valid = in_valid || buf_valid;

    reg [127:0] out_data_reg;
    reg [15:0]  out_tkeep_reg;
    reg         out_tlast_reg;

    always @(*) begin
        if (buf_valid) begin
            if (buf_tlast) begin
                out_data_reg  = {64'h0, data_buf};
                out_tkeep_reg = {8'h00, buf_tkeep_high};
                out_tlast_reg = 1'b1;
            end else if (in_valid) begin
                out_data_reg  = {in_data[63:0], data_buf};
                out_tkeep_reg = {in_tkeep[7:0], buf_tkeep_high};
                if (in_tlast && (|in_tkeep[15:8])) begin
                    out_tlast_reg = 1'b0;
                end else begin
                    out_tlast_reg = in_tlast;
                end
            end else begin
                out_data_reg  = {64'h0, data_buf};
                out_tkeep_reg = {8'h00, buf_tkeep_high};
                out_tlast_reg = buf_tlast;
            end
        end else if (sop) begin
            out_data_reg  = {in_data[63:0], PREAMBLE_SFD};
            out_tkeep_reg = 16'hFFFF;
            out_tlast_reg = in_tlast;
        end else if (in_valid) begin
            out_data_reg  = in_data;
            out_tkeep_reg = in_tkeep;
            out_tlast_reg = in_tlast;
        end else begin
            out_data_reg  = 128'h0;
            out_tkeep_reg = 16'h0;
            out_tlast_reg = 1'b0;
        end
    end

    assign out_data  = out_data_reg;
    assign out_tkeep = out_tkeep_reg;
    assign out_tlast = out_tlast_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            in_pkt        <= 1'b0;
            buf_valid     <= 1'b0;
            data_buf      <= 64'h0;
            buf_tlast     <= 1'b0;
            buf_tkeep_high <= 8'h0;
        end else begin
            if (out_fire) begin
                if (sop) begin
                    in_pkt <= 1'b1;
                end else if (out_tlast_reg) begin
                    in_pkt <= 1'b0;
                end
            end

            if (out_fire) begin
                if (buf_valid) begin
                    if (in_fire && (|in_tkeep[15:8])) begin
                        data_buf       <= in_data[127:64];
                        buf_tlast      <= in_tlast;
                        buf_tkeep_high <= in_tkeep[15:8];
                        buf_valid      <= 1'b1;
                    end else begin
                        buf_valid <= 1'b0;
                    end
                end else if (sop && (|in_tkeep[15:8])) begin
                    data_buf       <= in_data[127:64];
                    buf_tlast      <= in_tlast;
                    buf_tkeep_high <= in_tkeep[15:8];
                    buf_valid      <= 1'b1;
                end
            end
        end
    end

endmodule
