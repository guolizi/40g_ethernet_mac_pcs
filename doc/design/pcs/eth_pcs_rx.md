# eth_pcs_rx 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_rx

**功能**: PCS RX 路径顶层模块，集成 Gearbox、块同步、AM 检测、Lane 去偏斜、解扰、64B/66B 解码、Idle 删除等子模块

**位置**: rtl/pcs/eth_pcs_rx.sv

**时钟域**: 整个处理链在 clk_pma_rx 域运行，CDC 在 Idle 删除后进行

## 2. 接口定义

```systemverilog
module eth_pcs_rx (
    input  wire         clk_pma,
    input  wire         rst_n_pma,

    input  wire [31:0]  lane0_rx_data,
    input  wire [31:0]  lane1_rx_data,
    input  wire [31:0]  lane2_rx_data,
    input  wire [31:0]  lane3_rx_data,
    input  wire         rx_valid,
    output wire         rx_ready,

    input  wire         clk_core,
    input  wire         rst_n_core,

    output wire [127:0] mac_rx_data,
    output wire [15:0]  mac_rx_ctrl,
    output wire         mac_rx_valid,
    input  wire         mac_rx_ready,

    output wire [3:0]   block_lock,
    output wire         deskew_done,
    output wire [3:0]   bip_error
);
```

### 2.1 信号说明

**clk_pma 域 (PMA 接口)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| lane0_rx_data | input | 32 | Lane 0 的 32-bit 输入 |
| lane1_rx_data | input | 32 | Lane 1 的 32-bit 输入 |
| lane2_rx_data | input | 32 | Lane 2 的 32-bit 输入 |
| lane3_rx_data | input | 32 | Lane 3 的 32-bit 输入 |
| rx_valid | input | 1 | 数据有效 |
| rx_ready | output | 1 | PCS 就绪 |

**clk_core 域 (MAC 接口)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| mac_rx_data | output | 128 | XLGMII 数据 (字节0-15) |
| mac_rx_ctrl | output | 16 | XLGMII 控制掩码 (bit[i]=1 表示字节i是控制字符) |
| mac_rx_valid | output | 1 | 数据有效 |
| mac_rx_ready | input | 1 | MAC 就绪 |

**状态信号**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| block_lock | output | 4 | 4 个 lane 的块锁定状态 |
| deskew_done | output | 1 | Lane 去偏斜完成 |
| bip_error | output | 4 | BIP 校验错误指示 |

### 2.2 时钟频率

| 时钟 | 频率 | 说明 |
|------|------|------|
| clk_pma | 322.266 MHz | PMA RX 恢复时钟 (远端时钟) |
| clk_core | 312.5 MHz | MAC/PCS 核心时钟 (本地时钟) |

## 3. 功能描述

### 3.1 架构设计原则

**关键问题**: clk_pma (恢复时钟) 与 clk_core (本地时钟) 不同源，存在频偏

**解决方案**: 
1. 整个 PCS RX 处理链在 clk_pma 域运行
2. Idle 删除在解码后进行，实现速率匹配
3. CDC 在 Idle 删除后、MAC 接口处进行

### 3.2 RX 数据流

```
PMA (clk_pma 域)
    │
    │ 4×32-bit
    ▼
┌─────────────────────┐
│  eth_pcs_gearbox_rx │  32-bit → 66-bit
└─────────────────────┘
    │
    │ 2×66-bit blocks (交替: L0/L1, L2/L3)
    ▼
┌─────────────────────┐
│  eth_pcs_block_sync │  块边界同步
└─────────────────────┘
    │
    │ 2×66-bit blocks (对齐) + block_lock[3:0]
    ▼
┌─────────────────────┐
│  eth_pcs_am_detect  │  AM 检测 + Lane 重排序
└─────────────────────┘
    │
    │ 2×66-bit blocks (逻辑 lane) + am_detected + lane_map_valid
    ▼
┌─────────────────────┐
│  eth_pcs_lane_deskew│  Lane 去偏斜 + AM 删除
└─────────────────────┘
    │
    │ 2×66-bit blocks (对齐，无 AM) + deskew_done
    ▼
┌─────────────────────┐
│  eth_pcs_descrambler│  自同步解扰
└─────────────────────┘
    │
    │ 2×66-bit blocks
    ▼
┌─────────────────────┐
│  eth_pcs_64b66b_dec │  64B/66B 解码
└─────────────────────┘
    │
    │ 128-bit data + 16-bit ctrl
    ▼
┌─────────────────────┐
│  eth_pcs_idle_delete│  Idle 删除 (速率匹配)
└─────────────────────┘
    │
    │ 128-bit data + 16-bit ctrl
    ▼
┌─────────────────────┐
│  async_fifo         │  CDC (clk_pma → clk_core)
└─────────────────────┘
    │
    │ 128-bit data + 16-bit ctrl @ clk_core
    ▼
MAC (XLGMII 格式)
```

### 3.3 各子模块功能

| 子模块 | 功能 | 时钟域 |
|--------|------|--------|
| eth_pcs_gearbox_rx | 32-bit → 66-bit 转换 | clk_pma |
| eth_pcs_block_sync | 检测 sync header，锁定块边界 | clk_pma |
| eth_pcs_am_detect | 检测 AM，建立 lane 映射，重排序数据 | clk_pma |
| eth_pcs_lane_deskew | 补偿 lane skew，删除 AM | clk_pma |
| eth_pcs_descrambler | 64-bit payload 解扰 | clk_pma |
| eth_pcs_64b66b_dec | 2×66-bit 块 → 128-bit data/ctrl 解码 | clk_pma |
| eth_pcs_idle_delete | 删除 Idle，实现速率匹配 | clk_pma |
| async_fifo | 跨时钟域传输 | clk_pma → clk_core |

### 3.4 数据流位宽与时序

```
clk_pma 域:
  - 输入: 4×32-bit @ 每周期
  - Gearbox 输出: 2×66-bit blocks (交替)
    - 周期 N: lane0_block = Lane 0, lane1_block = Lane 1
    - 周期 N+1: lane0_block = Lane 2, lane1_block = Lane 3
  - 解码输出: 128-bit data + 16-bit ctrl @ 每周期
  - Idle 删除后: 128-bit data + 16-bit ctrl @ 每周期 (部分周期可能被删除)

clk_core 域:
  - FIFO 输出: 128-bit data + 16-bit ctrl @ 每周期
```

### 3.5 速率匹配原理

**频偏问题**:
- clk_pma 是远端发送时钟恢复，与本地 clk_core 不同源
- 存在 ±100 ppm 频偏
- 直接 CDC 会导致 FIFO 溢出或读空

**Idle 删除解决方案**:
```
远端时钟略快 (clk_pma > 标称):
  - 接收数据率略高
  - 删除更多 Idle 匹配本地时钟

远端时钟略慢 (clk_pma < 标称):
  - 接收数据率略低
  - 删除较少 Idle 匹配本地时钟

Idle 删除速率:
  - 频偏 ±100 ppm → 数据率变化 ±1.03 Mbps
  - 需删除约 129k Idle 字节/秒
  - 相对于 5.16G 字节/秒，删除比例极小
```

### 3.6 Lane 去偏斜流程

```
1. eth_pcs_block_sync 模块锁定各 lane 的块边界
   - 输出 block_lock[3:0] 指示各 lane 锁定状态

2. eth_pcs_am_detect 模块检测 AM
   - 建立 物理 lane → 逻辑 lane 映射
   - 重排序数据到逻辑 lane 顺序
   - 输出 lane_map_valid 指示映射建立完成
   - 输出 am_detected 指示当前块是否为 AM

3. eth_pcs_lane_deskew 模块补偿 skew
   - 等待所有 lane 检测到 AM
   - 各 lane 从自己的 AM 之后开始读取
   - 删除 AM (out_valid=0)
   - 输出 deskew_done 指示去偏斜完成
```

### 3.7 状态指示

```
block_lock[3:0]:
  - 各 lane 独立的块锁定状态
  - 全部为 1 时表示所有 lane 已锁定

lane_map_valid:
  - 物理 lane → 逻辑 lane 映射建立完成
  - 在 am_detect 模块检测到所有 4 个 lane 的 AM 后置 1

deskew_done:
  - Lane 去偏斜完成
  - 在 lane_deskew 模块完成对齐后置 1
  - 此时输出数据已对齐，AM 已删除

bip_error[3:0]:
  - BIP 校验错误指示
  - 每 bit 对应一个逻辑 lane
```

## 4. 详细设计

### 4.1 模块实例化

```systemverilog
module eth_pcs_rx (
    input  wire         clk_pma,
    input  wire         rst_n_pma,

    input  wire [31:0]  lane0_rx_data,
    input  wire [31:0]  lane1_rx_data,
    input  wire [31:0]  lane2_rx_data,
    input  wire [31:0]  lane3_rx_data,
    input  wire         rx_valid,
    output wire         rx_ready,

    input  wire         clk_core,
    input  wire         rst_n_core,

    output wire [127:0] mac_rx_data,
    output wire [15:0]  mac_rx_ctrl,
    output wire         mac_rx_valid,
    input  wire         mac_rx_ready,

    output wire [3:0]   block_lock,
    output wire         deskew_done,
    output wire [3:0]   bip_error
);

    wire [65:0]  gb_lane0_block, gb_lane1_block;
    wire         gb_valid, gb_ready;

    wire [65:0]  sync_lane0_block, sync_lane1_block;
    wire         sync_valid, sync_ready;

    wire [65:0]  am_lane0_block, am_lane1_block;
    wire         am_valid, am_ready;
    wire [1:0]   am_detected;
    wire         lane_map_valid;

    wire [65:0]  deskew_lane0_block, deskew_lane1_block;
    wire         deskew_valid, deskew_ready;

    wire [65:0]  desc_block0, desc_block1;
    wire         desc_valid, desc_ready;

    wire [127:0] dec_data;
    wire [15:0]  dec_ctrl;
    wire         dec_valid, dec_ready;

    wire [127:0] idle_data;
    wire [15:0]  idle_ctrl;
    wire         idle_valid, idle_ready;

    wire         fifo_full;
    wire         fifo_empty;
    wire         fifo_rd_en;

    eth_pcs_gearbox_rx u_gearbox (
        .clk_pma       (clk_pma),
        .rst_n_pma     (rst_n_pma),
        .lane0_rx_data (lane0_rx_data),
        .lane1_rx_data (lane1_rx_data),
        .lane2_rx_data (lane2_rx_data),
        .lane3_rx_data (lane3_rx_data),
        .rx_valid      (rx_valid),
        .rx_ready      (rx_ready),
        .lane0_block   (gb_lane0_block),
        .lane1_block   (gb_lane1_block),
        .out_valid     (gb_valid),
        .out_ready     (gb_ready)
    );

    eth_pcs_block_sync u_block_sync (
        .clk            (clk_pma),
        .rst_n          (rst_n_pma),
        .lane0_block    (gb_lane0_block),
        .lane1_block    (gb_lane1_block),
        .in_valid       (gb_valid),
        .in_ready       (gb_ready),
        .out_lane0_block(sync_lane0_block),
        .out_lane1_block(sync_lane1_block),
        .out_valid      (sync_valid),
        .out_ready      (sync_ready),
        .block_lock     (block_lock)
    );

    eth_pcs_am_detect u_am_detect (
        .clk            (clk_pma),
        .rst_n          (rst_n_pma),
        .lane0_block    (sync_lane0_block),
        .lane1_block    (sync_lane1_block),
        .in_valid       (sync_valid),
        .in_ready       (sync_ready),
        .out_lane0_block(am_lane0_block),
        .out_lane1_block(am_lane1_block),
        .out_valid      (am_valid),
        .out_ready      (am_ready),
        .am_detected    (am_detected),
        .bip_error      (bip_error),
        .lane_map_valid (lane_map_valid)
    );

    eth_pcs_lane_deskew u_lane_deskew (
        .clk            (clk_pma),
        .rst_n          (rst_n_pma),
        .lane0_block    (am_lane0_block),
        .lane1_block    (am_lane1_block),
        .in_valid       (am_valid),
        .in_ready       (am_ready),
        .am_detected    (am_detected),
        .lane_map_valid (lane_map_valid),
        .out_lane0_block(deskew_lane0_block),
        .out_lane1_block(deskew_lane1_block),
        .out_valid      (deskew_valid),
        .out_ready      (deskew_ready),
        .deskew_done    (deskew_done)
    );

    eth_pcs_descrambler u_descrambler (
        .clk        (clk_pma),
        .rst_n      (rst_n_pma),
        .in_block0  (deskew_lane0_block),
        .in_block1  (deskew_lane1_block),
        .in_valid   (deskew_valid),
        .in_ready   (deskew_ready),
        .out_block0 (desc_block0),
        .out_block1 (desc_block1),
        .out_valid  (desc_valid),
        .out_ready  (desc_ready)
    );

    eth_pcs_64b66b_dec u_dec (
        .clk        (clk_pma),
        .rst_n      (rst_n_pma),
        .in_block0  (desc_block0),
        .in_block1  (desc_block1),
        .in_valid   (desc_valid),
        .in_ready   (desc_ready),
        .out_data   (dec_data),
        .out_ctrl   (dec_ctrl),
        .out_valid  (dec_valid),
        .out_ready  (dec_ready)
    );

    eth_pcs_idle_delete u_idle_delete (
        .clk_pma     (clk_pma),
        .rst_n_pma   (rst_n_pma),
        .in_data     (dec_data),
        .in_ctrl     (dec_ctrl),
        .in_valid    (dec_valid),
        .in_ready    (dec_ready),
        .out_data    (idle_data),
        .out_ctrl    (idle_ctrl),
        .out_valid   (idle_valid),
        .out_ready   (idle_ready)
    );

    async_fifo #(
        .DATA_WIDTH(144),
        .DEPTH(64)
    ) u_cdc_fifo (
        .wr_clk   (clk_pma),
        .wr_rst_n (rst_n_pma),
        .wr_en    (idle_valid && !fifo_full),
        .wr_data  ({idle_ctrl, idle_data}),
        .full     (fifo_full),

        .rd_clk   (clk_core),
        .rd_rst_n (rst_n_core),
        .rd_en    (fifo_rd_en),
        .rd_data  ({mac_rx_ctrl, mac_rx_data}),
        .empty    (fifo_empty)
    );

    assign idle_ready = !fifo_full;
    assign fifo_rd_en = !fifo_empty && mac_rx_ready;
    assign mac_rx_valid = !fifo_empty;

endmodule
```

### 4.2 流水线延迟

| 模块 | 延迟 (周期) | 说明 |
|------|-------------|------|
| eth_pcs_gearbox_rx | 变化 | 位宽转换 |
| eth_pcs_block_sync | 0 | 直通 (状态机独立) |
| eth_pcs_am_detect | 0 | 直通 (映射表独立) |
| eth_pcs_lane_deskew | 变化 | FIFO 缓冲 + 对齐 |
| eth_pcs_descrambler | 2 | 解扰流水线 |
| eth_pcs_64b66b_dec | 2 | 解码流水线 |
| eth_pcs_idle_delete | 1 | Idle 删除 |
| async_fifo | 变化 | CDC FIFO 深度 |

**总延迟**: 约 5-7 个 clk_pma 周期 + deskew FIFO 深度 + CDC FIFO 深度

### 4.3 反压传递

```
mac_rx_ready (MAC) → fifo_rd_en → fifo_full → idle_ready → dec_ready → desc_ready → deskew_ready → am_ready → sync_ready → gb_ready → rx_ready

当 MAC 反压时:
  1. FIFO 不读取，水位上升
  2. FIFO 满时，idle_ready = 0
  3. 反压传递到解码器、解扰器、去偏斜模块
  4. 去偏斜模块的 FIFO 填充
  5. FIFO 满时，反压传递到 PMA
```

### 4.4 初始化流程

```
1. 复位释放后，各模块开始工作

2. eth_pcs_gearbox_rx 开始接收 PMA 数据
   - 32-bit → 66-bit 转换

3. eth_pcs_block_sync 检测 sync header
   - 各 lane 独立锁定
   - block_lock[3:0] 逐步置 1

4. eth_pcs_am_detect 检测 AM
   - 建立 物理 lane → 逻辑 lane 映射
   - lane_map_valid 置 1

5. eth_pcs_lane_deskew 等待所有 lane 的 AM
   - 各 lane 从自己的 AM 之后开始读取
   - deskew_done 置 1

6. 正常数据流开始
   - 解扰、解码、Idle 删除、CDC、输出到 MAC
```

## 5. 时序图

### 5.1 初始化流程

```
clk_pma:       |  0  |  1  | ... | 64  | 65  | ... | 100 | ... |
                |     |     |     |     |     |     |     |     |
block_lock:     |  0  |  0  | ... |  7  |  F  |  F  |  F  |  F  |
                |     |     |     |     |     |     |     |     |
lane_map_valid: |  0  |  0  | ... |  0  |  0  |  1  |  1  |  1  |
                |     |     |     |     |     |     |     |     |
deskew_done:    |  0  |  0  | ... |  0  |  0  |  0  |  1  |  1  |
                |     |     |     |     |     |     |     |     |
mac_rx_valid:   |  0  |  0  | ... |  0  |  0  |  0  |  0  |  1  |
```

### 5.2 正常数据流

```
clk_pma:       |  N  | N+1 | N+2 | N+3 | N+4 | N+5 |
                |     |     |     |     |     |     |
gb_lane0:       | L0  | L2  | L0  | L2  | L0  | L2  |
gb_lane1:       | L1  | L3  | L1  | L3  | L1  | L3  |
                |     |     |     |     |     |     |
sync_lane0:     | L0  | L2  | L0  | L2  | L0  | L2  |
sync_lane1:     | L1  | L3  | L1  | L3  | L1  | L3  |
                |     |     |     |     |     |     |
am_lane0:       | L0' | L2' | L0' | L2' | L0' | L2' | (重排序后)
am_lane1:       | L1' | L3' | L1' | L3' | L1' | L3' |
                |     |     |     |     |     |     |
deskew_lane0:   | D0  | D2  | D0  | D2  | D0  | D2  | (AM 已删除)
deskew_lane1:   | D1  | D3  | D1  | D3  | D1  | D3  |
                |     |     |     |     |     |     |
dec_data:       |     |     | D0  | D1  | D2  | D3  |
dec_valid:      |     |     |  1  |  1  |  1  |  1  |
```

### 5.3 Idle 删除与 CDC

```
clk_pma:       |  N  | N+1 | N+2 | N+3 | N+4 |
                |     |     |     |     |     |
dec_data:       | IDLE| D0  | D1  | IDLE| D2  |
dec_ctrl:       |FFFF |0000 |0000 |FFFF |0000 |
                |     |     |     |     |     |
idle_data:      | IDLE| D0  | D1  |  -  | D2  | (N+3 的 IDLE 被删除)
idle_valid:     |  1  |  1  |  1  |  0  |  1  |
                |     |     |     |     |     |
fifo_wr:        |  1  |  1  |  1  |  0  |  1  |

clk_core:      |  M  | M+1 | M+2 | M+3 | M+4 |
                |     |     |     |     |     |
mac_rx_data:    | IDLE| D0  | D1  | D2  | ... |
mac_rx_valid:   |  1  |  1  |  1  |  1  | ... |
```

## 6. 错误处理

### 6.1 块同步错误

当 `block_lock` 某一位为 0 时：
- 对应 lane 未锁定
- 数据可能不正确
- 上层应等待所有 lane 锁定

### 6.2 Lane 映射错误

当 `lane_map_valid = 0` 时：
- 物理 lane 到逻辑 lane 的映射未建立
- 数据可能未正确重排序
- 上层应等待映射建立

### 6.3 去偏斜未完成

当 `deskew_done = 0` 时：
- Lane 去偏斜未完成
- 各 lane 数据未对齐
- 上层应等待去偏斜完成

### 6.4 BIP 校验错误

当 `bip_error` 某一位为 1 时：
- 对应逻辑 lane 的 BIP 校验失败
- 可能存在传输错误
- 可用于链路质量监测

### 6.5 FIFO 溢出

当 Idle 删除不足以匹配频偏时：
- FIFO 可能溢出
- 需要监控 FIFO 水位
- 可配置丢弃策略

## 7. 资源估算

| 资源 | 估算值 | 说明 |
|------|--------|------|
| FF | ~2500 | 流水线寄存器 + FIFO + 状态机 |
| LUT | ~1800 | 解码/解扰/同步逻辑 |
| BRAM | 0 | 使用分布式 RAM |

## 8. 测试要点

| 测试项 | 说明 |
|--------|------|
| 单帧接收 | 验证数据正确解码、解扰、对齐 |
| 连续帧接收 | 验证背靠背帧处理 |
| 块同步 | 验证各 lane 正确锁定块边界 |
| Lane 重排序 | 验证物理 lane 到逻辑 lane 映射正确 |
| Lane 去偏斜 | 验证各 lane 数据正确对齐 |
| AM 删除 | 验证 AM 正确删除，out_valid=0 |
| Idle 删除 | 验证帧间 Idle 正确删除 |
| 速率匹配 | 验证不同频偏下 FIFO 不溢出/不读空 |
| CDC | 验证跨时钟域数据正确传输 |
| 反压处理 | 验证 mac_rx_ready=0 时数据不丢失 |
| 复位行为 | 验证复位后状态正确 |

## 9. 与其他模块的关系

```
PMA → eth_pcs_rx → MAC (eth_mac_xgmii_dec)
            │
            ▼
      Gearbox (32:66)
      块同步
      AM 检测 + Lane 重排序
      Lane 去偏斜 + AM 删除
      解扰
      64B/66B 解码
      Idle 删除 (速率匹配)
      CDC FIFO
            │
            ▼
      mac_rx_data/ctrl/valid/ready
      block_lock, deskew_done, bip_error
```

## 10. 参考文献

- IEEE 802.3-2018 Clause 82 (PCS for 40GBASE-R)
- IEEE 802.3-2018 Clause 82.2.3 (64B/66B Encoding)
- IEEE 802.3-2018 Clause 82.2.5 (Scrambling)
- IEEE 802.3-2018 Clause 82.2.8 (Alignment Marker Detection)
- IEEE 802.3-2018 Clause 82.2.9 (Lane Deskew)
- IEEE 802.3-2018 Clause 82.2.10 (Block Synchronization)
- IEEE 802.3-2018 Clause 46.3.4 (Rate Matching)

## 11. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-13 | 初始版本 |
| 2.0 | 2026-04-13 | 整个处理链移到 clk_pma 域，添加 Idle 删除模块，CDC 移到 MAC 接口处 |
