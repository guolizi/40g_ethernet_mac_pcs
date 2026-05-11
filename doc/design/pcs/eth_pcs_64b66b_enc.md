# eth_pcs_64b66b_enc 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_64b66b_enc

**功能**: 将 128-bit 数据/控制字符编码为两个 66-bit 块 (64B/66B 编码)

**位置**: rtl/pcs/eth_pcs_64b66b_enc.sv

## 2. 接口定义

```systemverilog
module eth_pcs_64b66b_enc (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [127:0]          in_data,
    input  wire [15:0]           in_ctrl,
    input  wire                  in_valid,
    output wire                  in_ready,

    output wire [65:0]           out_block0,
    output wire [65:0]           out_block1,
    output wire                  out_valid,
    input  wire                  out_ready
);
```

### 2.1 信号说明

**输入** (与 eth_mac_xgmii_enc 输出对接):
- `in_data[7:0]` = 第0字节, `in_data[15:8]` = 第1字节, ... `in_data[127:120]` = 第15字节
- `in_ctrl[i]=1` 表示 `in_data[i*8+7:i*8]` 是控制字符
- `in_ctrl[i]=0` 表示 `in_data[i*8+7:i*8]` 是数据字节

**输出**:
- 每周期输出 2 个独立的 66-bit 块
- `out_block0[1:0]` = sync header (块0)
- `out_block0[65:2]` = 块0 的 payload
- `out_block1[1:0]` = sync header (块1)
- `out_block1[65:2]` = 块1 的 payload

## 3. 66-bit 块格式

根据 IEEE 802.3-2018 Clause 82.2.3.3:
- **Bit 0** 是第一个发送的位（LSB first）
- **Sync Header**: Bit 1:0
- **Payload**: Bit 65:2

```
┌─────────────────────────────────────────────────────────────────┐
│  Bit 1:0    │  Bit 65:2 (payload)                               │
│  Sync[1:0]  │                                                      │
├─────────────┼────────────────────────────────────────────────────┤
│    2'b01    │  数据块: D[0] D[1] D[2] D[3] D[4] D[5] D[6] D[7]  │
│    2'b10    │  控制块: Type[7:0] + 56-bit                        │
└─────────────┴────────────────────────────────────────────────────┘
```

**重要**: Sync Header 位于 **Bit 1:0**（不是 Bit 65:64）！

## 4. 控制字符编码

| 字符 | XLGMII 编码 (hex) | 40/100GBASE-R 控制码 | 说明 |
|------|-------------------|---------------------|------|
| /I/  | 0x07              | 0x00                | Idle (空闲) |
| /LI/ | 0x06              | 0x06                | LPI Idle |
| /S/  | 0xFB              | 由 Type 隐含        | Start (帧开始) |
| /T/  | 0xFD              | 由 Type 隐含        | Terminate (帧结束) |
| /E/  | 0xFE              | 0x1E                | Error (错误) |
| /Q/  | 0x9C              | 0x0D                | Sequence Ordered Set |

## 5. 编码规则

每周期输入 16 字节，输出 2 个 66-bit 块:
- **块0**: 处理 `in_data[63:0]`, `in_ctrl[7:0]` (字节0-7)
- **块1**: 处理 `in_data[127:64]`, `in_ctrl[15:8]` (字节8-15)

### 5.1 数据块 (sync = 2'b01)

当 `in_ctrl == 8'h00` (8个字节全部是数据):
```systemverilog
out_block[1:0]   = 2'b01;        // sync header
out_block[65:2]  = in_data[63:0]; // payload
```

### 5.2 控制块 (sync = 2'b10)

**块0 编码逻辑** (字节0-7):

| 条件 | Type | payload 格式 | 说明 |
|------|------|-------------|------|
| ctrl=8'hFF, data=8×0x07 | 0x1E | /I/ × 8 | Idle块 |
| ctrl[0]=1, data[7:0]=0xFB, ctrl[7:1]=0 | 0x78 | /S/ + 7字节数据 | Start块 |
| ctrl[0]=1, data[7:0]=0xFD | 0x87 | /T/ + 7字节数据 | Term (1个/T/) |
| ctrl[1:0]=2'b11, data[15:0]=16'hFDFD | 0x99 | /T/ + /T/ + 6字节数据 | Term (2个/T/) |
| ctrl[2:0]=3'b111, data[23:0]=24'hFDFDFD | 0xAA | /T/ × 3 + 5字节数据 | Term (3个/T/) |
| ctrl[3:0]=4'b1111, data[31:0]=32'hFDFDFDFD | 0xB4 | /T/ × 4 + 4字节数据 | Term (4个/T/) |
| ctrl[4:0]=5'b11111, data[39:0]=40'hFDFDFDFDFD | 0xCC | /T/ × 5 + 3字节数据 | Term (5个/T/) |
| ctrl[5:0]=6'b111111, data[47:0]=48'hFDFDFDFDFDFD | 0xD2 | /T/ × 6 + 2字节数据 | Term (6个/T/) |
| ctrl[6:0]=7'b1111111, data[55:0]=56'hFDFDFDFDFDFDFD | 0xE1 | /T/ × 7 + 1字节数据 | Term (7个/T/) |
| ctrl=8'hFF, data=8×0xFD | 0xFF | /T/ × 8 | Term (8个/T/) |
| ctrl[0]=1, data[7:0]=0x9C | 0x4B | /Q/ + O code + 数据 | Ordered Set |

**块1 编码逻辑** (字节8-15): 与块0 相同

## 6. 编码逻辑

### 6.1 块类型判断

```systemverilog
wire [63:0] block0_data = in_data[63:0];
wire [7:0]  block0_ctrl = in_ctrl[7:0];

wire [63:0] block1_data = in_data[127:64];
wire [7:0]  block1_ctrl = in_ctrl[15:8];

wire block0_is_data = (block0_ctrl == 8'h00);
wire block1_is_data = (block1_ctrl == 8'h00);

wire block0_is_idle = (block0_ctrl == 8'hFF) && (block0_data == 64'h0707070707070707);
wire block1_is_idle = (block1_ctrl == 8'hFF) && (block1_data == 64'h0707070707070707);

wire block0_is_start = block0_ctrl[0] && (block0_data[7:0] == 8'hFB) && (block0_ctrl[7:1] == 7'h00);
wire block1_is_start = block1_ctrl[0] && (block1_data[7:0] == 8'hFB) && (block1_ctrl[7:1] == 7'h00);

wire block0_is_term = block0_ctrl[0] && (block0_data[7:0] == 8'hFD || block0_data[7:0] == 8'hFE);
wire block1_is_term = block1_ctrl[0] && (block1_data[7:0] == 8'hFD || block1_data[7:0] == 8'hFE);

wire block0_is_ordered_set = block0_ctrl[0] && (block0_data[7:0] == 8'h9C);
wire block1_is_ordered_set = block1_ctrl[0] && (block1_data[7:0] == 8'h9C);
```

### 6.2 Terminate块Type值选择

```systemverilog
function automatic [7:0] get_term_type(input [7:0] ctrl, input [63:0] data);
    integer i;
    reg found;
    begin
        found = 1'b0;
        get_term_type = 8'h1E;
        for (i = 0; i < 8; i = i + 1) begin
            if (!found && ctrl[i] && (data[i*8 +: 8] == 8'hFD || data[i*8 +: 8] == 8'hFE)) begin
                case (i)
                    0: get_term_type = 8'h87;
                    1: get_term_type = 8'h99;
                    2: get_term_type = 8'hAA;
                    3: get_term_type = 8'hB4;
                    4: get_term_type = 8'hCC;
                    5: get_term_type = 8'hD2;
                    6: get_term_type = 8'hE1;
                    7: get_term_type = 8'hFF;
                endcase
                found = 1'b1;
            end
        end
    end
endfunction
```

### 6.3 控制块 payload 生成

```systemverilog
function automatic [63:0] get_ctrl_payload(input [7:0] ctrl, input [63:0] data);
    integer i;
    reg [63:0] payload;
    reg [6:0] ctrl_code;
    begin
        payload = 64'h0;
        for (i = 0; i < 8; i = i + 1) begin
            if (ctrl[i]) begin
                case (data[i*8 +: 8])
                    8'h07: ctrl_code = 7'h00;  // /I/
                    8'h06: ctrl_code = 7'h06;  // /LI/
                    8'hFE: ctrl_code = 7'h1E;  // /E/
                    8'h9C: ctrl_code = 7'h0D;  // /Q/ (O code from data[15:8])
                    default: ctrl_code = 7'h00;
                endcase
                payload[i*7 +: 7] = ctrl_code;
            end else begin
                payload[i*8 +: 8] = data[i*8 +: 8];
            end
        end
        get_ctrl_payload = payload;
    end
endfunction
```

### 6.4 块编码输出

```systemverilog
reg [65:0] out_block0_reg;
reg [65:0] out_block1_reg;

always @(*) begin
    if (block0_is_data) begin
        out_block0_reg = {block0_data, 2'b01};
    end else if (block0_is_idle) begin
        out_block0_reg = {8'h1E, 56'h00000000000000, 2'b10};
    end else if (block0_is_start) begin
        out_block0_reg = {8'h78, block0_data[63:8], 2'b10};
    end else if (block0_is_term) begin
        out_block0_reg = {get_term_type(block0_ctrl, block0_data), block0_data[63:8], 2'b10};
    end else if (block0_is_ordered_set) begin
        out_block0_reg = {8'h4B, block0_data[15:8], 7'h0D, block0_data[63:24], 2'b10};
    end else begin
        out_block0_reg = {8'h1E, 56'h00000000000000, 2'b10};
    end
end

always @(*) begin
    if (block1_is_data) begin
        out_block1_reg = {block1_data, 2'b01};
    end else if (block1_is_idle) begin
        out_block1_reg = {8'h1E, 56'h00000000000000, 2'b10};
    end else if (block1_is_start) begin
        out_block1_reg = {8'h78, block1_data[63:8], 2'b10};
    end else if (block1_is_term) begin
        out_block1_reg = {get_term_type(block1_ctrl, block1_data), block1_data[63:8], 2'b10};
    end else if (block1_is_ordered_set) begin
        out_block1_reg = {8'h4B, block1_data[15:8], 7'h0D, block1_data[63:24], 2'b10};
    end else begin
        out_block1_reg = {8'h1E, 56'h00000000000000, 2'b10};
    end
end

assign out_block0 = out_block0_reg;
assign out_block1 = out_block1_reg;
```

## 7. 流水线

采用 2 周期流水线:
- Cycle N: 输入寄存，计算两个块的 Type 和 payload
- Cycle N+1: 输出两个 66-bit 块

```
clk:        │   N   │  N+1  │  N+2  │
            │       │       │       │
in_data     │  D0   │  D1   │  D2   │
in_ctrl     │  C0   │  C1   │  C2   │
in_valid    │___/   │   \___│   \___|
            │       │       │       │
out_block0  │       │ B00   │ B10   │
out_block1  │       │ B01   │ B11   │
out_valid   │       │___/   │   \___|
```

## 8. 与 MAC 层接口

本模块直接接收来自 eth_mac_xgmii_enc 的输出:

| 信号 | 位宽 | 描述 |
|------|------|------|
| in_data | 128 | XLGMII 数据 (字节0-15) |
| in_ctrl | 16 | XLGMII 控制掩码 (bit[i]=1 表示字节i是控制字符) |

**帧边界跨块处理**:
- 帧起始 /S/ 可能在块0 或块1 的首字节
- 帧结束 /T/ 可能在块0 或块1 的任意位置
- 每个块独立编码，不需要跨块状态

## 9. 参考文献

- IEEE 802.3-2018 Clause 82.2.3 (64B/66B Transmission Code)
- IEEE 802.3-2018 Figure 82-5 (64B/66B Block Formats)
- IEEE 802.3-2018 Table 82-1 (Control Codes)

## 10. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-08 | 初始版本 |
| 1.1 | 2026-04-08 | 修正接口为128-bit输入，每周期输出2个66-bit块 |
| 1.2 | 2026-04-10 | 修正Type值表格；补充Type选择逻辑和完整编码实现 |
| 1.3 | 2026-04-10 | **重大修正**: Sync Header 位置改为 Bit 1:0；Data Block sync=01, Control Block sync=10 |
