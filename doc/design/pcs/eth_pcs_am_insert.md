# eth_pcs_am_insert 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_am_insert

**功能**: 块计数与对齐标记 (Alignment Marker) 插入指示

**位置**: rtl/pcs/eth_pcs_am_insert.sv

## 2. 接口定义

```systemverilog
module eth_pcs_am_insert (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [65:0]           in_block0,
    input  wire [65:0]           in_block1,
    input  wire                  in_valid,
    output wire                  in_ready,

    output wire [65:0]           out_block0,
    output wire [65:0]           out_block1,
    output wire                  out_valid,
    input  wire                  out_ready,

    output wire                  am_insert
);
```

### 2.1 信号说明

**输入**:
- `in_block0[65:0]`: 第一个 66-bit 块
- `in_block1[65:0]`: 第二个 66-bit 块
- `in_valid`: 块有效
- `in_ready`: 上游就绪

**输出**:
- `out_block0[65:0]`: 第一个 66-bit 块
- `out_block1[65:0]`: 第二个 66-bit 块
- `out_valid`: 块有效
- `out_ready`: 下游就绪
- `am_insert`: AM 插入指示（高电平表示下一周期需要插入 AM）

## 3. 功能描述

### 3.1 设计策略

AM 插入分为两个模块完成：

1. **eth_pcs_am_insert**: 块计数 + AM 插入指示
2. **eth_pcs_lane_dist**: 根据 `am_insert` 信号插入对应 lane 的 AM，计算 BIP，处理反压

**原因**:
- 每个 lane 需要插入不同的 AM 值
- 每个 lane 需要独立计算 BIP
- `eth_pcs_lane_dist` 模块知道当前输出到哪个 lane
- 反压由 `eth_pcs_lane_dist` 处理，通过 `out_ready` 信号传递

### 3.2 AM 插入规则

根据 IEEE 802.3-2018 Clause 82.2.7:

- **每个 lane 独立计数**: 每 **16383** 个数据块后插入一次 AM
- **4 个 lane 同步插入**: 在同一时刻插入
- **插入位置**: AM 替换数据/控制块，必要时删除 IPG

### 3.3 计数逻辑

**lane 分布关系**:
```
每周期输入: 2 个 66-bit 块
lane 分布: 
  - 周期 N:   block0 → lane0, block1 → lane1
  - 周期 N+1: block0 → lane2, block1 → lane3
  - 周期 N+2: block0 → lane0, block1 → lane1
  - ...

每 2 个周期: 4 个 lane 各得到 1 个块
```

**计数计算**:
- 每个 lane 每 16383 个数据块后插入一次 AM
- 每 2 个周期，4 个 lane 各得到 1 个块
- 所以每 16383 × 4 = 65532 个输入块后，每个 lane 都收到了 16383 个块
- 此时应该插入 AM

**计数器**:
- 16-bit 计数器
- 范围：0 ~ 65531
- 每周期 +2（处理 2 个块）
- 计数到 65530 时，下一周期插入 AM（`am_insert = 1`）

## 4. 详细设计

### 4.1 块计数器

```systemverilog
reg [15:0] block_cnt;

always @(posedge clk) begin
    if (!rst_n) begin
        block_cnt <= 16'h0;
    end else if (in_valid && out_ready) begin
        if (block_cnt >= 16'd65530) begin
            block_cnt <= 16'h0;
        end else begin
            block_cnt <= block_cnt + 16'd2;
        end
    end
end
```

### 4.2 AM 插入指示

```systemverilog
assign am_insert = (block_cnt == 16'd65530) && in_valid && out_ready;
```

### 4.3 数据直通

```systemverilog
assign out_block0 = in_block0;
assign out_block1 = in_block1;
assign out_valid  = in_valid;
assign in_ready   = out_ready;
```

## 5. 完整实现

```systemverilog
module eth_pcs_am_insert (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [65:0]           in_block0,
    input  wire [65:0]           in_block1,
    input  wire                  in_valid,
    output wire                  in_ready,

    output wire [65:0]           out_block0,
    output wire [65:0]           out_block1,
    output wire                  out_valid,
    input  wire                  out_ready,

    output wire                  am_insert
);

    reg [15:0] block_cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            block_cnt <= 16'h0;
        end else if (in_valid && out_ready) begin
            if (block_cnt >= 16'd65530) begin
                block_cnt <= 16'h0;
            end else begin
                block_cnt <= block_cnt + 16'd2;
            end
        end
    end

    assign am_insert = (block_cnt == 16'd65530) && in_valid && out_ready;

    assign out_block0 = in_block0;
    assign out_block1 = in_block1;
    assign out_valid  = in_valid;
    assign in_ready   = out_ready;

endmodule
```

## 6. 与 lane_dist 的配合

### 6.1 反压处理

`eth_pcs_lane_dist` 模块接收 `am_insert=1` 后：

1. 拉低 `out_ready`，反压传递到上游
2. 在 2 个周期内输出 4 个 lane 的 AM
3. 恢复 `out_ready`，继续正常数据分发

### 6.2 时序示例

```
周期:        |  N    | N+1   | N+2   | N+3   | N+4   |
             |       |       |       |       |       |
block_cnt:   | 65528 | 65530 |   0   |   2   |   4   |
             |       |       |       |       |       |
am_insert:   |   0   |   1   |   0   |   0   |   0   |
             |       |       |       |       |       |
out_ready:   |   1   |   1   |   0   |   0   |   1   |  ← lane_dist 反压
             |       |       |       |       |       |
in_block0:   | D0    | D2    | D2    | D2    | D4    |
in_block1:   | D1    | D3    | D3    | D3    | D5    |
             |       |       |       |       |       |
lane_dist:   |       |       |       |       |       |
  output:    | D0→L0 | D2→L0 | AM_L0 | AM_L2 | D4→L0 |
             | D1→L1 | D3→L1 | AM_L1 | AM_L3 | D5→L1 |
```

## 7. 流水线

本模块为直通模式，无流水线延迟。

## 8. 数据流位置

```
TX: eth_pcs_64b66b_enc → eth_pcs_scrambler → eth_pcs_am_insert → eth_pcs_lane_dist
```

## 9. 参考文献

- IEEE 802.3-2018 Clause 82.2.6 (Block Distribution)
- IEEE 802.3-2018 Clause 82.2.7 (Alignment Marker Insertion)

## 10. 参考文献

- IEEE 802.3-2018 Clause 82.2.6 (Block Distribution)
- IEEE 802.3-2018 Clause 82.2.7 (Alignment Marker Insertion)

## 11. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-10 | 初始版本 |
| 1.1 | 2026-04-10 | 修正计数器为16-bit，计数范围0~65535 |
| 1.2 | 2026-04-10 | 修正AM插入周期为16383（IEEE 802.3-2018），移除BIP计算（移至lane_dist） |
| 1.3 | 2026-04-10 | 添加66-bit块格式说明（Sync Header位于Bit 1:0） |
