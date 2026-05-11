# eth_pcs_lane_deskew 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_lane_deskew

**功能**: 补偿 4 个 lane 之间的传输延迟差异 (skew)，使所有 lane 的数据对齐后输出，并删除对齐后的 AM

**位置**: rtl/pcs/eth_pcs_lane_deskew.sv

## 2. 接口定义

```systemverilog
module eth_pcs_lane_deskew (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [65:0]  lane0_block,
    input  wire [65:0]  lane1_block,
    input  wire         in_valid,
    output wire         in_ready,

    input  wire [1:0]   am_detected,
    input  wire         lane_map_valid,

    output wire [65:0]  out_lane0_block,
    output wire [65:0]  out_lane1_block,
    output wire         out_valid,
    input  wire         out_ready,

    output wire         deskew_done
);
```

### 2.1 信号说明

| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| lane0_block | input | 66 | 输入逻辑 Lane 0/2 的 66-bit 块 (交替，含 AM) |
| lane1_block | input | 66 | 输入逻辑 Lane 1/3 的 66-bit 块 (交替，含 AM) |
| in_valid | input | 1 | 输入有效 |
| in_ready | output | 1 | 接收就绪 |
| am_detected | input | 2 | AM 检测指示，bit 0 对应 lane0_block，bit 1 对应 lane1_block |
| lane_map_valid | input | 1 | Lane 映射建立完成 (来自 am_detect) |
| out_lane0_block | output | 66 | 输出逻辑 Lane 0/2 的 66-bit 块 (交替，不含 AM) |
| out_lane1_block | output | 66 | 输出逻辑 Lane 1/3 的 66-bit 块 (交替，不含 AM) |
| out_valid | output | 1 | 输出有效 (AM 时为 0) |
| out_ready | input | 1 | 下游就绪 |
| deskew_done | output | 1 | Lane 去偏斜完成 |

### 2.2 数据流约定

输入/输出数据交替传输 4 个逻辑 lane：
- 周期 N: lane0_block = 逻辑 Lane 0, lane1_block = 逻辑 Lane 1
- 周期 N+1: lane0_block = 逻辑 Lane 2, lane1_block = 逻辑 Lane 3

**输入**: 包含 AM 数据
**输出**: AM 已删除

## 3. 功能描述

### 3.1 Lane Skew 问题

由于 4 个物理 lane 的传输路径长度可能不同，导致数据到达时间存在差异：

```
时间轴:
  Lane 0: ────────AM────D0────D1────D2────...
  Lane 1: ──────AM────D0────D1────D2─────...  (快 1 个块)
  Lane 2: ────────────AM────D0────D1────D2────...  (慢 1 个块)
  Lane 3: ────────AM────D0────D1────D2─────...  (快 1 个块)

需要将所有 lane 对齐到最慢的 lane
```

### 3.2 去偏斜原理

**核心思路**: 各 lane 从自己的 AM 之后开始读取，由于 AM 标识了数据的起始位置，输出自然对齐。

```
1. 每个 lane 使用独立的 FIFO 缓冲数据
2. 当检测到 AM 时，记录该 lane 的 FIFO 写指针位置 (AM 所在位置)
3. 所有 lane 都检测到 AM 后，各 lane 从自己的 AM 之后的位置 (am_wr_ptr + 1) 开始读取
4. 读取时检测 AM 标志，AM 时不输出 (out_valid = 0)
```

### 3.3 AM 删除机制

**第一轮 AM**: 通过初始化读指针到 `am_wr_ptr + 1` 跳过。

**后续 AM**: 通过 `out_valid = 0` 不输出，读指针正常递增跳过。

```
假设 Lane 0 快 2 个块，Lane 2 最慢:

FIFO 内容 (AM 到达时):
  Lane 0: [D-2][D-1][AM][D0][D1][D2]...  ← AM 在位置 2
  Lane 1: [D-1][AM][D0][D1][D2]...       ← AM 在位置 1
  Lane 2: [AM][D0][D1][D2]...            ← AM 在位置 0 (最慢)
  Lane 3: [D-1][AM][D0][D1][D2]...       ← AM 在位置 1

第一轮 AM 删除:
  Lane 0: 从位置 3 开始读取 → 跳过位置 2 的 AM
  Lane 1: 从位置 2 开始读取 → 跳过位置 1 的 AM
  Lane 2: 从位置 1 开始读取 → 跳过位置 0 的 AM
  Lane 3: 从位置 2 开始读取 → 跳过位置 1 的 AM

后续 AM 删除:
  读取时检测 AM 标志，AM 时 out_valid = 0，读指针正常递增跳过
```

### 3.4 对齐输出

由于各 lane 的 AM 标识了数据的起始位置，从 AM 之后开始读取，输出自然对齐：

```
当所有 lane 的 AM 都到达时:
  Lane 0: 从位置 3 开始读取 → D0, D1, D2...
  Lane 1: 从位置 2 开始读取 → D0, D1, D2...
  Lane 2: 从位置 1 开始读取 → D0, D1, D2...
  Lane 3: 从位置 2 开始读取 → D0, D1, D2...

所有 lane 同时输出各自的 D0，数据自然对齐
```

### 3.5 最大可补偿 Skew

- FIFO 深度: 64 entries (每个 lane)
- 最大可补偿 skew: ±32 块 (相对于平均)

### 3.6 去偏斜流程

```
状态机:
  IDLE: 等待 lane_map_valid
  WAIT_AM: 等待所有 lane 检测到 AM
  CALCULATE: 设置各 lane 的读取起始位置
  NORMAL: 正常工作，所有 lane 同步输出
```

## 4. 详细设计

### 4.1 整体架构

```
                    lane0_block[65:0] ──────┐
                    lane1_block[65:0] ──────┤
                    am_detected[1:0] ───────┤
                                            │
                                            ▼
                    ┌────────────────────────────────────┐
                    │          Lane 解复用器              │
                    └────────────────────────────────────┘
                              │
          ┌───────────┬───────┼───────┬───────────┐
          │           │       │       │           │
          ▼           ▼       ▼       ▼           │
     ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
     │ Lane 0  │ │ Lane 1  │ │ Lane 2  │ │ Lane 3  │
     │  FIFO   │ │  FIFO   │ │  FIFO   │ │  FIFO   │
     │(数据+AM │ │(数据+AM │ │(数据+AM │ │(数据+AM │
     │ 标志)   │ │ 标志)   │ │ 标志)   │ │ 标志)   │
     └─────────┘ └─────────┘ └─────────┘ └─────────┘
          │           │       │       │           │
          ▼           ▼       ▼       ▼           │
     ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
     │ Lane 0  │ │ Lane 1  │ │ Lane 2  │ │ Lane 3  │
     │ Read    │ │ Read    │ │ Read    │ │ Read    │
     │ Ctrl    │ │ Ctrl    │ │ Ctrl    │ │ Ctrl    │
     └─────────┘ └─────────┘ └─────────┘ └─────────┘
          │           │       │       │           │
          └───────────┴───────┼───────┴───────────┘
                                │
                                ▼
                    ┌────────────────────────────────────┐
                    │          Lane 复用器                │
                    └────────────────────────────────────┘
                                │
                                ▼
                    out_lane0_block, out_lane1_block
                    out_valid, deskew_done
```

### 4.2 状态机定义

```systemverilog
typedef enum logic [1:0] {
    STATE_IDLE      = 2'b00,
    STATE_WAIT_AM   = 2'b01,
    STATE_CALCULATE = 2'b10,
    STATE_NORMAL    = 2'b11
} state_t;

reg [1:0] state;
```

### 4.3 内部 Lane 选择状态

```systemverilog
reg lane_sel;

always @(posedge clk) begin
    if (!rst_n) begin
        lane_sel <= 1'b0;
    end else if (in_valid && in_ready) begin
        lane_sel <= ~lane_sel;
    end
end
```

### 4.4 Lane FIFO 设计

每个 lane 使用独立的 FIFO，存储数据 + AM 标志：

```systemverilog
reg [65:0] lane_fifo [0:3][0:63];
reg        lane_am_flag [0:3][0:63];
reg [5:0]  wr_ptr [0:3];
reg [5:0]  rd_ptr [0:3];
reg [5:0]  am_wr_ptr [0:3];
reg [3:0]  am_detected_flag;

always @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 4; i++) begin
            wr_ptr[i] <= 6'd0;
        end
    end else if (in_valid && in_ready) begin
        if (lane_sel == 1'b0) begin
            lane_fifo[0][wr_ptr[0]] <= lane0_block;
            lane_fifo[1][wr_ptr[1]] <= lane1_block;
            lane_am_flag[0][wr_ptr[0]] <= am_detected[0];
            lane_am_flag[1][wr_ptr[1]] <= am_detected[1];
            wr_ptr[0] <= wr_ptr[0] + 6'd1;
            wr_ptr[1] <= wr_ptr[1] + 6'd1;
        end else begin
            lane_fifo[2][wr_ptr[2]] <= lane0_block;
            lane_fifo[3][wr_ptr[3]] <= lane1_block;
            lane_am_flag[2][wr_ptr[2]] <= am_detected[0];
            lane_am_flag[3][wr_ptr[3]] <= am_detected[1];
            wr_ptr[2] <= wr_ptr[2] + 6'd1;
            wr_ptr[3] <= wr_ptr[3] + 6'd1;
        end
    end
end
```

**注意**: `am_detected[0]` 对应当前输入的 `lane0_block`，`am_detected[1]` 对应当前输入的 `lane1_block`。

### 4.5 AM 检测与指针记录

当检测到 AM 时，记录该 lane 的写指针位置（AM 所在位置）：

```systemverilog
reg [5:0]  am_wr_ptr [0:3];
reg [3:0]  am_detected_flag;

always @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 4; i++) begin
            am_wr_ptr[i] <= 6'd0;
            am_detected_flag[i] <= 1'b0;
        end
    end else if (state == STATE_WAIT_AM && in_valid && in_ready) begin
        if (lane_sel == 1'b0) begin
            if (am_detected[0] && !am_detected_flag[0]) begin
                am_wr_ptr[0] <= wr_ptr[0] - 6'd1;
                am_detected_flag[0] <= 1'b1;
            end
            if (am_detected[1] && !am_detected_flag[1]) begin
                am_wr_ptr[1] <= wr_ptr[1] - 6'd1;
                am_detected_flag[1] <= 1'b1;
            end
        end else begin
            if (am_detected[0] && !am_detected_flag[2]) begin
                am_wr_ptr[2] <= wr_ptr[2] - 6'd1;
                am_detected_flag[2] <= 1'b1;
            end
            if (am_detected[1] && !am_detected_flag[3]) begin
                am_wr_ptr[3] <= wr_ptr[3] - 6'd1;
                am_detected_flag[3] <= 1'b1;
            end
        end
    end
end
```

**注意**: 
- `am_detected[0]` 在 `lane_sel=0` 时对应 Lane 0，在 `lane_sel=1` 时对应 Lane 2
- `am_detected[1]` 在 `lane_sel=0` 时对应 Lane 1，在 `lane_sel=1` 时对应 Lane 3
- `wr_ptr - 1` 是因为 `am_detected` 与数据同步，此时数据已写入，`wr_ptr` 已增加，AM 的实际位置是 `wr_ptr - 1`

### 4.6 读指针管理

各 lane 从自己的 AM 之后开始读取。读指针始终 +1，AM 时通过 `out_valid = 0` 不输出：

```systemverilog
reg [5:0] rd_ptr [0:3];

wire is_am_lane0 = lane_am_flag[0][rd_ptr[0]];
wire is_am_lane1 = lane_am_flag[1][rd_ptr[1]];
wire is_am_lane2 = lane_am_flag[2][rd_ptr[2]];
wire is_am_lane3 = lane_am_flag[3][rd_ptr[3]];

wire fifo_not_empty = (rd_ptr[0] != wr_ptr[0]) && 
                      (rd_ptr[1] != wr_ptr[1]) &&
                      (rd_ptr[2] != wr_ptr[2]) && 
                      (rd_ptr[3] != wr_ptr[3]);

always @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 4; i++) begin
            rd_ptr[i] <= 6'd0;
        end
    end else if (state == STATE_CALCULATE) begin
        for (int i = 0; i < 4; i++) begin
            rd_ptr[i] <= am_wr_ptr[i] + 6'd1;
        end
    end else if (state == STATE_NORMAL && fifo_not_empty && out_ready) begin
        // 读指针始终 +1
        if (out_lane_sel == 1'b0) begin
            rd_ptr[0] <= rd_ptr[0] + 6'd1;
            rd_ptr[1] <= rd_ptr[1] + 6'd1;
        end else begin
            rd_ptr[2] <= rd_ptr[2] + 6'd1;
            rd_ptr[3] <= rd_ptr[3] + 6'd1;
        end
    end
end
```

**说明**: 
- 在 CALCULATE 状态，直接用 `am_wr_ptr + 1` 初始化读指针
- 在 NORMAL 状态，当 FIFO 非空且下游就绪时，读指针 +1
- AM 时 `out_valid = 0`，AM 不输出，但读指针正常递增跳过 AM

### 4.7 状态机转换

```systemverilog
always @(posedge clk) begin
    if (!rst_n) begin
        state <= STATE_IDLE;
    end else begin
        case (state)
            STATE_IDLE: begin
                if (lane_map_valid) begin
                    state <= STATE_WAIT_AM;
                end
            end
            STATE_WAIT_AM: begin
                if (am_detected_flag == 4'b1111) begin
                    state <= STATE_CALCULATE;
                end
            end
            STATE_CALCULATE: begin
                state <= STATE_NORMAL;
            end
            STATE_NORMAL: begin
                // 正常工作，持续监控
            end
        endcase
    end
end

assign deskew_done = (state == STATE_NORMAL);
```

### 4.8 输出逻辑

检测到 AM 时 `out_valid = 0`，AM 不输出：

```systemverilog
reg out_lane_sel;

always @(posedge clk) begin
    if (!rst_n) begin
        out_lane_sel <= 1'b0;
    end else if (out_valid && out_ready) begin
        out_lane_sel <= ~out_lane_sel;
    end
end

wire [65:0] fifo_out_lane0 = (out_lane_sel == 1'b0) ? 
                              lane_fifo[0][rd_ptr[0]] : lane_fifo[2][rd_ptr[2]];
wire [65:0] fifo_out_lane1 = (out_lane_sel == 1'b0) ? 
                              lane_fifo[1][rd_ptr[1]] : lane_fifo[3][rd_ptr[3]];

wire is_am_current = (out_lane_sel == 1'b0) ? 
                     (is_am_lane0 || is_am_lane1) : 
                     (is_am_lane2 || is_am_lane3);

assign out_lane0_block = fifo_out_lane0;
assign out_lane1_block = fifo_out_lane1;
assign out_valid = (state == STATE_NORMAL) && fifo_not_empty && !is_am_current;
assign in_ready = (state != STATE_NORMAL) || out_ready;
```

**说明**: 
- `fifo_not_empty` 在 4.6 节定义
- `is_am_current` 检测当前输出的 lane 是否包含 AM
- 如果是 AM，`out_valid = 0`，AM 不输出
- 读指针始终 +1，AM 被跳过但不影响后续数据

## 5. 时序图

### 5.1 去偏斜过程

```
clk:             |  0  |  1  |  2  |  3  |  4  |  5  |  6  |  7  |  8  |
                 |     |     |     |     |     |     |     |     |     |
 state:          |IDLE |WAIT |WAIT |WAIT |CALC |NORM |NORM |NORM |NORM |
                 |     |     |     |     |     |     |     |     |     |
 lane_map_valid: |  0  |  1  |  1  |  1  |  1  |  1  |  1  |  1  |  1  |
                 |     |     |     |     |     |     |     |     |     |
 am_detected_flg:|0000 |0001 |0011 |1111 |1111 |1111 |1111 |1111 |1111 |
                 |     |     |     |     |     |     |     |     |     |
 deskew_done:    |  0  |  0  |  0  |  0  |  0  |  1  |  1  |  1  |  1  |
                 |     |     |     |     |     |     |     |     |     |
 out_valid:      |  0  |  0  |  0  |  0  |  0  |  1  |  1  |  1  |  1  |
```

### 5.2 Lane 对齐示例

假设 Lane 0 快 2 个块，Lane 1 快 1 个块，Lane 2 最慢，Lane 3 快 1 个块：

```
AM 到达时的写指针 (AM 位置):
  Lane 0: am_wr_ptr = 2 (AM 在 FIFO 位置 2)
  Lane 1: am_wr_ptr = 1 (AM 在 FIFO 位置 1)
  Lane 2: am_wr_ptr = 0 (AM 在 FIFO 位置 0, 最慢)
  Lane 3: am_wr_ptr = 1 (AM 在 FIFO 位置 1)

读取起始位置:
  Lane 0: rd_start = 2 + 1 = 3
  Lane 1: rd_start = 1 + 1 = 2
  Lane 2: rd_start = 0 + 1 = 1
  Lane 3: rd_start = 1 + 1 = 2

所有 lane 从各自的 rd_start 开始读取，输出自然对齐
```

### 5.3 数据流示例

```
FIFO 内容 (Lane 0, 快 2 个块):
  位置 0: D-2
  位置 1: D-1
  位置 2: AM
  位置 3: D0  ← 从这里开始读取
  位置 4: D1
  ...

FIFO 内容 (Lane 2, 最慢):
  位置 0: AM
  位置 1: D0  ← 从这里开始读取
  位置 2: D1
  ...

输出:
  所有 lane 同时输出各自的 D0，数据对齐
```

## 6. 参数配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| FIFO_DEPTH | 64 | 每个 lane 的 FIFO 深度 |
| MAX_SKEW | 32 | 最大可补偿 skew (块数) |

## 7. 与其他模块的关系

```
eth_pcs_am_detect → eth_pcs_lane_deskew → eth_pcs_descrambler
         │                   │
         │                   ▼
         │            补偿 lane skew
         │            对齐 4 个 lane 的数据
         │            删除对齐后的 AM
         │            deskew_done 指示
         │
         └── am_detected, lane_map_valid
```

## 8. 资源估算

| 资源 | 估算值 | 说明 |
|------|--------|------|
| FF | ~450 | 4 个 FIFO 指针 + 状态机 + AM 标志 |
| BRAM | 4 | 4 个 64x66 FIFO (或使用分布式 RAM) |
| LUT | ~250 | 控制逻辑 + 地址计算 + AM 删除 |

## 9. 测试要点

| 测试项 | 说明 |
|--------|------|
| 无 skew | 验证各 lane 无延迟差时正确对齐 |
| 有 skew | 验证各 lane 有延迟差时正确对齐 |
| 最大 skew | 验证最大可补偿 skew 边界 |
| 超出范围 | 验证 skew 超出 FIFO 深度时的处理 |
| AM 删除 | 验证对齐后 AM 正确删除，out_valid=0 |
| 数据完整性 | 验证去偏斜后数据无丢失、无重复 |
| 反压处理 | 验证 out_ready=0 时数据不丢失 |
| 复位行为 | 验证复位后状态正确 |

## 10. 参考文献

- IEEE 802.3-2018 Clause 82.2.8 (Alignment Marker Detection)
- IEEE 802.3-2018 Clause 82.2.9 (Lane Deskew)

## 11. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-10 | 初始版本 |
| 2.0 | 2026-04-10 | 添加 AM 删除功能，对齐后统一删除 AM |
| 3.0 | 2026-04-13 | **重大修正**: (1) AM 删除改为跳过读取方式；(2) 所有 lane 从相同位置 (max_am_ptr+1) 开始读取；(3) 移除 ALIGN 状态；(4) 修正 am_wr_ptr 记录逻辑 (wr_ptr-1) |
| 3.1 | 2026-04-13 | 适配 am_detect 模块的 am_detected 改为 2-bit 输出 |
| 4.0 | 2026-04-13 | **重大修正**: (1) 各 lane 从自己的 AM 之后开始读取；(2) 添加 ALIGN 状态，延迟快 lane 输出；(3) 添加 lane_delay 和 lane_out_en 控制 |
| 5.0 | 2026-04-13 | **简化设计**: (1) 移除 ALIGN 状态，各 lane 从自己的 AM 之后开始读取即可自然对齐；(2) 移除 lane_delay 和 lane_out_en；(3) 状态机简化为 4 状态 |
| 5.1 | 2026-04-13 | 修正时序问题：直接用 am_wr_ptr+1 初始化 rd_ptr，移除 rd_start 中间变量 |
| 5.2 | 2026-04-13 | **修正 AM 删除逻辑**: (1) 读取时检测 AM 标志；(2) AM 时读指针 +2 跳过；(3) out_valid 在 AM 时为 0 |
| 5.3 | 2026-04-13 | **修正读指针逻辑**: 读指针始终 +1，AM 时 out_valid=0 不输出，避免跳过正常数据 |
| 5.4 | 2026-04-13 | **修正读指针条件**: 读指针递增条件改为 fifo_not_empty && out_ready，避免 FIFO 为空时读指针越界；更新 3.3 节 AM 删除机制描述 |
