# eth_pcs_tx 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_tx

**功能**: PCS TX 路径顶层模块，集成 64B/66B 编码、加扰、AM 插入、Lane 分布、Gearbox 等子模块

**位置**: rtl/pcs/eth_pcs_tx.sv

## 2. 接口定义

```systemverilog
module eth_pcs_tx (
    input  wire         clk_core,
    input  wire         rst_n_core,

    input  wire [127:0] mac_tx_data,
    input  wire [15:0]  mac_tx_ctrl,
    input  wire         mac_tx_valid,
    output wire         mac_tx_ready,

    input  wire         clk_pma,
    input  wire         rst_n_pma,

    output wire [31:0]  lane0_tx_data,
    output wire [31:0]  lane1_tx_data,
    output wire [31:0]  lane2_tx_data,
    output wire [31:0]  lane3_tx_data,
    output wire         tx_valid,
    input  wire         tx_ready
);
```

### 2.1 信号说明

**clk_core 域 (MAC 接口)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| mac_tx_data | input | 128 | XLGMII 数据 (字节0-15) |
| mac_tx_ctrl | input | 16 | XLGMII 控制掩码 (bit[i]=1 表示字节i是控制字符) |
| mac_tx_valid | input | 1 | 数据有效 |
| mac_tx_ready | output | 1 | PCS 就绪 |

**clk_pma 域 (PMA 接口)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| lane0_tx_data | output | 32 | Lane 0 的 32-bit 输出 |
| lane1_tx_data | output | 32 | Lane 1 的 32-bit 输出 |
| lane2_tx_data | output | 32 | Lane 2 的 32-bit 输出 |
| lane3_tx_data | output | 32 | Lane 3 的 32-bit 输出 |
| tx_valid | output | 1 | 数据有效 |
| tx_ready | input | 1 | PMA 就绪 |

### 2.2 时钟频率

| 时钟 | 频率 | 说明 |
|------|------|------|
| clk_core | 312.5 MHz | MAC/PCS 核心时钟 |
| clk_pma | 322.266 MHz | PMA 接口时钟 |

## 3. 功能描述

### 3.1 TX 数据流

```
MAC (XLGMII 格式)
    │
    │ 128-bit data + 16-bit ctrl
    ▼
┌─────────────────────┐
│  eth_pcs_64b66b_enc │  64B/66B 编码
└─────────────────────┘
    │
    │ 2×66-bit blocks
    ▼
┌─────────────────────┐
│  eth_pcs_scrambler  │  自同步加扰
└─────────────────────┘
    │
    │ 2×66-bit blocks
    ▼
┌─────────────────────┐
│  eth_pcs_am_insert  │  AM 插入指示
└─────────────────────┘
    │
    │ 2×66-bit blocks + am_insert
    ▼
┌─────────────────────┐
│  eth_pcs_lane_dist  │  Lane 分布 + BIP 计算
└─────────────────────┘
    │
    │ 2×66-bit blocks (交替: L0/L1, L2/L3)
    ▼
┌─────────────────────┐
│  eth_pcs_gearbox_tx │  66-bit → 32-bit + CDC
└─────────────────────┘
    │
    │ 4×32-bit @ clk_pma
    ▼
PMA
```

### 3.2 各子模块功能

| 子模块 | 功能 | 时钟域 |
|--------|------|--------|
| eth_pcs_64b66b_enc | 128-bit data/ctrl → 2×66-bit 块编码 | clk_core |
| eth_pcs_scrambler | 64-bit payload 加扰 (sync 不加扰) | clk_core |
| eth_pcs_am_insert | 块计数，每 16383 块插入 AM 指示 | clk_core |
| eth_pcs_lane_dist | 分发到 4 个 lane，插入 AM，计算 BIP | clk_core |
| eth_pcs_gearbox_tx | 66-bit → 32-bit 转换 + CDC | clk_core → clk_pma |

### 3.3 数据流位宽与时序

```
clk_core 域:
  - 输入: 128-bit data + 16-bit ctrl @ 每周期
  - 编码: 2×66-bit blocks @ 每周期
  - Lane 分布: 每 2 周期输出 4 个 lane 的 66-bit 块
    - 周期 N: lane0_block = Lane 0, lane1_block = Lane 1
    - 周期 N+1: lane0_block = Lane 2, lane1_block = Lane 3

clk_pma 域:
  - 输出: 4×32-bit @ 每周期
  - 每 33 个 clk_pma 周期对应 16 个 66-bit 块
```

### 3.4 AM 插入机制

```
1. eth_pcs_am_insert 模块计数块数
2. 每 16383 个块 (每个 lane) 后，am_insert = 1
3. eth_pcs_lane_dist 模块收到 am_insert 后:
   - 暂停接收上游数据 (拉低 in_ready)
   - 在 2 个周期内输出 4 个 lane 的 AM
   - 每个 lane 的 AM 包含独立的 BIP 值
   - 恢复正常数据分发
```

## 4. 详细设计

### 4.1 模块实例化

```systemverilog
module eth_pcs_tx (
    input  wire         clk_core,
    input  wire         rst_n_core,

    input  wire [127:0] mac_tx_data,
    input  wire [15:0]  mac_tx_ctrl,
    input  wire         mac_tx_valid,
    output wire         mac_tx_ready,

    input  wire         clk_pma,
    input  wire         rst_n_pma,

    output wire [31:0]  lane0_tx_data,
    output wire [31:0]  lane1_tx_data,
    output wire [31:0]  lane2_tx_data,
    output wire [31:0]  lane3_tx_data,
    output wire         tx_valid,
    input  wire         tx_ready
);

    // 内部信号
    wire [65:0]  enc_block0, enc_block1;
    wire         enc_valid, enc_ready;

    wire [65:0]  scr_block0, scr_block1;
    wire         scr_valid, scr_ready;

    wire [65:0]  am_block0, am_block1;
    wire         am_valid, am_ready;
    wire         am_insert;

    wire [65:0]  dist_lane0_block, dist_lane1_block;
    wire         dist_valid, dist_ready;

    // 64B/66B 编码器
    eth_pcs_64b66b_enc u_enc (
        .clk        (clk_core),
        .rst_n      (rst_n_core),
        .in_data    (mac_tx_data),
        .in_ctrl    (mac_tx_ctrl),
        .in_valid   (mac_tx_valid),
        .in_ready   (mac_tx_ready),
        .out_block0 (enc_block0),
        .out_block1 (enc_block1),
        .out_valid  (enc_valid),
        .out_ready  (enc_ready)
    );

    // 加扰器
    eth_pcs_scrambler u_scrambler (
        .clk        (clk_core),
        .rst_n      (rst_n_core),
        .in_block0  (enc_block0),
        .in_block1  (enc_block1),
        .in_valid   (enc_valid),
        .in_ready   (enc_ready),
        .out_block0 (scr_block0),
        .out_block1 (scr_block1),
        .out_valid  (scr_valid),
        .out_ready  (scr_ready)
    );

    // AM 插入指示
    eth_pcs_am_insert u_am_insert (
        .clk        (clk_core),
        .rst_n      (rst_n_core),
        .in_block0  (scr_block0),
        .in_block1  (scr_block1),
        .in_valid   (scr_valid),
        .in_ready   (scr_ready),
        .out_block0 (am_block0),
        .out_block1 (am_block1),
        .out_valid  (am_valid),
        .out_ready  (am_ready),
        .am_insert  (am_insert)
    );

    // Lane 分布
    eth_pcs_lane_dist u_lane_dist (
        .clk           (clk_core),
        .rst_n         (rst_n_core),
        .in_block0     (am_block0),
        .in_block1     (am_block1),
        .in_valid      (am_valid),
        .in_ready      (am_ready),
        .am_insert     (am_insert),
        .lane0_block   (dist_lane0_block),
        .lane1_block   (dist_lane1_block),
        .lane_valid    (dist_valid),
        .lane_ready    (dist_ready)
    );

    // TX Gearbox
    eth_pcs_gearbox_tx u_gearbox (
        .clk_core     (clk_core),
        .rst_n_core   (rst_n_core),
        .lane0_block  (dist_lane0_block),
        .lane1_block  (dist_lane1_block),
        .lane_valid   (dist_valid),
        .lane_ready   (dist_ready),
        .clk_pma      (clk_pma),
        .rst_n_pma    (rst_n_pma),
        .lane0_tx_data(lane0_tx_data),
        .lane1_tx_data(lane1_tx_data),
        .lane2_tx_data(lane2_tx_data),
        .lane3_tx_data(lane3_tx_data),
        .tx_valid     (tx_valid),
        .tx_ready     (tx_ready)
    );

endmodule
```

### 4.2 流水线延迟

| 模块 | 延迟 (周期) | 说明 |
|------|-------------|------|
| eth_pcs_64b66b_enc | 2 | 编码流水线 |
| eth_pcs_scrambler | 2 | 加扰流水线 |
| eth_pcs_am_insert | 0 | 直通 |
| eth_pcs_lane_dist | 0 | 直通 (AM 插入时暂停) |
| eth_pcs_gearbox_tx | 变化 | CDC FIFO + 位宽转换 |

**总延迟**: 约 4-6 个 clk_core 周期 + CDC FIFO 深度

### 4.3 反压传递

```
tx_ready (PMA) → gearbox → dist_ready → am_ready → scr_ready → enc_ready → mac_tx_ready

当 PMA 反压时:
  1. gearbox 的 CDC FIFO 填充
  2. FIFO 满时，gearbox 拉高 lane_ready (反压传递)
  3. lane_dist 暂停输出
  4. 反压传递到 MAC 层
```

## 5. 时序图

### 5.1 正常数据流

```
clk_core:     |  N  | N+1 | N+2 | N+3 | N+4 | N+5 |
              |     |     |     |     |     |     |
mac_tx_data:  | D0  | D1  | D2  | D3  | D4  | D5  |
mac_tx_valid: |  1  |  1  |  1  |  1  |  1  |  1  |
              |     |     |     |     |     |     |
enc_block0:   |     | B00 | B10 | B20 | B30 | B40 |
enc_block1:   |     | B01 | B11 | B21 | B31 | B41 |
enc_valid:    |     |  1  |  1  |  1  |  1  |  1  |
              |     |     |     |     |     |     |
scr_block0:   |     |     | B00'|B10'|B20'|B30'|
scr_block1:   |     |     | B01'|B11'|B21'|B31'|
              |     |     |     |     |     |     |
dist_lane0:   |     |     |     | L0  | L2  | L0  |
dist_lane1:   |     |     |     | L1  | L3  | L1  |
```

### 5.2 AM 插入

```
clk_core:     |  N  | N+1 | N+2 | N+3 | N+4 |
              |     |     |     |     |     |
am_insert:    |  0  |  1  |  0  |  0  |  0  |
              |     |     |     |     |     |
dist_state:   |NORM |NORM |AM_0 |AM_1 |NORM |
              |     |     |     |     |     |
dist_lane0:   | D0  | D2  |AM_L0|AM_L2| D4  |
dist_lane1:   | D1  | D3  |AM_L1|AM_L3| D5  |
              |     |     |     |     |     |
in_ready:     |  1  |  1  |  0  |  0  |  1  |
```

## 6. 资源估算

| 资源 | 估算值 | 说明 |
|------|--------|------|
| FF | ~1500 | 流水线寄存器 + FIFO |
| LUT | ~1200 | 编码/加扰/分发逻辑 |
| BRAM | 0 | 使用分布式 RAM |

## 7. 测试要点

| 测试项 | 说明 |
|--------|------|
| 单帧发送 | 验证数据正确编码、加扰、分发 |
| 连续帧发送 | 验证背靠背帧处理 |
| AM 插入 | 验证每 16383 块插入 AM |
| Lane 分布 | 验证数据正确分发到 4 个 lane |
| BIP 计算 | 验证 BIP 正确计算并插入 AM |
| CDC | 验证跨时钟域数据正确传输 |
| 反压处理 | 验证 tx_ready=0 时数据不丢失 |
| 复位行为 | 验证复位后状态正确 |

## 8. 与其他模块的关系

```
MAC (eth_mac_xgmii_enc) → eth_pcs_tx → PMA
          │                    │
          │                    ▼
          │              64B/66B 编码
          │              加扰
          │              AM 插入
          │              Lane 分布
          │              Gearbox + CDC
          │
          └── mac_tx_data/ctrl/valid/ready
```

## 9. 参考文献

- IEEE 802.3-2018 Clause 82 (PCS for 40GBASE-R)
- IEEE 802.3-2018 Clause 82.2.3 (64B/66B Encoding)
- IEEE 802.3-2018 Clause 82.2.5 (Scrambling)
- IEEE 802.3-2018 Clause 82.2.6 (Block Distribution)
- IEEE 802.3-2018 Clause 82.2.7 (Alignment Marker Insertion)

## 10. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-13 | 初始版本 |
