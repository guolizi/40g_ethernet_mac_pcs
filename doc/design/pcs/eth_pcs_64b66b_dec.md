# eth_pcs_64b66b_dec 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_64b66b_dec

**功能**: 将 66-bit 块解码为 64-bit 数据/控制字符 (64B/66B 解码)

**位置**: rtl/pcs/eth_pcs_64b66b_dec.sv

## 2. 接口定义

```systemverilog
module eth_pcs_64b66b_dec (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [65:0]           in_block0,
    input  wire [65:0]           in_block1,
    input  wire                  in_valid,
    output wire                  in_ready,

    output wire [127:0]          out_data,
    output wire [15:0]           out_ctrl,
    output wire                  out_valid,
    input  wire                  out_ready
);
```

### 2.1 信号说明

**输入** (每周期2个66-bit块):
- `in_block0[1:0]` = sync header (块0)
- `in_block0[65:2]` = payload (块0)
- `in_block1[1:0]` = sync header (块1)
- `in_block1[65:2]` = payload (块1)

**输出** (128-bit XLGMII 格式):
- `out_data[7:0]` = 第0字节, `out_data[15:8]` = 第1字节, ... `out_data[127:120]` = 第15字节
- `out_ctrl[i]=1` 表示 `out_data[i*8+7:i*8]` 是控制字符
- `out_ctrl[i]=0` 表示 `out_data[i*8+7:i*8]` 是数据字节

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

## 4. 控制字符编码

| 字符 | XLGMII 编码 (hex) | 40/100GBASE-R 控制码 | 说明 |
|------|-------------------|---------------------|------|
| /I/  | 0x07              | 0x00                | Idle (空闲) |
| /LI/ | 0x06              | 0x06                | LPI Idle |
| /S/  | 0xFB              | 由 Type 隐含        | Start (帧开始) |
| /T/  | 0xFD              | 由 Type 隐含        | Terminate (帧结束) |
| /E/  | 0xFE              | 0x1E                | Error (错误) |
| /Q/  | 0x9C              | 0x0D                | Sequence Ordered Set |

## 5. 解码规则

### 5.1 数据块 (sync = 2'b01)

当 `sync == 2'b01`:
```systemverilog
out_data_byte = payload[63:0]  // 8字节直接输出
out_ctrl_byte = 8'h00          // 全部是数据
```

### 5.2 控制块 (sync = 2'b10)

**Type 解析**:

| Type (hex) | payload 格式 | out_ctrl | out_data | 说明 |
|------------|-------------|----------|----------|------|
| 0x1E | /I/ × 8 | 8'hFF | 8 × 0x07 | Idle块 |
| 0x78 | /S/ D[0] D[1] D[2] D[3] D[4] D[5] D[6] | 8'h01 | 0xFB + 7字节数据 | Start块 |
| 0x87 | /T/ D[0] D[1] D[2] D[3] D[4] D[5] D[6] | 8'h80 | 7字节数据 + 0xFD | Term (1 T) |
| 0x99 | /T/ /T/ D[0] D[1] D[2] D[3] D[4] D[5] | 8'hC0 | 6字节数据 + 2×0xFD | Term (2 T) |
| 0xAA | /T/ /T/ /T/ D[0] D[1] D[2] D[3] D[4] | 8'hE0 | 5字节数据 + 3×0xFD | Term (3 T) |
| 0xB4 | /T/ /T/ /T/ /T/ D[0] D[1] D[2] D[3] | 8'hF0 | 4字节数据 + 4×0xFD | Term (4 T) |
| 0xCC | /T/ /T/ /T/ /T/ /T/ D[0] D[1] D[2] | 8'hF8 | 3字节数据 + 5×0xFD | Term (5 T) |
| 0xD2 | /T/ /T/ /T/ /T/ /T/ /T/ D[0] D[1] | 8'hFC | 2字节数据 + 6×0xFD | Term (6 T) |
| 0xE1 | /T/ /T/ /T/ /T/ /T/ /T/ /T/ D[0] | 8'hFE | 1字节数据 + 7×0xFD | Term (7 T) |
| 0xFF | /T/ × 8 | 8'hFF | 8 × 0xFD | Term (8 T) |
| 0x4B | /O/ D[0] D[1] D[2] Z4 Z5 Z6 Z7 | 8'h01 | 0x9C + O code + 数据 | Ordered Set |

## 6. 解码逻辑

### 6.1 块类型判断

```systemverilog
wire [1:0] block0_sync = in_block0[1:0];
wire [7:0] block0_type = in_block0[9:2];
wire [63:0] block0_payload = in_block0[65:2];

wire [1:0] block1_sync = in_block1[1:0];
wire [7:0] block1_type = in_block1[9:2];
wire [63:0] block1_payload = in_block1[65:2];

wire block0_is_data = (block0_sync == 2'b01);
wire block1_is_data = (block1_sync == 2'b01);

wire block0_is_ctrl = (block0_sync == 2'b10);
wire block1_is_ctrl = (block1_sync == 2'b10);
```

### 6.2 Terminate块ctrl生成

```systemverilog
function automatic [7:0] get_term_ctrl(input [7:0] type_val);
    case (type_val)
        8'h87: get_term_ctrl = 8'h80;
        8'h99: get_term_ctrl = 8'hC0;
        8'hAA: get_term_ctrl = 8'hE0;
        8'hB4: get_term_ctrl = 8'hF0;
        8'hCC: get_term_ctrl = 8'hF8;
        8'hD2: get_term_ctrl = 8'hFC;
        8'hE1: get_term_ctrl = 8'hFE;
        8'hFF: get_term_ctrl = 8'hFF;
        default: get_term_ctrl = 8'hFF;
    endcase
endfunction
```

### 6.3 Terminate块data生成

```systemverilog
function automatic [63:0] get_term_data(input [7:0] type_val, input [55:0] payload);
    case (type_val)
        8'h87: get_term_data = {payload, 8'hFD};
        8'h99: get_term_data = {payload[47:0], 16'hFDFD};
        8'hAA: get_term_data = {payload[39:0], 24'hFDFDFD};
        8'hB4: get_term_data = {payload[31:0], 32'hFDFDFDFD};
        8'hCC: get_term_data = {payload[23:0], 40'hFDFDFDFDFD};
        8'hD2: get_term_data = {payload[15:0], 48'hFDFDFDFDFDFD};
        8'hE1: get_term_data = {payload[7:0], 56'hFDFDFDFDFDFDFD};
        8'hFF: get_term_data = {64{8'hFD}};
        default: get_term_data = {64{8'h07}};
    endcase
endfunction
```

### 6.4 控制码转XLGMII编码

```systemverilog
function automatic [7:0] ctrl_code_to_xlgmii(input [6:0] ctrl_code);
    case (ctrl_code)
        7'h00: ctrl_code_to_xlgmii = 8'h07;  // /I/
        7'h06: ctrl_code_to_xlgmii = 8'h06;  // /LI/
        7'h1E: ctrl_code_to_xlgmii = 8'hFE;  // /E/
        7'h0D: ctrl_code_to_xlgmii = 8'h9C;  // /Q/
        default: ctrl_code_to_xlgmii = 8'h07;
    endcase
endfunction
```

### 6.5 块解码输出

```systemverilog
reg [63:0] out_data0;
reg [7:0]  out_ctrl0;
reg [63:0] out_data1;
reg [7:0]  out_ctrl1;

always @(*) begin
    if (block0_is_data) begin
        out_data0 = block0_payload;
        out_ctrl0 = 8'h00;
    end else if (block0_is_ctrl) begin
        case (block0_type)
            8'h1E: begin
                out_data0 = {8{8'h07}};
                out_ctrl0 = 8'hFF;
            end
            8'h78: begin
                out_data0 = {block0_payload[55:0], 8'hFB};
                out_ctrl0 = 8'h01;
            end
            8'h87, 8'h99, 8'hAA, 8'hB4, 8'hCC, 8'hD2, 8'hE1, 8'hFF: begin
                out_data0 = get_term_data(block0_type, block0_payload[55:0]);
                out_ctrl0 = get_term_ctrl(block0_type);
            end
            8'h4B: begin
                out_data0 = {block0_payload[55:16], block0_payload[15:8], 8'h9C};
                out_ctrl0 = 8'h01;
            end
            default: begin
                out_data0 = {8{8'h07}};
                out_ctrl0 = 8'hFF;
            end
        endcase
    end else begin
        out_data0 = {8{8'h07}};
        out_ctrl0 = 8'hFF;
    end
end

always @(*) begin
    if (block1_is_data) begin
        out_data1 = block1_payload;
        out_ctrl1 = 8'h00;
    end else if (block1_is_ctrl) begin
        case (block1_type)
            8'h1E: begin
                out_data1 = {8{8'h07}};
                out_ctrl1 = 8'hFF;
            end
            8'h78: begin
                out_data1 = {block1_payload[55:0], 8'hFB};
                out_ctrl1 = 8'h01;
            end
            8'h87, 8'h99, 8'hAA, 8'hB4, 8'hCC, 8'hD2, 8'hE1, 8'hFF: begin
                out_data1 = get_term_data(block1_type, block1_payload[55:0]);
                out_ctrl1 = get_term_ctrl(block1_type);
            end
            8'h4B: begin
                out_data1 = {block1_payload[55:16], block1_payload[15:8], 8'h9C};
                out_ctrl1 = 8'h01;
            end
            default: begin
                out_data1 = {8{8'h07}};
                out_ctrl1 = 8'hFF;
            end
        endcase
    end else begin
        out_data1 = {8{8'h07}};
        out_ctrl1 = 8'hFF;
    end
end

assign out_data = {out_data1, out_data0};
assign out_ctrl = {out_ctrl1, out_ctrl0};
```

## 7. 流水线

采用 2 周期流水线:
- Cycle N: 输入寄存，解析 sync 和 Type
- Cycle N+1: 输出解码结果

```systemverilog
reg [65:0]  in_block0_reg, in_block1_reg;
reg         in_valid_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        in_block0_reg <= 66'h0;
        in_block1_reg <= 66'h0;
        in_valid_reg  <= 1'b0;
    end else if (in_valid && in_ready) begin
        in_block0_reg <= in_block0;
        in_block1_reg <= in_block1;
        in_valid_reg  <= 1'b1;
    end else begin
        in_valid_reg  <= 1'b0;
    end
end

reg [127:0] out_data_reg;
reg [15:0]  out_ctrl_reg;
reg         out_valid_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        out_data_reg  <= 128'h0;
        out_ctrl_reg  <= 16'h0;
        out_valid_reg <= 1'b0;
    end else begin
        out_data_reg  <= {out_data1, out_data0};
        out_ctrl_reg  <= {out_ctrl1, out_ctrl0};
        out_valid_reg <= in_valid_reg;
    end
end

assign out_data  = out_data_reg;
assign out_ctrl  = out_ctrl_reg;
assign out_valid = out_valid_reg;
assign in_ready  = out_ready;
```

**时序图**:
```
clk:        │   N   │  N+1  │  N+2  │
            │       │       │       │
in_block0   │  B0   │  B1   │  B2   │
in_block1   │  B0   │  B1   │  B2   │
in_valid    │___/   │   \___│   \___|
            │       │       │       │
in_block0_reg│      │  B0   │  B1   │
in_valid_reg │      │___/   │   \___|
            │       │       │       │
out_data    │       │       │ D0    │
out_ctrl    │       │       │ C0    │
out_valid   │       │       │___/   │
```

**注意**: `out_valid` 延迟 `in_valid` 2 个周期，与数据流水线对齐。

## 8. 错误处理

- **无效 sync**: sync 既不是 2'b01 也不是 2'b10 → 输出 Idle
- **保留 Type**: 未定义的 Type 值 → 输出 Idle
- **sync=10 但 type=00**: 保留组合 → 输出 Idle

## 9. 与下游模块接口

本模块输出送到 eth_mac_xgmii_dec。

**输出格式**:
- `out_data` = 16字节数据
- `out_ctrl` = 16位控制掩码

## 10. 参考文献

- IEEE 802.3-2018 Clause 82.2.3 (64B/66B Transmission Code)
- IEEE 802.3-2018 Figure 82-5 (64B/66B Block Formats)
- IEEE 802.3-2018 Table 82-1 (Control Codes)

## 11. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-08 | 初始版本 |
| 1.1 | 2026-04-10 | 补充Ordered Set Type值；完善解码逻辑实现 |
| 1.2 | 2026-04-10 | **重大修正**: Sync Header 位置改为 Bit 1:0；Data Block sync=01, Control Block sync=10 |
| 1.3 | 2026-04-13 | 添加流水线寄存器，正确处理 in_valid/out_valid 信号 |
