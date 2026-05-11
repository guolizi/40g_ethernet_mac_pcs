# eth_pcs_gearbox_tx 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_gearbox_tx

**功能**: TX 方向 Gearbox，将 4 个 lane 的 66-bit 块流转换为 32-bit 输出，实现跨时钟域传输

**位置**: rtl/pcs/eth_pcs_gearbox_tx.sv

## 2. 接口定义

```systemverilog
module eth_pcs_gearbox_tx (
    input  wire         clk_core,
    input  wire         rst_n_core,

    input  wire [65:0]  lane0_block,
    input  wire [65:0]  lane1_block,
    input  wire         lane_valid,
    output wire         lane_ready,

    input  wire         clk_pma,
    input  wire         rst_n_pma,

    output wire [31:0]  lane0_tx_data,
    output wire [31:0]  lane1_tx_data,
    output wire [31:0]  lane2_tx_data,
    output wire [31:0]  lane3_tx_data,
    output wire         tx_valid,
    input  wire         tx_ready
);
```

### 2.1 信号说明

**clk_core 域 (输入侧)**:
- `lane0_block[65:0]`: Lane 0/2 的 66-bit 块 (根据 lane_sel)
- `lane1_block[65:0]`: Lane 1/3 的 66-bit 块 (根据 lane_sel)
- `lane_valid`: 块有效
- `lane_ready`: 上游就绪

**clk_pma 域 (输出侧)**:
- `lane0_tx_data[31:0]`: Lane 0 的 32-bit 输出
- `lane1_tx_data[31:0]`: Lane 1 的 32-bit 输出
- `lane2_tx_data[31:0]`: Lane 2 的 32-bit 输出
- `lane3_tx_data[31:0]`: Lane 3 的 32-bit 输出
- `tx_valid`: 数据有效
- `tx_ready`: 下游就绪

### 2.2 时钟频率

| 时钟 | 频率 | 说明 |
|------|------|------|
| clk_core | 312.5 MHz | MAC/PCS 核心时钟 |
| clk_pma | 322.266 MHz | PMA 接口时钟 |

## 3. 功能描述

### 3.1 数据流

```
来自 eth_pcs_lane_dist:
  - 周期 N:   lane0_block = Lane 0, lane1_block = Lane 1
  - 周期 N+1: lane0_block = Lane 2, lane1_block = Lane 3
  - 周期 N+2: lane0_block = Lane 0, lane1_block = Lane 1
  ...

每个 lane 每 2 个 clk_core 周期获得 1 个 66-bit 块
```

### 3.2 位宽转换

每个 lane 独立进行 66-bit → 32-bit 转换：

```
输入: 66-bit 块 @ 每 2 个 clk_core 周期
输出: 32-bit 数据 @ clk_pma

速率计算:
- 输入速率: 66 / 2 × 312.5M = 10.3125 Gbps (每个 lane)
- 输出速率: 32 × 322.266M = 10.3125 Gbps ✓
```

### 3.3 转换比例

```
66-bit → 32-bit 转换:
- 每 16 个 66-bit 块 = 1056 bits
- 每 33 个 32-bit 数据 = 1056 bits ✓

即: 每 16 个 66-bit 块 → 33 个 32-bit 输出
```

## 4. 详细设计

### 4.1 整体架构

```
                    clk_core 域
                         │
    lane0_block[65:0] ───┼───┐
    lane1_block[65:0] ───┼───┤
                         │   │
                         ▼   ▼
                  ┌──────────────────┐
                  │  Lane 分发逻辑    │
                  │  (根据 lane_sel) │
                  └──────────────────┘
                         │
         ┌───────┬───────┼───────┬───────┐
         │       │       │       │       │
         ▼       ▼       ▼       ▼       │
    ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
    │ Lane 0 │ │ Lane 1 │ │ Lane 2 │ │ Lane 3 │
    │Gearbox │ │Gearbox │ │Gearbox │ │Gearbox │
    └────────┘ └────────┘ └────────┘ └────────┘
         │       │       │       │       │
         ▼       ▼       ▼       ▼       │
    lane0_tx  lane1_tx lane2_tx lane3_tx │
    [31:0]    [31:0]   [31:0]   [31:0]   │
                                        clk_pma 域
```

### 4.2 单 Lane Gearbox 设计

每个 lane 的 Gearbox 实现 66-bit → 32-bit 转换：

```systemverilog
module eth_pcs_gearbox_tx_lane (
    input  wire         clk_core,
    input  wire         rst_n_core,

    input  wire [65:0]  in_block,
    input  wire         in_valid,
    output wire         in_ready,

    input  wire         clk_pma,
    input  wire         rst_n_pma,

    output wire [31:0]  out_data,
    output wire         out_valid,
    input  wire         out_ready
);
```

### 4.3 66:32 转换原理

```
66-bit 块: [sync[1:0], payload[63:0]]

转换为 32-bit 数据流:
  Word 0: payload[31:0]
  Word 1: payload[63:32]
  Word 2: {sync[1:0], payload[31:2]} (来自下一个块)
  Word 3: payload[63:32]
  ...

每 16 个 66-bit 块产生 33 个 32-bit 输出
```

### 4.4 单 Lane Gearbox 实现

```systemverilog
module eth_pcs_gearbox_tx_lane (
    input  wire         clk_core,
    input  wire         rst_n_core,

    input  wire [65:0]  in_block,
    input  wire         in_valid,
    output wire         in_ready,

    input  wire         clk_pma,
    input  wire         rst_n_pma,

    output wire [31:0]  out_data,
    output wire         out_valid,
    input  wire         out_ready
);

    // CDC FIFO: 存储 66-bit 块
    wire [65:0]  fifo_dout;
    wire         fifo_full;
    wire         fifo_empty;
    wire         fifo_rd_en;

    async_fifo #(
        .DATA_WIDTH(66),
        .DEPTH(64)
    ) u_cdc_fifo (
        .wr_clk   (clk_core),
        .wr_rst_n (rst_n_core),
        .wr_en    (in_valid && !fifo_full),
        .wr_data  (in_block),
        .full     (fifo_full),
        
        .rd_clk   (clk_pma),
        .rd_rst_n (rst_n_pma),
        .rd_en    (fifo_rd_en),
        .rd_data  (fifo_dout),
        .empty    (fifo_empty)
    );

    assign in_ready = !fifo_full;

    // clk_pma 域: 66-bit → 32-bit 转换
    reg [97:0]  shift_reg;    // 存储当前块 + 部分下一块
    reg [5:0]   shift_cnt;    // 0-32
    reg         shift_valid;
    reg         need_data;

    // 状态定义
    localparam [1:0]
        STATE_IDLE   = 2'b00,
        STATE_READ   = 2'b01,
        STATE_SHIFT  = 2'b10;

    reg [1:0] state;

    always @(posedge clk_pma) begin
        if (!rst_n_pma) begin
            state       <= STATE_IDLE;
            shift_reg   <= 98'h0;
            shift_cnt   <= 6'h0;
            shift_valid <= 1'b0;
            need_data   <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    shift_valid <= 1'b0;
                    if (!fifo_empty) begin
                        state     <= STATE_READ;
                        need_data <= 1'b1;
                    end
                end

                STATE_READ: begin
                    if (!fifo_empty) begin
                        if (need_data) begin
                            // 读入新的 66-bit 块
                            shift_reg <= {fifo_dout, shift_reg[31:0]};
                            need_data <= 1'b0;
                            state     <= STATE_SHIFT;
                            shift_cnt <= 6'h0;
                        end
                    end
                end

                STATE_SHIFT: begin
                    if (out_ready) begin
                        // 输出 32-bit
                        shift_valid <= 1'b1;
                        shift_reg   <= {32'h0, shift_reg[97:32]};
                        shift_cnt   <= shift_cnt + 6'h1;

                        // 检查是否需要新的数据
                        if (shift_cnt == 6'd1 || shift_cnt == 6'd17) begin
                            // 需要读入新的 66-bit 块
                            need_data <= 1'b1;
                            state     <= STATE_READ;
                        end else if (shift_cnt == 6'd32) begin
                            // 完成一个周期 (16 块 → 33 输出)
                            state     <= STATE_IDLE;
                        end
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

    assign fifo_rd_en = (state == STATE_READ) && !fifo_empty && need_data;
    assign out_data   = shift_reg[31:0];
    assign out_valid  = shift_valid;

endmodule
```

### 4.5 简化实现

为便于理解和验证，提供简化版本：

```systemverilog
module eth_pcs_gearbox_tx_lane (
    input  wire         clk_core,
    input  wire         rst_n_core,

    input  wire [65:0]  in_block,
    input  wire         in_valid,
    output wire         in_ready,

    input  wire         clk_pma,
    input  wire         rst_n_pma,

    output wire [31:0]  out_data,
    output wire         out_valid,
    input  wire         out_ready
);

    // CDC FIFO
    wire [65:0]  fifo_dout;
    wire         fifo_full;
    wire         fifo_empty;

    async_fifo #(
        .DATA_WIDTH(66),
        .DEPTH(64)
    ) u_cdc_fifo (
        .wr_clk   (clk_core),
        .wr_rst_n (rst_n_core),
        .wr_en    (in_valid && !fifo_full),
        .wr_data  (in_block),
        .full     (fifo_full),
        
        .rd_clk   (clk_pma),
        .rd_rst_n (rst_n_pma),
        .rd_en    (!fifo_empty && out_ready),
        .rd_data  (fifo_dout),
        .empty    (fifo_empty)
    );

    assign in_ready = !fifo_full;

    // 简化: 每 2 个 66-bit 块 → 4 个 32-bit 输出 (近似)
    // 实际需要完整的 16:33 转换逻辑
    
    reg [65:0] block_buf;
    reg [1:0]  out_phase;
    reg        buf_valid;

    always @(posedge clk_pma) begin
        if (!rst_n_pma) begin
            block_buf <= 66'h0;
            out_phase <= 2'h0;
            buf_valid <= 1'b0;
        end else if (!fifo_empty && out_ready) begin
            if (out_phase == 2'h0) begin
                block_buf <= fifo_dout;
                out_phase <= 2'h1;
                buf_valid <= 1'b1;
            end else if (out_phase == 2'h1) begin
                out_phase <= 2'h2;
            end else begin
                out_phase <= 2'h0;
                buf_valid <= 1'b0;
            end
        end
    end

    assign out_data = (out_phase == 2'h1) ? block_buf[31:0] : 
                      (out_phase == 2'h2) ? block_buf[63:32] : 32'h0;
    assign out_valid = buf_valid && (out_phase != 2'h0);

endmodule
```

## 5. 顶层模块实现

```systemverilog
module eth_pcs_gearbox_tx (
    input  wire         clk_core,
    input  wire         rst_n_core,

    input  wire [65:0]  lane0_block,
    input  wire [65:0]  lane1_block,
    input  wire         lane_valid,
    output wire         lane_ready,

    input  wire         clk_pma,
    input  wire         rst_n_pma,

    output wire [31:0]  lane0_tx_data,
    output wire [31:0]  lane1_tx_data,
    output wire [31:0]  lane2_tx_data,
    output wire [31:0]  lane3_tx_data,
    output wire         tx_valid,
    input  wire         tx_ready
);

    // Lane 分发: 每 2 个周期接收 4 个 lane 的数据
    reg         lane_sel;  // 0: Lane 0/1, 1: Lane 2/3
    reg [65:0]  lane0_buf, lane1_buf, lane2_buf, lane3_buf;
    reg [1:0]   buf_valid;

    always @(posedge clk_core) begin
        if (!rst_n_core) begin
            lane_sel  <= 1'b0;
            buf_valid <= 2'h0;
        end else if (lane_valid && lane_ready) begin
            if (lane_sel == 1'b0) begin
                lane0_buf <= lane0_block;
                lane1_buf <= lane1_block;
                lane_sel  <= 1'b1;
                buf_valid <= 2'h1;
            end else begin
                lane2_buf <= lane0_block;
                lane3_buf <= lane1_block;
                lane_sel  <= 1'b0;
                buf_valid <= 2'h3;
            end
        end
    end

    // 4 个独立的 Lane Gearbox
    wire [31:0] lane0_out, lane1_out, lane2_out, lane3_out;
    wire        lane0_valid, lane1_valid, lane2_valid, lane3_valid;
    wire        lane0_ready, lane1_ready, lane2_ready, lane3_ready;

    eth_pcs_gearbox_tx_lane u_lane0 (
        .clk_core   (clk_core),
        .rst_n_core (rst_n_core),
        .in_block   (lane0_buf),
        .in_valid   (buf_valid[0]),
        .in_ready   (lane0_ready),
        .clk_pma    (clk_pma),
        .rst_n_pma  (rst_n_pma),
        .out_data   (lane0_out),
        .out_valid  (lane0_valid),
        .out_ready  (tx_ready)
    );

    eth_pcs_gearbox_tx_lane u_lane1 (
        .clk_core   (clk_core),
        .rst_n_core (rst_n_core),
        .in_block   (lane1_buf),
        .in_valid   (buf_valid[0]),
        .in_ready   (lane1_ready),
        .clk_pma    (clk_pma),
        .rst_n_pma  (rst_n_pma),
        .out_data   (lane1_out),
        .out_valid  (lane1_valid),
        .out_ready  (tx_ready)
    );

    eth_pcs_gearbox_tx_lane u_lane2 (
        .clk_core   (clk_core),
        .rst_n_core (rst_n_core),
        .in_block   (lane2_buf),
        .in_valid   (buf_valid[1]),
        .in_ready   (lane2_ready),
        .clk_pma    (clk_pma),
        .rst_n_pma  (rst_n_pma),
        .out_data   (lane2_out),
        .out_valid  (lane2_valid),
        .out_ready  (tx_ready)
    );

    eth_pcs_gearbox_tx_lane u_lane3 (
        .clk_core   (clk_core),
        .rst_n_core (rst_n_core),
        .in_block   (lane3_buf),
        .in_valid   (buf_valid[1]),
        .in_ready   (lane3_ready),
        .clk_pma    (clk_pma),
        .rst_n_pma  (rst_n_pma),
        .out_data   (lane3_out),
        .out_valid  (lane3_valid),
        .out_ready  (tx_ready)
    );

    // 输出
    assign lane0_tx_data = lane0_out;
    assign lane1_tx_data = lane1_out;
    assign lane2_tx_data = lane2_out;
    assign lane3_tx_data = lane3_out;
    assign tx_valid      = lane0_valid && lane1_valid && lane2_valid && lane3_valid;
    assign lane_ready    = lane0_ready && lane1_ready && lane2_ready && lane3_ready;

endmodule
```

## 6. 时序图

### 6.1 Lane 分发 (clk_core 域)

```
clk_core:     |  N  | N+1  | N+2  | N+3  |
              |     |      |      |      |
lane_sel:     |  0  |  1   |  0   |  1   |
              |     |      |      |      |
lane0_block:  | L0  | L2   | L0   | L2   |
lane1_block:  | L1  | L3   | L1   | L3   |
              |     |      |      |      |
lane0_buf:    |     | L0   | L0   | L0   |
lane1_buf:    |     | L1   | L1   | L1   |
lane2_buf:    |     |      | L2   | L2   |
lane3_buf:    |     |      | L3   | L3   |
buf_valid:    |  0  |  1   |  3   |  1   |
```

### 6.2 单 Lane 66:32 转换 (clk_pma 域)

```
clk_pma:      |  0  |  1  |  2  |  3  |  4  |  5  | ... | 32  | 33  |
              |     |     |     |     |     |     |     |     |     |
FIFO 读取:    | RD  |     |     | RD  |     |     | ... |     | RD  |
              |     |     |     |     |     |     |     |     |     |
shift_reg:    | B0  | B0' | B0" | B1  | B1' | B1" | ... | B15 | B0  |
              |     |     |     |     |     |     |     |     |     |
out_data:     |     | W0  | W1  | W2  | W3  | W4  | ... | W32 | W0  |
out_valid:    |  0  |  1  |  1  |  1  |  1  |  1  | ... |  1  |  1  |

每 16 个 66-bit 块 → 33 个 32-bit 输出
```

## 7. 资源估算

| 资源 | 单 Lane | 4 Lane 总计 | 说明 |
|------|---------|-------------|------|
| FF | ~200 | ~800 | 移位寄存器 + 状态机 |
| LUT | ~150 | ~600 | 数据选择 + 控制逻辑 |
| BRAM | 0 | 0 | 使用分布式 RAM 实现 FIFO |

## 8. 测试要点

| 测试项 | 说明 |
|--------|------|
| 数据完整性 | 验证 66-bit → 32-bit 转换后数据无丢失 |
| 跨时钟域 | 验证 clk_core → clk_pma 数据正确传输 |
| Lane 独立性 | 验证 4 个 lane 独立工作，互不干扰 |
| 反压处理 | 验证 tx_ready=0 时数据不丢失 |
| 复位行为 | 验证复位后状态正确 |

## 9. 参考文献

- IEEE 802.3-2018 Clause 82.2.9 (Gearbox)
- IEEE 802.3-2018 Clause 84 (PMA)

## 10. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-10 | 初始版本 |
| 1.1 | 2026-04-10 | 修正输出为 32-bit @ 322.266 MHz；添加 4 lane 独立 Gearbox |
