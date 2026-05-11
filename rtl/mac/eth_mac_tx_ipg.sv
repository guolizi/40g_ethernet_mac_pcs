module eth_mac_tx_ipg (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [7:0]   ipg_cfg,

    input  wire         in_valid,
    input  wire [127:0] in_data,
    input  wire [15:0]  in_tkeep,
    input  wire         in_tlast,
    output wire         in_ready,

    output wire         out_valid,
    output wire [127:0] out_data,
    output wire [15:0]  out_tkeep,
    output wire         out_tlast,
    output wire [3:0]   ipg_bytes,
    output wire         need_t_cycle,
    input  wire         out_ready
);

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

    reg [127:0] data_reg;
    reg [15:0]  tkeep_reg;
    reg         tlast_reg;
    reg         valid_reg;
    reg [3:0]   ipg_bytes_reg;
    reg         need_t_cycle_reg;

    wire [4:0]  valid_bytes = popcount(in_tkeep);
    wire [4:0]  invalid_bytes = 16 - valid_bytes;
    wire [5:0]  tail_ipg = (invalid_bytes > 0) ? (invalid_bytes - 1) : 6'd0;
    wire [8:0]  ipg_rem_ext = (ipg_cfg > tail_ipg) ? ({1'b0, ipg_cfg} - {1'b0, tail_ipg}) : 9'd0;
    wire        ipg_overflow = ipg_rem_ext > 15;
    wire [3:0]  ipg_rem = ipg_overflow ? 4'd15 : ipg_rem_ext[3:0];
    wire        need_t = (invalid_bytes == 0) && in_tlast;

    wire        in_fire = in_valid && in_ready;
    wire        out_fire = out_valid && out_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            data_reg        <= 128'h0;
            tkeep_reg       <= 16'h0;
            tlast_reg       <= 1'b0;
            valid_reg       <= 1'b0;
            ipg_bytes_reg   <= 4'h0;
            need_t_cycle_reg <= 1'b0;
        end else begin
            if (out_fire) begin
                if (in_fire) begin
                    data_reg        <= in_data;
                    tkeep_reg       <= in_tkeep;
                    tlast_reg       <= in_tlast;
                    valid_reg       <= 1'b1;
                    ipg_bytes_reg   <= in_tlast ? ipg_rem : 4'h0;
                    need_t_cycle_reg <= in_tlast ? need_t : 1'b0;
                end else begin
                    valid_reg       <= 1'b0;
                end
            end else if (in_fire && !valid_reg) begin
                data_reg        <= in_data;
                tkeep_reg       <= in_tkeep;
                tlast_reg       <= in_tlast;
                valid_reg       <= 1'b1;
                ipg_bytes_reg   <= in_tlast ? ipg_rem : 4'h0;
                need_t_cycle_reg <= in_tlast ? need_t : 1'b0;
            end
        end
    end

    assign in_ready      = !valid_reg || out_ready;
    assign out_valid     = valid_reg;
    assign out_data      = data_reg;
    assign out_tkeep     = tkeep_reg;
    assign out_tlast     = tlast_reg;
    assign ipg_bytes     = ipg_bytes_reg;
    assign need_t_cycle  = need_t_cycle_reg;

endmodule
