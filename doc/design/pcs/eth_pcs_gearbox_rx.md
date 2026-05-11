# eth_pcs_gearbox_rx 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_gearbox_rx

**功能**: RX 方向 Gearbox，将 4 个 lane 的 32-bit 输入转换为 66-bit 块流

**位置**: rtl/pcs/eth_pcs_gearbox_rx.sv

**注意**: 本模块仅进行位宽转换，不包含 CDC。整个 PCS RX 处理链在 clk_pma_rx 域运行。

## 2. 接口定义

```systemverilog
module eth_pcs_gearbox_rx (
    input  wire         clk_pma,
    input  wire         rst_n_pma,

    input  wire [31:0]  lane0_rx_data,
    input  wire [31:0]  lane1_rx_data,
    input  wire [31:0]  lane2_rx_data,
    input  wire [31:0]  lane3_rx_data,
    input  wire         rx_valid,
    output wire         rx_ready,

    output wire [65:0]  lane0_block,
    output wire [65:0]  lane1_block,
    output wire         out_valid,
    input  wire         out_ready
);
```

### 2.1 信号说明

**输入侧 (clk_pma 域)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| lane0_rx_data | input | 32 | Lane 0 的 32-bit 输入 |
| lane1_rx_data | input | 32 | Lane 1 的 32-bit 输入 |
| lane2_rx_data | input | 32 | Lane 2 的 32-bit 输入 |
| lane3_rx_data | input | 32 | Lane 3 的 32-bit 输入 |
| rx_valid | input | 1 | 数据有效 |
| rx_ready | output | 1 | 接收就绪 |

**输出侧 (clk_pma 域)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| lane0_block | output | 66 | Lane 0/2 的 66-bit 块 (根据 lane_sel) |
| lane1_block | output | 66 | Lane 1/3 的 66-bit 块 (根据 lane_sel) |
| out_valid | output | 1 | 块有效 |
| out_ready | input | 1 | 下游就绪 |

### 2.2 时钟频率

| 时钟 | 频率 | 说明 |
|------|------|------|
| clk_pma | 322.266 MHz | PMA RX 恢复时钟 |

## 3. 功能描述

### 3.1 架构说明

本模块仅进行 32-bit → 66-bit 位宽转换，不包含 CDC 功能。

**设计原因**:
- 整个 PCS RX 处理链（Gearbox → 块同步 → AM 检测 → 去偏斜 → 解扰 → 解码 → Idle 删除）在 clk_pma_rx 域运行
- Idle 删除在解码后进行，实现速率匹配
- CDC 在 Idle 删除后、MAC 接口处进行

### 3.2 数据流

```
来自 PMA:
  - 每周期: 4 个 lane 的 32-bit 数据
  - 每个 lane 数据率: 32 × 322.266M = 10.3125 Gbps

Gearbox 转换 (clk_pma 域):
  - 每 33 个 32-bit → 16 个 66-bit

输出到 block_sync (clk_pma 域):
  - 周期 N:   lane0_block = Lane 0, lane1_block = Lane 1
  - 周期 N+1: lane0_block = Lane 2, lane1_block = Lane 3
  - 每 2 个周期输出 4 个 lane 的 66-bit 块
```

### 3.3 位宽转换原理

```
每 33 个 32-bit 数据 = 1056 bits
每 16 个 66-bit 块 = 1056 bits

转换过程:
  使用移位寄存器累积 32-bit 输入
  每累积 66 bits 输出一个块

输出频率:
  16/33 × 322.266 MHz ≈ 156.36 MHz
```

## 4. 详细设计

### 4.1 整体架构

```
                     clk_pma 域
                          │
lane0_rx_data[31:0] ─────┼───┐
lane1_rx_data[31:0] ─────┼───┤
lane2_rx_data[31:0] ─────┼───┤
lane3_rx_data[31:0] ─────┼───┤
                          │   │
                          ▼   ▼
     ┌────────────────────────────────────────┐
     │           32:66 Gearbox                │
     │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
     │  │ Lane 0 │ │ Lane 1 │ │ Lane 2 │ │ Lane 3 │
     │  │Gearbox │ │Gearbox │ │Gearbox │ │Gearbox │
     │  └────────┘ └────────┘ └────────┘ └────────┘
     └────────────────────────────────────────┘
                          │
          ┌───────┬───────┼───────┬───────┐
          │       │       │       │       │
          ▼       ▼       ▼       ▼       │
     lane0_block lane1_block               │
      [65:0]    [65:0]                     │
                                          输出到 block_sync
```

### 4.2 单 Lane Gearbox 设计

```systemverilog
module eth_pcs_gearbox_rx_lane (
    input  wire         clk_pma,
    input  wire         rst_n_pma,

    input  wire [31:0]  in_data,
    input  wire         in_valid,
    output wire         in_ready,

    output wire [65:0]  out_block,
    output wire         out_valid,
    input  wire         out_ready
);
```

### 4.3 32:66 转换实现

```systemverilog
module eth_pcs_gearbox_rx_lane (
    input  wire         clk_pma,
    input  wire         rst_n_pma,

    input  wire [31:0]  in_data,
    input  wire         in_valid,
    output wire         in_ready,

    output wire [65:0]  out_block,
    output wire         out_valid,
    input  wire         out_ready
);

    reg [97:0]  shift_reg;
    reg [5:0]   bit_count;
    reg         out_valid_reg;
    reg [65:0]  out_block_reg;

    always @(posedge clk_pma) begin
        if (!rst_n_pma) begin
            shift_reg    <= 98'h0;
            bit_count    <= 6'h0;
            out_valid_reg <= 1'b0;
            out_block_reg <= 66'h0;
        end else if (in_valid && out_ready) begin
            shift_reg <= {in_data, shift_reg[97:32]};
            bit_count <= bit_count + 6'd32;

            if (bit_count >= 6'd34) begin
                out_block_reg <= shift_reg[65:0];
                out_valid_reg <= 1'b1;
                shift_reg <= {32'h0, shift_reg[97:66]};
                bit_count <= bit_count - 6'd34;
            end else begin
                out_valid_reg <= 1'b0;
            end
        end
    end

    assign out_block = out_block_reg;
    assign out_valid = out_valid_reg;
    assign in_ready  = out_ready;

endmodule
```

### 4.4 顶层模块实现

```systemverilog
module eth_pcs_gearbox_rx (
    input  wire         clk_pma,
    input  wire         rst_n_pma,

    input  wire [31:0]  lane0_rx_data,
    input  wire [31:0]  lane1_rx_data,
    input  wire [31:0]  lane2_rx_data,
    input  wire [31:0]  lane3_rx_data,
    input  wire         rx_valid,
    output wire         rx_ready,

    output wire [65:0]  lane0_block,
    output wire [65:0]  lane1_block,
    output wire         out_valid,
    input  wire         out_ready
);

    wire [65:0] lane0_out, lane1_out, lane2_out, lane3_out;
    wire        lane0_valid, lane1_valid, lane2_valid, lane3_valid;
    wire        lane0_ready, lane1_ready, lane2_ready, lane3_ready;

    eth_pcs_gearbox_rx_lane u_lane0 (
        .clk_pma   (clk_pma),
        .rst_n_pma (rst_n_pma),
        .in_data   (lane0_rx_data),
        .in_valid  (rx_valid),
        .in_ready  (lane0_ready),
        .out_block (lane0_out),
        .out_valid (lane0_valid),
        .out_ready (out_ready)
    );

    eth_pcs_gearbox_rx_lane u_lane1 (
        .clk_pma   (clk_pma),
        .rst_n_pma (rst_n_pma),
        .in_data   (lane1_rx_data),
        .in_valid  (rx_valid),
        .in_ready  (lane1_ready),
        .out_block (lane1_out),
        .out_valid (lane1_valid),
        .out_ready (out_ready)
    );

    eth_pcs_gearbox_rx_lane u_lane2 (
        .clk_pma   (clk_pma),
        .rst_n_pma (rst_n_pma),
        .in_data   (lane2_rx_data),
        .in_valid  (rx_valid),
        .in_ready  (lane2_ready),
        .out_block (lane2_out),
        .out_valid (lane2_valid),
        .out_ready (out_ready)
    );

    eth_pcs_gearbox_rx_lane u_lane3 (
        .clk_pma   (clk_pma),
        .rst_n_pma (rst_n_pma),
        .in_data   (lane3_rx_data),
        .in_valid  (rx_valid),
        .in_ready  (lane3_ready),
        .out_block (lane3_out),
        .out_valid (lane3_valid),
        .out_ready (out_ready)
    );

    reg         lane_sel;
    reg [65:0]  lane0_buf, lane1_buf, lane2_buf, lane3_buf;
    reg         buf_valid;

    always @(posedge clk_pma) begin
        if (!rst_n_pma) begin
            lane_sel  <= 1'b0;
            buf_valid <= 1'b0;
        end else if (out_ready) begin
            lane_sel <= ~lane_sel;
            if (lane_sel == 1'b0) begin
                lane0_buf <= lane0_out;
                lane1_buf <= lane1_out;
                lane2_buf <= lane2_out;
                lane3_buf <= lane3_out;
                buf_valid <= lane0_valid && lane1_valid && lane2_valid && lane3_valid;
            end
        end
    end

    assign lane0_block = (lane_sel == 1'b0) ? lane0_buf : lane2_buf;
    assign lane1_block = (lane_sel == 1'b0) ? lane1_buf : lane3_buf;
    assign out_valid   = buf_valid;
    assign rx_ready    = out_ready;

endmodule
```

## 5. 时序图

### 5.1 单 Lane 32:66 转换

```
clk_pma:      |  0  |  1  |  2  | ... | 32  | 33  | 34  | ... |
              |     |     |     |     |     |     |     |     |
in_data:      | W0  | W1  | W2  | ... | W32 | W33 | W34 | ... |
in_valid:     |  1  |  1  |  1  | ... |  1  |  1  |  1  | ... |
              |     |     |     |     |     |     |     |     |
shift_reg:    | W0  |W0W1 |W0W1W2|... |     |     |     |     |
bit_count:    | 32  | 64  | 96  | ... |     |     |     |     |
              |     |     |     |     |     |     |     |     |
out_block:    |  -  |  -  | B0  | ... | B15 |  -  | B16 | ... |
out_valid:    |  0  |  0  |  1  | ... |  1  |  0  |  1  | ... |

每 33 个输入周期产生 16 个 66-bit 块
```

### 5.2 Lane 聚合输出

```
clk_pma:      |  N  | N+1  | N+2  | N+3  | N+4  | N+5  |
              |     |      |      |      |      |      |
lane_sel:     |  0  |  1   |  0   |  1   |  0   |  1   |
              |     |      |      |      |      |      |
lane0_block:  | L0  | L2   | L0   | L2   | L0   | L2   |
lane1_block:  | L1  | L3   | L1   | L3   | L1   | L3   |
out_valid:    |  1  |  1   |  1   |  1   |  1   |  1   |
```

## 6. 与后续模块的关系

```
eth_pcs_gearbox_rx → eth_pcs_block_sync → eth_pcs_am_detect
                               │
                               ▼
                        确定 66-bit 块边界
                        恢复 sync header
```

**注意**: Gearbox 输出的 66-bit 块边界可能不正确，sync header 需要由 `eth_pcs_block_sync` 模块恢复。

## 7. 资源估算

| 资源 | 单 Lane | 4 Lane 总计 | 说明 |
|------|---------|-------------|------|
| FF | ~150 | ~600 | 移位寄存器 + 计数器 |
| LUT | ~100 | ~400 | 数据选择 + 控制逻辑 |
| BRAM | 0 | 0 | 无存储需求 |

## 8. 测试要点

| 测试项 | 说明 |
|--------|------|
| 数据完整性 | 验证 32-bit → 66-bit 转换后数据无丢失 |
| Lane 独立性 | 验证 4 个 lane 独立工作，互不干扰 |
| 反压处理 | 验证 out_ready=0 时数据不丢失 |
| 复位行为 | 验证复位后状态正确 |

## 9. 参考文献

- IEEE 802.3-2018 Clause 82.2.9 (Gearbox)
- IEEE 802.3-2018 Clause 84 (PMA)

## 10. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-10 | 初始版本 |
| 1.1 | 2026-04-10 | 修正架构：先 Gearbox 后 FIFO，解决速率不匹配问题 |
| 2.0 | 2026-04-13 | 移除 CDC，整个 PCS RX 处理链在 clk_pma_rx 域运行 |
