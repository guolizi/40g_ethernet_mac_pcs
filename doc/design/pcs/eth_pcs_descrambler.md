# eth_pcs_descrambler 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_descrambler

**功能**: 64B/66B 编码块的 payload 解扰 (自同步解扰，与加扰器配对)

**位置**: rtl/pcs/eth_pcs_descrambler.sv

## 2. 接口定义

```systemverilog
module eth_pcs_descrambler (
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

## 3. 解扰算法

### 3.1 多项式

根据 IEEE 802.3-2018 Clause 49.2.6:

**G(x) = 1 + x + x^39 + x^58**

与加扰器使用相同的多项式。自同步特性保证了自动同步。

### 3.2 解扰原理

**公式**: `descrambled[i] = scrambled[i] XOR scrambled[i-58] XOR scrambled[i-39]`

由于加扰: `scrambled[i] = data[i] XOR scrambled[i-58] XOR scrambled[i-39]`

所以: `descrambled[i] = scrambled[i] XOR scrambled[i-58] XOR scrambled[i-39] = data[i]`

### 3.3 自同步特性

- 解扰器与加扰器使用相同的 LFSR 更新逻辑
- 无需显式同步，加扰数据流过即可自动对齐
- LFSR 状态由输入的加扰数据自身决定

## 4. 连续块解扰

两个块 (128-bit payload) 连续送入解扰器，LFSR 状态在块间连续更新：

```
Block 0 (加扰): payload[65:2] ──┐
                                ├──> 连续128位解扰
Block 1 (加扰): payload[65:2] ──┘

与加扰器完全相同的处理流程！
```

## 5. 详细设计

### 5.1 LFSR 状态

```systemverilog
reg [57:0] lfsr_state;
```

### 5.2 解扰公式详解

**IEEE 802.3 自同步解扰公式**:
```
descrambled[i] = scrambled[i] XOR scrambled[i-58] XOR scrambled[i-39]
```

**关键理解**:
- `scrambled[i-58]`: 58个周期前的加扰输入，来自 LFSR
- `scrambled[i-39]`: 39个周期前的加扰输入
  - 对于 i < 39: 来自 LFSR (即 `lfsr[i+19]`)
  - 对于 i >= 39: 来自当前块的加扰输入 (即 `in_payload[i-39]`)

**与加扰器的区别**:
- 加扰器 LFSR 存储 **加扰输出** (scrambled output)
- 解扰器 LFSR 存储 **加扰输入** (scrambled input)

### 5.3 Block 0 解扰计算

```systemverilog
wire [57:0] s = lfsr_state;
wire [63:0] block0_scrambled = in_block0[65:2];
wire [63:0] block0_descrambled;

assign block0_descrambled[38:0] = block0_scrambled[38:0] ^ s[38:0] ^ s[57:19];

wire [24:0] block0_descrambled_39_63;
genvar i;
generate
    for (i = 0; i < 25; i=i+1) begin : gen_block0_high
        assign block0_descrambled_39_63[i] = 
            block0_scrambled[39+i] ^ s[39+i] ^ block0_scrambled[i];
    end
endgenerate
assign block0_descrambled[63:39] = block0_descrambled_39_63;
```

### 5.4 Block 0 后的 LFSR 更新

```systemverilog
wire [57:0] lfsr_after_block0 = block0_scrambled[63:6];
```

### 5.5 Block 1 解扰计算

```systemverilog
wire [57:0] s1 = lfsr_after_block0;
wire [63:0] block1_scrambled = in_block1[65:2];
wire [63:0] block1_descrambled;

assign block1_descrambled[38:0] = block1_scrambled[38:0] ^ s1[38:0] ^ s1[57:19];

wire [24:0] block1_descrambled_39_63;
generate
    for (i = 0; i < 25; i=i+1) begin : gen_block1_high
        assign block1_descrambled_39_63[i] = 
            block1_scrambled[39+i] ^ s1[39+i] ^ block1_scrambled[i];
    end
endgenerate
assign block1_descrambled[63:39] = block1_descrambled_39_63;
```

### 5.6 Block 1 后的 LFSR 更新

```systemverilog
wire [57:0] lfsr_after_block1 = block1_scrambled[63:6];
```

### 5.7 流水线寄存器

解扰计算是组合逻辑，需要添加流水线寄存器：

```systemverilog
reg [65:0]  out_block0_reg;
reg [65:0]  out_block1_reg;
reg         out_valid_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        out_block0_reg <= 66'h0;
        out_block1_reg <= 66'h0;
        out_valid_reg  <= 1'b0;
    end else if (in_valid && in_ready) begin
        out_block0_reg <= {block0_descrambled, in_block0[1:0]};
        out_block1_reg <= {block1_descrambled, in_block1[1:0]};
        out_valid_reg  <= 1'b1;
    end else begin
        out_valid_reg  <= 1'b0;
    end
end

assign out_block0 = out_block0_reg;
assign out_block1 = out_block1_reg;
assign out_valid  = out_valid_reg;
assign in_ready   = out_ready;
```

### 5.8 LFSR 状态更新

```systemverilog
always @(posedge clk) begin
    if (!rst_n) begin
        lfsr_state <= 58'h0;
    end else if (in_valid && in_ready) begin
        lfsr_state <= lfsr_after_block1;
    end
end
```

**时序图**:
```
clk:         │   N   │  N+1  │  N+2  │
             │       │       │       │
in_block0    │  B0   │  B1   │  B2   │
in_block1    │  B0   │  B1   │  B2   │
in_valid     │___/   │   \___│   \___|
             │       │       │       │
out_block0   │       │  B0'  │  B1'  │
out_block1   │       │  B0'  │  B1'  │
out_valid    │       │___/   │   \___|
```

**注意**: 解扰延迟 1 个周期，`out_valid` 与数据对齐。

## 6. 与加扰器的关系

| 特性 | 加扰器 | 解扰器 |
|------|--------|--------|
| 多项式 | 1 + x + x^39 + x^58 | 1 + x + x^39 + x^58 |
| LFSR 位宽 | 58-bit | 58-bit |
| 处理方式 | 连续处理两个块 | 连续处理两个块 |
| 流水线 | 2 周期 | 2 周期 |
| 同步方式 | 自同步 | 自同步 |

**数据流**:
```
加扰: data → scrambler → scrambled data
解扰: scrambled data → descrambler → data
```

## 7. 验证要点

- 64B/66b_enc → scrambler → descrambler → 64b66b_dec 应得到原始数据
- LFSR 初始值为 0 时也应正常工作

## 8. 参考文献

- IEEE 802.3-2018 Clause 49.2.6 (Scrambler/Descrambler)
- IEEE 802.3-2018 Clause 82.2.5 (Scrambler)

## 9. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-08 | 初始版本 |
| 1.1 | 2026-04-10 | 修正解扰算法：i>=39时需使用当前块加扰输入；简化LFSR更新为取最新58位加扰输入 |
| 1.2 | 2026-04-10 | **重大修正**: Sync Header 位置改为 Bit 1:0；payload 位于 Bit 65:2 |
| 1.3 | 2026-04-13 | 添加流水线寄存器，正确处理 in_valid/out_valid 信号 |
