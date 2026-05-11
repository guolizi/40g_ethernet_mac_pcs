# eth_pcs_idle_delete 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_idle_delete

**功能**: 删除 XLGMII Idle 块，实现 RX 方向速率匹配

**位置**: rtl/pcs/eth_pcs_idle_delete.sv

**时钟域**: clk_pma_rx (PMA 恢复时钟)

## 2. 接口定义

```systemverilog
module eth_pcs_idle_delete (
    input  wire         clk_pma,
    input  wire         rst_n_pma,

    input  wire [127:0] in_data,
    input  wire [15:0]  in_ctrl,
    input  wire         in_valid,
    output wire         in_ready,

    output wire [127:0] out_data,
    output wire [15:0]  out_ctrl,
    output wire         out_valid,
    input  wire         out_ready,

    output wire [3:0]   idle_blocks_deleted
);
```

### 2.1 信号说明

**输入侧**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| in_data | input | 128 | XLGMII 数据 |
| in_ctrl | input | 16 | XLGMII 控制掩码 |
| in_valid | input | 1 | 数据有效 |
| in_ready | output | 1 | 上游就绪 |

**输出侧**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| out_data | output | 128 | XLGMII 数据 (Idle 已删除) |
| out_ctrl | output | 16 | XLGMII 控制掩码 |
| out_valid | output | 1 | 数据有效 |
| out_ready | input | 1 | 下游就绪 |

**统计输出**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| idle_blocks_deleted | output | 4 | 本周期删除的 Idle 块数 (0-2) |

## 3. 功能描述

### 3.1 速率匹配原理

**问题**:
- `clk_pma_rx` 是远端发送时钟恢复，与本地 `clk_core` 不同源
- 存在 ±100 ppm 频偏
- 直接 CDC 会导致 FIFO 溢出或读空

**解决方案**:
- 通过删除 Idle 块实现速率匹配
- 当远端时钟略快时，接收数据率略高，删除更多 Idle
- 当远端时钟略慢时，接收数据率略低，保留更多 Idle

### 3.2 数据块定义

**128-bit 数据布局**:
```
in_data[127:0]:
  - [63:0]   = 块0 (低位)
  - [127:64] = 块1 (高位)

in_ctrl[15:0]:
  - [7:0]   = 块0 控制掩码
  - [15:8]  = 块1 控制掩码
```

**为什么按 8 字节块处理**:
- 64B/66B 编码的基本单位是 8 字节块
- `/S/` (Start) 只能出现在块边界 (块0 或 块1 的起始位置)
- `/S/` 之前的 Idle 数量必然是 8 的倍数

### 3.3 Idle 块识别

**XLGMII Idle 字符**: `/I/` = 0x07 (控制字符)

**Idle 块定义**:
- 块0 是 Idle: `in_ctrl[7:0] == 8'hFF` 且 `in_data[63:0] == {8{8'h07}}`
- 块1 是 Idle: `in_ctrl[15:8] == 8'hFF` 且 `in_data[127:64] == {8{8'h07}}`

### 3.4 删除策略

**删除条件**:
- 当前处于帧间状态 (STATE_IDLE)
- 当前块是 Idle 块

**删除场景**:

| 场景 | 块0 | 块1 | 操作 |
|------|-----|-----|------|
| 全 Idle | I | I | 删除整拍 (2 块) |
| 部分 Idle | I | 非 I | 删除块0，缓存块1 |

**说明**:
- 块1 有 `/S/` 时也可以删除块0
- `/S/` 移累到块0 位置完全合法

### 3.5 数据缓存与重排

**问题**:
- 删除块0 后，块1 的数据需要缓存
- 下一拍需要把缓存数据和输入数据组合成 128-bit 输出

**缓存机制**:
- `cache_data`: 缓存块1 数据
- `cache_ctrl`: 缓存块1 控制掩码
- `cache_valid`: 缓存有效标志

**重排逻辑**:
```
缓存空时 (cache_valid=0):
  out_data = in_data

缓存有效时 (cache_valid=1):
  out_data[63:0]   = cache_data  (上一拍缓存的块1，现在变成块0)
  out_data[127:64] = in_data[63:0] (当前拍的块0，现在变成块1)
```

**帧结束处理**:
- STATE_TERM 时，不更新 cache_data
- 下一拍进入 STATE_IDLE 时清空 cache_valid

## 4. 详细设计

### 4.1 状态定义

```systemverilog
localparam [1:0]
    STATE_IDLE  = 2'b00,  // 帧间空闲
    STATE_FRAME = 2'b01,  // 帧内
    STATE_TERM  = 2'b10;  // 帧结束 (检测到 /T/)
```

### 4.2 块级信号识别

```systemverilog
wire block0_is_idle = (in_ctrl[7:0] == 8'hFF) && 
                      (in_data[63:0] == {8{8'h07}});
wire block1_is_idle = (in_ctrl[15:8] == 8'hFF) && 
                      (in_data[127:64] == {8{8'h07}});
wire both_idle = block0_is_idle && block1_is_idle;

wire block0_has_start = in_ctrl[0] && (in_data[7:0] == 8'hFB);
wire block1_has_start = in_ctrl[8] && (in_data[71:64] == 8'hFB);
wire has_start = block0_has_start || block1_has_start;

wire [15:0] is_term;
genvar i;
generate
    for (i = 0; i < 16; i = i + 1) begin : gen_term_check
        assign is_term[i] = in_ctrl[i] && (in_data[8*i +: 8] == 8'hFD);
    end
endgenerate
wire has_term = (is_term != 16'h0000);
```

### 4.3 删除条件

```systemverilog
wire can_delete_both = both_idle;
wire can_delete_one  = block0_is_idle && !block1_is_idle;
```

### 4.4 缓存管理

```systemverilog
reg         cache_valid;
reg  [63:0] cache_data;
reg  [7:0]  cache_ctrl;

always @(posedge clk_pma) begin
    if (!rst_n_pma) begin
        cache_valid <= 1'b0;
        cache_data  <= 64'h0;
        cache_ctrl  <= 8'h0;
    end else if (in_valid && out_ready) begin
        case (state)
            STATE_IDLE: begin
                if (can_delete_one) begin
                    cache_valid <= 1'b1;
                    cache_data  <= in_data[127:64];
                    cache_ctrl  <= in_ctrl[15:8];
                end else begin
                    cache_valid <= 1'b0;
                end
            end

            STATE_FRAME: begin
                if (cache_valid) begin
                    cache_data <= in_data[127:64];
                    cache_ctrl <= in_ctrl[15:8];
                end
            end

            STATE_TERM: begin
                // 不更新 cache_data，保持最后一帧的缓存值
            end

            default: begin
                cache_valid <= 1'b0;
            end
        endcase
    end
end
```

### 4.5 完整实现代码

```systemverilog
module eth_pcs_idle_delete (
    input  wire         clk_pma,
    input  wire         rst_n_pma,

    input  wire [127:0] in_data,
    input  wire [15:0]  in_ctrl,
    input  wire         in_valid,
    output wire         in_ready,

    output wire [127:0] out_data,
    output wire [15:0]  out_ctrl,
    output wire         out_valid,
    input  wire         out_ready,

    output wire [3:0]   idle_blocks_deleted
);

    localparam [1:0]
        STATE_IDLE  = 2'b00,
        STATE_FRAME = 2'b01,
        STATE_TERM  = 2'b10;

    reg [1:0] state;

    wire block0_is_idle = (in_ctrl[7:0] == 8'hFF) && 
                          (in_data[63:0] == {8{8'h07}});
    wire block1_is_idle = (in_ctrl[15:8] == 8'hFF) && 
                          (in_data[127:64] == {8{8'h07}});
    wire both_idle = block0_is_idle && block1_is_idle;

    wire block0_has_start = in_ctrl[0] && (in_data[7:0] == 8'hFB);
    wire block1_has_start = in_ctrl[8] && (in_data[71:64] == 8'hFB);
    wire has_start = block0_has_start || block1_has_start;

    wire [15:0] is_term;
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : gen_term_check
            assign is_term[i] = in_ctrl[i] && (in_data[8*i +: 8] == 8'hFD);
        end
    endgenerate
    wire has_term = (is_term != 16'h0000);

    wire can_delete_both = both_idle;
    wire can_delete_one  = block0_is_idle && !block1_is_idle;

    always @(posedge clk_pma) begin
        if (!rst_n_pma) begin
            state <= STATE_IDLE;
        end else if (in_valid) begin
            case (state)
                STATE_IDLE: begin
                    if (has_start) state <= STATE_FRAME;
                end
                STATE_FRAME: begin
                    if (has_term) state <= STATE_TERM;
                end
                STATE_TERM: begin
                    state <= STATE_IDLE;
                end
                default: state <= STATE_IDLE;
            endcase
        end
    end

    reg         cache_valid;
    reg  [63:0] cache_data;
    reg  [7:0]  cache_ctrl;

    always @(posedge clk_pma) begin
        if (!rst_n_pma) begin
            cache_valid <= 1'b0;
            cache_data  <= 64'h0;
            cache_ctrl  <= 8'h0;
        end else if (in_valid && out_ready) begin
            case (state)
                STATE_IDLE: begin
                    if (can_delete_one) begin
                        cache_valid <= 1'b1;
                        cache_data  <= in_data[127:64];
                        cache_ctrl  <= in_ctrl[15:8];
                    end else begin
                        cache_valid <= 1'b0;
                    end
                end

                STATE_FRAME: begin
                    if (cache_valid) begin
                        cache_data <= in_data[127:64];
                        cache_ctrl <= in_ctrl[15:8];
                    end
                end

                STATE_TERM: begin
                    // 不更新 cache_data
                end

                default: begin
                    cache_valid <= 1'b0;
                end
            endcase
        end
    end

    reg         out_en;
    reg [3:0]   blocks_deleted;

    always @(posedge clk_pma) begin
        if (!rst_n_pma) begin
            out_en         <= 1'b0;
            blocks_deleted <= 4'h0;
        end else if (in_valid && out_ready) begin
            case (state)
                STATE_IDLE: begin
                    if (can_delete_both) begin
                        out_en         <= 1'b0;
                        blocks_deleted <= 4'h2;
                    end else if (can_delete_one) begin
                        out_en         <= 1'b0;
                        blocks_deleted <= 4'h1;
                    end else begin
                        out_en         <= 1'b1;
                        blocks_deleted <= 4'h0;
                    end
                end
                STATE_FRAME: begin
                    out_en         <= 1'b1;
                    blocks_deleted <= 4'h0;
                end
                STATE_TERM: begin
                    out_en         <= 1'b1;
                    blocks_deleted <= 4'h0;
                end
                default: begin
                    out_en         <= 1'b0;
                    blocks_deleted <= 4'h0;
                end
            endcase
        end else begin
            out_en         <= 1'b0;
            blocks_deleted <= 4'h0;
        end
    end

    wire [127:0] reorder_data = {in_data[63:0], cache_data};
    wire [15:0]  reorder_ctrl = {in_ctrl[7:0], cache_ctrl};

    assign out_data            = cache_valid ? reorder_data : in_data;
    assign out_ctrl            = cache_valid ? reorder_ctrl : in_ctrl;
    assign out_valid           = out_en && in_valid;
    assign in_ready            = out_ready;
    assign idle_blocks_deleted = blocks_deleted;

endmodule
```

## 5. 时序图

**时序图说明**:
- `in_data` 格式: `[块0, 块1]` (块0在低位，块1在高位)
- `out_data` 格式: `[块0, 块1]`
- `I` = Idle 块, `S` = Start, `T` = Terminate, `D` = Data
- **寄存器值 (state, cache_valid, cache_data, out_en)**: 显示时钟沿后的值
- **组合逻辑输出 (out_data, out_valid)**: 显示当前周期的输出

### 5.1 正常数据流 (无删除)

```
              |  周期 N  | 周期 N+1 | 周期 N+2 | 周期 N+3 | 周期 N+4 | 周期 N+5 |
              |          |          |          |          |          |          |
in_data:      |   I,I    |   S,D    |   D,D    |   D,T    |   I,I    |   I,I    |
              |          |          |          |          |          |          |
--- 时钟沿后 (寄存器值) ---
state:        |   IDLE   |  FRAME   |  FRAME   |   TERM   |   IDLE   |   IDLE   |
cache_valid:  |     0    |     0    |     0    |     0    |     0    |     0    |
out_en:       |     1    |     1    |     1    |     1    |     1    |     1    |
              |          |          |          |          |          |          |
--- 组合逻辑输出 ---
out_data:     |   I,I    |   S,D    |   D,D    |   D,T    |   I,I    |   I,I    |
out_valid:    |     1    |     1    |     1    |     1    |     1    |     1    |

说明: 无 Idle 删除，数据直通。
```

### 5.2 删除整拍 Idle (2 块)

```
              |  周期 N  | 周期 N+1 | 周期 N+2 | 周期 N+3 | 周期 N+4 |
              |          |          |          |          |          |
in_data:      |   I,I    |   I,I    |   I,I    |   S,D    |   D,D    |
can_del_both: |     1    |     1    |     1    |     0    |     0    |
has_start:    |     0    |     0    |     0    |     1    |     0    |
              |          |          |          |          |          |
--- 时钟沿后 (寄存器值) ---
state:        |   IDLE   |   IDLE   |   IDLE   |  FRAME   |  FRAME   |
cache_valid:  |     0    |     0    |     0    |     0    |     0    |
out_en:       |     0    |     0    |     0    |     1    |     1    |
              |          |          |          |          |          |
--- 组合逻辑输出 ---
out_data:     |    -     |    -     |    -     |   S,D    |   D,D    |
out_valid:    |     0    |     0    |     0    |     1    |     1    |
blocks_del:   |     2    |     2    |     2    |     0    |     0    |

说明: 连续 3 拍全 Idle，全部删除，直到检测到 /S/ 才开始输出。
```

### 5.3 删除单块 Idle + 数据重排

```
              |  周期 N  | 周期 N+1 | 周期 N+2 | 周期 N+3 | 周期 N+4 |
              |          |          |          |          |          |
in_data:      |   I,D0   |  D1,D2   |  D3,D4   |  D5,D6   |   T,I    |
can_del_one:  |     1    |     0    |     0    |     0    |     0    |
has_start:    |     0    |     0    |     0    |     0    |     0    |
has_term:     |     0    |     0    |     0    |     0    |     1    |
              |          |          |          |          |          |
--- 时钟沿后 (寄存器值) ---
state:        |   IDLE   |  FRAME   |  FRAME   |  FRAME   |   TERM   |
cache_valid:  |     1    |     1    |     1    |     1    |     1    |
cache_data:   |    D0    |    D2    |    D4    |    D6    |    D6    |
out_en:       |     0    |     1    |     1    |     1    |     1    |
              |          |          |          |          |          |
--- 组合逻辑输出 ---
out_data:     |    -     |  D0,D1   |  D2,D3   |  D4,D5   |  D6,T    |
out_valid:    |     0    |     1    |     1    |     1    |     1    |
blocks_del:   |     1    |     0    |     0    |     0    |     0    |

说明:
- N:   删除块0(I)，缓存块1(D0)，不输出
- N+1: 输出 [D0,D1] (cache_data=D0, in_data[63:0]=D1)，缓存 D2
- N+2: 输出 [D2,D3]，缓存 D4
- N+3: 输出 [D4,D5]，缓存 D6
- N+4: 输出 [D6,T]，STATE_TERM 不更新 cache_data
```

### 5.4 /S/ 出现在块1 (删除块0)

```
              |  周期 N  | 周期 N+1 | 周期 N+2 | 周期 N+3 |
              |          |          |          |          |
in_data:      |   I,S    |  D0,D1   |  D2,T    |   I,I    |
can_del_one:  |     1    |     0    |     0    |     0    |
has_start:    |     1    |     0    |     0    |     0    |
has_term:     |     0    |     0    |     1    |     0    |
              |          |          |          |          |
--- 时钟沿后 (寄存器值) ---
state:        |  FRAME   |  FRAME   |   TERM   |   IDLE   |
cache_valid:  |     1    |     1    |     1    |     0    |
cache_data:   |     S    |    D1    |     T    |    -     |
out_en:       |     0    |     1    |     1    |     1    |
              |          |          |          |          |
--- 组合逻辑输出 ---
out_data:     |    -     |   S,D0   |  D1,D2   |   T,I    |
out_valid:    |     0    |     1    |     1    |     1    |
blocks_del:   |     1    |     0    |     0    |     0    |

说明:
- N:   删除块0(I)，缓存块1(S)，不输出 (out_en=0)
- N+1: 输出 [S,D0]，/S/ 移到块0 位置
- N+2: 输出 [D1,D2]，缓存 T
- N+3: 输出 [T,I]，STATE_TERM
- N+4: STATE_IDLE，cache_valid 清零，正常输出
```

### 5.5 短帧 (帧结束后清空缓存)

```
              |  周期 N  | 周期 N+1 | 周期 N+2 | 周期 N+3 |
              |          |          |          |          |
in_data:      |   I,S    |  D0,T    |   I,I    |   I,I    |
can_del_one:  |     1    |     0    |     0    |     0    |
has_start:    |     1    |     0    |     0    |     0    |
has_term:     |     0    |     1    |     0    |     0    |
              |          |          |          |          |
--- 时钟沿后 (寄存器值) ---
state:        |  FRAME   |   TERM   |   IDLE   |   IDLE   |
cache_valid:  |     1    |     1    |     0    |     0    |
cache_data:   |     S    |     T    |    -     |    -     |
out_en:       |     0    |     1    |     1    |     1    |
              |          |          |          |          |
--- 组合逻辑输出 ---
out_data:     |    -     |   S,D0   |   T,I    |   I,I    |
out_valid:    |     0    |     1    |     1    |     1    |
blocks_del:   |     1    |     0    |     0    |     0    |

说明:
- N:   删除块0(I)，缓存块1(S)，不输出 (out_en=0)
- N+1: 输出 [S,D0]，STATE_TERM
- N+2: STATE_IDLE，cache_valid 清零，正常输出
```

## 6. 与其他模块的关系

```
eth_pcs_64b66b_dec → eth_pcs_idle_delete → async_fifo → MAC
        │                    │
        │                    ▼
        │              速率匹配
        │              (删除 Idle 块)
        │
        └── 输出 XLGMII 格式 (data + ctrl)
```

## 7. 资源估算

| 资源 | 估算值 | 说明 |
|------|--------|------|
| FF | ~80 | 状态机 + 缓存 + 控制逻辑 |
| LUT | ~150 | 块识别 + 重排逻辑 |
| BRAM | 0 | 无存储需求 |

## 8. 测试要点

| 测试项 | 说明 |
|--------|------|
| 块识别 | 验证正确识别 8 字节 Idle 块 |
| 帧边界检测 | 验证 /S/ 只出现在块边界 |
| 整拍删除 | 验证删除 2 块 Idle |
| 单块删除 | 验证删除块0，数据重排正确 |
| 数据顺序 | 验证重排后数据顺序正确 |
| /S/在块1 | 验证删除块0后 /S/ 移到块0 |
| 帧结束处理 | 验证 STATE_TERM 时正确输出最后一拍 |
| 缓存清空 | 验证帧结束后 cache_valid 正确清零 |
| 速率匹配 | 验证不同频偏下 FIFO 不溢出/不读空 |
| 反压处理 | 验证 out_ready=0 时数据不丢失 |
| 复位行为 | 验证复位后状态正确 |

## 9. 参考文献

- IEEE 802.3-2018 Clause 46.3.4 (Rate Matching)
- IEEE 802.3-2018 Clause 82.2.10 (Idle Deletion)

## 10. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-13 | 初始版本 |
| 2.0 | 2026-04-13 | 改为按 8 字节块处理 |
| 3.0 | 2026-04-13 | 增加数据缓存和重排逻辑 |
| 4.0 | 2026-04-13 | 修正双缓存时序和数据顺序 |
| 5.0 | 2026-04-13 | 优化帧结束处理，整理文档结构 |
| 6.0 | 2026-04-13 | 修正缓存赋值 bug，简化为单缓存 |
| 7.0 | 2026-04-13 | 修正时序图，明确寄存器与组合逻辑时序关系 |
