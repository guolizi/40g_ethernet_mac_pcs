module eth_mac_tx_fcs (
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

    reg [127:0] hold_data;
    reg [15:0]  hold_tkeep;
    reg         hold_tlast;
    reg         hold_valid;
    reg         in_pkt;
    reg         fcs_pending;
    reg [2:0]   fcs_remain_cnt;

    wire        in_fire = in_valid && in_ready;
    wire        out_fire = out_valid && out_ready;
    wire        sop = in_fire && !in_pkt;

    wire [31:0] fcs_raw;
    wire [31:0] fcs = fcs_raw;

    wire [127:0] crc_data_in = sop ? {in_data[127:64], 64'h0} : in_data;
    wire [15:0]  crc_byte_en = sop ? {in_tkeep[15:8], 8'h00} : (in_fire ? in_tkeep : 16'h0);

    crc32 u_crc32 (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (sop),
        .data_in   (crc_data_in),
        .byte_en   (crc_byte_en),
        .crc_out   (fcs_raw),
        .crc_valid ()
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            hold_data  <= 128'h0;
            hold_tkeep <= 16'h0;
            hold_tlast <= 1'b0;
            hold_valid <= 1'b0;
        end else begin
            if (out_fire) begin
                if (in_fire) begin
                    hold_data  <= in_data;
                    hold_tkeep <= in_tkeep;
                    hold_tlast <= in_tlast;
                    hold_valid <= 1'b1;
                end else begin
                    hold_valid <= 1'b0;
                end
            end else if (in_fire && !hold_valid) begin
                hold_data  <= in_data;
                hold_tkeep <= in_tkeep;
                hold_tlast <= in_tlast;
                hold_valid <= 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            in_pkt <= 1'b0;
        end else begin
            if (in_fire && !in_pkt) in_pkt <= 1'b1;
            if (in_fire && in_tlast) in_pkt <= 1'b0;
        end
    end

    function [4:0] count_ones;
        input [15:0] val;
        integer i;
        begin
            count_ones = 5'd0;
            for (i = 0; i < 16; i = i + 1) begin
                count_ones = count_ones + val[i];
            end
        end
    endfunction

    wire [4:0] n_bytes_high = count_ones(hold_tkeep[15:8]);
    wire [4:0] n_bytes_low  = count_ones(hold_tkeep[7:0]);
    wire [4:0] n_bytes = n_bytes_high + n_bytes_low;
    wire       can_merge = (n_bytes <= 12);
    wire       need_split = (n_bytes >= 13) && (n_bytes <= 15);
    wire       data_in_low = (n_bytes_high == 0) && (n_bytes_low > 0);
    wire       data_split = (n_bytes_high > 0) && (n_bytes_low > 0);

    wire [2:0] fcs_partial_bytes = need_split ? (3'd4 - (n_bytes - 5'd12)) : 3'd0;
    wire [2:0] fcs_remain_bytes = need_split ? (n_bytes - 5'd12) : 3'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            fcs_pending <= 1'b0;
            fcs_remain_cnt <= 3'd0;
        end else if (out_fire) begin
            if (fcs_pending) begin
                fcs_pending <= 1'b0;
                fcs_remain_cnt <= 3'd0;
            end else if (hold_tlast && !can_merge) begin
                fcs_pending <= 1'b1;
                fcs_remain_cnt <= fcs_remain_bytes;
            end
        end
    end

    assign in_ready = !hold_valid || out_fire;

    assign out_valid = fcs_pending || hold_valid;

    reg [127:0] out_data_reg;
    reg [15:0]  out_tkeep_reg;
    reg         out_tlast_reg;

    always @(*) begin
        if (fcs_pending) begin
            case (fcs_remain_cnt)
                3'd1: begin
                    out_data_reg  = {120'h0, fcs[31:24]};
                    out_tkeep_reg = 16'h0001;
                end
                3'd2: begin
                    out_data_reg  = {112'h0, fcs[31:16]};
                    out_tkeep_reg = 16'h0003;
                end
                3'd3: begin
                    out_data_reg  = {104'h0, fcs[31:8]};
                    out_tkeep_reg = 16'h0007;
                end
                default: begin
                    out_data_reg  = {96'h0, fcs};
                    out_tkeep_reg = 16'h000F;
                end
            endcase
            out_tlast_reg = 1'b1;
        end else if (hold_tlast) begin
            if (can_merge) begin
                if (data_in_low) begin
                    case (n_bytes_low)
                        5'd1: begin
                            out_data_reg  = {88'h0, fcs, hold_data[7:0]};
                            out_tkeep_reg = 16'h001F;
                        end
                        5'd2: begin
                            out_data_reg  = {80'h0, fcs, hold_data[15:0]};
                            out_tkeep_reg = 16'h003F;
                        end
                        5'd3: begin
                            out_data_reg  = {72'h0, fcs, hold_data[23:0]};
                            out_tkeep_reg = 16'h007F;
                        end
                        5'd4: begin
                            out_data_reg  = {64'h0, fcs, hold_data[31:0]};
                            out_tkeep_reg = 16'h00FF;
                        end
                        5'd5: begin
                            out_data_reg  = {56'h0, fcs, hold_data[39:0]};
                            out_tkeep_reg = 16'h01FF;
                        end
                        5'd6: begin
                            out_data_reg  = {48'h0, fcs, hold_data[47:0]};
                            out_tkeep_reg = 16'h03FF;
                        end
                        5'd7: begin
                            out_data_reg  = {40'h0, fcs, hold_data[55:0]};
                            out_tkeep_reg = 16'h07FF;
                        end
                        default: begin
                            out_data_reg  = {32'h0, fcs, hold_data[63:0]};
                            out_tkeep_reg = 16'h0FFF;
                        end
                    endcase
                end else if (data_split) begin
                    if (n_bytes_low == 5'd8) begin
                        case (n_bytes_high)
                            5'd1: begin
                                out_data_reg  = {24'h0, fcs, hold_data[71:0]};
                                out_tkeep_reg = 16'h1FFF;
                            end
                            5'd2: begin
                                out_data_reg  = {16'h0, fcs, hold_data[79:0]};
                                out_tkeep_reg = 16'h3FFF;
                            end
                            5'd3: begin
                                out_data_reg  = {8'h0, fcs, hold_data[87:0]};
                                out_tkeep_reg = 16'h7FFF;
                            end
                            5'd4: begin
                                out_data_reg  = {fcs, hold_data[95:0]};
                                out_tkeep_reg = 16'hFFFF;
                            end
                            default: begin
                                out_data_reg  = {hold_data[127:32], fcs};
                                out_tkeep_reg = {hold_tkeep[15:4], 4'hF};
                            end
                        endcase
                    end else begin
                        out_data_reg  = {hold_data[127:32], fcs};
                        out_tkeep_reg = {hold_tkeep[15:4], 4'hF};
                    end
                end else begin
                    out_data_reg  = {hold_data[127:32], fcs};
                    out_tkeep_reg = {hold_tkeep[15:4], 4'hF};
                end
                out_tlast_reg = 1'b1;
            end else if (need_split) begin
                case (n_bytes)
                    5'd13: begin
                        out_data_reg  = {fcs[23:0], hold_data[103:0]};
                        out_tkeep_reg = 16'hFFFF;
                    end
                    5'd14: begin
                        out_data_reg  = {fcs[15:0], hold_data[111:0]};
                        out_tkeep_reg = 16'hFFFF;
                    end
                    5'd15: begin
                        out_data_reg  = {fcs[7:0], hold_data[119:0]};
                        out_tkeep_reg = 16'hFFFF;
                    end
                    default: begin
                        out_data_reg  = hold_data;
                        out_tkeep_reg = hold_tkeep;
                    end
                endcase
                out_tlast_reg = 1'b0;
            end else begin
                out_data_reg  = hold_data;
                out_tkeep_reg = hold_tkeep;
                out_tlast_reg = 1'b0;
            end
        end else begin
            out_data_reg  = hold_data;
            out_tkeep_reg = hold_tkeep;
            out_tlast_reg = hold_tlast;
        end
    end

    assign out_data  = out_data_reg;
    assign out_tkeep = out_tkeep_reg;
    assign out_tlast = out_tlast_reg;

endmodule
