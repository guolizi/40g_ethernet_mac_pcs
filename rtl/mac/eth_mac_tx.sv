module eth_mac_tx (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [127:0] s_axis_tdata,
    input  wire [15:0]  s_axis_tkeep,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,

    output wire [127:0] mac_tx_data,
    output wire [15:0]  mac_tx_ctrl,
    output wire         mac_tx_valid,
    input  wire         mac_tx_ready,

    input  wire         pause_req,
    input  wire [15:0]  pause_time,
    input  wire [47:0]  pause_src_mac,

    input  wire [7:0]   ipg_cfg,

    output wire         pause_busy,

    output wire         tx_frame_done,
    output wire [15:0]  tx_byte_cnt,
    output wire         tx_pause_done
);

    wire        fifo_wr_en;
    wire [127:0] fifo_wr_data;
    wire [15:0]  fifo_wr_tkeep;
    wire         fifo_wr_tlast;
    wire         fifo_full;
    wire         fifo_almost_full;

    wire        fifo2pause_valid;
    wire [127:0] fifo2pause_data;
    wire [15:0]  fifo2pause_tkeep;
    wire         fifo2pause_tlast;
    wire         pause2fifo_ready;

    wire        pause2pre_valid;
    wire [127:0] pause2pre_data;
    wire [15:0]  pause2pre_tkeep;
    wire         pause2pre_tlast;
    wire         pre2pause_ready;

    wire        pre2fcs_valid;
    wire [127:0] pre2fcs_data;
    wire [15:0]  pre2fcs_tkeep;
    wire         pre2fcs_tlast;
    wire         fcs2pre_ready;

    wire        fcs2ipg_valid;
    wire [127:0] fcs2ipg_data;
    wire [15:0]  fcs2ipg_tkeep;
    wire         fcs2ipg_tlast;
    wire         ipg2fcs_ready;

    wire        ipg2enc_valid;
    wire [127:0] ipg2enc_data;
    wire [15:0]  ipg2enc_tkeep;
    wire         ipg2enc_tlast;
    wire [3:0]   ipg2enc_ipg_bytes;
    wire         ipg2enc_need_t;
    wire         enc2ipg_ready;

    assign s_axis_tready = !fifo_almost_full;
    assign fifo_wr_en    = s_axis_tvalid && s_axis_tready;
    assign fifo_wr_data  = s_axis_tdata;
    assign fifo_wr_tkeep = s_axis_tkeep;
    assign fifo_wr_tlast = s_axis_tlast;

    eth_mac_tx_fifo u_tx_fifo (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr_en        (fifo_wr_en),
        .wr_data      (fifo_wr_data),
        .wr_tkeep     (fifo_wr_tkeep),
        .wr_tlast     (fifo_wr_tlast),
        .full         (fifo_full),
        .almost_full  (fifo_almost_full),
        .rd_en        (pause2fifo_ready),
        .rd_data      (fifo2pause_data),
        .rd_tkeep     (fifo2pause_tkeep),
        .rd_tlast     (fifo2pause_tlast),
        .rd_valid     (fifo2pause_valid),
        .empty        ()
    );

    eth_mac_tx_pause u_tx_pause (
        .clk            (clk),
        .rst_n          (rst_n),
        .in_valid       (fifo2pause_valid),
        .in_data        (fifo2pause_data),
        .in_tkeep       (fifo2pause_tkeep),
        .in_tlast       (fifo2pause_tlast),
        .in_ready       (pause2fifo_ready),
        .out_valid      (pause2pre_valid),
        .out_data       (pause2pre_data),
        .out_tkeep      (pause2pre_tkeep),
        .out_tlast      (pause2pre_tlast),
        .out_ready      (pre2pause_ready),
        .pause_req      (pause_req),
        .pause_time     (pause_time),
        .pause_src_mac  (pause_src_mac),
        .pause_busy     (pause_busy)
    );

    eth_mac_tx_preamble u_tx_preamble (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (pause2pre_valid),
        .in_data    (pause2pre_data),
        .in_tkeep   (pause2pre_tkeep),
        .in_tlast   (pause2pre_tlast),
        .in_ready   (pre2pause_ready),
        .out_valid  (pre2fcs_valid),
        .out_data   (pre2fcs_data),
        .out_tkeep  (pre2fcs_tkeep),
        .out_tlast  (pre2fcs_tlast),
        .out_ready  (fcs2pre_ready)
    );

    eth_mac_tx_fcs u_tx_fcs (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (pre2fcs_valid),
        .in_data    (pre2fcs_data),
        .in_tkeep   (pre2fcs_tkeep),
        .in_tlast   (pre2fcs_tlast),
        .in_ready   (fcs2pre_ready),
        .out_valid  (fcs2ipg_valid),
        .out_data   (fcs2ipg_data),
        .out_tkeep  (fcs2ipg_tkeep),
        .out_tlast  (fcs2ipg_tlast),
        .out_ready  (ipg2fcs_ready)
    );

    eth_mac_tx_ipg u_tx_ipg (
        .clk          (clk),
        .rst_n        (rst_n),
        .ipg_cfg      (ipg_cfg),
        .in_valid     (fcs2ipg_valid),
        .in_data      (fcs2ipg_data),
        .in_tkeep     (fcs2ipg_tkeep),
        .in_tlast     (fcs2ipg_tlast),
        .in_ready     (ipg2fcs_ready),
        .out_valid    (ipg2enc_valid),
        .out_data     (ipg2enc_data),
        .out_tkeep    (ipg2enc_tkeep),
        .out_tlast    (ipg2enc_tlast),
        .ipg_bytes    (ipg2enc_ipg_bytes),
        .need_t_cycle (ipg2enc_need_t),
        .out_ready    (enc2ipg_ready)
    );

    eth_mac_xgmii_enc u_xgmii_enc (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_valid     (ipg2enc_valid),
        .in_data      (ipg2enc_data),
        .in_tkeep     (ipg2enc_tkeep),
        .in_tlast     (ipg2enc_tlast),
        .ipg_bytes    (ipg2enc_ipg_bytes),
        .need_t_cycle (ipg2enc_need_t),
        .in_ready     (enc2ipg_ready),
        .out_valid    (mac_tx_valid),
        .out_data     (mac_tx_data),
        .out_ctrl     (mac_tx_ctrl),
        .out_ready    (mac_tx_ready)
    );

    reg         tx_frame_done_reg;
    reg [15:0]  tx_byte_cnt_reg;
    reg         tx_pause_done_reg;
    reg [15:0]  frame_byte_cnt;
    reg         in_tx_frame;

    wire enc_out_fire = mac_tx_valid && mac_tx_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            tx_frame_done_reg <= 1'b0;
            tx_byte_cnt_reg   <= 16'h0;
            tx_pause_done_reg <= 1'b0;
            frame_byte_cnt    <= 16'h0;
            in_tx_frame       <= 1'b0;
        end else begin
            tx_frame_done_reg <= 1'b0;
            tx_pause_done_reg <= 1'b0;

            if (enc_out_fire) begin
                if (!in_tx_frame) begin
                    in_tx_frame    <= 1'b1;
                    frame_byte_cnt <= $countones(mac_tx_ctrl ? 16'h0 : 16'hFFFF);
                end else begin
                    frame_byte_cnt <= frame_byte_cnt + $countones(mac_tx_ctrl ? 16'h0 : 16'hFFFF);
                end

                if (ipg2enc_tlast) begin
                    tx_frame_done_reg <= 1'b1;
                    tx_byte_cnt_reg   <= frame_byte_cnt + $countones(ipg2enc_tkeep);
                    in_tx_frame       <= 1'b0;
                end
            end
        end
    end

    assign tx_frame_done = tx_frame_done_reg;
    assign tx_byte_cnt   = tx_byte_cnt_reg;
    assign tx_pause_done = tx_pause_done_reg;

endmodule
