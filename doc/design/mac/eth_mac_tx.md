# eth_mac_tx 模块详细设计

## 1. 概述

### 1.1 功能
MAC TX 路径顶层模块，实例化所有 TX 子模块，将 AXI-Stream 输入转换为 XLGMII 格式输出给 PCS。

### 1.2 数据流
```
AXI-Stream 输入
    ↓
eth_mac_tx_fifo (数据缓冲)
    ↓
eth_mac_tx_pause (Pause 帧插入 MUX)
    ↓
eth_mac_tx_preamble (插入 Preamble/SFD)
    ↓
eth_mac_tx_fcs (计算并追加 FCS)
    ↓
eth_mac_tx_ipg (插入 IPG)
    ↓
eth_mac_xgmii_enc (AXI-Stream → XLGMII)
    ↓
PCS (XLGMII)
```

---

## 2. 接口定义

```systemverilog
module eth_mac_tx (
    input  wire         clk,
    input  wire         rst_n,          // 同步复位，低有效

    // AXI-Stream 输入 (来自用户逻辑)
    input  wire [127:0] s_axis_tdata,
    input  wire [15:0]  s_axis_tkeep,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,

    // XLGMII 输出 (去往 PCS)
    output wire [127:0] mac_tx_data,
    output wire [15:0]  mac_tx_ctrl,
    output wire         mac_tx_valid,
    input  wire         mac_tx_ready,

    // Pause 控制输入 (来自 RX)
    input  wire         pause_req,
    input  wire [15:0]  pause_time,
    input  wire [47:0]  pause_src_mac,

    // 配置输入
    input  wire [7:0]   ipg_cfg,        // IPG 配置 (默认 12)

    // 状态输出
    output wire         pause_busy,

    // 统计事件输出 (连接 eth_mac_stats)
    output wire         tx_frame_done,
    output wire [15:0]  tx_byte_cnt,
    output wire         tx_pause_done
);
```

### 2.1 信号说明
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| clk | input | 1 | 时钟，312.5 MHz |
| rst_n | input | 1 | 同步复位，低有效 |
| s_axis_tdata | input | 127:0 | AXI-Stream 数据 |
| s_axis_tkeep | input | 15:0 | 字节有效 |
| s_axis_tlast | input | 1 | 帧结束 |
| s_axis_tvalid | input | 1 | 数据有效 |
| s_axis_tready | output | 1 | MAC 就绪 |
| mac_tx_data | output | 127:0 | XLGMII 数据 |
| mac_tx_ctrl | output | 15:0 | 控制标志 |
| mac_tx_valid | output | 1 | 数据有效 |
| mac_tx_ready | input | 1 | PCS 就绪 |
| pause_req | input | 1 | Pause 请求 |
| pause_time | input | 15:0 | Pause 时间 |
| pause_src_mac | input | 47:0 | Pause 源 MAC |
| ipg_cfg | input | 7:0 | IPG 配置 |
| pause_busy | output | 1 | Pause 发送中 |
| tx_frame_done | output | 1 | 帧发送完成脉冲 |
| tx_byte_cnt | output | 15:0 | 本帧字节数 |
| tx_pause_done | output | 1 | Pause 帧发送完成脉冲 |

---

## 3. 子模块实例化

### 3.1 内部信号

```systemverilog
// AXI-Stream → tx_fifo
wire        fifo_wr_en;
wire [127:0] fifo_wr_data;
wire [15:0]  fifo_wr_tkeep;
wire         fifo_wr_tlast;
wire         fifo_full;
wire         fifo_almost_full;

// tx_fifo → tx_pause
wire        fifo2pause_valid;
wire [127:0] fifo2pause_data;
wire [15:0]  fifo2pause_tkeep;
wire         fifo2pause_tlast;
wire         pause2fifo_ready;

// tx_pause → tx_preamble
wire        pause2pre_valid;
wire [127:0] pause2pre_data;
wire [15:0]  pause2pre_tkeep;
wire         pause2pre_tlast;
wire         pre2pause_ready;

// tx_preamble → tx_fcs
wire        pre2fcs_valid;
wire [127:0] pre2fcs_data;
wire [15:0]  pre2fcs_tkeep;
wire         pre2fcs_tlast;
wire         fcs2pre_ready;

// tx_fcs → tx_ipg
wire        fcs2ipg_valid;
wire [127:0] fcs2ipg_data;
wire [15:0]  fcs2ipg_tkeep;
wire         fcs2ipg_tlast;
wire         ipg2fcs_ready;

// tx_ipg → xgmii_enc
wire        ipg2enc_valid;
wire [127:0] ipg2enc_data;
wire [15:0]  ipg2enc_tkeep;
wire         ipg2enc_tlast;
wire         enc2ipg_ready;

// 统计事件
reg         tx_frame_done_reg;
reg [15:0]  tx_byte_cnt_reg;
reg         tx_pause_done_reg;
reg [3:0]   frame_byte_shift;  // 帧字节偏移计数
```

### 3.2 子模块实例化

```systemverilog
// AXI-Stream 接口 (反压控制)
assign s_axis_tready = !fifo_almost_full;
assign fifo_wr_en    = s_axis_tvalid && s_axis_tready;
assign fifo_wr_data  = s_axis_tdata;
assign fifo_wr_tkeep = s_axis_tkeep;
assign fifo_wr_tlast = s_axis_tlast;

// TX FIFO
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

// Pause 帧插入
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

// Preamble 插入
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

// FCS 计算
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

// IPG 插入
eth_mac_tx_ipg u_tx_ipg (
    .clk        (clk),
    .rst_n      (rst_n),
    .ipg_cfg    (ipg_cfg),
    .in_valid   (fcs2ipg_valid),
    .in_data    (fcs2ipg_data),
    .in_tkeep   (fcs2ipg_tkeep),
    .in_tlast   (fcs2ipg_tlast),
    .in_ready   (ipg2fcs_ready),
    .out_valid  (ipg2enc_valid),
    .out_data   (ipg2enc_data),
    .out_tkeep  (ipg2enc_tkeep),
    .out_tlast  (ipg2enc_tlast),
    .out_ready  (enc2ipg_ready)
);

// XLGMII 编码
eth_mac_xgmii_enc u_xgmii_enc (
    .clk        (clk),
    .rst_n      (rst_n),
    .in_valid   (ipg2enc_valid),
    .in_data    (ipg2enc_data),
    .in_tkeep   (ipg2enc_tkeep),
    .in_tlast   (ipg2enc_tlast),
    .in_ready   (enc2ipg_ready),
    .out_valid  (mac_tx_valid),
    .out_data   (mac_tx_data),
    .out_ctrl   (mac_tx_ctrl),
    .out_ready  (mac_tx_ready)
);

// 统计事件输出
// tx_frame_done: 在 XLGMII 输出 tlast 时脉冲
// tx_byte_cnt: 本帧字节数 (tkeep 中 1 的个数累加)
// tx_pause_done: Pause 帧发送完成脉冲

assign tx_frame_done  = tx_frame_done_reg;
assign tx_byte_cnt    = tx_byte_cnt_reg;
assign tx_pause_done  = tx_pause_done_reg;
```

---

## 4. 配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| ipg_cfg | 12 | IPG 字节数 (8-64) |
| pause_src_mac | 寄存器配置 | Pause 帧源 MAC 地址 |

---

## 5. 资源估算

| 子模块 | LUT | FF | 说明 |
|--------|-----|-----|------|
| tx_fifo | ~50 | ~200 | 2KB FIFO |
| tx_pause | ~80 | ~80 | Pause 生成 |
| tx_preamble | ~50 | ~100 | Preamble 插入 |
| tx_fcs | ~850 | ~400 | CRC32 + 延迟线 |
| tx_ipg | ~50 | ~250 | IPG 插入 |
| xgmii_enc | ~100 | ~0 | XLGMII 编码 |
| **总计** | **~1180** | **~1030** | |

---

## 6. 测试要点

| 测试项 | 说明 |
|--------|------|
| 完整帧发送 | 验证端到端数据正确 |
| Preamble/SFD | 验证前导码正确插入 |
| FCS 计算 | 验证 FCS 值正确 |
| Pause 帧 | 验证 Pause 帧生成和插入 |
| IPG 插入 | 验证帧间间隔正确 |
| 背靠背帧 | 验证连续帧处理 |
| 反压处理 | 验证 s_axis_tready 反压 |
