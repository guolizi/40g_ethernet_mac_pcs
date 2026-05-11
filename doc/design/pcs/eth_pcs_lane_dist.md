# eth_pcs_lane_dist 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_lane_dist

**功能**: Lane 分布，将 66-bit 块流分发到 4 个 lane，处理 AM 插入，计算 BIP

**位置**: rtl/pcs/eth_pcs_lane_dist.sv

## 2. 接口定义

```systemverilog
module eth_pcs_lane_dist (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [65:0]           in_block0,
    input  wire [65:0]           in_block1,
    input  wire                  in_valid,
    output wire                  in_ready,

    input  wire                  am_insert,

    output wire [65:0]           lane0_block,
    output wire [65:0]           lane1_block,
    output wire                  lane_valid,
    input  wire                  lane_ready
);
```

### 2.1 信号说明

**输入**:
- `in_block0[65:0]`: 第一个 66-bit 块
- `in_block1[65:0]`: 第二个 66-bit 块
- `in_valid`: 块有效
- `in_ready`: 上游就绪
- `am_insert`: AM 插入指示（高电平表示需要插入 AM）

**输出**:
- `lane0_block[65:0]`: Lane 0/2 的 66-bit 块
- `lane1_block[65:0]`: Lane 1/3 的 66-bit 块
- `lane_valid`: 块有效
- `lane_ready`: 下游就绪

> 注：每周期输出 2 个 lane 的数据，Lane 2 和 Lane 3 在下一周期输出。

## 3. 功能描述

### 3.1 Lane 分布规则

每周期输入 2 个 66-bit 块，分发到 4 个 lane：

```
周期 N:   block0 → Lane 0,  block1 → Lane 1
周期 N+1: block0 → Lane 2,  block1 → Lane 3
周期 N+2: block0 → Lane 0,  block1 → Lane 1
...
```

### 3.2 输出格式

每周期输出 2 个 lane 的数据：

```
周期 N:   输出 Lane 0 和 Lane 1
周期 N+1: 输出 Lane 2 和 Lane 3
周期 N+2: 输出 Lane 0 和 Lane 1
...
```

### 3.3 AM 插入

当 `am_insert = 1` 时：

1. 暂停接收上游数据（拉低 `in_ready`）
2. 在 2 个周期内输出 4 个 lane 的 AM
3. 恢复正常数据分发

### 3.4 BIP 计算

每个 lane 独立计算 BIP-3（8-bit 偶校验），计算范围是从上一个 AM 到当前 AM 之间的所有数据块（不含 AM）。

## 4. 详细设计

### 4.1 AM 值定义（IEEE 802.3-2018 Table 82-3）

**40GBASE-R AM 格式** (66-bit):

```
Bit 0-1:   Sync Header = 10 (control block)
Bit 2-9:   M0
Bit 10-17: M1
Bit 18-25: M2
Bit 26-33: BIP3
Bit 34-41: M4 (= ~M0)
Bit 42-49: M5 (= ~M1)
Bit 50-57: M6 (= ~M2)
Bit 58-65: BIP7 (= ~BIP3)
```

**AM 值表**:

| Lane | M0 | M1 | M2 | M4 | M5 | M6 |
|------|------|------|------|------|------|------|
| 0 | 0x90 | 0x76 | 0x47 | 0x6F | 0x89 | 0xB8 |
| 1 | 0xF0 | 0xC4 | 0xE6 | 0x0F | 0x3B | 0x19 |
| 2 | 0xC5 | 0x65 | 0x9B | 0x3A | 0x9A | 0x64 |
| 3 | 0xA2 | 0x79 | 0x3D | 0x5D | 0x86 | 0xC2 |

**AM 构造**（以 Lane 0 为例）:
```
sync_header = 2'b10
M0 = 0x90, M1 = 0x76, M2 = 0x47
BIP3 = 动态计算值
M4 = ~M0 = 0x6F, M5 = ~M1 = 0x89, M6 = ~M2 = 0xB8
BIP7 = ~BIP3
```

### 4.2 BIP 计算规则（IEEE 802.3-2018 Table 82-4）

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

### 4.3 BIP 计算实现

```systemverilog
function automatic [7:0] calc_bip(input [65:0] block, input [7:0] bip_acc_in);
    reg [7:0] bip_new;
    begin
        bip_new[0] = ^{block[58], block[50], block[42], block[34], block[26], block[18], block[10], block[2]};
        bip_new[1] = ^{block[59], block[51], block[43], block[35], block[27], block[19], block[11], block[3]};
        bip_new[2] = ^{block[60], block[52], block[44], block[36], block[28], block[20], block[12], block[4]};
        bip_new[3] = ^{block[61], block[53], block[45], block[37], block[29], block[21], block[13], block[5], block[0]};
        bip_new[4] = ^{block[62], block[54], block[46], block[38], block[30], block[22], block[14], block[6], block[1]};
        bip_new[5] = ^{block[63], block[55], block[47], block[39], block[31], block[23], block[15], block[7]};
        bip_new[6] = ^{block[64], block[56], block[48], block[40], block[32], block[24], block[16], block[8]};
        bip_new[7] = ^{block[65], block[57], block[49], block[41], block[33], block[25], block[17], block[9]};
        calc_bip = bip_acc_in ^ bip_new;
    end
endfunction
```

### 4.4 Lane 选择计数器

```systemverilog
reg lane_sel;

always @(posedge clk) begin
    if (!rst_n) begin
        lane_sel <= 1'b0;
    end else if (lane_valid && lane_ready && state == NORMAL) begin
        lane_sel <= ~lane_sel;
    end
end
```

### 4.5 AM 插入状态机

```systemverilog
typedef enum logic [1:0] {
    NORMAL,      
    AM_INSERT_0, 
    AM_INSERT_1  
} state_t;

reg [1:0] state;

always @(posedge clk) begin
    if (!rst_n) begin
        state <= NORMAL;
    end else begin
        case (state)
            NORMAL: begin
                if (am_insert && in_valid && lane_ready) begin
                    state <= AM_INSERT_0;
                end
            end
            AM_INSERT_0: begin
                if (lane_ready) begin
                    state <= AM_INSERT_1;
                end
            end
            AM_INSERT_1: begin
                if (lane_ready) begin
                    state <= NORMAL;
                end
            end
            default: state <= NORMAL;
        endcase
    end
end
```

### 4.6 BIP 累加器

每个 lane 独立的 BIP 累加器：

```systemverilog
reg [7:0] bip_acc [0:3];

always @(posedge clk) begin
    if (!rst_n) begin
        bip_acc[0] <= 8'h00;
        bip_acc[1] <= 8'h00;
        bip_acc[2] <= 8'h00;
        bip_acc[3] <= 8'h00;
    end else if (in_valid && in_ready && state == NORMAL) begin
        if (lane_sel == 1'b0) begin
            bip_acc[0] <= calc_bip(in_block0, bip_acc[0]);
            bip_acc[1] <= calc_bip(in_block1, bip_acc[1]);
        end else begin
            bip_acc[2] <= calc_bip(in_block0, bip_acc[2]);
            bip_acc[3] <= calc_bip(in_block1, bip_acc[3]);
        end
    end else if (state == AM_INSERT_1 && lane_ready) begin
        bip_acc[0] <= 8'h00;
        bip_acc[1] <= 8'h00;
        bip_acc[2] <= 8'h00;
        bip_acc[3] <= 8'h00;
    end
end
```

### 4.7 AM 构造函数

```systemverilog
function automatic [65:0] build_am(input [1:0] lane_num, input [7:0] bip3);
    reg [7:0] m0, m1, m2;
    reg [7:0] m4, m5, m6;
    begin
        case (lane_num)
            2'd0: begin m0 = 8'h90; m1 = 8'h76; m2 = 8'h47; end
            2'd1: begin m0 = 8'hF0; m1 = 8'hC4; m2 = 8'hE6; end
            2'd2: begin m0 = 8'hC5; m1 = 8'h65; m2 = 8'h9B; end
            2'd3: begin m0 = 8'hA2; m1 = 8'h79; m2 = 8'h3D; end
        endcase
        m4 = ~m0;
        m5 = ~m1;
        m6 = ~m2;
        
        build_am = {~bip3, m6, m5, m4, bip3, m2, m1, m0, 2'b10};
    end
endfunction
```

## 5. 完整实现

```systemverilog
module eth_pcs_lane_dist (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [65:0]           in_block0,
    input  wire [65:0]           in_block1,
    input  wire                  in_valid,
    output wire                  in_ready,

    input  wire                  am_insert,

    output wire [65:0]           lane0_block,
    output wire [65:0]           lane1_block,
    output wire                  lane_valid,
    input  wire                  lane_ready
);

    typedef enum logic [1:0] {
        NORMAL,      
        AM_INSERT_0, 
        AM_INSERT_1  
    } state_t;

    reg [1:0] state;
    reg       lane_sel;
    reg [7:0] bip_acc [0:3];

    function automatic [7:0] calc_bip(input [65:0] block, input [7:0] bip_acc_in);
        reg [7:0] bip_new;
        begin
            bip_new[0] = ^{block[58], block[50], block[42], block[34], block[26], block[18], block[10], block[2]};
            bip_new[1] = ^{block[59], block[51], block[43], block[35], block[27], block[19], block[11], block[3]};
            bip_new[2] = ^{block[60], block[52], block[44], block[36], block[28], block[20], block[12], block[4]};
            bip_new[3] = ^{block[61], block[53], block[45], block[37], block[29], block[21], block[13], block[5], block[0]};
            bip_new[4] = ^{block[62], block[54], block[46], block[38], block[30], block[22], block[14], block[6], block[1]};
            bip_new[5] = ^{block[63], block[55], block[47], block[39], block[31], block[23], block[15], block[7]};
            bip_new[6] = ^{block[64], block[56], block[48], block[40], block[32], block[24], block[16], block[8]};
            bip_new[7] = ^{block[65], block[57], block[49], block[41], block[33], block[25], block[17], block[9]};
            calc_bip = bip_acc_in ^ bip_new;
        end
    endfunction

    function automatic [65:0] build_am(input [1:0] lane_num, input [7:0] bip3);
        reg [7:0] m0, m1, m2;
        reg [7:0] m4, m5, m6;
        begin
            case (lane_num)
                2'd0: begin m0 = 8'h90; m1 = 8'h76; m2 = 8'h47; end
                2'd1: begin m0 = 8'hF0; m1 = 8'hC4; m2 = 8'hE6; end
                2'd2: begin m0 = 8'hC5; m1 = 8'h65; m2 = 8'h9B; end
                2'd3: begin m0 = 8'hA2; m1 = 8'h79; m2 = 8'h3D; end
            endcase
            m4 = ~m0;
            m5 = ~m1;
            m6 = ~m2;
            build_am = {~bip3, m6, m5, m4, bip3, m2, m1, m0, 2'b10};
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= NORMAL;
        end else begin
            case (state)
                NORMAL: begin
                    if (am_insert && in_valid && lane_ready) begin
                        state <= AM_INSERT_0;
                    end
                end
                AM_INSERT_0: begin
                    if (lane_ready) begin
                        state <= AM_INSERT_1;
                    end
                end
                AM_INSERT_1: begin
                    if (lane_ready) begin
                        state <= NORMAL;
                    end
                end
                default: state <= NORMAL;
            endcase
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            lane_sel <= 1'b0;
        end else if (state == NORMAL && lane_valid && lane_ready) begin
            lane_sel <= ~lane_sel;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            bip_acc[0] <= 8'h00;
            bip_acc[1] <= 8'h00;
            bip_acc[2] <= 8'h00;
            bip_acc[3] <= 8'h00;
        end else if (state == NORMAL && in_valid && lane_ready) begin
            if (lane_sel == 1'b0) begin
                bip_acc[0] <= calc_bip(in_block0, bip_acc[0]);
                bip_acc[1] <= calc_bip(in_block1, bip_acc[1]);
            end else begin
                bip_acc[2] <= calc_bip(in_block0, bip_acc[2]);
                bip_acc[3] <= calc_bip(in_block1, bip_acc[3]);
            end
        end else if (state == AM_INSERT_1 && lane_ready) begin
            bip_acc[0] <= 8'h00;
            bip_acc[1] <= 8'h00;
            bip_acc[2] <= 8'h00;
            bip_acc[3] <= 8'h00;
        end
    end

    reg [65:0] lane0_block_reg;
    reg [65:0] lane1_block_reg;

    always @(*) begin
        case (state)
            NORMAL: begin
                lane0_block_reg = in_block0;
                lane1_block_reg = in_block1;
            end
            AM_INSERT_0: begin
                lane0_block_reg = build_am(2'd0, bip_acc[0]);
                lane1_block_reg = build_am(2'd1, bip_acc[1]);
            end
            AM_INSERT_1: begin
                lane0_block_reg = build_am(2'd2, bip_acc[2]);
                lane1_block_reg = build_am(2'd3, bip_acc[3]);
            end
            default: begin
                lane0_block_reg = 66'h0;
                lane1_block_reg = 66'h0;
            end
        endcase
    end

    assign lane0_block = lane0_block_reg;
    assign lane1_block = lane1_block_reg;

    assign lane_valid = (state == NORMAL) ? in_valid : 1'b1;
    assign in_ready   = (state == NORMAL) ? lane_ready : 1'b0;

endmodule
```

## 6. 时序图

### 6.1 正常数据分发

```
周期:        |   N   |  N+1  |  N+2  |  N+3  |
             |       |       |       |       |
lane_sel:    |   0   |   1   |   0   |   1   |
             |       |       |       |       |
in_block0:   |  D0   |  D2   |  D4   |  D6   |
in_block1:   |  D1   |  D3   |  D5   |  D7   |
             |       |       |       |       |
lane0_block: |  D0   |  D2   |  D4   |  D6   | → Lane 0/2
lane1_block: |  D1   |  D3   |  D5   |  D7   | → Lane 1/3
             |       |       |       |       |
输出:        | L0,L1 | L2,L3 | L0,L1 | L2,L3 |
```

### 6.2 AM 插入

```
周期:        |   N   |  N+1  |  N+2  |  N+3  |  N+4  |
             |       |       |       |       |       |
am_insert:   |   0   |   1   |   0   |   0   |   0   |
             |       |       |       |       |       |
state:       |NORMAL |NORMAL |AM_INS0|AM_INS1|NORMAL |
             |       |       |       |       |       |
in_ready:    |   1   |   1   |   0   |   0   |   1   |
             |       |       |       |       |       |
in_block0:   |  D0   |  D2   |  D2   |  D2   |  D4   |
in_block1:   |  D1   |  D3   |  D3   |  D3   |  D5   |
             |       |       |       |       |       |
lane0_block: |  D0   |  D2   | AM_L0 | AM_L2 |  D4   |
lane1_block: |  D1   |  D3   | AM_L1 | AM_L3 |  D5   |
             |       |       |       |       |       |
输出:        | L0,L1 | L2,L3 | L0,L1 | L2,L3 | L0,L1 |
             |       |       |       |       |       |
BIP计算:     | 累加  | 累加  | 使用  | 使用  | 清零  |
```

## 7. 数据流位置

```
TX: eth_pcs_am_insert → eth_pcs_lane_dist → eth_pcs_gearbox_tx
```

## 8. 参考文献

- IEEE 802.3-2018 Clause 82.2.6 (Block Distribution)
- IEEE 802.3-2018 Clause 82.2.7 (Alignment Marker Insertion)
- IEEE 802.3-2018 Clause 82.2.8 (BIP Calculations)
- IEEE 802.3-2018 Table 82-3 (40GBASE-R Alignment Marker Encodings)
- IEEE 802.3-2018 Table 82-4 (BIP3 Bit Assignments)

## 9. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-10 | 初始版本 |
| 1.1 | 2026-04-10 | 添加 BIP 计算，更新 AM 值（IEEE 802.3-2018 Table 82-3） |
| 1.2 | 2026-04-10 | 确认 Sync Header 位于 Bit 1:0，AM 格式正确 |
