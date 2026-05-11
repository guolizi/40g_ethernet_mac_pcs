module eth_mac_rx_pause (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         in_valid,
    input  wire [127:0] in_data,
    input  wire [15:0]  in_tkeep,
    input  wire         in_tlast,
    input  wire         fcs_error,
    output wire         in_ready,

    output wire         out_valid,
    output wire [127:0] out_data,
    output wire [15:0]  out_tkeep,
    output wire         out_tlast,
    input  wire         out_ready,

    output wire         pause_req,
    output wire [15:0]  pause_time,
    output wire         pause_detected
);

    localparam [47:0] PAUSE_DA     = 48'h01_80_C2_00_00_01;
    localparam [15:0] PAUSE_TYPE   = 16'h8808;
    localparam [15:0] PAUSE_OPCODE = 16'h0001;

    reg         in_pkt;
    reg [1:0]   cycle_cnt;
    reg         pause_frame;
    reg         pause_frame_reg;
    reg [15:0]  pause_time_reg;
    reg         pause_req_reg;

    wire in_fire = in_valid && in_ready;
    wire sop = in_fire && !in_pkt;

    wire [47:0] rx_da = {in_data[7:0], in_data[15:8], in_data[23:16], in_data[31:24], in_data[39:32], in_data[47:40]};
    wire [15:0] rx_type = {in_data[103:96], in_data[111:104]};
    wire [15:0] rx_opcode = {in_data[119:112], in_data[127:120]};

    wire pause_da_match     = (rx_da == PAUSE_DA);
    wire pause_type_match   = (rx_type == PAUSE_TYPE);
    wire pause_opcode_match = (rx_opcode == PAUSE_OPCODE);

    wire pause_detected_now = sop && pause_da_match && 
                              pause_type_match && pause_opcode_match;

    always @(posedge clk) begin
        if (!rst_n) begin
            in_pkt          <= 1'b0;
            cycle_cnt       <= 2'd0;
            pause_frame     <= 1'b0;
            pause_frame_reg <= 1'b0;
        end else if (in_fire) begin
            if (sop) begin
                in_pkt      <= 1'b1;
                cycle_cnt   <= 2'd0;
                pause_frame <= pause_detected_now;
            end else begin
                cycle_cnt <= cycle_cnt + 1'b1;
            end
            
            if (in_tlast) begin
                in_pkt          <= 1'b0;
                pause_frame_reg <= pause_frame;
                pause_frame     <= 1'b0;
            end
        end
    end

    wire [15:0] rx_pause_time = {in_data[7:0], in_data[15:8]};
    
    wire is_second_cycle = in_fire && in_pkt && (cycle_cnt == 2'd0);

    always @(posedge clk) begin
        if (!rst_n) begin
            pause_time_reg <= 16'h0;
        end else if (is_second_cycle && pause_frame) begin
            pause_time_reg <= rx_pause_time;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            pause_req_reg <= 1'b0;
        end else begin
            pause_req_reg <= in_fire && in_tlast && pause_frame && !fcs_error;
        end
    end

    assign out_valid = in_valid;
    assign out_data  = in_data;
    assign out_tkeep = in_tkeep;
    assign out_tlast = in_tlast;
    assign in_ready  = out_ready;

    assign pause_req      = pause_req_reg;
    assign pause_time     = pause_time_reg;
    assign pause_detected = pause_frame_reg;

endmodule
