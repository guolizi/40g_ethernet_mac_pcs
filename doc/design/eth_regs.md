# eth_regs 模块设计

## 1. 模块概述

**模块名称**: eth_regs

**功能**: 统一寄存器模块，处理 AXI-Lite 接口访问，包含配置寄存器、状态寄存器和统计计数器

**位置**: rtl/eth_regs.sv

## 2. 接口定义

```systemverilog
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
    input  wire [15:0]  rx_frame_len,
    input  wire         rx_alignment_error
);
```

### 2.1 信号说明

**AXI-Lite 接口**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| s_axi_awvalid | input | 1 | 写地址有效 |
| s_axi_awaddr | input | 16 | 写地址 |
| s_axi_awready | output | 1 | 写地址就绪 |
| s_axi_wvalid | input | 1 | 写数据有效 |
| s_axi_wdata | input | 32 | 写数据 |
| s_axi_wstrb | input | 4 | 写字节选通 |
| s_axi_wready | output | 1 | 写数据就绪 |
| s_axi_bresp | output | 2 | 写响应 |
| s_axi_bvalid | output | 1 | 写响应有效 |
| s_axi_bready | input | 1 | 写响应就绪 |
| s_axi_arvalid | input | 1 | 读地址有效 |
| s_axi_araddr | input | 16 | 读地址 |
| s_axi_arready | output | 1 | 读地址就绪 |
| s_axi_rdata | output | 32 | 读数据 |
| s_axi_rresp | output | 2 | 读响应 |
| s_axi_rvalid | output | 1 | 读数据有效 |
| s_axi_rready | input | 1 | 读数据就绪 |

**配置输出**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| cfg_ipg | output | 8 | IPG 配置 (字节) |
| cfg_mac_addr | output | 48 | 本地 MAC 地址 |
| cfg_max_frame_len | output | 16 | 最大帧长 |

**PCS 状态输出**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| link_up | output | 1 | 链路就绪 |
| pcs_block_lock | output | 4 | 块锁定状态 |
| pcs_deskew_done | output | 1 | 去偏斜完成 |
| pcs_bip_error | output | 4 | BIP 校验错误 |

**PCS 状态输入 (来自 clk_pma_rx 域)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| pcs_block_lock_raw | input | 4 | 块锁定状态 (未同步) |
| pcs_deskew_done_raw | input | 1 | 去偏斜完成 (未同步) |
| pcs_bip_error_raw | input | 4 | BIP 校验错误 (未同步) |

**MAC 统计事件输入**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| tx_frame_done | input | 1 | TX 帧发送完成脉冲 |
| tx_byte_cnt | input | 16 | TX 帧字节数 |
| tx_pause_done | input | 1 | TX Pause 帧发送完成脉冲 |
| rx_frame_done | input | 1 | RX 帧接收完成脉冲 |
| rx_byte_cnt | input | 16 | RX 帧字节数 |
| rx_fcs_error | input | 1 | RX FCS 错误脉冲 |
| rx_short_frame | input | 1 | RX 过短帧脉冲 |
| rx_long_frame | input | 1 | RX 过长帧脉冲 |
| rx_alignment_error | input | 1 | RX 对齐错误脉冲 |
| rx_pause_frame | input | 1 | RX Pause 帧脉冲 |
| rx_vlan_frame | input | 1 | RX VLAN 帧脉冲 |
| rx_dropped | input | 1 | RX 丢弃帧脉冲 |
| rx_frame_len | input | 16 | RX 帧长度 |
| rx_alignment_error | input | 1 | RX 对齐错误脉冲 |

## 3. 寄存器映射

### 3.1 地址空间划分

| 地址范围 | 类型 | 说明 |
|----------|------|------|
| 0x0000 - 0x00FF | R/W | 配置寄存器 |
| 0x0100 - 0x01FF | RO | 状态寄存器 |
| 0x0200 - 0x03FF | RO | TX 统计计数器 |
| 0x0400 - 0x05FF | RO | RX 统计计数器 |

### 3.2 配置寄存器 (0x0000 - 0x00FF)

| 地址 | 名称 | 位宽 | 访问 | 复位值 | 说明 |
|------|------|------|------|--------|------|
| 0x0000 | CFG_IPG | 8 | R/W | 0x0C | IPG 配置 (字节)，范围 8-64 |
| 0x0004 | CFG_MAC_ADDR_LO | 32 | R/W | 0x00000000 | MAC 地址 [31:0] |
| 0x0008 | CFG_MAC_ADDR_HI | 16 | R/W | 0x0000 | MAC 地址 [47:32] |
| 0x000C | CFG_MAX_FRAME_LEN | 16 | R/W | 0x2400 | 最大帧长，默认 9216 |
| 0x0010 - 0x00FF | Reserved | - | R/W | 0x00000000 | 保留，读返回 0 |

### 3.3 状态寄存器 (0x0100 - 0x01FF)

| 地址 | 名称 | 位宽 | 访问 | 说明 |
|------|------|------|------|------|
| 0x0100 | PCS_STATUS | 32 | RO | PCS 状态 |
| 0x0100[3:0] | block_lock | 4 | RO | 块锁定状态，每 bit 对应一个 lane |
| 0x0100[4] | deskew_done | 1 | RO | 去偏斜完成 |
| 0x0100[5] | link_up | 1 | RO | 链路就绪 (block_lock==4'hF && deskew_done) |
| 0x0100[31:6] | Reserved | 26 | RO | 保留 |
| 0x0104 | BIP_ERROR | 32 | RO | BIP 校验错误指示 |
| 0x0104[3:0] | bip_error | 4 | RO | BIP 错误，每 bit 对应一个 lane |
| 0x0104[31:4] | Reserved | 28 | RO | 保留 |
| 0x0108 - 0x01FF | Reserved | - | RO | 保留，读返回 0 |

### 3.4 TX 统计寄存器 (0x0200 - 0x03FF)

| 地址 | 名称 | 位宽 | 访问 | 说明 |
|------|------|------|------|------|
| 0x0200 | TX_FRAMES_OK_LO | 32 | RO | 成功发送帧数 [31:0] |
| 0x0204 | TX_FRAMES_OK_HI | 16 | RO | 成功发送帧数 [47:32] |
| 0x0208 | TX_BYTES_OK_LO | 32 | RO | 成功发送字节数 [31:0] |
| 0x020C | TX_BYTES_OK_HI | 16 | RO | 成功发送字节数 [47:32] |
| 0x0210 | TX_PAUSE_FRAMES_LO | 32 | RO | 发送 Pause 帧数 [31:0] |
| 0x0214 | TX_PAUSE_FRAMES_HI | 16 | RO | 发送 Pause 帧数 [47:32] |
| 0x0218 - 0x03FF | Reserved | - | RO | 保留，读返回 0 |

### 3.5 RX 统计寄存器 (0x0400 - 0x05FF)

| 地址 | 名称 | 位宽 | 访问 | 说明 |
|------|------|------|------|------|
| 0x0400 | RX_FRAMES_OK_LO | 32 | RO | 成功接收帧数 [31:0] |
| 0x0404 | RX_FRAMES_OK_HI | 16 | RO | 成功接收帧数 [47:32] |
| 0x0408 | RX_BYTES_OK_LO | 32 | RO | 成功接收字节数 [31:0] |
| 0x040C | RX_BYTES_OK_HI | 16 | RO | 成功接收字节数 [47:32] |
| 0x0410 | RX_FCS_ERRORS_LO | 32 | RO | FCS 错误帧数 [31:0] |
| 0x0414 | RX_FCS_ERRORS_HI | 16 | RO | FCS 错误帧数 [47:32] |
| 0x0418 | RX_SHORT_FRAMES_LO | 32 | RO | 过短帧数 [31:0] |
| 0x041C | RX_SHORT_FRAMES_HI | 16 | RO | 过短帧数 [47:32] |
| 0x0420 | RX_LONG_FRAMES_LO | 32 | RO | 过长帧数 [31:0] |
| 0x0424 | RX_LONG_FRAMES_HI | 16 | RO | 过长帧数 [47:32] |
| 0x0428 | RX_PAUSE_FRAMES_LO | 32 | RO | 接收 Pause 帧数 [31:0] |
| 0x042C | RX_PAUSE_FRAMES_HI | 16 | RO | 接收 Pause 帧数 [47:32] |
| 0x0430 | RX_VLAN_FRAMES_LO | 32 | RO | VLAN 帧数 [31:0] |
| 0x0434 | RX_VLAN_FRAMES_HI | 16 | RO | VLAN 帧数 [47:32] |
| 0x0438 | RX_DROPPED_LO | 32 | RO | 丢弃帧数 [31:0] |
| 0x043C | RX_DROPPED_HI | 16 | RO | 丢弃帧数 [47:32] |
| 0x0440 | RX_ALIGNMENT_ERRORS_LO | 32 | RO | 对齐错误数 [31:0] |
| 0x0444 | RX_ALIGNMENT_ERRORS_HI | 16 | RO | 对齐错误数 [47:32] |
| 0x0448 | RX_FRAMES_64_LO | 32 | RO | 64 字节帧数 [31:0] |
| 0x044C | RX_FRAMES_64_HI | 16 | RO | 64 字节帧数 [47:32] |
| 0x0450 | RX_FRAMES_65_127_LO | 32 | RO | 65-127 字节帧数 [31:0] |
| 0x0454 | RX_FRAMES_65_127_HI | 16 | RO | 65-127 字节帧数 [47:32] |
| 0x0458 | RX_FRAMES_128_255_LO | 32 | RO | 128-255 字节帧数 [31:0] |
| 0x045C | RX_FRAMES_128_255_HI | 16 | RO | 128-255 字节帧数 [47:32] |
| 0x0460 | RX_FRAMES_256_511_LO | 32 | RO | 256-511 字节帧数 [31:0] |
| 0x0464 | RX_FRAMES_256_511_HI | 16 | RO | 256-511 字节帧数 [47:32] |
| 0x0468 | RX_FRAMES_512_1023_LO | 32 | RO | 512-1023 字节帧数 [31:0] |
| 0x046C | RX_FRAMES_512_1023_HI | 16 | RO | 512-1023 字节帧数 [47:32] |
| 0x0470 | RX_FRAMES_1024_1518_LO | 32 | RO | 1024-1518 字节帧数 [31:0] |
| 0x0474 | RX_FRAMES_1024_1518_HI | 16 | RO | 1024-1518 字节帧数 [47:32] |
| 0x0478 | RX_FRAMES_1519_MAX_LO | 32 | RO | 1519-最大帧长 字节数 [31:0] |
| 0x047C | RX_FRAMES_1519_MAX_HI | 16 | RO | 1519-最大帧长 字节数 [47:32] |
| 0x0480 - 0x05FF | Reserved | - | RO | 保留，读返回 0 |

## 4. 详细设计

### 4.1 PCS 状态同步

PCS 状态信号在 clk_pma_rx 域产生，需要同步到 clk_core 域：

```systemverilog
    reg [3:0]  pcs_block_lock_reg;
    reg        pcs_deskew_done_reg;
    reg [3:0]  pcs_bip_error_reg;

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

    assign pcs_block_lock  = pcs_block_lock_reg;
    assign pcs_deskew_done = pcs_deskew_done_reg;
    assign pcs_bip_error   = pcs_bip_error_reg;
    assign link_up         = (pcs_block_lock_reg == 4'hF) && pcs_deskew_done_reg;
```

### 4.2 配置寄存器

```systemverilog
    reg [7:0]   cfg_ipg_reg;
    reg [31:0]  cfg_mac_addr_lo_reg;
    reg [15:0]  cfg_mac_addr_hi_reg;
    reg [15:0]  cfg_max_frame_len_reg;

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

    assign cfg_ipg           = cfg_ipg_reg;
    assign cfg_mac_addr      = {cfg_mac_addr_hi_reg, cfg_mac_addr_lo_reg};
    assign cfg_max_frame_len = cfg_max_frame_len_reg;
```

### 4.2 统计计数器

所有统计计数器为 48-bit，饱和计数，不清零：

```systemverilog
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
    reg [47:0] rx_dropped;
    reg [47:0] rx_alignment_errors;
    reg [47:0] rx_frames_64;
    reg [47:0] rx_frames_65_127;
    reg [47:0] rx_frames_128_255;
    reg [47:0] rx_frames_256_511;
    reg [47:0] rx_frames_512_1023;
    reg [47:0] rx_frames_1024_1518;
    reg [47:0] rx_frames_1519_max;

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
            rx_frames_ok     <= 48'h0;
            rx_bytes_ok      <= 48'h0;
            rx_fcs_errors    <= 48'h0;
            rx_short_frames  <= 48'h0;
            rx_long_frames   <= 48'h0;
            rx_pause_frames  <= 48'h0;
            rx_vlan_frames   <= 48'h0;
            rx_dropped       <= 48'h0;
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
            if (rx_dropped && rx_dropped != 48'hFFFFFFFFFFFF)
                rx_dropped <= rx_dropped + 48'h1;
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
```

### 4.3 AXI-Lite 读逻辑

```systemverilog
    reg         rd_req;
    reg [15:0]  rd_addr;
    reg [31:0]  rd_data;

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
            16'h0438: rd_data = rx_dropped[31:0];
            16'h043C: rd_data = {16'h0, rx_dropped[47:32]};
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
```

### 4.4 AXI-Lite 状态机

```systemverilog
    localparam IDLE   = 2'b00;
    localparam WR     = 2'b01;
    localparam WR_RESP = 2'b10;
    localparam RD     = 2'b11;

    reg [1:0] state;

    wire wr_en = s_axi_awvalid && s_axi_wvalid;

    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= IDLE;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b0;
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'h0;
            s_axi_rresp   <= 2'b0;
            rd_req       <= 1'b0;
            rd_addr      <= 16'h0;
        end else begin
            case (state)
                IDLE: begin
                    s_axi_bvalid <= 1'b0;
                    s_axi_rvalid <= 1'b0;
                    if (wr_en) begin
                        state         <= WR_RESP;
                        s_axi_awready <= 1'b1;
                        s_axi_wready  <= 1'b1;
                        s_axi_bvalid  <= 1'b1;
                        s_axi_bresp   <= 2'b00;
                    end else if (s_axi_arvalid) begin
                        state         <= RD;
                        s_axi_arready <= 1'b1;
                        rd_req        <= 1'b1;
                        rd_addr       <= s_axi_araddr;
                    end
                end
                WR_RESP: begin
                    s_axi_awready <= 1'b0;
                    s_axi_wready  <= 1'b0;
                    if (s_axi_bready)
                        state <= IDLE;
                end
                RD: begin
                    s_axi_arready <= 1'b0;
                    rd_req        <= 1'b0;
                    s_axi_rvalid  <= 1'b1;
                    s_axi_rdata   <= rd_data;
                    s_axi_rresp   <= 2'b00;
                    if (s_axi_rready)
                        state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
```

## 5. 时序图

### 5.1 写操作

```
clk:          |  0  |  1  |  2  |  3  |  4  |
              |     |     |     |     |     |
s_axi_awvalid:|__/--|     |     |     |     |
s_axi_awaddr: | A0  |     |     |     |     |
s_axi_wvalid: |__/--|     |     |     |     |
s_axi_wdata:  | D0  |     |     |     |     |
              |     |     |     |     |     |
s_axi_awready:|     |--/__|     |     |     |
s_axi_wready: |     |--/__|     |     |     |
s_axi_bvalid: |     |     |--/__|     |     |
s_axi_bresp:  |     |     | OK  |     |     |
```

### 5.2 读操作

```
clk:          |  0  |  1  |  2  |  3  |  4  |
              |     |     |     |     |     |
s_axi_arvalid:|__/--|     |     |     |     |
s_axi_araddr: | A0  |     |     |     |     |
              |     |     |     |     |     |
s_axi_arready:|     |--/__|     |     |     |
s_axi_rvalid: |     |     |--/__|     |     |
s_axi_rdata:  |     |     | D0  |     |     |
s_axi_rresp:  |     |     | OK  |     |     |
```

## 6. 资源估算

| 资源 | 数量 | 说明 |
|------|------|------|
| LUT | ~400 | 地址译码 + AXI-Lite 状态机 + 帧长分类 |
| FF | ~3000 | 配置寄存器 + 统计计数器 (19×48-bit) |
| BRAM | 0 | 使用分布式 RAM |

## 7. 测试要点

| 测试项 | 说明 |
|--------|------|
| 配置寄存器读写 | 验证 IPG/MAC 地址/最大帧长读写正确 |
| 状态寄存器读取 | 验证 PCS 状态正确反映 |
| 统计计数器累加 | 验证各计数器正确累加 |
| 计数器饱和 | 验证计数器达到最大值后不再增加 |
| AXI-Lite 协议 | 验证读写时序符合 AXI-Lite 规范 |
| 保留地址访问 | 验证读返回 0，写忽略 |
| 复位行为 | 验证复位后寄存器值为默认值 |

## 8. 参考文献

- ARM AMBA AXI4-Lite Specification
- IEEE 802.3-2018 Clause 30 (Management)

## 9. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-13 | 初始版本 |
| 1.1 | 2026-04-14 | 添加 rx_alignment_errors 计数器；添加按帧长分布的 7 个统计计数器 (rx_frames_64 ~ rx_frames_1519_max) |
