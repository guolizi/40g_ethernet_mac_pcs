module eth_mac_tx_pause (
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

    input  wire         pause_req,
    input  wire [15:0]  pause_time,
    input  wire [47:0]  pause_src_mac,

    output wire         pause_busy
);

    localparam IDLE         = 2'b00;
    localparam WAIT_EOP     = 2'b01;
    localparam PAUSE_INSERT = 2'b10;

    localparam [47:0] PAUSE_DA     = 48'h01_80_C2_00_00_01;
    localparam [15:0] PAUSE_TYPE   = 16'h0888;
    localparam [15:0] PAUSE_OPCODE = 16'h0100;

    reg [1:0] state;
    reg [1:0] pause_cycle;
    reg [15:0] pause_time_reg;

    reg [127:0] hold_data;
    reg [15:0]  hold_tkeep;
    reg         hold_tlast;
    reg         hold_valid;

    wire in_fire = in_valid && in_ready;
    wire out_fire = out_valid && out_ready;

    assign in_ready = (state == IDLE) ? (!hold_valid || out_ready) && !pause_req :
                      (state == WAIT_EOP) ? 1'b1 : 1'b0;
    assign pause_busy = (state != IDLE);

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

    reg [127:0] pause_data_reg;
    reg [15:0]  pause_tkeep_reg;
    reg         pause_tlast_reg;

    always @(*) begin
        case (pause_cycle)
            2'd0: begin
                pause_data_reg  = {PAUSE_OPCODE, PAUSE_TYPE, pause_src_mac, PAUSE_DA};
                pause_tkeep_reg = 16'hFFFF;
                pause_tlast_reg = 1'b0;
            end
            2'd1: begin
                pause_data_reg  = {112'h0, pause_time_reg};
                pause_tkeep_reg = 16'hFFFF;
                pause_tlast_reg = 1'b0;
            end
            2'd2: begin
                pause_data_reg  = 128'h0;
                pause_tkeep_reg = 16'hFFFF;
                pause_tlast_reg = 1'b0;
            end
            2'd3: begin
                pause_data_reg  = 128'h0;
                pause_tkeep_reg = 16'h0FFF;
                pause_tlast_reg = 1'b1;
            end
            default: begin
                pause_data_reg  = 128'h0;
                pause_tkeep_reg = 16'h0;
                pause_tlast_reg = 1'b0;
            end
        endcase
    end

    assign out_valid = (state == IDLE) ? hold_valid :
                       (state == PAUSE_INSERT) ? 1'b1 : 1'b0;
    assign out_data  = (state == IDLE) ? hold_data : pause_data_reg;
    assign out_tkeep = (state == IDLE) ? hold_tkeep : pause_tkeep_reg;
    assign out_tlast = (state == IDLE) ? hold_tlast : pause_tlast_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= IDLE;
            pause_cycle  <= 2'd0;
            pause_time_reg <= 16'd0;
        end else begin
            case (state)
                IDLE: begin
                    if (pause_req) begin
                        pause_time_reg <= pause_time;
                        if (!hold_valid || (hold_tlast && hold_valid)) begin
                            state <= PAUSE_INSERT;
                            pause_cycle <= 2'd0;
                        end else begin
                            state <= WAIT_EOP;
                        end
                    end
                end

                WAIT_EOP: begin
                    if (hold_tlast && hold_valid && out_ready) begin
                        state <= PAUSE_INSERT;
                        pause_cycle <= 2'd0;
                    end
                end

                PAUSE_INSERT: begin
                    if (out_ready) begin
                        if (pause_cycle == 2'd3) begin
                            state <= IDLE;
                            pause_cycle <= 2'd0;
                        end else begin
                            pause_cycle <= pause_cycle + 1'b1;
                        end
                    end
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
