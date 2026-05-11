# eth_pcs_am_detect 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_am_detect

**功能**: 检测 4 个 lane 的对齐标记 (Alignment Marker)，建立物理 lane 到逻辑 lane 的映射，提取 BIP 用于 lane deskew，数据透传（AM 由 lane_deskew 模块删除）

**位置**: rtl/pcs/eth_pcs_am_detect.sv

## 2. 接口定义

```systemverilog
module eth_pcs_am_detect (
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

    output wire [1:0]   am_detected,
    output wire [3:0]   bip_error,
    output wire         lane_map_valid
);
```

### 2.1 信号说明

| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| lane0_block | input | 66 | 输入物理 Lane 0/2 的 66-bit 块 (交替) |
| lane1_block | input | 66 | 输入物理 Lane 1/3 的 66-bit 块 (交替) |
| in_valid | input | 1 | 输入有效 |
| in_ready | output | 1 | 接收就绪 |
| out_lane0_block | output | 66 | 输出逻辑 Lane 0/2 的 66-bit 块 (交替，含 AM) |
| out_lane1_block | output | 66 | 输出逻辑 Lane 1/3 的 66-bit 块 (交替，含 AM) |
| out_valid | output | 1 | 输出有效 |
| out_ready | input | 1 | 下游就绪 |
| am_detected | output | 2 | AM 检测指示，bit 0 对应 out_lane0，bit 1 对应 out_lane1 |
| bip_error | output | 4 | BIP 校验错误指示，每 bit 对应一个逻辑 lane |
| lane_map_valid | output | 1 | Lane 映射建立完成 |

### 2.2 数据流约定

**输入**: 物理 lane 交替输入
- 周期 N: lane0_block = 物理 Lane 0, lane1_block = 物理 Lane 1
- 周期 N+1: lane0_block = 物理 Lane 2, lane1_block = 物理 Lane 3

**输出**: 逻辑 lane 交替输出 (重排序后，含 AM)
- 周期 N: out_lane0_block = 逻辑 Lane 0, out_lane1_block = 逻辑 Lane 1
- 周期 N+1: out_lane0_block = 逻辑 Lane 2, out_lane1_block = 逻辑 Lane 3

**注意**: AM 数据正常透传，由 lane_deskew 模块在对齐后统一删除。

## 3. 功能描述

### 3.1 AM 格式 (IEEE 802.3-2018 Table 82-3)

```
66-bit AM 块:
┌────────┬────────┬────────┬────────┬────────┬────────┬────────┬────────┬────────┐
│ Sync   │   M0   │   M1   │   M2   │  BIP3  │   M4   │   M5   │   M6   │  BIP7  │
│ [1:0]  │ [9:2]  │[17:10] │[25:18] │[33:26] │[41:34] │[49:42] │[57:50] │[65:58] │
├────────┼────────┼────────┼────────┼────────┼────────┼────────┼────────┼────────┤
│  10    │  8-bit │  8-bit │  8-bit │  8-bit │ ~M0    │ ~M1    │ ~M2    │ ~BIP3  │
└────────┴────────┴────────┴────────┴────────┴────────┴────────┴────────┴────────┘

- Sync Header = 10 (control block)
- M0, M1, M2: Lane 标识符 (标识该数据属于哪个逻辑 lane)
- M4 = ~M0, M5 = ~M1, M6 = ~M2 (用于校验)
- BIP3: 8-bit 偶校验值 (从上一个 AM 到当前 AM 之间所有块的累积校验)
- BIP7 = ~BIP3
```

### 3.2 AM 标识的逻辑 Lane

| M0 | M1 | M2 | 逻辑 Lane |
|------|------|------|-----------|
| 0x90 | 0x76 | 0x47 | Lane 0 |
| 0xF0 | 0xC4 | 0xE6 | Lane 1 |
| 0xC5 | 0x65 | 0x9B | Lane 2 |
| 0xA2 | 0x79 | 0x3D | Lane 3 |

### 3.3 BIP 校验原理

**重要**: BIP 是对从上一个 AM 到当前 AM 之间的**所有数据块**计算的累积校验值，不是只对当前块计算。

本模块维护每个逻辑 lane 的 BIP 累加器：
1. 从上一个 AM 之后开始累加每个块的 BIP
2. 检测到当前 AM 时，比较累加值与 AM 中的 BIP3
3. 比较后清零累加器，开始下一轮累加

### 3.4 Lane 重排序原理

AM 中的 M0/M1/M2 标识了该物理 lane 传输的是哪个逻辑 lane 的数据：

```
示例：物理 lane 连接错位
  物理 Lane 0 收到 AM: M0=0xF0 → 逻辑 Lane 1 的数据
  物理 Lane 1 收到 AM: M0=0x90 → 逻辑 Lane 0 的数据
  物理 Lane 2 收到 AM: M0=0xA2 → 逻辑 Lane 3 的数据
  物理 Lane 3 收到 AM: M0=0xC5 → 逻辑 Lane 2 的数据

映射表:
  物理 Lane 0 → 逻辑 Lane 1
  物理 Lane 1 → 逻辑 Lane 0
  物理 Lane 2 → 逻辑 Lane 3
  物理 Lane 3 → 逻辑 Lane 2

输出时根据映射表重排序，确保输出按逻辑 Lane 0/1/2/3 顺序
```

### 3.5 AM 处理流程

```
1. 检测 AM:
   - 检查 sync_header == 2'b10
   - 匹配 M0/M1/M2 确定逻辑 lane
   - 校验 M4/M5/M6 (可选)

2. 建立映射:
   - 首次检测到各 lane 的 AM 后，建立物理 lane → 逻辑 lane 映射表
   - 所有 4 个 lane 都检测到 AM 后，lane_map_valid = 1

3. BIP 累积与校验:
   - 对每个逻辑 lane 维护独立的 BIP 累加器
   - 每个数据块计算 BIP 并累加到对应逻辑 lane 的累加器
   - 检测到 AM 时，比较累加值与 AM 中的 BIP3
   - 比较后清零累加器，开始下一轮

4. 数据透传:
   - 所有数据（包括 AM）正常透传
   - AM 由 lane_deskew 模块在对齐后统一删除

5. 数据重排序:
   - 根据 lane_map_valid 状态决定是否重排序
   - lane_map_valid = 0: 直通模式 (未建立映射)
   - lane_map_valid = 1: 根据映射表重排序
```

### 3.6 BIP 计算 (IEEE 802.3-2018 Table 82-4)

BIP3 是 8-bit 偶校验，每个 bit 对应 66-bit 块中的特定位置：

| BIP3 bit | 计算的 bit 位置 |
|----------|-----------------------------------|
| 0 | 2, 10, 18, 26, 34, 42, 50, 58 |
| 1 | 3, 11, 19, 27, 35, 43, 51, 59 |
| 2 | 4, 12, 20, 28, 36, 44, 52, 60 |
| 3 | **0**, 5, 13, 21, 29, 37, 45, 53, 61 |
| 4 | **1**, 6, 14, 22, 30, 38, 46, 54, 62 |
| 5 | 7, 15, 23, 31, 39, 47, 55, 63 |
| 6 | 8, 16, 24, 32, 40, 48, 56, 64 |
| 7 | 9, 17, 25, 33, 41, 49, 57, 65 |

**注意**: BIP3[3] 和 BIP3[4] 包含 sync header 的两个 bit（bit 0 和 bit 1）！

BIP 累加：`bip_acc_new = bip_acc_old ^ block_bip`（异或累加）

### 3.7 为什么不在本模块删除 AM

由于各 lane 存在 skew，AM 到达时间不同：
- Lane 0 的 AM 可能在周期 N 到达
- Lane 1 的 AM 可能在周期 N+2 到达
- Lane 2 的 AM 可能在周期 N+1 到达
- Lane 3 的 AM 可能在周期 N+3 到达

如果在本模块删除 AM，会导致各 lane 数据不对齐，后续处理困难。因此：
- 本模块只做检测、映射、BIP 提取、重排序
- lane_deskew 模块在对齐后统一删除 AM

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
     │物理Lane0│ │物理Lane1│ │物理Lane2│ │物理Lane3│
     │ Buffer  │ │ Buffer  │ │ Buffer  │ │ Buffer  │
     └─────────┘ └─────────┘ └─────────┘ └─────────┘
          │           │       │       │           │
          ▼           ▼       ▼       ▼           │
     ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
     │ AM      │ │ AM      │ │ AM      │ │ AM      │
     │ Detect  │ │ Detect  │ │ Detect  │ │ Detect  │
     └─────────┘ └─────────┘ └─────────┘ └─────────┘
          │           │       │       │           │
          └───────────┴───────┼───────┴───────────┘
                                │
                                ▼
                    ┌────────────────────────────────────┐
                    │       Lane 映射表 (物理→逻辑)       │
                    └────────────────────────────────────┘
                                │
                                ▼
                    ┌────────────────────────────────────┐
                    │          Lane 重排序器              │
                    │  根据映射表将物理 lane 数据重排序    │
                    └────────────────────────────────────┘
                                │
                                ▼
                    out_lane0_block, out_lane1_block
                    out_valid, am_detected, bip_lane0~3
```

### 4.2 内部 Lane 选择状态

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
reg [65:0] phy_lane_buf [0:3];

always @(posedge clk) begin
    if (!rst_n) begin
        // reset
    end else if (in_valid && in_ready) begin
        if (lane_sel == 1'b0) begin
            phy_lane_buf[0] <= lane0_block;
            phy_lane_buf[1] <= lane1_block;
        end else begin
            phy_lane_buf[2] <= lane0_block;
            phy_lane_buf[3] <= lane1_block;
        end
    end
end
```

### 4.4 AM 检测逻辑

检测每个物理 lane 的 AM，确定其对应的逻辑 lane：

```systemverilog
wire [1:0] sync_header [0:3];
wire [7:0] m0 [0:3];
wire [7:0] m1 [0:3];
wire [7:0] m2 [0:3];
wire [7:0] bip3 [0:3];

genvar i;
generate
    for (i = 0; i < 4; i = i + 1) begin : gen_am_fields
        assign sync_header[i] = phy_lane_buf[i][1:0];
        assign m0[i]          = phy_lane_buf[i][9:2];
        assign m1[i]          = phy_lane_buf[i][17:10];
        assign m2[i]          = phy_lane_buf[i][25:18];
        assign bip3[i]        = phy_lane_buf[i][33:26];
    end
endgenerate

wire [1:0] logic_lane [0:3];

assign logic_lane[0] = (m0[0] == 8'h90) ? 2'd0 :
                       (m0[0] == 8'hF0) ? 2'd1 :
                       (m0[0] == 8'hC5) ? 2'd2 : 2'd3;

assign logic_lane[1] = (m0[1] == 8'h90) ? 2'd0 :
                       (m0[1] == 8'hF0) ? 2'd1 :
                       (m0[1] == 8'hC5) ? 2'd2 : 2'd3;

assign logic_lane[2] = (m0[2] == 8'h90) ? 2'd0 :
                       (m0[2] == 8'hF0) ? 2'd1 :
                       (m0[2] == 8'hC5) ? 2'd2 : 2'd3;

assign logic_lane[3] = (m0[3] == 8'h90) ? 2'd0 :
                       (m0[3] == 8'hF0) ? 2'd1 :
                       (m0[3] == 8'hC5) ? 2'd2 : 2'd3;

wire [3:0] is_am;
assign is_am[0] = (sync_header[0] == 2'b10) && (m0[0] inside {8'h90, 8'hF0, 8'hC5, 8'hA2});
assign is_am[1] = (sync_header[1] == 2'b10) && (m0[1] inside {8'h90, 8'hF0, 8'hC5, 8'hA2});
assign is_am[2] = (sync_header[2] == 2'b10) && (m0[2] inside {8'h90, 8'hF0, 8'hC5, 8'hA2});
assign is_am[3] = (sync_header[3] == 2'b10) && (m0[3] inside {8'h90, 8'hF0, 8'hC5, 8'hA2});
```

### 4.5 BIP 累加器设计

每个逻辑 lane 维护独立的 BIP 累加器，对从上一个 AM 到当前 AM 之间的所有数据块进行累积校验：

```systemverilog
reg [7:0] bip_acc [0:3];

function automatic [7:0] calc_block_bip(input [65:0] block);
    reg [7:0] bip;
    begin
        bip[0] = ^{block[58], block[50], block[42], block[34], block[26], block[18], block[10], block[2]};
        bip[1] = ^{block[59], block[51], block[43], block[35], block[27], block[19], block[11], block[3]};
        bip[2] = ^{block[60], block[52], block[44], block[36], block[28], block[20], block[12], block[4]};
        bip[3] = ^{block[61], block[53], block[45], block[37], block[29], block[21], block[13], block[5], block[0]};
        bip[4] = ^{block[62], block[54], block[46], block[38], block[30], block[22], block[14], block[6], block[1]};
        bip[5] = ^{block[63], block[55], block[47], block[39], block[31], block[23], block[15], block[7]};
        bip[6] = ^{block[64], block[56], block[48], block[40], block[32], block[24], block[16], block[8]};
        bip[7] = ^{block[65], block[57], block[49], block[41], block[33], block[25], block[17], block[9]};
        calc_block_bip = bip;
    end
endfunction

always @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 4; i++) begin
            bip_acc[i] <= 8'h00;
        end
    end else if (in_valid && in_ready) begin
        if (lane_sel == 1'b0) begin
            if (!is_am[0]) begin
                bip_acc[logic_lane[0]] <= bip_acc[logic_lane[0]] ^ calc_block_bip(phy_lane_buf[0]);
            end
            if (!is_am[1]) begin
                bip_acc[logic_lane[1]] <= bip_acc[logic_lane[1]] ^ calc_block_bip(phy_lane_buf[1]);
            end
        end else begin
            if (!is_am[2]) begin
                bip_acc[logic_lane[2]] <= bip_acc[logic_lane[2]] ^ calc_block_bip(phy_lane_buf[2]);
            end
            if (!is_am[3]) begin
                bip_acc[logic_lane[3]] <= bip_acc[logic_lane[3]] ^ calc_block_bip(phy_lane_buf[3]);
            end
        end
    end
end
```

### 4.6 BIP 校验逻辑

检测到 AM 时，比较累加值与 AM 中的 BIP3：

```systemverilog
reg [3:0] bip_error_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        bip_error_reg <= 4'b0000;
    end else if (in_valid && in_ready) begin
        if (lane_sel == 1'b0) begin
            if (is_am[0]) begin
                bip_error_reg[0] <= (bip3[0] != bip_acc[logic_lane[0]]);
                bip_acc[logic_lane[0]] <= 8'h00;
            end
            if (is_am[1]) begin
                bip_error_reg[1] <= (bip3[1] != bip_acc[logic_lane[1]]);
                bip_acc[logic_lane[1]] <= 8'h00;
            end
        end else begin
            if (is_am[2]) begin
                bip_error_reg[2] <= (bip3[2] != bip_acc[logic_lane[2]]);
                bip_acc[logic_lane[2]] <= 8'h00;
            end
            if (is_am[3]) begin
                bip_error_reg[3] <= (bip3[3] != bip_acc[logic_lane[3]]);
                bip_acc[logic_lane[3]] <= 8'h00;
            end
        end
    end
end

assign bip_error = bip_error_reg;
```

### 4.7 Lane 映射表

```systemverilog
reg [1:0] lane_map [0:3];
reg [3:0] lane_map_done;
reg       lane_map_valid_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        lane_map[0] <= 2'd0;
        lane_map[1] <= 2'd1;
        lane_map[2] <= 2'd2;
        lane_map[3] <= 2'd3;
        lane_map_done <= 4'b0000;
        lane_map_valid_reg <= 1'b0;
    end else begin
        for (int i = 0; i < 4; i++) begin
            if (is_am[i] && !lane_map_done[i]) begin
                lane_map[i] <= logic_lane[i];
                lane_map_done[i] <= 1'b1;
            end
        end
        if (lane_map_done == 4'b1111) begin
            lane_map_valid_reg <= 1'b1;
        end
    end
end

assign lane_map_valid = lane_map_valid_reg;
```

### 4.8 AM 检测输出

`am_detected` 信号直接输出，无寄存器延迟，确保 lane_deskew 模块能正确记录 AM 位置：

```systemverilog
wire [1:0] am_detected_comb;

assign am_detected_comb[0] = (out_lane_sel == 1'b0) ? is_am[phy_lane_of[0]] : is_am[phy_lane_of[2]];
assign am_detected_comb[1] = (out_lane_sel == 1'b0) ? is_am[phy_lane_of[1]] : is_am[phy_lane_of[3]];

assign am_detected = am_detected_comb;
```

**说明**:
- `am_detected[0]` = 1 表示 `out_lane0_block` 是 AM 块
- `am_detected[1]` = 1 表示 `out_lane1_block` 是 AM 块
- 输出与数据同步，无延迟，下游模块可直接使用

### 4.9 Lane 重排序逻辑

根据映射表将物理 lane 数据重排序到逻辑 lane。

**映射表含义**: `lane_map[phy_lane] = logic_lane` 表示物理 lane `phy_lane` 对应逻辑 lane `logic_lane`。

**逆映射**: 为了高效重排序，需要建立逆映射 `phy_lane_of[logic_lane]`，表示逻辑 lane `logic_lane` 对应哪个物理 lane。

```systemverilog
reg [1:0] phy_lane_of [0:3];

always @(*) begin
    for (int logic = 0; logic < 4; logic++) begin
        for (int phy = 0; phy < 4; phy++) begin
            if (lane_map[phy] == logic) begin
                phy_lane_of[logic] = phy;
            end
        end
    end
end

wire [65:0] logic_lane_buf [0:3];

assign logic_lane_buf[0] = phy_lane_buf[phy_lane_of[0]];
assign logic_lane_buf[1] = phy_lane_buf[phy_lane_of[1]];
assign logic_lane_buf[2] = phy_lane_buf[phy_lane_of[2]];
assign logic_lane_buf[3] = phy_lane_buf[phy_lane_of[3]];
```

### 4.10 输出逻辑

数据透传（包括 AM）：

```systemverilog
reg out_lane_sel;

always @(posedge clk) begin
    if (!rst_n) begin
        out_lane_sel <= 1'b0;
    end else if (out_valid && out_ready) begin
        out_lane_sel <= ~out_lane_sel;
    end
end

assign out_lane0_block = (out_lane_sel == 1'b0) ? logic_lane_buf[0] : logic_lane_buf[2];
assign out_lane1_block = (out_lane_sel == 1'b0) ? logic_lane_buf[1] : logic_lane_buf[3];
assign out_valid = in_valid;
assign in_ready = out_ready;
```

## 5. 时序图

### 5.1 正常数据流 (无 AM)

```
clk:             |  0  |  1  |  2  |  3  |  4  |  5  |
                 |     |     |     |     |     |     |
lane_sel(内部):  |  0  |  1  |  0  |  1  |  0  |  1  |
                 |     |     |     |     |     |     |
lane0_block(物理):| D0  | D2  | D4  | D6  | D8  | D10 |
lane1_block(物理):| D1  | D3  | D5  | D7  | D9  | D11 |
in_valid:        |  1  |  1  |  1  |  1  |  1  |  1  |
                 |     |     |     |     |     |     |
is_am:           |  0  |  0  |  0  |  0  |  0  |  0  |
                 |     |     |     |     |     |     |
out_lane0_block: | D0  | D2  | D4  | D6  | D8  | D10 |
out_lane1_block: | D1  | D3  | D5  | D7  | D9  | D11 |
out_valid:       |  1  |  1  |  1  |  1  |  1  |  1  |
```

### 5.2 AM 检测与透传

```
clk:             |  0  |  1  |  2  |  3  |  4  |  5  |
                 |     |     |     |     |     |     |
lane_sel(内部):  |  0  |  1  |  0  |  1  |  0  |  1  |
                 |     |     |     |     |     |     |
lane0_block(物理):| AM0 | D2  | D4  | D6  | AM0 | D10 |
lane1_block(物理):| D1  | AM3 | D5  | D7  | D9  | AM3 |
in_valid:        |  1  |  1  |  1  |  1  |  1  |  1  |
                 |     |     |     |     |     |     |
is_am[1:0]:      | 01  | 00  | 00  | 00  | 01  | 00  |
is_am[3:2]:      | 00  | 10  | 00  | 00  | 00  | 10  |
                 |     |     |     |     |     |     |
am_detected:     | 01  | 10  | 00  | 00  | 01  | 10  |
                 |     |     |     |     |     |     |
out_lane0_block: | AM0 | D2  | D4  | D6  | AM0 | D10 |
out_lane1_block: | D1  | AM3 | D5  | D7  | D9  | AM3 |
out_valid:       |  1  |  1  |  1  |  1  |  1  |  1  |
```

**注意**: 
- `am_detected` 为 2-bit，bit 0 对应 out_lane0，bit 1 对应 out_lane1
- AM 正常透传，由 lane_deskew 模块在对齐后统一删除

### 5.3 Lane 重排序示例

假设物理 lane 连接错位：
- 物理 Lane 0 → 逻辑 Lane 1
- 物理 Lane 1 → 逻辑 Lane 0
- 物理 Lane 2 → 逻辑 Lane 3
- 物理 Lane 3 → 逻辑 Lane 2

```
AM 检测后建立映射:
  lane_map[0] = 1 (物理 Lane 0 对应逻辑 Lane 1)
  lane_map[1] = 0 (物理 Lane 1 对应逻辑 Lane 0)
  lane_map[2] = 3 (物理 Lane 2 对应逻辑 Lane 3)
  lane_map[3] = 2 (物理 Lane 3 对应逻辑 Lane 2)

数据重排序:
  物理 Lane 0 的数据 → 逻辑 Lane 1 的输出位置
  物理 Lane 1 的数据 → 逻辑 Lane 0 的输出位置
  物理 Lane 2 的数据 → 逻辑 Lane 3 的输出位置
  物理 Lane 3 的数据 → 逻辑 Lane 2 的输出位置
```

## 6. 参数配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| AM_CHECK_M456 | 1 | 是否校验 M4/M5/M6 (0=不校验, 1=校验) |

## 7. 与其他模块的关系

```
eth_pcs_block_sync → eth_pcs_am_detect → eth_pcs_lane_deskew
         │                   │
         │                   ▼
         │            检测 AM (不删除)
         │            建立物理→逻辑 lane 映射
         │            提取 BIP 用于 deskew
         │            数据重排序
         │            AM 透传给 lane_deskew
         │
         └── block_lock[3:0] (用于状态指示)
```

## 8. 资源估算

| 资源 | 估算值 | 说明 |
|------|--------|------|
| FF | ~300 | 4 个 lane 的 buffer + 映射表 + 检测逻辑 |
| LUT | ~250 | AM 匹配 + 重排序逻辑 |

## 9. 测试要点

| 测试项 | 说明 |
|--------|------|
| AM 检测 | 验证正确检测各物理 lane 的 AM |
| Lane 映射 | 验证正确建立物理 lane → 逻辑 lane 映射 |
| 数据重排序 | 验证数据按逻辑 lane 顺序输出 |
| BIP 提取 | 验证正确提取各逻辑 lane 的 BIP 值 |
| AM 透传 | 验证 AM 正常透传，不被删除 |
| 数据透传 | 验证所有数据正确传递 |
| 反压处理 | 验证 out_ready=0 时数据不丢失 |
| 复位行为 | 验证复位后状态正确 |

## 10. 参考文献

- IEEE 802.3-2018 Clause 82.2.8 (Alignment Marker Detection)
- IEEE 802.3-2018 Table 82-3 (40GBASE-R Alignment Marker Encodings)

## 11. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-10 | 初始版本 |
| 2.0 | 2026-04-10 | 添加 Lane 重排序功能，AM 移除时 out_valid=0 |
| 3.0 | 2026-04-10 | 移除 AM 删除功能，AM 透传给 lane_deskew 模块处理 |
| 4.0 | 2026-04-13 | **重大修正**: (1) BIP 改为累积校验，维护累加器；(2) 修正 Lane 重排序逻辑；(3) am_detected 改为组合逻辑输出，无延迟 |
| 4.1 | 2026-04-13 | 简化 am_detected 为 2-bit 输出，直接对应 out_lane0/1 |
