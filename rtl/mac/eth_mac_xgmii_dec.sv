module eth_mac_xgmii_dec (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [127:0] pcs_rx_data,
    input  wire [15:0]  pcs_rx_ctrl,
    input  wire         pcs_rx_valid,
    output wire         pcs_rx_ready,

    output wire         out_valid,
    output wire [127:0] out_data,
    output wire [15:0]  out_tkeep,
    output wire         out_tlast,
    input  wire         out_ready
);

    reg         in_pkt;
    reg         pending_output;

    wire [15:0] byte_is_start;
    wire [15:0] byte_is_terminate;

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : gen_ctrl_detect
            assign byte_is_start[gi]      = pcs_rx_ctrl[gi] && (pcs_rx_data[gi*8 +: 8] == 8'hFB);
            assign byte_is_terminate[gi]  = pcs_rx_ctrl[gi] && (pcs_rx_data[gi*8 +: 8] == 8'hFD);
        end
    endgenerate

    wire has_start = |byte_is_start;
    wire has_terminate = |byte_is_terminate;

    function [4:0] find_first_start;
        input [15:0] start_mask;
        integer i;
        begin
            find_first_start = 5'h1F;
            for (i = 0; i < 16; i = i + 1) begin
                if (start_mask[i]) begin
                    find_first_start = i[4:0];
                end
            end
        end
    endfunction

    function [4:0] find_first_terminate;
        input [15:0] term_mask;
        integer i;
        begin
            find_first_terminate = 5'h1F;
            for (i = 0; i < 16; i = i + 1) begin
                if (term_mask[i]) begin
                    find_first_terminate = i[4:0];
                end
            end
        end
    endfunction

    wire [4:0] start_pos = find_first_start(byte_is_start);
    wire [4:0] term_pos = find_first_terminate(byte_is_terminate);

    wire [15:0] tkeep_from_term = (term_pos == 5'h1F) ? 16'hFFFF : ((16'h1 << term_pos) - 1'b1);

    always @(posedge clk) begin
        if (!rst_n) begin
            in_pkt         <= 1'b0;
            pending_output <= 1'b0;
        end else if (pcs_rx_valid && out_ready) begin
            if (pending_output) begin
                pending_output <= 1'b0;
            end
            if (!in_pkt && has_start) begin
                in_pkt <= 1'b1;
                if (has_terminate) begin
                    pending_output <= 1'b1;
                end
            end else if (in_pkt && has_terminate) begin
                in_pkt         <= 1'b0;
                pending_output <= 1'b1;
            end
        end
    end

    assign pcs_rx_ready = out_ready;

    reg [127:0] skid_data;
    reg [15:0]  skid_tkeep;
    reg         skid_tlast;
    reg         skid_valid;

    wire should_output = pcs_rx_valid && (in_pkt || has_start);
    wire out_fire = out_valid && out_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            skid_data  <= 128'h0;
            skid_tkeep <= 16'h0;
            skid_tlast <= 1'b0;
            skid_valid <= 1'b0;
        end else begin
            if (out_ready) begin
                if (should_output) begin
                    skid_valid <= 1'b1;
                    if (has_start) begin
                        if (start_pos < 5'd15) begin
                            skid_data <= pcs_rx_data >> ((start_pos + 1'b1) * 8);
                        end else begin
                            skid_data <= 128'h0;
                        end
                        if (has_terminate) begin
                            if (term_pos > start_pos + 1) begin
                                skid_tkeep <= (16'h1 << (term_pos - start_pos - 1)) - 1'b1;
                            end else begin
                                skid_tkeep <= 16'h0;
                            end
                            skid_tlast <= 1'b1;
                        end else begin
                            skid_tkeep <= (16'h1 << (15 - start_pos)) - 1'b1;
                            skid_tlast <= 1'b0;
                        end
                    end else begin
                        skid_data  <= pcs_rx_data;
                        skid_tkeep <= has_terminate ? tkeep_from_term : 16'hFFFF;
                        skid_tlast <= has_terminate;
                    end
                end else begin
                    skid_valid <= 1'b0;
                end
            end
        end
    end

    assign out_valid = skid_valid;
    assign out_data  = skid_data;
    assign out_tkeep = skid_tkeep;
    assign out_tlast = skid_tlast;

endmodule
