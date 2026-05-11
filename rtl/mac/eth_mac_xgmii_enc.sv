module eth_mac_xgmii_enc (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         in_valid,
    input  wire [127:0] in_data,
    input  wire [15:0]  in_tkeep,
    input  wire         in_tlast,
    input  wire [3:0]   ipg_bytes,
    input  wire         need_t_cycle,
    output wire         in_ready,

    output wire         out_valid,
    output wire [127:0] out_data,
    output wire [15:0]  out_ctrl,
    input  wire         out_ready
);

    reg [127:0] out_data_reg;
    reg [15:0]  out_ctrl_reg;
    reg [2:0]   state;
    reg [3:0]   ipg_cnt;
    reg         in_pkt;

    localparam STATE_IDLE      = 3'd0;
    localparam STATE_T_CYCLE   = 3'd1;
    localparam STATE_IPG       = 3'd2;

    function [4:0] popcount;
        input [15:0] val;
        integer i;
        begin
            popcount = 5'd0;
            for (i = 0; i < 16; i = i + 1) begin
                popcount = popcount + val[i];
            end
        end
    endfunction

    wire [4:0] first_invalid = popcount(in_tkeep);
    wire sop = in_valid && in_ready && !in_pkt;

    reg [127:0] tail_data;
    reg [15:0]  tail_ctrl;

    integer i;
    always @(*) begin
        for (i = 0; i < 16; i = i + 1) begin
            if (in_tkeep[i]) begin
                tail_data[i*8 +: 8] = in_data[i*8 +: 8];
                tail_ctrl[i] = 1'b0;
            end else if (i == first_invalid) begin
                tail_data[i*8 +: 8] = 8'hFD;
                tail_ctrl[i] = 1'b1;
            end else begin
                tail_data[i*8 +: 8] = 8'h07;
                tail_ctrl[i] = 1'b1;
            end
        end
    end

    assign out_valid = 1'b1;
    assign in_ready = (state == STATE_IDLE) && out_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= STATE_IDLE;
            ipg_cnt      <= 4'h0;
            out_data_reg <= {16{8'h07}};
            out_ctrl_reg <= 16'hFFFF;
            in_pkt       <= 1'b0;
        end else if (out_ready) begin
            case (state)
                STATE_IDLE: begin
                    if (in_valid && in_ready) begin
                        if (sop) begin
                            in_pkt <= 1'b1;
                        end
                        
                        if (in_tlast) begin
                            if (need_t_cycle) begin
                                out_data_reg <= in_data;
                                out_ctrl_reg <= 16'h0000;
                                if (sop) begin
                                    out_data_reg[7:0] <= 8'hFB;
                                    out_ctrl_reg[0] <= 1'b1;
                                end
                                state <= STATE_T_CYCLE;
                                ipg_cnt <= ipg_bytes;
                            end else begin
                                out_data_reg <= tail_data;
                                out_ctrl_reg <= tail_ctrl;
                                if (sop) begin
                                    out_data_reg[7:0] <= 8'hFB;
                                    out_ctrl_reg[0] <= 1'b1;
                                end
                                if (ipg_bytes > 0) begin
                                    state <= STATE_IPG;
                                    ipg_cnt <= ipg_bytes;
                                end
                            end
                            in_pkt <= 1'b0;
                        end else begin
                            out_data_reg <= in_data;
                            out_ctrl_reg <= 16'h0000;
                            if (sop) begin
                                out_data_reg[7:0] <= 8'hFB;
                                out_ctrl_reg[0] <= 1'b1;
                            end
                        end
                    end else begin
                        out_data_reg <= {16{8'h07}};
                        out_ctrl_reg <= 16'hFFFF;
                    end
                end
                
                STATE_T_CYCLE: begin
                    out_data_reg <= {{15{8'h07}}, 8'hFD};
                    out_ctrl_reg <= 16'hFFFF;
                    in_pkt <= 1'b0;
                    if (ipg_cnt > 0) begin
                        state <= STATE_IPG;
                    end else begin
                        state <= STATE_IDLE;
                    end
                end
                
                STATE_IPG: begin
                    out_data_reg <= {16{8'h07}};
                    out_ctrl_reg <= 16'hFFFF;
                    in_pkt <= 1'b0;
                    if (ipg_cnt <= 16) begin
                        state <= STATE_IDLE;
                        ipg_cnt <= 4'h0;
                    end else begin
                        ipg_cnt <= ipg_cnt - 4'd16;
                    end
                end
                
                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

    assign out_data = out_data_reg;
    assign out_ctrl = out_ctrl_reg;

endmodule
