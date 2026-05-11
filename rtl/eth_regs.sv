module eth_regs (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         s_axi_awvalid,
    input  wire [15:0]  s_axi_awaddr,
    output wire         s_axi_awready,
    input  wire         s_axi_wvalid,
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    output wire         s_axi_wready,
    output wire [1:0]   s_axi_bresp,
    output wire         s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire         s_axi_arvalid,
    input  wire [15:0]  s_axi_araddr,
    output wire         s_axi_arready,
    output wire [31:0]  s_axi_rdata,
    output wire [1:0]   s_axi_rresp,
    output wire         s_axi_rvalid,
    input  wire         s_axi_rready,

    output wire [7:0]   cfg_ipg,
    output wire [47:0]  cfg_mac_addr,
    output wire [15:0]  cfg_max_frame_len,

    output wire         link_up,
    output wire [3:0]   pcs_block_lock,
    output wire         pcs_deskew_done,
    output wire [3:0]   pcs_bip_error,

    input  wire [3:0]   pcs_block_lock_raw,
    input  wire         pcs_deskew_done_raw,
    input  wire [3:0]   pcs_bip_error_raw,

    input  wire         tx_frame_done,
    input  wire [15:0]  tx_byte_cnt,
    input  wire         tx_pause_done,
    input  wire         rx_frame_done,
    input  wire [15:0]  rx_byte_cnt,
    input  wire         rx_fcs_error,
    input  wire         rx_short_frame,
    input  wire         rx_long_frame,
    input  wire         rx_alignment_error,
    input  wire         rx_pause_frame,
    input  wire         rx_vlan_frame,
    input  wire         rx_dropped,
    input  wire [15:0]  rx_frame_len
);

    localparam IDLE     = 2'b00;
    localparam WR_RESP  = 2'b01;
    localparam RD       = 2'b10;

    reg [1:0] state;

    reg [7:0]   cfg_ipg_reg;
    reg [31:0]  cfg_mac_addr_lo_reg;
    reg [15:0]  cfg_mac_addr_hi_reg;
    reg [15:0]  cfg_max_frame_len_reg;

    reg [3:0]   pcs_block_lock_reg;
    reg         pcs_deskew_done_reg;
    reg [3:0]   pcs_bip_error_reg;

    reg [47:0] tx_frames_ok;
    reg [47:0] tx_bytes_ok;
    reg [47:0] tx_pause_frames;

    reg [47:0] rx_frames_ok;
    reg [47:0] rx_bytes_ok;
    reg [47:0] rx_fcs_errors;
    reg [47:0] rx_short_frames;
    reg [47:0] rx_long_frames;
    reg [47:0] rx_pause_frames;
    reg [47:0] rx_vlan_frames;
    reg [47:0] rx_dropped_cnt;
    reg [47:0] rx_alignment_errors;
    reg [47:0] rx_frames_64;
    reg [47:0] rx_frames_65_127;
    reg [47:0] rx_frames_128_255;
    reg [47:0] rx_frames_256_511;
    reg [47:0] rx_frames_512_1023;
    reg [47:0] rx_frames_1024_1518;
    reg [47:0] rx_frames_1519_max;

    reg         rd_req;
    reg [15:0]  rd_addr;
    reg [31:0]  rd_data;

    reg         s_axi_awready_reg;
    reg         s_axi_wready_reg;
    reg         s_axi_bvalid_reg;
    reg [1:0]   s_axi_bresp_reg;
    reg         s_axi_arready_reg;
    reg         s_axi_rvalid_reg;
    reg [31:0]  s_axi_rdata_reg;
    reg [1:0]   s_axi_rresp_reg;

    wire wr_en = s_axi_awvalid && s_axi_wvalid;

    assign s_axi_awready = s_axi_awready_reg;
    assign s_axi_wready  = s_axi_wready_reg;
    assign s_axi_bvalid  = s_axi_bvalid_reg;
    assign s_axi_bresp   = s_axi_bresp_reg;
    assign s_axi_arready = s_axi_arready_reg;
    assign s_axi_rvalid  = s_axi_rvalid_reg;
    assign s_axi_rdata   = s_axi_rdata_reg;
    assign s_axi_rresp   = s_axi_rresp_reg;

    assign cfg_ipg           = cfg_ipg_reg;
    assign cfg_mac_addr      = {cfg_mac_addr_hi_reg, cfg_mac_addr_lo_reg};
    assign cfg_max_frame_len = cfg_max_frame_len_reg;

    assign pcs_block_lock  = pcs_block_lock_reg;
    assign pcs_deskew_done = pcs_deskew_done_reg;
    assign pcs_bip_error   = pcs_bip_error_reg;
    assign link_up         = (pcs_block_lock_reg == 4'hF) && pcs_deskew_done_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            pcs_block_lock_reg  <= 4'h0;
            pcs_deskew_done_reg <= 1'b0;
            pcs_bip_error_reg   <= 4'h0;
        end else begin
            pcs_block_lock_reg  <= pcs_block_lock_raw;
            pcs_deskew_done_reg <= pcs_deskew_done_raw;
            pcs_bip_error_reg   <= pcs_bip_error_raw;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            cfg_ipg_reg           <= 8'h0C;
            cfg_mac_addr_lo_reg   <= 32'h00000000;
            cfg_mac_addr_hi_reg   <= 16'h0000;
            cfg_max_frame_len_reg <= 16'h2400;
        end else if (wr_en && s_axi_wstrb[0]) begin
            case (s_axi_awaddr)
                16'h0000: cfg_ipg_reg           <= s_axi_wdata[7:0];
                16'h0004: cfg_mac_addr_lo_reg   <= s_axi_wdata;
                16'h0008: cfg_mac_addr_hi_reg   <= s_axi_wdata[15:0];
                16'h000C: cfg_max_frame_len_reg <= s_axi_wdata[15:0];
                default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            tx_frames_ok     <= 48'h0;
            tx_bytes_ok      <= 48'h0;
            tx_pause_frames  <= 48'h0;
        end else begin
            if (tx_frame_done && tx_frames_ok != 48'hFFFFFFFFFFFF)
                tx_frames_ok <= tx_frames_ok + 48'h1;
            if (tx_frame_done && tx_bytes_ok <= 48'hFFFFFFFFFFFF - tx_byte_cnt)
                tx_bytes_ok <= tx_bytes_ok + tx_byte_cnt;
            if (tx_pause_done && tx_pause_frames != 48'hFFFFFFFFFFFF)
                tx_pause_frames <= tx_pause_frames + 48'h1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_frames_ok        <= 48'h0;
            rx_bytes_ok         <= 48'h0;
            rx_fcs_errors       <= 48'h0;
            rx_short_frames     <= 48'h0;
            rx_long_frames      <= 48'h0;
            rx_pause_frames     <= 48'h0;
            rx_vlan_frames      <= 48'h0;
            rx_dropped_cnt      <= 48'h0;
            rx_alignment_errors <= 48'h0;
            rx_frames_64        <= 48'h0;
            rx_frames_65_127    <= 48'h0;
            rx_frames_128_255   <= 48'h0;
            rx_frames_256_511   <= 48'h0;
            rx_frames_512_1023  <= 48'h0;
            rx_frames_1024_1518 <= 48'h0;
            rx_frames_1519_max  <= 48'h0;
        end else begin
            if (rx_frame_done && rx_frames_ok != 48'hFFFFFFFFFFFF)
                rx_frames_ok <= rx_frames_ok + 48'h1;
            if (rx_frame_done && rx_bytes_ok <= 48'hFFFFFFFFFFFF - rx_byte_cnt)
                rx_bytes_ok <= rx_bytes_ok + rx_byte_cnt;
            if (rx_fcs_error && rx_fcs_errors != 48'hFFFFFFFFFFFF)
                rx_fcs_errors <= rx_fcs_errors + 48'h1;
            if (rx_short_frame && rx_short_frames != 48'hFFFFFFFFFFFF)
                rx_short_frames <= rx_short_frames + 48'h1;
            if (rx_long_frame && rx_long_frames != 48'hFFFFFFFFFFFF)
                rx_long_frames <= rx_long_frames + 48'h1;
            if (rx_pause_frame && rx_pause_frames != 48'hFFFFFFFFFFFF)
                rx_pause_frames <= rx_pause_frames + 48'h1;
            if (rx_vlan_frame && rx_vlan_frames != 48'hFFFFFFFFFFFF)
                rx_vlan_frames <= rx_vlan_frames + 48'h1;
            if (rx_dropped && rx_dropped_cnt != 48'hFFFFFFFFFFFF)
                rx_dropped_cnt <= rx_dropped_cnt + 48'h1;
            if (rx_alignment_error && rx_alignment_errors != 48'hFFFFFFFFFFFF)
                rx_alignment_errors <= rx_alignment_errors + 48'h1;
            if (rx_frame_done) begin
                if (rx_frame_len <= 16'd64 && rx_frames_64 != 48'hFFFFFFFFFFFF)
                    rx_frames_64 <= rx_frames_64 + 48'h1;
                else if (rx_frame_len <= 16'd127 && rx_frames_65_127 != 48'hFFFFFFFFFFFF)
                    rx_frames_65_127 <= rx_frames_65_127 + 48'h1;
                else if (rx_frame_len <= 16'd255 && rx_frames_128_255 != 48'hFFFFFFFFFFFF)
                    rx_frames_128_255 <= rx_frames_128_255 + 48'h1;
                else if (rx_frame_len <= 16'd511 && rx_frames_256_511 != 48'hFFFFFFFFFFFF)
                    rx_frames_256_511 <= rx_frames_256_511 + 48'h1;
                else if (rx_frame_len <= 16'd1023 && rx_frames_512_1023 != 48'hFFFFFFFFFFFF)
                    rx_frames_512_1023 <= rx_frames_512_1023 + 48'h1;
                else if (rx_frame_len <= 16'd1518 && rx_frames_1024_1518 != 48'hFFFFFFFFFFFF)
                    rx_frames_1024_1518 <= rx_frames_1024_1518 + 48'h1;
                else if (rx_frames_1519_max != 48'hFFFFFFFFFFFF)
                    rx_frames_1519_max <= rx_frames_1519_max + 48'h1;
            end
        end
    end

    always @(*) begin
        case (rd_addr)
            16'h0000: rd_data = {24'h0, cfg_ipg_reg};
            16'h0004: rd_data = cfg_mac_addr_lo_reg;
            16'h0008: rd_data = {16'h0, cfg_mac_addr_hi_reg};
            16'h000C: rd_data = {16'h0, cfg_max_frame_len_reg};
            16'h0100: rd_data = {26'h0, link_up, pcs_deskew_done_reg, pcs_block_lock_reg};
            16'h0104: rd_data = {28'h0, pcs_bip_error_reg};
            16'h0200: rd_data = tx_frames_ok[31:0];
            16'h0204: rd_data = {16'h0, tx_frames_ok[47:32]};
            16'h0208: rd_data = tx_bytes_ok[31:0];
            16'h020C: rd_data = {16'h0, tx_bytes_ok[47:32]};
            16'h0210: rd_data = tx_pause_frames[31:0];
            16'h0214: rd_data = {16'h0, tx_pause_frames[47:32]};
            16'h0400: rd_data = rx_frames_ok[31:0];
            16'h0404: rd_data = {16'h0, rx_frames_ok[47:32]};
            16'h0408: rd_data = rx_bytes_ok[31:0];
            16'h040C: rd_data = {16'h0, rx_bytes_ok[47:32]};
            16'h0410: rd_data = rx_fcs_errors[31:0];
            16'h0414: rd_data = {16'h0, rx_fcs_errors[47:32]};
            16'h0418: rd_data = rx_short_frames[31:0];
            16'h041C: rd_data = {16'h0, rx_short_frames[47:32]};
            16'h0420: rd_data = rx_long_frames[31:0];
            16'h0424: rd_data = {16'h0, rx_long_frames[47:32]};
            16'h0428: rd_data = rx_pause_frames[31:0];
            16'h042C: rd_data = {16'h0, rx_pause_frames[47:32]};
            16'h0430: rd_data = rx_vlan_frames[31:0];
            16'h0434: rd_data = {16'h0, rx_vlan_frames[47:32]};
            16'h0438: rd_data = rx_dropped_cnt[31:0];
            16'h043C: rd_data = {16'h0, rx_dropped_cnt[47:32]};
            16'h0440: rd_data = rx_alignment_errors[31:0];
            16'h0444: rd_data = {16'h0, rx_alignment_errors[47:32]};
            16'h0448: rd_data = rx_frames_64[31:0];
            16'h044C: rd_data = {16'h0, rx_frames_64[47:32]};
            16'h0450: rd_data = rx_frames_65_127[31:0];
            16'h0454: rd_data = {16'h0, rx_frames_65_127[47:32]};
            16'h0458: rd_data = rx_frames_128_255[31:0];
            16'h045C: rd_data = {16'h0, rx_frames_128_255[47:32]};
            16'h0460: rd_data = rx_frames_256_511[31:0];
            16'h0464: rd_data = {16'h0, rx_frames_256_511[47:32]};
            16'h0468: rd_data = rx_frames_512_1023[31:0];
            16'h046C: rd_data = {16'h0, rx_frames_512_1023[47:32]};
            16'h0470: rd_data = rx_frames_1024_1518[31:0];
            16'h0474: rd_data = {16'h0, rx_frames_1024_1518[47:32]};
            16'h0478: rd_data = rx_frames_1519_max[31:0];
            16'h047C: rd_data = {16'h0, rx_frames_1519_max[47:32]};
            default:  rd_data = 32'h00000000;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state               <= IDLE;
            s_axi_awready_reg   <= 1'b0;
            s_axi_wready_reg    <= 1'b0;
            s_axi_bvalid_reg    <= 1'b0;
            s_axi_bresp_reg     <= 2'b0;
            s_axi_arready_reg   <= 1'b0;
            s_axi_rvalid_reg    <= 1'b0;
            s_axi_rdata_reg     <= 32'h0;
            s_axi_rresp_reg     <= 2'b0;
            rd_req              <= 1'b0;
            rd_addr             <= 16'h0;
        end else begin
            case (state)
                IDLE: begin
                    if (wr_en) begin
                        state               <= WR_RESP;
                        s_axi_awready_reg   <= 1'b1;
                        s_axi_wready_reg    <= 1'b1;
                        s_axi_bvalid_reg    <= 1'b1;
                        s_axi_bresp_reg     <= 2'b00;
                    end else if (s_axi_arvalid) begin
                        state               <= RD;
                        s_axi_arready_reg   <= 1'b1;
                        rd_req              <= 1'b1;
                        rd_addr             <= s_axi_araddr;
                    end else begin
                        s_axi_bvalid_reg    <= 1'b0;
                        s_axi_rvalid_reg    <= 1'b0;
                    end
                end
                WR_RESP: begin
                    s_axi_awready_reg   <= 1'b0;
                    s_axi_wready_reg    <= 1'b0;
                    if (s_axi_bready) begin
                        state               <= IDLE;
                        s_axi_bvalid_reg    <= 1'b0;
                    end
                end
                RD: begin
                    s_axi_arready_reg   <= 1'b0;
                    rd_req              <= 1'b0;
                    s_axi_rvalid_reg    <= 1'b1;
                    s_axi_rdata_reg     <= rd_data;
                    s_axi_rresp_reg     <= 2'b00;
                    if (s_axi_rready) begin
                        state               <= IDLE;
                        s_axi_rvalid_reg    <= 1'b0;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
