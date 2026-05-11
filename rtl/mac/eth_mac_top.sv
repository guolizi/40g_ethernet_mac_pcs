module eth_mac_top (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [127:0] s_axis_tdata,
    input  wire [15:0]  s_axis_tkeep,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,

    output wire [127:0] m_axis_tdata,
    output wire [15:0]  m_axis_tkeep,
    output wire         m_axis_tlast,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,

    output wire [127:0] mac_tx_data,
    output wire [15:0]  mac_tx_ctrl,
    output wire         mac_tx_valid,
    input  wire         mac_tx_ready,

    input  wire [127:0] pcs_rx_data,
    input  wire [15:0]  pcs_rx_ctrl,
    input  wire         pcs_rx_valid,
    output wire         pcs_rx_ready,

    input  wire [7:0]   ipg_cfg,
    input  wire [47:0]  pause_src_mac,

    output wire         tx_frame_done,
    output wire [15:0]  tx_byte_cnt,
    output wire         tx_pause_done,
    output wire         rx_frame_done,
    output wire [15:0]  rx_byte_cnt,
    output wire         rx_fcs_error,
    output wire         rx_short_frame,
    output wire         rx_long_frame,
    output wire         rx_alignment_error,
    output wire         rx_pause_frame,
    output wire         rx_vlan_frame,
    output wire         rx_dropped,
    output wire [15:0]  rx_frame_len,
    output wire         rx_preamble_error
);

    wire        rx_pause_req;
    wire [15:0] rx_pause_time;

    eth_mac_tx u_mac_tx (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tkeep   (s_axis_tkeep),
        .s_axis_tlast   (s_axis_tlast),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .mac_tx_data    (mac_tx_data),
        .mac_tx_ctrl    (mac_tx_ctrl),
        .mac_tx_valid   (mac_tx_valid),
        .mac_tx_ready   (mac_tx_ready),
        .pause_req      (rx_pause_req),
        .pause_time     (rx_pause_time),
        .pause_src_mac  (pause_src_mac),
        .ipg_cfg        (ipg_cfg),
        .pause_busy     (),
        .tx_frame_done  (tx_frame_done),
        .tx_byte_cnt    (tx_byte_cnt),
        .tx_pause_done  (tx_pause_done)
    );

    eth_mac_rx u_mac_rx (
        .clk                (clk),
        .rst_n              (rst_n),
        .pcs_rx_data        (pcs_rx_data),
        .pcs_rx_ctrl        (pcs_rx_ctrl),
        .pcs_rx_valid       (pcs_rx_valid),
        .pcs_rx_ready       (pcs_rx_ready),
        .m_axis_tdata       (m_axis_tdata),
        .m_axis_tkeep       (m_axis_tkeep),
        .m_axis_tlast       (m_axis_tlast),
        .m_axis_tvalid      (m_axis_tvalid),
        .m_axis_tready      (m_axis_tready),
        .pause_req          (rx_pause_req),
        .pause_time         (rx_pause_time),
        .fcs_error          (rx_fcs_error),
        .sop_detected       (),
        .preamble_error     (rx_preamble_error),
        .rx_frame_done      (rx_frame_done),
        .rx_byte_cnt        (rx_byte_cnt),
        .rx_short_frame     (rx_short_frame),
        .rx_long_frame      (rx_long_frame),
        .rx_alignment_error (rx_alignment_error),
        .rx_pause_frame     (rx_pause_frame),
        .rx_vlan_frame      (rx_vlan_frame),
        .rx_dropped         (rx_dropped),
        .rx_frame_len       (rx_frame_len)
    );

endmodule
