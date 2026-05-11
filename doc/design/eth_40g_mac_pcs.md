# eth_40g_mac_pcs 模块设计

## 1. 模块概述

**模块名称**: eth_40g_mac_pcs

**功能**: 40G Ethernet MAC + PCS 顶层模块，集成 MAC 和 PCS 层

**位置**: rtl/eth_40g_mac_pcs.sv

## 2. 接口定义

```systemverilog
module eth_40g_mac_pcs (
    input  wire         clk_core,
    input  wire         rst_n_core,

    input  wire         clk_pma_tx,
    input  wire         rst_n_pma_tx,

    input  wire         clk_pma_rx,
    input  wire         rst_n_pma_rx,

    output wire         link_up,

    input  wire [127:0] s_axis_tx_tdata,
    input  wire [15:0]  s_axis_tx_tkeep,
    input  wire         s_axis_tx_tlast,
    input  wire         s_axis_tx_tvalid,
    output wire         s_axis_tx_tready,

    output wire [127:0] m_axis_rx_tdata,
    output wire [15:0]  m_axis_rx_tkeep,
    output wire         m_axis_rx_tlast,
    output wire         m_axis_rx_tvalid,
    input  wire         m_axis_rx_tready,

    output wire [31:0]  pma_tx_lane0_data,
    output wire [31:0]  pma_tx_lane1_data,
    output wire [31:0]  pma_tx_lane2_data,
    output wire [31:0]  pma_tx_lane3_data,
    output wire         pma_tx_valid,
    input  wire         pma_tx_ready,

    input  wire [31:0]  pma_rx_lane0_data,
    input  wire [31:0]  pma_rx_lane1_data,
    input  wire [31:0]  pma_rx_lane2_data,
    input  wire [31:0]  pma_rx_lane3_data,
    input  wire         pma_rx_valid,
    output wire         pma_rx_ready,

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
    input  wire         s_axi_rready
);
```

### 2.1 信号说明

**时钟与复位**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| clk_core | input | 1 | 核心时钟，312.5 MHz |
| rst_n_core | input | 1 | 核心时钟域同步复位，低有效 |
| clk_pma_tx | input | 1 | PMA TX 时钟，322.266 MHz |
| rst_n_pma_tx | input | 1 | PMA TX 时钟域同步复位，低有效 |
| clk_pma_rx | input | 1 | PMA RX 恢复时钟，322.266 MHz |
| rst_n_pma_rx | input | 1 | PMA RX 时钟域同步复位，低有效 |

**链路状态**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| link_up | output | 1 | 链路就绪 (block_lock==4'hF && deskew_done) |

**TX AXI-Stream (用户接口)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| s_axis_tx_tdata | input | 128 | 发送数据 |
| s_axis_tx_tkeep | input | 16 | 字节有效 |
| s_axis_tx_tlast | input | 1 | 帧结束 |
| s_axis_tx_tvalid | input | 1 | 数据有效 |
| s_axis_tx_tready | output | 1 | MAC 就绪 |

**RX AXI-Stream (用户接口)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| m_axis_rx_tdata | output | 128 | 接收数据 |
| m_axis_rx_tkeep | output | 16 | 字节有效 |
| m_axis_rx_tlast | output | 1 | 帧结束 |
| m_axis_rx_tvalid | output | 1 | 数据有效 |
| m_axis_rx_tready | input | 1 | 用户就绪 |

**PMA TX 接口**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| pma_tx_lane0_data | output | 32 | Lane 0 TX 数据 |
| pma_tx_lane1_data | output | 32 | Lane 1 TX 数据 |
| pma_tx_lane2_data | output | 32 | Lane 2 TX 数据 |
| pma_tx_lane3_data | output | 32 | Lane 3 TX 数据 |
| pma_tx_valid | output | 1 | TX 数据有效 |
| pma_tx_ready | input | 1 | PMA 就绪 |

**PMA RX 接口**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| pma_rx_lane0_data | input | 32 | Lane 0 RX 数据 |
| pma_rx_lane1_data | input | 32 | Lane 1 RX 数据 |
| pma_rx_lane2_data | input | 32 | Lane 2 RX 数据 |
| pma_rx_lane3_data | input | 32 | Lane 3 RX 数据 |
| pma_rx_valid | input | 1 | RX 数据有效 |
| pma_rx_ready | output | 1 | PCS 就绪 |

**AXI-Lite 寄存器接口**:
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

## 3. 寄存器映射

### 3.1 寄存器地址空间

| 地址范围 | 模块 | 说明 |
|----------|------|------|
| 0x0000 - 0x00FF | 配置寄存器 | MAC/PCS 配置 |
| 0x0100 - 0x01FF | 状态寄存器 | PCS 状态 |
| 0x0200 - 0x03FF | MAC TX 统计 | TX 统计计数器 |
| 0x0400 - 0x05FF | MAC RX 统计 | RX 统计计数器 |

### 3.2 配置寄存器 (0x0000 - 0x00FF)

| 地址 | 名称 | 位宽 | 访问 | 复位值 | 说明 |
|------|------|------|------|--------|------|
| 0x0000 | CFG_IPG | 8 | R/W | 0x0C | IPG 配置 (字节) |
| 0x0004 | CFG_MAC_ADDR_LO | 32 | R/W | 0x00000000 | MAC 地址 [31:0] |
| 0x0008 | CFG_MAC_ADDR_HI | 16 | R/W | 0x0000 | MAC 地址 [47:32] |
| 0x000C | CFG_MAX_FRAME_LEN | 16 | R/W | 0x2400 | 最大帧长 (9216) |
| 0x0010 - 0x00FF | Reserved | - | - | - | 保留 |

### 3.3 状态寄存器 (0x0100 - 0x01FF)

| 地址 | 名称 | 位宽 | 访问 | 复位值 | 说明 |
|------|------|------|------|--------|------|
| 0x0100 | PCS_STATUS | 32 | RO | 0x00000000 | PCS 状态 |
| 0x0100[3:0] | block_lock | 4 | RO | 0x0 | 块锁定状态 |
| 0x0100[4] | deskew_done | 1 | RO | 0x0 | 去偏斜完成 |
| 0x0100[5] | link_up | 1 | RO | 0x0 | 链路就绪 |
| 0x0104 | BIP_ERROR | 4 | RO | 0x0 | BIP 校验错误指示 |
| 0x0108 - 0x01FF | Reserved | - | - | - | 保留 |

### 3.4 MAC TX 统计寄存器 (0x0200 - 0x03FF)

| 地址 | 名称 | 位宽 | 访问 | 说明 |
|------|------|------|------|------|
| 0x0200 | TX_FRAMES_OK | 48 | RO | 成功发送帧数 |
| 0x0208 | TX_BYTES_OK | 48 | RO | 成功发送字节数 |
| 0x0210 | TX_PAUSE_FRAMES | 48 | RO | 发送 Pause 帧数 |
| 0x0218 - 0x03FF | Reserved | - | - | 保留 |

### 3.5 MAC RX 统计寄存器 (0x0400 - 0x05FF)

| 地址 | 名称 | 位宽 | 访问 | 说明 |
|------|------|------|------|------|
| 0x0400 | RX_FRAMES_OK | 48 | RO | 成功接收帧数 |
| 0x0408 | RX_BYTES_OK | 48 | RO | 成功接收字节数 |
| 0x0410 | RX_FCS_ERRORS | 48 | RO | FCS 错误帧数 |
| 0x0418 | RX_SHORT_FRAMES | 48 | RO | 过短帧数 |
| 0x0420 | RX_LONG_FRAMES | 48 | RO | 过长帧数 |
| 0x0428 | RX_PAUSE_FRAMES | 48 | RO | 接收 Pause 帧数 |
| 0x0430 | RX_VLAN_FRAMES | 48 | RO | VLAN 帧数 |
| 0x0438 | RX_DROPPED | 48 | RO | 丢弃帧数 |
| 0x0440 | RX_ALIGNMENT_ERRORS | 48 | RO | 对齐错误数 |
| 0x0448 | RX_FRAMES_64 | 48 | RO | 64 字节帧数 |
| 0x0450 | RX_FRAMES_65_127 | 48 | RO | 65-127 字节帧数 |
| 0x0458 | RX_FRAMES_128_255 | 48 | RO | 128-255 字节帧数 |
| 0x0460 | RX_FRAMES_256_511 | 48 | RO | 256-511 字节帧数 |
| 0x0468 | RX_FRAMES_512_1023 | 48 | RO | 512-1023 字节帧数 |
| 0x0470 | RX_FRAMES_1024_1518 | 48 | RO | 1024-1518 字节帧数 |
| 0x0478 | RX_FRAMES_1519_MAX | 48 | RO | 1519-最大帧长 字节数 |
| 0x0480 - 0x05FF | Reserved | - | - | 保留 |

## 4. 架构设计

### 4.1 模块层次结构

```
eth_40g_mac_pcs
├── eth_regs                          # 统一寄存器模块
│   ├── 配置寄存器 (R/W)
│   ├── 状态寄存器 (RO)
│   └── 统计计数器 (RO)
│
├── eth_mac_top
│   ├── eth_mac_tx
│   │   ├── eth_mac_tx_fifo
│   │   ├── eth_mac_tx_pause
│   │   ├── eth_mac_tx_preamble
│   │   ├── eth_mac_tx_fcs
│   │   ├── eth_mac_tx_ipg
│   │   └── eth_mac_xgmii_enc
│   ├── eth_mac_rx
│   │   ├── eth_mac_xgmii_dec
│   │   ├── eth_mac_rx_preamble
│   │   ├── eth_mac_rx_fcs
│   │   └── eth_mac_rx_pause
│   └── eth_mac_stats (移除，统计由 eth_regs 处理)
│
└── eth_pcs_top
    ├── eth_pcs_tx
    │   ├── eth_pcs_64b66b_enc
    │   ├── eth_pcs_scrambler
    │   ├── eth_pcs_am_insert
    │   ├── eth_pcs_lane_dist
    │   └── eth_pcs_gearbox_tx
    └── eth_pcs_rx
        ├── eth_pcs_gearbox_rx
        ├── eth_pcs_block_sync
        ├── eth_pcs_am_detect
        ├── eth_pcs_lane_deskew
        ├── eth_pcs_descrambler
        ├── eth_pcs_64b66b_dec
        ├── eth_pcs_idle_delete
        └── async_fifo (CDC)
```

### 4.2 数据流

```
                          ┌─────────────────────────────────────────────────────────┐
                          │                      TX 路径                            │
                          └─────────────────────────────────────────────────────────┘
                                                      │
用户逻辑 ──AXI-Stream──> eth_mac_top ──XLGMII──> eth_pcs_top ──4×32-bit──> PMA
                           │                        │
                        clk_core              clk_core → clk_pma_tx

                          ┌─────────────────────────────────────────────────────────┐
                          │                      RX 路径                            │
                          └─────────────────────────────────────────────────────────┘
                                                      │
PMA ──4×32-bit──> eth_pcs_top ──XLGMII──> eth_mac_top ──AXI-Stream──> 用户逻辑
                      │                        │
                 clk_pma_rx → clk_core      clk_core
```

### 4.3 时钟域划分

| 时钟域 | 频率 | 模块 | 说明 |
|--------|------|------|------|
| clk_core | 312.5 MHz | eth_mac_top (全部) + eth_pcs_top TX 核心 + eth_regs | 本地核心时钟 |
| clk_pma_tx | 322.266 MHz | eth_pcs_top TX Gearbox 输出 | PMA TX 时钟 |
| clk_pma_rx | 322.266 MHz | eth_pcs_top RX (全部) | PMA RX 恢复时钟 |

**CDC 位置**:
- TX: eth_pcs_top 内部 Gearbox (clk_core → clk_pma_tx)
- RX: eth_pcs_top 内部 async_fifo (clk_pma_rx → clk_core)
- PCS 状态: 需要从 clk_pma_rx 同步到 clk_core

### 4.4 Pause 帧处理

```
RX 方向:
  eth_mac_top 内部 eth_mac_rx_pause 检测 Pause 帧
      │
      ├──> pause_req (脉冲)
      └──> pause_time[15:0]

TX 方向:
  eth_mac_top 内部 eth_mac_tx_pause 接收 pause_req/pause_time
      │
      └──> 插入 Pause 帧 (优先于用户数据)
```

## 5. 详细设计

### 5.1 内部信号

```systemverilog
    // MAC TX → PCS TX (XLGMII @ clk_core)
    wire [127:0] mac_tx_data;
    wire [15:0]  mac_tx_ctrl;
    wire         mac_tx_valid;
    wire         mac_tx_ready;

    // PCS RX → MAC RX (XLGMII @ clk_core)
    wire [127:0] mac_rx_data;
    wire [15:0]  mac_rx_ctrl;
    wire         mac_rx_valid;
    wire         mac_rx_ready;

    // PCS 状态 (clk_pma_rx 域)
    wire [3:0]   pcs_block_lock_raw;
    wire         pcs_deskew_done_raw;
    wire [3:0]   pcs_bip_error_raw;

    // 配置寄存器输出
    wire [7:0]   cfg_ipg;
    wire [47:0]  cfg_mac_addr;
    wire [15:0]  cfg_max_frame_len;

    // MAC 统计事件
    wire         tx_frame_done;
    wire [15:0]  tx_byte_cnt;
    wire         tx_pause_done;
    wire         rx_frame_done;
    wire [15:0]  rx_byte_cnt;
    wire         rx_fcs_error;
    wire         rx_short_frame;
    wire         rx_long_frame;
    wire         rx_alignment_error;
    wire         rx_pause_frame;
    wire         rx_vlan_frame;
    wire         rx_dropped;
    wire [15:0]  rx_frame_len;
```

### 5.2 模块实例化

```systemverilog
    eth_mac_top u_mac_top (
        .clk                (clk_core),
        .rst_n              (rst_n_core),

        .s_axis_tdata       (s_axis_tx_tdata),
        .s_axis_tkeep       (s_axis_tx_tkeep),
        .s_axis_tlast       (s_axis_tx_tlast),
        .s_axis_tvalid      (s_axis_tx_tvalid),
        .s_axis_tready      (s_axis_tx_tready),

        .m_axis_tdata       (m_axis_rx_tdata),
        .m_axis_tkeep       (m_axis_rx_tkeep),
        .m_axis_tlast       (m_axis_rx_tlast),
        .m_axis_tvalid      (m_axis_rx_tvalid),
        .m_axis_tready      (m_axis_rx_tready),

        .mac_tx_data        (mac_tx_data),
        .mac_tx_ctrl        (mac_tx_ctrl),
        .mac_tx_valid       (mac_tx_valid),
        .mac_tx_ready       (mac_tx_ready),

        .pcs_rx_data        (mac_rx_data),
        .pcs_rx_ctrl        (mac_rx_ctrl),
        .pcs_rx_valid       (mac_rx_valid),
        .pcs_rx_ready       (mac_rx_ready),

        .ipg_cfg            (cfg_ipg),
        .pause_src_mac      (cfg_mac_addr),

        .tx_frame_done      (tx_frame_done),
        .tx_byte_cnt        (tx_byte_cnt),
        .tx_pause_done      (tx_pause_done),
        .rx_frame_done      (rx_frame_done),
        .rx_byte_cnt        (rx_byte_cnt),
        .rx_fcs_error       (rx_fcs_error),
        .rx_short_frame     (rx_short_frame),
        .rx_long_frame      (rx_long_frame),
        .rx_alignment_error (rx_alignment_error),
        .rx_pause_frame     (rx_pause_frame),
        .rx_vlan_frame      (rx_vlan_frame),
        .rx_dropped         (rx_dropped),
        .rx_frame_len       (rx_frame_len)
    );

    eth_pcs_top u_pcs_top (
        .clk_core       (clk_core),
        .rst_n_core     (rst_n_core),

        .clk_pma_tx     (clk_pma_tx),
        .rst_n_pma_tx   (rst_n_pma_tx),

        .clk_pma_rx     (clk_pma_rx),
        .rst_n_pma_rx   (rst_n_pma_rx),

        .mac_tx_data    (mac_tx_data),
        .mac_tx_ctrl    (mac_tx_ctrl),
        .mac_tx_valid   (mac_tx_valid),
        .mac_tx_ready   (mac_tx_ready),

        .mac_rx_data    (mac_rx_data),
        .mac_rx_ctrl    (mac_rx_ctrl),
        .mac_rx_valid   (mac_rx_valid),
        .mac_rx_ready   (mac_rx_ready),

        .lane0_tx_data  (pma_tx_lane0_data),
        .lane1_tx_data  (pma_tx_lane1_data),
        .lane2_tx_data  (pma_tx_lane2_data),
        .lane3_tx_data  (pma_tx_lane3_data),
        .tx_valid       (pma_tx_valid),
        .tx_ready       (pma_tx_ready),

        .lane0_rx_data  (pma_rx_lane0_data),
        .lane1_rx_data  (pma_rx_lane1_data),
        .lane2_rx_data  (pma_rx_lane2_data),
        .lane3_rx_data  (pma_rx_lane3_data),
        .rx_valid       (pma_rx_valid),
        .rx_ready       (pma_rx_ready),

        .block_lock     (pcs_block_lock_raw),
        .deskew_done    (pcs_deskew_done_raw),
        .bip_error      (pcs_bip_error_raw)
    );

    eth_regs u_regs (
        .clk                (clk_core),
        .rst_n              (rst_n_core),

        .s_axi_awvalid      (s_axi_awvalid),
        .s_axi_awaddr       (s_axi_awaddr),
        .s_axi_awready      (s_axi_awready),
        .s_axi_wvalid       (s_axi_wvalid),
        .s_axi_wdata        (s_axi_wdata),
        .s_axi_wstrb        (s_axi_wstrb),
        .s_axi_wready       (s_axi_wready),
        .s_axi_bresp        (s_axi_bresp),
        .s_axi_bvalid       (s_axi_bvalid),
        .s_axi_bready       (s_axi_bready),
        .s_axi_arvalid      (s_axi_arvalid),
        .s_axi_araddr       (s_axi_araddr),
        .s_axi_arready      (s_axi_arready),
        .s_axi_rdata        (s_axi_rdata),
        .s_axi_rresp        (s_axi_rresp),
        .s_axi_rvalid       (s_axi_rvalid),
        .s_axi_rready       (s_axi_rready),

        .cfg_ipg            (cfg_ipg),
        .cfg_mac_addr       (cfg_mac_addr),
        .cfg_max_frame_len  (cfg_max_frame_len),

        .link_up            (link_up),
        .pcs_block_lock     (),
        .pcs_deskew_done    (),
        .pcs_bip_error      (),

        .pcs_block_lock_raw (pcs_block_lock_raw),
        .pcs_deskew_done_raw(pcs_deskew_done_raw),
        .pcs_bip_error_raw  (pcs_bip_error_raw),

        .tx_frame_done      (tx_frame_done),
        .tx_byte_cnt        (tx_byte_cnt),
        .tx_pause_done      (tx_pause_done),
        .rx_frame_done      (rx_frame_done),
        .rx_byte_cnt        (rx_byte_cnt),
        .rx_fcs_error       (rx_fcs_error),
        .rx_short_frame     (rx_short_frame),
        .rx_long_frame      (rx_long_frame),
        .rx_alignment_error (rx_alignment_error),
        .rx_pause_frame     (rx_pause_frame),
        .rx_vlan_frame      (rx_vlan_frame),
        .rx_dropped         (rx_dropped),
        .rx_frame_len       (rx_frame_len)
    );
```

## 6. 时序图

### 6.1 初始化流程

```
clk_pma_rx:    |  0  |  1  | ... | 64  | 65  | ... | 100 | ... |
                |     |     |     |     |     |     |     |     |
block_lock:     |  0  |  0  | ... |  7  |  F  |  F  |  F  |  F  |
                |     |     |     |     |     |     |     |     |
deskew_done:    |  0  |  0  | ... |  0  |  0  |  0  |  1  |  1  |
                |     |     |     |     |     |     |     |     |
link_up:        |  0  |  0  | ... |  0  |  0  |  0  |  1  |  1  |
                |     |     |     |     |     |     |     |     |
m_axis_rx_*:    |  -  |  -  | ... |  -  |  -  |  -  |  -  | D0  |
```

### 6.2 帧发送流程

```
clk_core:       |  N  | N+1 | N+2 | N+3 | N+4 | N+5 |
                |     |     |     |     |     |     |
s_axis_tx_*:    | D0  | D1  | D2  | D3  | D4  | D5  | (用户数据)
                |     |     |     |     |     |     |
mac_tx_*:       |     | M0  | M1  | M2  | M3  | M4  | (MAC 处理后)
                |     |     |     |     |     |     |
pma_tx_*:       |     |     |     | P0  | P1  | P2  | (PCS 处理后)
```

### 6.3 帧接收流程

```
clk_pma_rx:     |  N  | N+1 | N+2 | N+3 | N+4 |
                |     |     |     |     |     |
pma_rx_*:       | R0  | R1  | R2  | R3  | R4  |
                |     |     |     |     |     |
mac_rx_*:       |     |     | M0  | M1  | M2  | (PCS → MAC)

clk_core:       |  M  | M+1 | M+2 | M+3 | M+4 |
                |     |     |     |     |     |
m_axis_rx_*:    |     |     | D0  | D1  | D2  | (MAC → 用户)
```

## 7. 资源估算

| 模块 | LUT | FF | 说明 |
|------|-----|-----|------|
| eth_regs | ~400 | ~3000 | 寄存器 + 统计计数器 (19×48-bit) |
| eth_mac_top | ~2190 | ~1210 | MAC TX/RX (无 Stats) |
| eth_pcs_top | ~3000 | ~4000 | PCS TX/RX + CDC |
| **总计** | **~5590** | **~8210** | |

## 8. 测试要点

| 测试项 | 说明 |
|--------|------|
| 单帧收发 | 验证端到端数据正确 |
| 背靠背帧 | 验证连续帧处理 |
| Pause 帧 | 验证 Pause 帧检测和流量控制 |
| 链路初始化 | 验证 block_lock → deskew_done → link_up |
| 反压处理 | 验证 TX/RX 方向反压传递 |
| FCS 错误 | 验证错误帧检测 |
| BIP 错误 | 验证链路质量监测 |
| CDC | 验证跨时钟域数据正确传输 |
| 寄存器访问 | 验证 AXI-Lite 读写正确 |
| 统计计数器 | 验证计数器累加正确 |
| 复位行为 | 验证复位后状态正确 |

## 9. 与外部模块的关系

```
                    ┌─────────────────────────────────────┐
                    │           用户逻辑                   │
                    │  (AXI-Stream TX/RX 接口)            │
                    └─────────────────────────────────────┘
                                    │
                      s_axis_tx_* / m_axis_rx_*
                                    │
                                    ▼
                    ┌─────────────────────────────────────┐
                    │         eth_40g_mac_pcs             │
                    │                                     │
                    │  ┌─────────────────────────────┐   │
                    │  │       eth_regs              │   │
                    │  │  (配置/状态/统计寄存器)      │   │
                    │  └─────────────────────────────┘   │
                    │                 │                   │
                    │           cfg / status              │
                    │                 │                   │
                    │  ┌──────────────▼──────────────┐   │
                    │  │       eth_mac_top           │   │
                    │  │  (MAC TX/RX)                │   │
                    │  └──────────────┬──────────────┘   │
                    │                 │                   │
                    │           XLGMII (clk_core)        │
                    │                 │                   │
                    │  ┌──────────────▼──────────────┐   │
                    │  │       eth_pcs_top           │   │
                    │  │  (PCS TX/RX + CDC)          │   │
                    │  └──────────────┬──────────────┘   │
                    │                 │                   │
                    └─────────────────┼───────────────────┘
                                      │
                        pma_tx_* / pma_rx_*
                                      │
                                      ▼
                    ┌─────────────────────────────────────┐
                    │              PMA                     │
                    │  (GTY/GTYP 收发器 + 时钟恢复)        │
                    └─────────────────────────────────────┘
```

## 10. 参考文献

- IEEE 802.3-2018 Clause 82 (PCS for 40GBASE-R)
- IEEE 802.3-2018 Clause 46 (MAC Control)
- Xilinx UltraScale+ GTY/GTYP Transceiver User Guide

## 11. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-13 | 初始版本 |
| 2.0 | 2026-04-13 | 配置和状态统一通过 AXI-Lite 寄存器接口访问，只保留 link_up 信号 |
| 2.1 | 2026-04-14 | 添加 RX_ALIGNMENT_ERRORS 和按帧长分布的 7 个统计计数器 |
