# eth_mac_top 模块详细设计

## 1. 概述

### 1.1 功能
MAC 顶层模块，实例化 TX/RX 路径，提供 AXI-Stream 用户接口和 XLGMII PCS 接口。

### 1.2 数据流
```
AXI-Stream 输入 → eth_mac_tx → XLGMII TX → PCS
PCS → XLGMII RX → eth_mac_rx → AXI-Stream 输出
```

---

## 2. 接口定义

```systemverilog
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
    output wire [15:0]  rx_frame_len
);
```

### 2.1 信号说明

**时钟与复位**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| clk | input | 1 | 时钟，312.5 MHz |
| rst_n | input | 1 | 同步复位，低有效 |

**AXI-Stream TX 接口 (用户输入)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| s_axis_tdata | input | 128 | 发送数据 |
| s_axis_tkeep | input | 16 | 字节有效 |
| s_axis_tlast | input | 1 | 帧结束 |
| s_axis_tvalid | input | 1 | 数据有效 |
| s_axis_tready | output | 1 | MAC 就绪 |

**AXI-Stream RX 接口 (用户输出)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| m_axis_tdata | output | 128 | 接收数据 |
| m_axis_tkeep | output | 16 | 字节有效 |
| m_axis_tlast | output | 1 | 帧结束 |
| m_axis_tvalid | output | 1 | 数据有效 |
| m_axis_tready | input | 1 | 用户就绪 |

**XLGMII TX 接口 (去往 PCS)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| mac_tx_data | output | 128 | TX 数据 |
| mac_tx_ctrl | output | 16 | TX 控制掩码 |
| mac_tx_valid | output | 1 | TX 数据有效 |
| mac_tx_ready | input | 1 | PCS 就绪 |

**XLGMII RX 接口 (来自 PCS)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| pcs_rx_data | input | 128 | RX 数据 |
| pcs_rx_ctrl | input | 16 | RX 控制掩码 |
| pcs_rx_valid | input | 1 | RX 数据有效 |
| pcs_rx_ready | output | 1 | MAC 就绪 |

**配置输入**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| ipg_cfg | input | 8 | IPG 配置 (默认 12) |
| pause_src_mac | input | 48 | Pause 帧源 MAC 地址 |

**TX 统计事件输出**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| tx_frame_done | output | 1 | 帧发送完成脉冲 |
| tx_byte_cnt | output | 16 | 本帧字节数 |
| tx_pause_done | output | 1 | Pause 帧发送完成脉冲 |

**RX 统计事件输出**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| rx_frame_done | output | 1 | 帧接收完成脉冲 |
| rx_byte_cnt | output | 16 | 本帧字节数 |
| rx_fcs_error | output | 1 | FCS 校验错误脉冲 |
| rx_short_frame | output | 1 | 过短帧脉冲 |
| rx_long_frame | output | 1 | 过长帧脉冲 |
| rx_alignment_error | output | 1 | 对齐错误脉冲 |
| rx_pause_frame | output | 1 | Pause 帧脉冲 |
| rx_vlan_frame | output | 1 | VLAN 帧脉冲 |
| rx_dropped | output | 1 | 丢弃帧脉冲 |
| rx_frame_len | output | 16 | 帧长度 |

---

## 3. 子模块实例化

### 3.1 内部信号

```systemverilog
wire         rx_pause_req;
wire [15:0]  rx_pause_time;
```

### 3.2 子模块实例化

```systemverilog
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
    .preamble_error     (),
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
```

---

## 4. 资源估算

| 子模块 | LUT | FF | 说明 |
|--------|-----|-----|------|
| eth_mac_tx | ~1180 | ~1030 | TX 路径 |
| eth_mac_rx | ~1010 | ~480 | RX 路径 |
| **总计** | **~2190** | **~1510** | |

---

## 5. 测试要点

| 测试项 | 说明 |
|--------|------|
| TX 路径 | 验证 AXI-Stream → XLGMII 转换 |
| RX 路径 | 验证 XLGMII → AXI-Stream 转换 |
| Pause 帧 | 验证 RX 检测 → TX 响应 |
| 统计事件 | 验证事件脉冲输出正确 |
| 背靠背帧 | 验证连续帧处理 |
| 反压处理 | 验证 tready 反压 |

---

## 6. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-08 | 初始版本 |
| 2.0 | 2026-04-13 | 移除 eth_mac_stats，统计事件改为输出端口 |
