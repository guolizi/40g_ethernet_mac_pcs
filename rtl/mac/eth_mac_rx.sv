module eth_mac_rx (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [127:0] pcs_rx_data,
    input  wire [15:0]  pcs_rx_ctrl,
    input  wire         pcs_rx_valid,
    output wire         pcs_rx_ready,

    output wire [127:0] m_axis_tdata,
    output wire [15:0]  m_axis_tkeep,
    output wire         m_axis_tlast,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,

    output wire         pause_req,
    output wire [15:0]  pause_time,

    output wire         fcs_error,
    output wire         sop_detected,
    output wire         preamble_error,

    output wire         rx_frame_done,
    output wire [15:0]  rx_byte_cnt,
    output wire         rx_short_frame,
    output wire         rx_long_frame,
    output wire         rx_alignment_error,
    output wire         rx_pause_frame,
    output wire         rx_vlan_frame,
    output wire         rx_dropped,
    output wire [15:0]  rx_frame_len
);

    wire        dec2pre_valid;
    wire [127:0] dec2pre_data;
    wire [15:0]  dec2pre_tkeep;
    wire         dec2pre_tlast;
    wire         pre2dec_ready;

    wire        pre2fcs_valid;
    wire [127:0] pre2fcs_data;
    wire [15:0]  pre2fcs_tkeep;
    wire         pre2fcs_tlast;
    wire         fcs2pre_ready;

    wire        fcs2pause_valid;
    wire [127:0] fcs2pause_data;
    wire [15:0]  fcs2pause_tkeep;
    wire         fcs2pause_tlast;
    wire         pause2fcs_ready;
    wire         fcs_error_internal;
    wire         fcs_valid_internal;

    wire        pause2out_valid;
    wire [127:0] pause2out_data;
    wire [15:0]  pause2out_tkeep;
    wire         pause2out_tlast;
    wire         out2pause_ready;

    eth_mac_xgmii_dec u_xgmii_dec (
        .clk           (clk),
        .rst_n         (rst_n),
        .pcs_rx_data   (pcs_rx_data),
        .pcs_rx_ctrl   (pcs_rx_ctrl),
        .pcs_rx_valid  (pcs_rx_valid),
        .pcs_rx_ready  (pcs_rx_ready),
        .out_valid     (dec2pre_valid),
        .out_data      (dec2pre_data),
        .out_tkeep     (dec2pre_tkeep),
        .out_tlast     (dec2pre_tlast),
        .out_ready     (pre2dec_ready)
    );

    eth_mac_rx_preamble u_rx_preamble (
        .clk            (clk),
        .rst_n          (rst_n),
        .in_valid       (dec2pre_valid),
        .in_data        (dec2pre_data),
        .in_tkeep       (dec2pre_tkeep),
        .in_tlast       (dec2pre_tlast),
        .in_ready       (pre2dec_ready),
        .out_valid      (pre2fcs_valid),
        .out_data       (pre2fcs_data),
        .out_tkeep      (pre2fcs_tkeep),
        .out_tlast      (pre2fcs_tlast),
        .out_ready      (fcs2pre_ready),
        .sop_detected   (sop_detected),
        .preamble_error (preamble_error)
    );

    eth_mac_rx_fcs u_rx_fcs (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (pre2fcs_valid),
        .in_data    (pre2fcs_data),
        .in_tkeep   (pre2fcs_tkeep),
        .in_tlast   (pre2fcs_tlast),
        .in_ready   (fcs2pre_ready),
        .out_valid  (fcs2pause_valid),
        .out_data   (fcs2pause_data),
        .out_tkeep  (fcs2pause_tkeep),
        .out_tlast  (fcs2pause_tlast),
        .out_ready  (pause2fcs_ready),
        .fcs_error  (fcs_error_internal),
        .fcs_valid  (fcs_valid_internal)
    );

    eth_mac_rx_pause u_rx_pause (
        .clk            (clk),
        .rst_n          (rst_n),
        .in_valid       (fcs2pause_valid),
        .in_data        (fcs2pause_data),
        .in_tkeep       (fcs2pause_tkeep),
        .in_tlast       (fcs2pause_tlast),
        .fcs_error      (fcs_error_internal),
        .in_ready       (pause2fcs_ready),
        .out_valid      (pause2out_valid),
        .out_data       (pause2out_data),
        .out_tkeep      (pause2out_tkeep),
        .out_tlast      (pause2out_tlast),
        .out_ready      (out2pause_ready),
        .pause_req      (pause_req),
        .pause_time     (pause_time),
        .pause_detected ()
    );

    assign m_axis_tdata   = pause2out_data;
    assign m_axis_tkeep   = pause2out_tkeep;
    assign m_axis_tlast   = pause2out_tlast;
    assign m_axis_tvalid  = pause2out_valid;
    assign out2pause_ready = m_axis_tready;

    assign fcs_error = fcs_error_internal;

    reg [15:0] frame_byte_cnt;
    reg        in_rx_frame;

    always @(posedge clk) begin
        if (!rst_n) begin
            frame_byte_cnt  <= 16'h0;
            in_rx_frame     <= 1'b0;
        end else if (pause2out_valid && out2pause_ready) begin
            if (!in_rx_frame) begin
                in_rx_frame    <= 1'b1;
                frame_byte_cnt <= $countones(pause2out_tkeep);
            end else begin
                frame_byte_cnt <= frame_byte_cnt + $countones(pause2out_tkeep);
            end
            if (pause2out_tlast) begin
                in_rx_frame <= 1'b0;
            end
        end
    end

    assign rx_frame_done   = pause2out_valid && out2pause_ready && pause2out_tlast;
    assign rx_byte_cnt     = frame_byte_cnt;
    assign rx_short_frame  = rx_frame_done && (frame_byte_cnt < 16'd64);
    assign rx_long_frame   = rx_frame_done && (frame_byte_cnt > 16'd9216);
    assign rx_alignment_error = preamble_error;
    assign rx_pause_frame  = pause_req;

    wire vlan_detected = (pause2out_data[111:96] == 16'h8100);
    assign rx_vlan_frame = rx_frame_done && vlan_detected;
    assign rx_dropped    = preamble_error || fcs_error_internal;
    assign rx_frame_len  = frame_byte_cnt;

endmodule
