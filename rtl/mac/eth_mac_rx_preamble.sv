module eth_mac_rx_preamble (
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
    input  wire         out_ready,

    output wire         sop_detected,
    output wire         preamble_error
);

    localparam IDLE         = 2'b00;
    localparam MERGE        = 2'b01;
    localparam PASS_THROUGH = 2'b10;
    localparam DROP         = 2'b11;

    reg [1:0] state;
    reg [63:0] data_buf;
    reg [7:0]  tkeep_buf;
    reg        buf_valid;
    reg        buf_tlast;

    wire sfd_valid = (in_data[55:48] == 8'hD5);
    wire preamble_valid = (in_data[47:0] == 48'h55_55_55_55_55_55);
    wire sop = in_valid && in_ready && (state == IDLE);
    wire preamble_ok = sop && sfd_valid && preamble_valid;
    wire preamble_err = sop && !preamble_ok;

    wire in_fire = in_valid && in_ready;
    wire out_fire = out_valid && out_ready;

    reg [127:0] out_data_reg;
    reg [15:0]  out_tkeep_reg;
    reg         out_tlast_reg;
    reg         out_valid_reg;

    always @(*) begin
        if (buf_valid) begin
            if (in_valid) begin
                out_data_reg  = {in_data[63:0], data_buf};
                out_tkeep_reg = {in_tkeep[7:0], tkeep_buf};
                if (in_tlast && (|in_tkeep[15:8])) begin
                    out_tlast_reg = 1'b0;
                end else begin
                    out_tlast_reg = in_tlast;
                end
            end else begin
                out_data_reg  = {64'h0, data_buf};
                out_tkeep_reg = {8'h0, tkeep_buf};
                out_tlast_reg = buf_tlast;
            end
            out_valid_reg = 1'b1;
        end else if (state == PASS_THROUGH && in_valid) begin
            out_data_reg  = in_data;
            out_tkeep_reg = in_tkeep;
            out_tlast_reg = in_tlast;
            out_valid_reg = 1'b1;
        end else begin
            out_data_reg  = 128'h0;
            out_tkeep_reg = 16'h0;
            out_tlast_reg = 1'b0;
            out_valid_reg = 1'b0;
        end
    end

    assign out_valid = out_valid_reg;
    assign out_data  = out_data_reg;
    assign out_tkeep = out_tkeep_reg;
    assign out_tlast = out_tlast_reg;

    assign in_ready = (state == DROP) ||
                      (state == IDLE) ||
                      (state == MERGE && (!buf_valid || out_ready)) ||
                      (state == PASS_THROUGH && out_ready);

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= IDLE;
            data_buf  <= 64'h0;
            tkeep_buf <= 8'h0;
            buf_valid <= 1'b0;
            buf_tlast <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    if (in_fire) begin
                        if (preamble_ok) begin
                            data_buf  <= in_data[119:56];
                            tkeep_buf <= in_tkeep[14:7];
                            buf_tlast <= 1'b0;
                            if (|in_tkeep[14:7]) begin
                                buf_valid <= 1'b1;
                            end else begin
                                buf_valid <= 1'b0;
                            end
                            state <= MERGE;
                        end else begin
                            state <= DROP;
                        end
                    end
                end

                MERGE: begin
                    if (out_fire) begin
                        if (in_fire) begin
                            if (in_tlast && (|in_tkeep[15:8])) begin
                                data_buf  <= in_data[127:64];
                                tkeep_buf <= in_tkeep[15:8];
                                buf_tlast <= in_tlast;
                                buf_valid <= 1'b1;
                            end else if (in_tlast) begin
                                buf_valid <= 1'b0;
                                state     <= IDLE;
                            end else if (|in_tkeep[15:8]) begin
                                data_buf  <= in_data[127:64];
                                tkeep_buf <= in_tkeep[15:8];
                                buf_tlast <= in_tlast;
                                buf_valid <= 1'b1;
                            end else begin
                                buf_valid <= 1'b0;
                                state     <= PASS_THROUGH;
                            end
                        end else if (buf_valid) begin
                            buf_valid <= 1'b0;
                            state     <= IDLE;
                        end
                    end else if (in_fire && !buf_valid) begin
                        if (|in_tkeep[15:8]) begin
                            data_buf  <= in_data[127:64];
                            tkeep_buf <= in_tkeep[15:8];
                            buf_tlast <= in_tlast;
                            buf_valid <= 1'b1;
                        end else begin
                            buf_valid <= 1'b0;
                            state     <= PASS_THROUGH;
                        end
                    end
                end

                PASS_THROUGH: begin
                    if (out_fire && in_fire && in_tlast) begin
                        state <= IDLE;
                    end
                end

                DROP: begin
                    if (in_fire && in_tlast) begin
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    assign sop_detected  = preamble_ok;
    assign preamble_error = preamble_err;

endmodule
