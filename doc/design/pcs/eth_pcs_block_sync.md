# eth_pcs_block_sync 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_block_sync

**功能**: 在 RX 数据流中检测并锁定 4 个 lane 的 66-bit 块边界，输出对齐的 66-bit 块

**位置**: rtl/pcs/eth_pcs_block_sync.sv

## 2. 接口定义

```systemverilog
module eth_pcs_block_sync (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [65:0]  lane0_block,
    input  wire [65:0]  lane1_block,
    input  wire         in_valid,
    output wire         in_ready,

    output wire [65:0]  out_lane0_block,
    output wire [65:0]  out_lane1_block,
    output wire         out_valid,
    input  wire         out_ready,

    output wire [3:0]   block_lock
);
```

### 2.1 信号说明

| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| lane0_block | input | 66 | 输入 Lane 0/2 的 66-bit 块 (交替) |
| lane1_block | input | 66 | 输入 Lane 1/3 的 66-bit 块 (交替) |
| in_valid | input | 1 | 输入有效 |
| in_ready | output | 1 | 接收就绪 |
| out_lane0_block | output | 66 | 输出 Lane 0/2 的 66-bit 块 (交替) |
| out_lane1_block | output | 66 | 输出 Lane 1/3 的 66-bit 块 (交替) |
| out_valid | output | 1 | 输出有效 |
| out_ready | input | 1 | 下游就绪 |
| block_lock | output | 4 | 4 个 lane 的块锁定状态 |

### 2.2 数据流约定

输入数据交替传输 4 个 lane：
- 周期 N: lane0_block = Lane 0, lane1_block = Lane 1
- 周期 N+1: lane0_block = Lane 2, lane1_block = Lane 3

模块内部维护 lane_sel 状态，每收到一个有效数据翻转一次。输出保持相同的交替方式。

## 3. 功能描述

### 3.1 Sync Header 定义

根据 IEEE 802.3-2018 Clause 82.2.3.3:

```
66-bit 块:
┌────────┬────────────────────────────────────────┐
│ Sync   │ Payload (64-bit)                       │
│ [1:0]  │ [65:2]                                 │
├────────┼────────────────────────────────────────┤
│ 2'b01  │ 数据块 (8 字节数据)                     │
│ 2'b10  │ 控制块 (Type + 56-bit)                  │
└────────┴────────────────────────────────────────┘

Sync Header 位于 Bit 1:0 (LSB first)
```

### 3.2 块同步原理

每个 lane 独立进行块同步：

```
检测方法:
1. 检查每个 66-bit 块的 bit[1:0] 是否为有效 sync header (01 或 10)
2. 统计连续正确的 sync header 次数
3. 当连续 N 次正确时，锁定该 lane
4. 锁定后统计连续错误次数，超过阈值则失锁
```

### 3.3 状态机 (每个 lane 独立)

```
        ┌──────────────────────┐
        │                      │
        ▼                      │
    ┌───────┐              ┌───────┐
    │ UNLOCK│──────────────►│ LOCK  │
    └───────┘              └───────┘
        │                      │
        │    连续错误超过阈值    │
        └──────────────────────┘
```

## 4. 详细设计

### 4.1 整体架构

```
                    lane0_block[65:0] ──────┐
                    lane1_block[65:0] ──────┤
                                            │
                                            ▼
                    ┌────────────────────────────────────┐
                    │          Lane 解复用器              │
                    │  根据内部 lane_sel 分发到对应 buffer │
                    └────────────────────────────────────┘
                              │
          ┌───────────┬───────┼───────┬───────────┐
          │           │       │       │           │
          ▼           ▼       ▼       ▼           │
     ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
     │ Lane 0  │ │ Lane 1  │ │ Lane 2  │ │ Lane 3  │
     │ Block   │ │ Block   │ │ Block   │ │ Block   │
     │ Sync    │ │ Sync    │ │ Sync    │ │ Sync    │
     │ FSM     │ │ FSM     │ │ FSM     │ │ FSM     │
     └─────────┘ └─────────┘ └─────────┘ └─────────┘
          │           │       │       │           │
          ▼           ▼       ▼       ▼           │
     ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
     │ Lane 0  │ │ Lane 1  │ │ Lane 2  │ │ Lane 3  │
     │ Output  │ │ Output  │ │ Output  │ │ Output  │
     │ Buffer  │ │ Buffer  │ │ Buffer  │ │ Buffer  │
     └─────────┘ └─────────┘ └─────────┘ └─────────┘
          │           │       │       │           │
          └───────────┴───────┼───────┴───────────┘
                                │
                                ▼
                    ┌────────────────────────────────────┐
                    │          Lane 复用器                │
                    │  根据 lane_sel 选择输出             │
                    └────────────────────────────────────┘
                                │
                                ▼
                     out_lane0_block, out_lane1_block
                     block_lock[3:0]
```

### 4.2 内部 Lane 选择状态

模块内部维护 lane_sel 状态，每收到一个有效数据翻转一次：

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

### 4.3 Lane 解复用逻辑

```systemverilog
reg [65:0] lane_buf [0:3];

always @(posedge clk) begin
    if (!rst_n) begin
        // reset
    end else if (in_valid && in_ready) begin
        if (lane_sel == 1'b0) begin
            lane_buf[0] <= lane0_block;
            lane_buf[1] <= lane1_block;
        end else begin
            lane_buf[2] <= lane0_block;
            lane_buf[3] <= lane1_block;
        end
    end
end
```

### 4.3 单 Lane 块同步状态机

每个 lane 有独立的状态机：

```systemverilog
typedef enum logic [1:0] {
    STATE_UNLOCK = 2'b00,
    STATE_LOCK   = 2'b01
} state_t;

reg [1:0]   state [0:3];
reg [6:0]   correct_count [0:3];
reg [4:0]   error_count [0:3];
```

**参数**:
- LOCK_COUNT = 64: 连续正确 sync header 次数阈值
- UNLOCK_COUNT = 16: 连续错误 sync header 次数阈值

### 4.4 Sync Header 检测

```systemverilog
wire [1:0] sync_header [0:3];
wire       sync_valid  [0:3];

genvar i;
generate
    for (i = 0; i < 4; i = i + 1) begin : gen_sync_check
        assign sync_header[i] = lane_buf[i][1:0];
        assign sync_valid[i]  = (sync_header[i] == 2'b01) ||
                                (sync_header[i] == 2'b10);
    end
endgenerate
```

### 4.5 状态转换逻辑

```
STATE_UNLOCK:
  - 检测 sync header
  - 正确: correct_count++
  - 错误: correct_count = 0
  - correct_count == LOCK_COUNT: 转到 STATE_LOCK

STATE_LOCK:
  - 检测 sync header
  - 正确: error_count = 0
  - 错误: error_count++
  - error_count == UNLOCK_COUNT: 转到 STATE_UNLOCK
```

### 4.6 输出逻辑

```systemverilog
reg [65:0] out_buf [0:3];
reg         out_lane_sel;

always @(posedge clk) begin
    if (!rst_n) begin
        out_lane_sel <= 1'b0;
    end else if (out_valid && out_ready) begin
        out_lane_sel <= ~out_lane_sel;
    end
end

assign out_lane0_block = (out_lane_sel == 1'b0) ? out_buf[0] : out_buf[2];
assign out_lane1_block = (out_lane_sel == 1'b0) ? out_buf[1] : out_buf[3];

```

### 4.7 Block Lock 输出

```systemverilog
assign block_lock[0] = (state[0] == STATE_LOCK);
assign block_lock[1] = (state[1] == STATE_LOCK);
assign block_lock[2] = (state[2] == STATE_LOCK);
assign block_lock[3] = (state[3] == STATE_LOCK);
```

## 5. 时序图

### 5.1 数据流处理

```
clk:           |  0  |  1  |  2  |  3  |  4  |  5  |
               |     |     |     |     |     |     |
lane_sel(内部):|  0  |  1  |  0  |  1  |  0  |  1  |
               |     |     |     |     |     |     |
lane0_block:   | L0  | L2  | L0  | L2  | L0  | L2  |
lane1_block:   | L1  | L3  | L1  | L3  | L1  | L3  |
in_valid:      |  1  |  1  |  1  |  1  |  1  |  1  |
               |     |     |     |     |     |     |
lane_buf[0]:   | L0  | L0  | L0' | L0' | L0''| L0''|
lane_buf[1]:   | L1  | L1  | L1' | L1' | L1''| L1''|
lane_buf[2]:   |  -  | L2  | L2  | L2' | L2' | L2''|
lane_buf[3]:   |  -  | L3  | L3  | L3' | L3' | L3''|
               |     |     |     |     |     |     |
out_lane_sel(内部):| 0 |  1  |  0  |  1  |  0  |  1  |
out_lane0_block| L0  | L2  | L0' | L2' | L0''| L2''|
out_lane1_block| L1  | L3  | L1' | L3' | L1''| L3''|
out_valid:     |  1  |  1  |  1  |  1  |  1  |  1  |
```

### 5.2 单 Lane 锁定过程

```
clk:          |  0  |  1  |  2  | ... | 63  | 64  | 65  |
              |     |     |     |     |     |     |     |
sync_header[0]:| 01 | 10  | 01  | ... | 10  | 01  | 10  |
sync_valid[0]: |  1 |  1  |  1  | ... |  1  |  1  |  1  |
              |     |     |     |     |     |     |     |
correct_count: |  1 |  2  |  3  | ... | 64  |  -  |  -  |
              |     |     |     |     |     |     |     |
state[0]:     |UNLOCK|UNLOCK|UNLOCK|... |UNLOCK|LOCK |LOCK |
              |     |     |     |     |     |     |     |
block_lock[0]:|  0  |  0  |  0  | ... |  0  |  1  |  1  |
```

### 5.3 单 Lane 失锁过程

```
clk:          |  0  |  1  |  2  | ... | 15  | 16  | 17  |
              |     |     |     |     |     |     |     |
sync_header[0]:| 01 | 11  | 00  | ... | 11  | 01  | 10  |
sync_valid[0]: |  1 |  0  |  0  | ... |  0  |  1  |  1  |
              |     |     |     |     |     |     |     |
error_count:  |  0  |  1  |  2  | ... | 15  |  0  |  0  |
              |     |     |     |     |     |     |     |
state[0]:     |LOCK |LOCK |LOCK | ... |LOCK |UNLOCK|UNLOCK|
              |     |     |     |     |     |     |     |
block_lock[0]:|  1  |  1  |  1  | ... |  1  |  0  |  0  |
```

## 6. 参数配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| LOCK_COUNT | 64 | 连续正确 sync header 次数阈值 |
| UNLOCK_COUNT | 16 | 连续错误 sync header 次数阈值 |

**调整建议**:
- 增大 LOCK_COUNT: 更稳定，但锁定时间更长
- 减小 UNLOCK_COUNT: 更快检测错误，但可能误判

## 7. 错误处理

### 7.1 Sync Header 错误

当检测到无效的 sync header (非 01 或 10) 时：

```
1. 在未锁定状态: 重置正确计数
2. 在已锁定状态: 增加错误计数
3. 错误计数超过阈值: 失锁，重新搜索
```

### 7.2 错误统计 (可选)

可添加错误计数器用于诊断：

```
sync_error_count[3:0]: 每个 lane 的 sync header 错误次数
```

## 8. 与其他模块的关系

```
eth_pcs_gearbox_rx → eth_pcs_block_sync → eth_pcs_am_detect
         │                   │
         │                   ▼
         │            确定块边界
         │            输出对齐的 66-bit 块
         │            block_lock[3:0]
         │
         └── lane_sel 信号透传
```

## 9. 资源估算

| 资源 | 估算值 | 说明 |
|------|--------|------|
| FF | ~200 | 4 个 lane 的计数器 + 状态机 + buffer |
| LUT | ~150 | sync header 检测 + 解复用/复用逻辑 |

## 10. 测试要点

| 测试项 | 说明 |
|--------|------|
| 单 lane 锁定 | 验证单个 lane 连续正确 sync header 后正确锁定 |
| 单 lane 失锁 | 验证单个 lane 连续错误 sync header 后正确失锁 |
| 多 lane 独立性 | 验证 4 个 lane 独立工作，互不影响 |
| 数据透传 | 验证锁定后数据正确传递 |
| 交替输出 | 验证内部 lane_sel 正确翻转，输出交替正确 |
| 反压处理 | 验证 out_ready=0 时数据不丢失 |
| 复位行为 | 验证复位后状态正确 |

## 11. 参考文献

- IEEE 802.3-2018 Clause 82.2.10 (Block Synchronization)
- IEEE 802.3-2018 Clause 82.2.3.3 (Sync Header)

## 12. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-10 | 初始版本 |
| 2.0 | 2026-04-10 | 重构：支持 4 个 lane 独立块同步，接口与 gearbox_rx 匹配 |
| 2.1 | 2026-04-10 | 移除 lane_sel 输入/输出端口，改为内部维护 |
