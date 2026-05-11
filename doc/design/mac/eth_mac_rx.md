# eth_mac_rx 模块详细设计

## 1. 概述

### 1.1 功能
MAC RX 路径顶层模块，实例化所有 RX 子模块，将 PCS 输出的 XLGMII 数据转换为 AXI-Stream 格式输出。

### 1.2 数据流
```
PCS (XLGMII)
    ↓
eth_mac_xgmii_dec (XLGMII → AXI-Stream)
    ↓
eth_mac_rx_preamble (剥离 Preamble/SFD)
    ↓
eth_mac_rx_fcs (CRC32 校验)
    ↓
eth_mac_rx_pause (Pause 帧检测)
    ↓
AXI-Stream 输出
```

> RX 方向不需要 FIFO：MAC 处理速度 ≥ PCS 处理速度，纯流水线即可。

---

## 2. 接口定义

```systemverilog
module eth_mac_rx (
    input  wire         clk,
    input  wire         rst_n,          // 同步复位，低有效

    // XLGMII 输入 (来自 PCS)
    input  wire [127:0] pcs_rx_data,
    input  wire [15:0]  pcs_rx_ctrl,
    input  wire         pcs_rx_valid,
    output wire         pcs_rx_ready,

    // AXI-Stream 输出 (去往用户逻辑)
    output wire [127:0] m_axis_tdata,
    output wire [15:0]  m_axis_tkeep,
    output wire         m_axis_tlast,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,

    // Pause 控制输出 (连接 TX)
    output wire         pause_req,
    output wire [15:0]  pause_time,

    // 错误输出
    output wire         fcs_error,
    output wire         sop_detected,
    output wire         preamble_error,

    // 统计事件输出 (连接 eth_mac_stats)
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
```

### 2.1 信号说明
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| clk | input | 1 | 时钟，312.5 MHz |
| rst_n | input | 1 | 同步复位，低有效 |
| pcs_rx_data | input | 127:0 | PCS 数据 |
| pcs_rx_ctrl | input | 15:0 | PCS 控制标志 |
| pcs_rx_valid | input | 1 | PCS 数据有效 |
| pcs_rx_ready | output | 1 | MAC 就绪 |
| m_axis_tdata | output | 127:0 | AXI-Stream 数据 |
| m_axis_tkeep | output | 15:0 | 字节有效 |
| m_axis_tlast | output | 1 | 帧结束 |
| m_axis_tvalid | output | 1 | 数据有效 |
| m_axis_tready | input | 1 | 下游就绪 |
| pause_req | output | 1 | Pause 请求 |
| pause_time | output | 15:0 | Pause 时间 |
| fcs_error | output | 1 | FCS 校验错误 |
| sop_detected | output | 1 | 帧起始检测 |
| preamble_error | output | 1 | 前导码错误 |
| rx_frame_done | output | 1 | 帧接收完成脉冲 |
| rx_byte_cnt | output | 15:0 | 本帧字节数 |
| rx_short_frame | output | 1 | 过短帧脉冲 |
| rx_long_frame | output | 1 | 过长帧脉冲 |
| rx_alignment_error | output | 1 | 对齐错误脉冲 |
| rx_pause_frame | output | 1 | 接收 Pause 帧脉冲 |
| rx_vlan_frame | output | 1 | 接收 VLAN 帧脉冲 |
| rx_dropped | output | 1 | 帧丢弃脉冲 |
| rx_frame_len | output | 15:0 | 帧长度 |

---

## 3. 子模块实例化

### 3.1 内部信号

```systemverilog
// xgmii_dec → rx_preamble
wire        dec2pre_valid;
wire [127:0] dec2pre_data;
wire [15:0]  dec2pre_tkeep;
wire         dec2pre_tlast;
wire         pre2dec_ready;

// rx_preamble → rx_fcs
wire        pre2fcs_valid;
wire [127:0] pre2fcs_data;
wire [15:0]  pre2fcs_tkeep;
wire         pre2fcs_tlast;
wire         fcs2pre_ready;

// rx_fcs → rx_pause
wire        fcs2pause_valid;
wire [127:0] fcs2pause_data;
wire [15:0]  fcs2pause_tkeep;
wire         fcs2pause_tlast;
wire         pause2fcs_ready;
wire         fcs_error_internal;
wire         fcs_valid_internal;

// rx_pause → 输出
wire        pause2out_valid;
wire [127:0] pause2out_data;
wire [15:0]  pause2out_tkeep;
wire         pause2out_tlast;
wire         out2pause_ready;
```

### 3.2 子模块实例化

```systemverilog
// XGMII 解码器
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

// 前导码剥离
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

// FCS 校验
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

// Pause 帧检测
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

// 输出直通
assign m_axis_tdata   = pause2out_data;
assign m_axis_tkeep   = pause2out_tkeep;
assign m_axis_tlast   = pause2out_tlast;
assign m_axis_tvalid  = pause2out_valid;
assign out2pause_ready = m_axis_tready;

assign fcs_error = fcs_error_internal;

// 统计事件
// 帧字节计数 (累加每周期 tkeep 中 1 的个数)
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

// VLAN 检测: EtherType 0x8100 在 Bytes 12-13 (帧起始后第 12-13 字节)
// 简化: 检测每帧第一个周期的 Bytes 12-13
wire vlan_detected = (pause2out_data[111:96] == 16'h8100);
assign rx_vlan_frame = rx_frame_done && vlan_detected;
assign rx_dropped    = preamble_error || rx_fcs_error;
assign rx_frame_len  = frame_byte_cnt;
```

---

## 4. 资源估算

| 子模块 | LUT | FF | 说明 |
|--------|-----|-----|------|
| xgmii_dec | ~80 | ~20 | XLGMII 解码 |
| rx_preamble | ~30 | ~10 | 前导码剥离 |
| rx_fcs | ~850 | ~400 | CRC32 + 延迟线 |
| rx_pause | ~50 | ~50 | Pause 检测 |
| **总计** | **~1010** | **~480** | 无 FIFO |

---

## 5. 测试要点

| 测试项 | 说明 |
|--------|------|
| 完整帧接收 | 验证端到端数据正确 |
| FCS 校验 | 验证正确/错误 FCS 帧 |
| Pause 帧 | 验证 Pause 帧检测和 pause_time 提取 |
| 前导码错误 | 验证无效前导码帧被丢弃 |
| 背靠背帧 | 验证连续帧处理 |
| 反压处理 | 验证 m_axis_tready 反压 |
