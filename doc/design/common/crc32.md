# CRC32 模块详细设计

## 1. 概述

### 1.1 功能
IEEE 802.3 标准 CRC32 计算器，用于 MAC 层 FCS (Frame Check Sequence) 的生成和校验。

### 1.2 关键参数
| 参数 | 值 | 说明 |
|------|-----|------|
| 多项式 | 0x04C11DB7 | IEEE 802.3 标准 (bit-reversed: 0xEDB88320) |
| 初始值 | 0xFFFFFFFF | 全 1 |
| 输入 XOR | 0xFFFFFFFF | 等效于初始值 |
| 输出 XOR | 0xFFFFFFFF | 最终结果取反 |
| 输入位宽 | 128-bit | 每时钟处理 16 字节 |
| 流水线 | 2 级 | 满足 312.5 MHz 时序 |
| 延迟 | 2 周期 | 输入到输出的流水线延迟 |

### 1.3 实例化
TX 和 RX 各实例化一个独立的 crc32 模块。

---

## 2. 接口定义

```systemverilog
module crc32 #(
    parameter CRC_POLY = 32'h04C11DB7,      // CRC32 多项式
    parameter CRC_INIT = 32'hFFFFFFFF,      // 初始值
    parameter CRC_XOR_OUT = 32'hFFFFFFFF    // 输出异或值
) (
    input  wire         clk,            // 312.5 MHz
    input  wire         rst_n,          // 同步复位，低有效
    input  wire         start,          // 帧开始，初始化 CRC 状态
    input  wire [127:0] data_in,        // 128-bit 输入数据
    input  wire [15:0]  byte_en,        // 字节使能，bit[i]=1 表示 byte[i] 有效
    output wire [31:0]  crc_out,        // 当前 CRC 值 (每时钟更新)
    output wire         crc_valid       // CRC 输出有效标志 (延迟 2 周期)
);
```

### 2.1 信号说明
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| clk | input | 1 | 时钟，312.5 MHz |
| rst_n | input | 1 | 同步复位，低有效 |
| start | input | 1 | 帧开始信号，高电平初始化 CRC 状态为 0xFFFFFFFF |
| data_in | input | 127:0 | 输入数据，每时钟 16 字节 |
| byte_en | input | 15:0 | 字节使能，bit[i]=1 表示 data_in[8*i+7:8*i] 有效 |
| crc_out | output | 31:0 | 当前 CRC 计算结果，每时钟更新 |
| crc_valid | output | 1 | CRC 输出有效标志，延迟 2 周期跟随 start |

---

## 3. 架构设计

### 3.1 流水线架构

```
Cycle 0 (输入):
    data_in[127:0]
    byte_en[15:0]
    start
        │
        ▼
┌───────────────────────────┐
│ Stage 1: 字节掩码 +        │
│ 第一级 CRC 计算            │
│ (64-bit 分组计算)          │
└─────────────┬─────────────┘
              │
Cycle 1:      │ 中间 CRC 结果
              ▼
┌───────────────────────────┐
│ Stage 2: 第二级 CRC 计算   │
│ (合并分组 + 输出取反)       │
└─────────────┬─────────────┘
              │
Cycle 2 (输出):
    crc_out[31:0]
    crc_valid
```

### 3.2 数据流

```
start ──► 初始化 crc_reg = 0xFFFFFFFF
              │
              ▼
每时钟:  crc_reg = CRC32_Parallel(crc_reg, masked_data)
              │
              ▼
输出:    crc_out = crc_reg XOR 0xFFFFFFFF  (取反)
```

---

## 4. 详细设计

### 4.1 字节掩码处理

当帧尾不足 16 字节时，`byte_en` 标记有效字节。无效字节用 0 填充，不参与 CRC 计算。

```systemverilog
// 字节掩码: 无效字节清零
wire [127:0] masked_data;
assign masked_data = data_in & {16{byte_en}};  // 每个 byte_en bit 控制 8-bit
// 实际实现需要按字节展开
```

正确实现:
```systemverilog
wire [127:0] masked_data;
genvar g;
generate
    for (g = 0; g < 16; g++) begin : gen_mask
        assign masked_data[g*8 +: 8] = byte_en[g] ? data_in[g*8 +: 8] : 8'h00;
    end
endgenerate
```

### 4.2 128-bit 并行 CRC 计算

#### 4.2.1 数学原理

CRC 的本质是模 2 除法。对于串行 CRC:
```
CRC_next = (CRC_current << 1) ^ (data_bit ? POLY : 0)
```

对于 128-bit 并行 CRC，可以表示为矩阵运算:
```
CRC_next = (CRC_current * M_crc) ^ (data_in * M_data)
```

其中:
- `M_crc` 是 32x32 矩阵，描述 CRC 状态经过 128 次移位后的转移
- `M_data` 是 32x128 矩阵，描述 128-bit 数据对 CRC 的影响

#### 4.2.2 矩阵预计算

`M_crc` 和 `M_data` 可以在编译时预计算为常量:

```systemverilog
// 32x32 矩阵: CRC 状态经过 128 个时钟周期 (128-bit) 后的转移
localparam [31:0] M_CRC [0:31] = '{
    32'hxxxx_xxxx,  // 每行是一个基向量经过 128 次 CRC 移位后的结果
    ...
};

// 32x128 矩阵: 128-bit 数据对 CRC 的影响
localparam [31:0] M_DATA [0:127] = '{
    32'hxxxx_xxxx,  // 每个 bit 位置对 CRC 的贡献
    ...
};
```

#### 4.2.3 实际实现

由于 128-bit 并行 CRC 的组合逻辑较深，采用 2 级流水线:

**Stage 1:** 将 128-bit 数据分为两组 64-bit，分别计算部分 CRC
**Stage 2:** 合并两组结果，输出最终 CRC

```
CRC_after_128bits = CRC_init * x^128 mod G(x)  XOR  data[127:0] * x^0 mod G(x)
```

分解为:
```
partial1 = CRC_init * x^64 mod G(x)  XOR  data[127:64] * x^0 mod G(x)
CRC_out  = partial1 * x^64 mod G(x)  XOR  data[63:0] * x^0 mod G(x)
```

### 4.3 状态管理

```systemverilog
reg [31:0] crc_reg;
reg        crc_valid_d1, crc_valid_d2;

always @(posedge clk) begin
    if (!rst_n) begin
        crc_reg      <= 32'h0;
        crc_valid_d1 <= 1'b0;
        crc_valid_d2 <= 1'b0;
    end else begin
        // start 信号初始化 CRC 状态
        if (start) begin
            crc_reg <= CRC_INIT;
        end else begin
            // 每时钟更新 CRC
            crc_reg <= crc32_next(crc_reg, masked_data);
        end

        // valid 延迟链
        crc_valid_d1 <= start;
        crc_valid_d2 <= crc_valid_d1;
    end
end

// 输出取反
assign crc_out  = crc_reg ^ CRC_XOR_OUT;
assign crc_valid = crc_valid_d2;
```

### 4.4 CRC32 核心函数

```systemverilog
function [31:0] crc32_next;
    input [31:0]  crc;
    input [127:0] data;
    begin
        // 128-bit 并行 CRC 计算
        // 使用预计算的查找表或矩阵乘法
        crc32_next = crc32_parallel_128(crc, data);
    end
endfunction
```

---

## 5. 使用方式

### 5.1 TX 侧 (FCS 生成)

```
时序:
Cycle 0: start=1, data_in=帧头16字节, byte_en=16'hFFFF
Cycle 1: start=0, data_in=接下来16字节, byte_en=16'hFFFF
...
Cycle N: start=0, data_in=帧尾 (可能不足16字节), byte_en=有效字节掩码
Cycle N+2: crc_out 有效 → 即为 FCS 值 (已取反)
```

FCS 追加到帧尾 (小端序):
```
FCS[7:0]   = crc_out[7:0]
FCS[15:8]  = crc_out[15:8]
FCS[23:16] = crc_out[23:16]
FCS[31:24] = crc_out[31:24]
```

### 5.2 RX 侧 (FCS 校验)

```
时序:
Cycle 0: start=1, data_in=帧头16字节 (不含前导码/SFD)
Cycle 1: start=0, data_in=接下来16字节
...
Cycle N: start=0, data_in=帧尾 4 字节 FCS + 可能的前导数据
Cycle N+2: crc_out 有效

校验:
if (crc_out == 32'h2144DF1C) → FCS 正确
else → FCS 错误
```

魔数 `0x2144DF1C` 是 CRC32 的固定余式，当包含正确 FCS 的完整帧通过 CRC32 计算后，结果恒为该值。

---

## 6. 资源估算

| 资源 | 估算值 | 说明 |
|------|--------|------|
| LUT | ~500-800 | 128-bit 并行 CRC 组合逻辑 |
| FF | ~100 | 流水线寄存器 + 状态寄存器 |
| 延迟 | 2 周期 | 流水线级数 |

---

## 7. 测试要点

| 测试项 | 说明 |
|--------|------|
| 单字节 CRC | 验证 1 字节输入的 CRC 计算 |
| 完整 16 字节 | 验证 128-bit 满字节输入的 CRC |
| 部分字节使能 | 验证 byte_en 屏蔽无效字节 |
| 多周期帧 | 验证跨多个时钟的 CRC 累积计算 |
| start 信号 | 验证 start 正确初始化 CRC 状态 |
| TX FCS 生成 | 验证已知数据的 FCS 输出 |
| RX 魔数校验 | 验证含正确 FCS 的帧输出魔数 |
| 复位行为 | 验证 rst_n 复位后状态正确 |
