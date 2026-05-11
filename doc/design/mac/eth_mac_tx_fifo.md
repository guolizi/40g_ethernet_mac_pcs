# eth_mac_tx_fifo 模块详细设计

## 1. 概述

### 1.1 功能
MAC TX 路径数据缓冲 FIFO，存储数据 + 帧边界控制信号 (tlast, tkeep)，支持 almost_full 反压。

### 1.2 关键参数
| 参数 | 值 | 说明 |
|------|-----|------|
| DATA_WIDTH | 128 | 数据位宽 |
| DEPTH | 128 | FIFO 深度 (2KB = 128 × 16B) |
| ALMOST_FULL_THRESH | 112 | almost_full 阈值 (87.5% 容量) |
| 存储内容 | {tlast, tkeep, data} | 数据 + 帧边界控制 |

### 1.3 特性
- 存储 128-bit 数据 + 16-bit tkeep + 1-bit tlast
- almost_full 反压控制
- 基于 sync_fifo 实例化

---

## 2. 接口定义

```systemverilog
module eth_mac_tx_fifo (
    input  wire         clk,
    input  wire         rst_n,          // 同步复位，低有效

    // 写接口 (来自 AXI-Stream)
    input  wire         wr_en,
    input  wire [127:0] wr_data,
    input  wire [15:0]  wr_tkeep,
    input  wire         wr_tlast,
    output wire         full,
    output wire         almost_full,

    // 读接口 (去往 MAC TX 逻辑)
    input  wire         rd_en,
    output wire [127:0] rd_data,
    output wire [15:0]  rd_tkeep,
    output wire         rd_tlast,
    output wire         rd_valid,       // 读数据有效 (= ~empty)
    output wire         empty
);
```

### 2.1 信号说明
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| clk | input | 1 | 时钟，312.5 MHz |
| rst_n | input | 1 | 同步复位，低有效 |
| wr_en | input | 1 | 写使能 |
| wr_data | input | 127:0 | 写数据 |
| wr_tkeep | input | 15:0 | 写字节使能 |
| wr_tlast | input | 1 | 写帧结束标志 |
| full | output | 1 | FIFO 满标志 |
| almost_full | output | 1 | 接近满标志 (112/128 entries) |
| rd_en | input | 1 | 读使能 |
| rd_data | output | 127:0 | 读数据 |
| rd_tkeep | output | 15:0 | 读字节使能 |
| rd_tlast | output | 1 | 读帧结束标志 |
| rd_valid | output | 1 | 读数据有效 (= ~empty)，供下游模块直接用作 in_valid |
| empty | output | 1 | FIFO 空标志 |

---

## 3. 架构设计

### 3.1 内部结构

```
wr_data[127:0] ──────┐
wr_tkeep[15:0]  ─────┤
wr_tlast        ─────┤
                     │   ┌─────────────────────────┐
                     ├──►│  打包: {tlast,tkeep,data}│
                     │   └────────────┬────────────┘
                     │                │
                     │   ┌────────────▼────────────┐
                     ├──►│  sync_fifo              │
                     │   │  DATA_WIDTH=145         │
                     │   │  DEPTH=128              │
                     │   │  ALMOST_FULL=112        │
                     │   └────────────┬────────────┘
                     │                │
                     │   ┌────────────▼────────────┐
                     ├──►│  解包                   │
                     │   └────────────┬────────────┘
                     │                │
rd_data[127:0] ◄────┘                │
rd_tkeep[15:0]  ◄────────────────────┘
rd_tlast        ◄────────────────────┘
```

### 3.2 数据打包格式

```
FIFO 存储格式 (145-bit):
┌────────┬──────────┬───────────────┐
│ tlast  │ tkeep    │ data          │
│ 1-bit  │ 15:0     │ 127:0         │
└────────┴──────────┴───────────────┘
```

---

## 4. 详细设计

### 4.1 内部信号

```systemverilog
localparam FIFO_DATA_WIDTH = 1 + 16 + 128;  // tlast + tkeep + data = 145
localparam FIFO_DEPTH      = 128;
localparam ALMOST_FULL     = 112;

wire [FIFO_DATA_WIDTH-1:0] fifo_wr_data;
wire [FIFO_DATA_WIDTH-1:0] fifo_rd_data;
wire fifo_full;
wire fifo_empty;
wire fifo_almost_full;
```

### 4.2 写打包

```systemverilog
assign fifo_wr_data = {wr_tlast, wr_tkeep, wr_data};
```

### 4.3 sync_fifo 实例化

```systemverilog
sync_fifo #(
    .DATA_WIDTH           (FIFO_DATA_WIDTH),
    .DEPTH                (FIFO_DEPTH),
    .ALMOST_FULL_THRESH   (ALMOST_FULL),
    .ALMOST_EMPTY_THRESH  (0)
) u_tx_fifo (
    .clk          (clk),
    .rst_n        (rst_n),
    .wr_en        (wr_en),
    .wr_data      (fifo_wr_data),
    .full         (fifo_full),
    .rd_en        (rd_en),
    .rd_data      (fifo_rd_data),
    .empty        (fifo_empty),
    .almost_full  (fifo_almost_full),
    .almost_empty ()
);
```

### 4.4 读解包

```systemverilog
assign rd_data   = fifo_rd_data[127:0];
assign rd_tkeep  = fifo_rd_data[143:128];
assign rd_tlast  = fifo_rd_data[144];
assign rd_valid  = ~fifo_empty;
assign full      = fifo_full;
assign almost_full = fifo_almost_full;
assign empty     = fifo_empty;
```

---

## 5. 反压机制

```
上游 AXI-Stream:
    s_axis_tready = ~almost_full

当 FIFO 数据量 >= 112 entries 时:
    almost_full = 1
    s_axis_tready = 0
    上游停止发送

当 FIFO 数据量 < 112 entries 时:
    almost_full = 0
    s_axis_tready = 1
    上游可以继续发送
```

> 留出 16 entries (256 字节) 的余量，确保帧不会被截断。

---

## 6. 资源估算

| 资源 | 估算值 | 说明 |
|------|--------|------|
| BRAM | 1 × RAMB36E2 | 145-bit × 128 entries ≈ 18.5 Kbit |
| FF | ~200 | 控制逻辑 + 预取寄存器 |
| LUT | ~50 | 打包/解包 + 标志逻辑 |

---

## 7. 测试要点

| 测试项 | 说明 |
|--------|------|
| 数据+tlast+tkeep 环回 | 验证写入和读出的数据、tlast、tkeep 一致 |
| almost_full 反压 | 验证数据量达到 112 时 almost_full 拉高 |
| 满/空标志 | 验证 full 和 empty 正确触发 |
| 帧边界完整性 | 验证跨 FIFO 的帧边界 (tlast) 不被破坏 |
| 背靠背帧 | 验证连续多帧写入和读出的正确性 |
| 复位行为 | 验证 rst_n 后 FIFO 为空，标志正确 |
