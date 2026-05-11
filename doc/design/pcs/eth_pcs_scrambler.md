# eth_pcs_scrambler 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_scrambler

**功能**: 64B/66B 编码块的 payload 加扰 (Self-synchronous Scrambling)

**位置**: rtl/pcs/eth_pcs_scrambler.sv

## 2. 接口定义

```systemverilog
module eth_pcs_scrambler (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [65:0]           in_block0,
    input  wire [65:0]           in_block1,
    input  wire                  in_valid,
    output wire                  in_ready,

    output wire [65:0]           out_block0,
    output wire [65:0]           out_block1,
    output wire                  out_valid,
    input  wire                  out_ready
);
```

### 2.1 信号说明

- 两个块构成连续的 128 位数据
- **sync 位 (bit[1:0])** 不被加扰，原样传递
- **64-bit payload (bit[65:2])** 被加扰，且块0 和块1 连续处理

## 3. 加扰算法

### 3.1 多项式

根据 IEEE 802.3-2018 Clause 49.2.6:

**G(x) = 1 + x + x^39 + x^58**

### 3.2 自同步原理

- **公式**: `scrambled[i] = data[i] XOR scrambled[i-58] XOR scrambled[i-39]`
- **无需初始同步**: LFSR 状态由输入数据自身决定
- **解扰器自动同步**: 使用相同的输入数据即可自动对齐

### 3.3 连续块加扰

两个块 (128-bit) 连续送入加扰器，LFSR 状态在块间连续更新：

```
Block 0 (64-bit): payload[65:2] ──┐
                                  ├──> 连续128位加扰
Block 1 (64-bit): payload[65:2] ──┘

LFSR状态更新:
1. 使用当前LFSR状态加扰Block 0的64位payload
2. 更新LFSR状态（基于Block 0的64位输出）
3. 使用更新后的LFSR状态加扰Block 1的64位payload
4. 更新LFSR状态（基于Block 1的64位输出）
```

## 4. 加扰规则

### 4.1 块类型处理

| 输入块类型 | 处理方式 |
|-----------|---------|
| 数据块 (sync=01) | payload 被加扰 |
| 控制块 (sync=10) | payload 被加扰 (Type + 数据) |

### 4.2 sync 位处理

- sync 位 (bit[1:0]) 原样传递，不参与加扰
- 仅 payload (bit[65:2]) 被加扰

## 5. 详细设计

### 5.1 LFSR 状态

```systemverilog
reg [57:0] lfsr_state;
```

### 5.2 加扰公式详解

**IEEE 802.3 自同步加扰公式**:
```
scrambled[i] = data[i] XOR scrambled[i-58] XOR scrambled[i-39]
```

**关键理解**:
- `scrambled[i-58]`: 58个周期前的输出，来自 LFSR
- `scrambled[i-39]`: 39个周期前的输出
  - 对于 i < 39: 来自 LFSR (即 `lfsr[i+19]`)
  - 对于 i >= 39: 来自当前块已计算的输出 (即 `scrambled[i-39]`)

### 5.3 Block 0 加扰计算

```systemverilog
wire [57:0] s = lfsr_state;
wire [63:0] block0_data = in_block0[65:2];
wire [63:0] block0_scrambled;

assign block0_scrambled[38:0] = block0_data[38:0] ^ s[38:0] ^ s[57:19];

wire [24:0] block0_scrambled_39_63;
genvar i;
generate
    for (i = 0; i < 25; i=i+1) begin : gen_block0_high
        assign block0_scrambled_39_63[i] = 
            block0_data[39+i] ^ s[39+i] ^ block0_scrambled[i];
    end
endgenerate
assign block0_scrambled[63:39] = block0_scrambled_39_63;
```

### 5.4 Block 0 后的 LFSR 更新

```systemverilog
wire [57:0] lfsr_after_block0 = block0_scrambled[63:6];
```

### 5.5 Block 1 加扰计算

```systemverilog
wire [57:0] s1 = lfsr_after_block0;
wire [63:0] block1_data = in_block1[65:2];
wire [63:0] block1_scrambled;

assign block1_scrambled[38:0] = block1_data[38:0] ^ s1[38:0] ^ s1[57:19];

wire [24:0] block1_scrambled_39_63;
generate
    for (i = 0; i < 25; i=i+1) begin : gen_block1_high
        assign block1_scrambled_39_63[i] = 
            block1_data[39+i] ^ s1[39+i] ^ block1_scrambled[i];
    end
endgenerate
assign block1_scrambled[63:39] = block1_scrambled_39_63;
```

### 5.6 Block 1 后的 LFSR 更新

```systemverilog
wire [57:0] lfsr_after_block1 = block1_scrambled[63:6];
```

### 5.7 输出组装

```systemverilog
assign out_block0 = {block0_scrambled, in_block0[1:0]};
assign out_block1 = {block1_scrambled, in_block1[1:0]};
```

### 5.8 时序逻辑

```systemverilog
always @(posedge clk) begin
    if (!rst_n) begin
        lfsr_state <= 58'h0;
    end else if (in_valid && in_ready) begin
        lfsr_state <= lfsr_after_block1;
    end
end
```

## 6. 流水线

采用 2 周期流水线:
- Cycle N: 输入，连续加扰两个块
- Cycle N+1: 输出结果，更新 LFSR

```
clk:        │   N   │  N+1  │  N+2  │
            │       │       │       │
in_block0   │  B00  │  B10  │  B20  │
in_block1   │  B01  │  B11  │  B21  │
in_valid    │___/   │   \___│   \___|
            │       │       │       │
lfsr_state  │  S0   │  S1   │  S2   │
            │       │       │       │
out_block0  │       │ B00'  │ B10'  │
out_block1  │       │ B01'  │ B11'  │
out_valid   │       │___/   │   \___|
```

## 7. 初始化

**LFSR 初始值**: `58'h0`

> 自同步加扰器即使初始状态为 0 也能正常工作，因为任何输入都会驱动状态机进入有效序列。

## 8. 数据流位置

加扰器位于 64B/66B 编码之后:
```
MAC → eth_pcs_64b66b_enc → eth_pcs_scrambler → eth_pcs_am_insert
```

## 9. 参考文献

- IEEE 802.3-2018 Clause 49.2.6 (Scrambler)
- IEEE 802.3-2018 Clause 82.2.5 (Scrambler)

## 10. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-08 | 初始版本 |
| 1.1 | 2026-04-08 | 修正为连续加扰两个块，LFSR状态在块间连续更新 |
| 1.2 | 2026-04-10 | 修正加扰算法：i>=39时需使用当前块已计算输出；简化LFSR更新为取最新58位输出 |
| 1.3 | 2026-04-10 | **重大修正**: Sync Header 位置改为 Bit 1:0；payload 位于 Bit 65:2 |
