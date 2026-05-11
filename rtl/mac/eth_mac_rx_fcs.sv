module eth_mac_rx_fcs (
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

    output wire         fcs_error,
    output wire         fcs_valid
);

    reg         in_pkt;

    reg [127:0] dly_data_0, dly_data_1;
    reg [15:0]  dly_tkeep_0, dly_tkeep_1;
    reg         dly_tlast_0, dly_tlast_1;
    reg         dly_valid_0, dly_valid_1;

    wire [31:0] crc_out;

    reg         fcs_error_reg;
    reg         fcs_valid_reg;
    reg [31:0]  saved_crc;

    wire in_fire = in_valid && in_ready;
    wire out_fire = out_valid && out_ready;
    wire sop = in_fire && !in_pkt;

    crc32 u_crc32 (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (sop),
        .data_in   (in_data),
        .byte_en   (in_fire ? in_tkeep : 16'h0),
        .crc_out   (crc_out),
        .crc_valid ()
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            in_pkt <= 1'b0;
        end else if (in_fire) begin
            if (!in_pkt) begin
                in_pkt <= 1'b1;
            end
            
            if (in_tlast) begin
                in_pkt <= 1'b0;
            end
        end
    end

    function [4:0] count_ones;
        input [15:0] vec;
        integer i;
        begin
            count_ones = 0;
            for (i = 0; i < 16; i = i + 1) begin
                if (vec[i]) count_ones = count_ones + 1;
            end
        end
    endfunction

    wire [4:0]  out_valid_bytes;
    wire        is_last_chunk;
    wire        skip_output;
    wire        next_is_fcs_only;
    
    assign out_valid_bytes = count_ones(dly_tkeep_1);
    assign next_is_fcs_only = dly_valid_0 && dly_tlast_0 && (count_ones(dly_tkeep_0) <= 5'd4);
    assign is_last_chunk = dly_tlast_1 || next_is_fcs_only || (dly_valid_0 && dly_tlast_0 && (count_ones(dly_tkeep_0) == 0));
    assign skip_output = is_last_chunk && out_valid_bytes <= 5'd4 && !next_is_fcs_only;
    
    wire skip_fire = dly_valid_1 && skip_output && out_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            dly_data_0  <= 128'h0;
            dly_data_1  <= 128'h0;
            dly_tkeep_0 <= 16'h0;
            dly_tkeep_1 <= 16'h0;
            dly_tlast_0 <= 1'b0;
            dly_tlast_1 <= 1'b0;
            dly_valid_0 <= 1'b0;
            dly_valid_1 <= 1'b0;
        end else begin
            if (in_fire) begin
                dly_data_0  <= in_data;
                dly_tkeep_0 <= in_tkeep;
                dly_tlast_0 <= in_tlast;
                dly_valid_0 <= 1'b1;
            end else begin
                dly_valid_0 <= 1'b0;
            end
            
            if (out_fire || skip_fire) begin
                if (dly_valid_0) begin
                    dly_data_1  <= dly_data_0;
                    dly_tkeep_1 <= dly_tkeep_0;
                    dly_tlast_1 <= dly_tlast_0;
                    dly_valid_1 <= 1'b1;
                end else begin
                    dly_valid_1 <= 1'b0;
                end
            end else if (dly_valid_0 && !dly_valid_1) begin
                dly_data_1  <= dly_data_0;
                dly_tkeep_1 <= dly_tkeep_0;
                dly_tlast_1 <= dly_tlast_0;
                dly_valid_1 <= 1'b1;
            end
        end
    end

    wire frame_end = dly_tlast_1 && dly_valid_1 && (out_fire || skip_fire);

    always @(posedge clk) begin
        if (!rst_n) begin
            fcs_error_reg <= 1'b0;
            fcs_valid_reg <= 1'b0;
            saved_crc     <= 32'h0;
        end else begin
            if (frame_end) begin
                saved_crc     <= crc_out;
                fcs_error_reg <= (crc_out != 32'h2144DF1C);
                fcs_valid_reg <= 1'b1;
            end else if (out_fire && dly_tlast_1) begin
                fcs_error_reg <= 1'b0;
                fcs_valid_reg <= 1'b0;
            end
        end
    end

    wire [4:0]  fcs_bytes_in_next;
    wire [4:0]  fcs_bytes_in_current;
    wire [15:0] adjusted_tkeep;
    
    assign fcs_bytes_in_next = next_is_fcs_only ? count_ones(dly_tkeep_0) : 5'd0;
    assign fcs_bytes_in_current = is_last_chunk ? (5'd4 - fcs_bytes_in_next) : 5'd0;
    
    assign adjusted_tkeep = is_last_chunk ? 
        (out_valid_bytes > fcs_bytes_in_current ? ((16'h1 << (out_valid_bytes - fcs_bytes_in_current)) - 1'b1) : 16'h0) : 
        dly_tkeep_1;

    assign out_valid = dly_valid_1 && !skip_output;

    assign out_data  = dly_data_1;
    assign out_tkeep = adjusted_tkeep;
    assign out_tlast = (dly_tlast_1 || next_is_fcs_only) && !skip_output;

    assign in_ready = !dly_valid_0 || out_ready;

    assign fcs_error = fcs_error_reg;
    assign fcs_valid = fcs_valid_reg;

endmodule
