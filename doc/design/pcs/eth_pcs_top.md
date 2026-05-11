# eth_pcs_top 模块设计

## 1. 模块概述

**模块名称**: eth_pcs_top

**功能**: PCS 层顶层模块，集成 TX 和 RX 路径，实现 IEEE 802.3ba 40GBASE-R PCS 功能

**位置**: rtl/pcs/eth_pcs_top.sv

## 2. 接口定义

```systemverilog
module eth_pcs_top (
    input  wire         clk_core,
    input  wire         rst_n_core,

    input  wire         clk_pma_tx,
    input  wire         rst_n_pma_tx,

    input  wire         clk_pma_rx,
    input  wire         rst_n_pma_rx,

    // MAC TX 接口 (XLGMII 格式)
    input  wire [127:0] mac_tx_data,
    input  wire [15:0]  mac_tx_ctrl,
    input  wire         mac_tx_valid,
    output wire         mac_tx_ready,

    // MAC RX 接口 (XLGMII 格式)
    output wire [127:0] mac_rx_data,
    output wire [15:0]  mac_rx_ctrl,
    output wire         mac_rx_valid,
    input  wire         mac_rx_ready,

    // PMA TX 接口
    output wire [31:0]  lane0_tx_data,
    output wire [31:0]  lane1_tx_data,
    output wire [31:0]  lane2_tx_data,
    output wire [31:0]  lane3_tx_data,
    output wire         tx_valid,
    input  wire         tx_ready,

    // PMA RX 接口
    input  wire [31:0]  lane0_rx_data,
    input  wire [31:0]  lane1_rx_data,
    input  wire [31:0]  lane2_rx_data,
    input  wire [31:0]  lane3_rx_data,
    input  wire         rx_valid,
    output wire         rx_ready,

    // 状态输出
    output wire [3:0]   block_lock,
    output wire         deskew_done,
    output wire [3:0]   bip_error
);
```

### 2.1 信号说明

**clk_core 域 (MAC 接口)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| mac_tx_data | input | 128 | TX 数据 (字节0-15) |
| mac_tx_ctrl | input | 16 | TX 控制掩码 (bit[i]=1 表示字节i是控制字符) |
| mac_tx_valid | input | 1 | TX 数据有效 |
| mac_tx_ready | output | 1 | PCS TX 就绪 |
| mac_rx_data | output | 128 | RX 数据 (字节0-15) |
| mac_rx_ctrl | output | 16 | RX 控制掩码 |
| mac_rx_valid | output | 1 | RX 数据有效 |
| mac_rx_ready | input | 1 | MAC RX 就绪 |

**clk_pma_tx 域 (PMA TX 接口)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| lane0_tx_data | output | 32 | Lane 0 的 32-bit 输出 |
| lane1_tx_data | output | 32 | Lane 1 的 32-bit 输出 |
| lane2_tx_data | output | 32 | Lane 2 的 32-bit 输出 |
| lane3_tx_data | output | 32 | Lane 3 的 32-bit 输出 |
| tx_valid | output | 1 | 数据有效 |
| tx_ready | input | 1 | PMA TX 就绪 |

**clk_pma_rx 域 (PMA RX 接口)**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| lane0_rx_data | input | 32 | Lane 0 的 32-bit 输入 |
| lane1_rx_data | input | 32 | Lane 1 的 32-bit 输入 |
| lane2_rx_data | input | 32 | Lane 2 的 32-bit 输入 |
| lane3_rx_data | input | 32 | Lane 3 的 32-bit 输入 |
| rx_valid | input | 1 | 数据有效 |
| rx_ready | output | 1 | PCS RX 就绪 |

**状态信号**:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| block_lock | output | 4 | 4 个 lane 的块锁定状态 |
| deskew_done | output | 1 | Lane 去偏斜完成 |
| bip_error | output | 4 | BIP 校验错误指示 |

### 2.2 时钟频率

| 时钟 | 频率 | 说明 |
|------|------|------|
| clk_core | 312.5 MHz | MAC/PCS 核心时钟 (本地时钟) |
| clk_pma_tx | 322.266 MHz | PMA TX 接口时钟 (本地时钟) |
| clk_pma_rx | 322.266 MHz | PMA RX 接口时钟 (远端恢复时钟) |

### 2.3 时钟域划分

| 时钟域 | 模块 | 说明 |
|--------|------|------|
| clk_core | MAC 全部 + PCS TX 核心 (编码/加扰/AM/lane分布) | 本地时钟 |
| clk_pma_tx | TX Gearbox (读侧) | 本地时钟 |
| clk_pma_rx | PCS RX 全部 (Gearbox/同步/检测/去偏斜/解扰/解码/Idle删除) | 远端恢复时钟 |

### 2.4 时钟源关系

```
TX 方向:
  clk_core (本地) → PCS TX 核心 → CDC FIFO → clk_pma_tx (本地)
  两个时钟同源，无频偏问题

RX 方向:
  clk_pma_rx (远端恢复) → PCS RX 全部处理 → Idle 删除 → CDC FIFO → clk_core (本地)
  两个时钟不同源，存在 ±100 ppm 频偏
  通过 Idle 删除实现速率匹配
```

## 3. 功能描述

### 3.1 整体架构

```
                              clk_core 域
    ┌─────────────────────────────────────────────────────────────┐
    │                                                             │
    │   MAC TX ──────► eth_pcs_tx ──────┐                        │
    │   (XLGMII)                        │                        │
    │                                   │                        │
    └───────────────────────────────────┼────────────────────────┘
                                        │
                              ┌─────────▼─────────┐
                              │   CDC (Gearbox)   │
                              │   clk_core →     │
                              │   clk_pma_tx     │
                              └─────────┬─────────┘
                                        │
    ┌───────────────────────────────────┼────────────────────────┐
    │                                   │                        │
    │                         clk_pma_tx 域 (本地时钟)           │
    │                                   │                        │
    │   lane0~3_tx_data ────────────────┼──────► PMA TX          │
    │                                   │                        │
    └───────────────────────────────────┼────────────────────────┘
                                        │
    ┌───────────────────────────────────┼────────────────────────┐
    │                                   │                        │
    │                         clk_pma_rx 域 (远端恢复时钟)       │
    │                                   │                        │
    │   lane0~3_rx_data ◄───────────────┼────── PMA RX          │
    │                                   │                        │
    │   ┌─────────────────────────────┐ │                        │
    │   │ eth_pcs_rx (全部处理)       │ │                        │
    │   │ - Gearbox (32:66)           │ │                        │
    │   │ - 块同步                    │ │                        │
    │   │ - AM 检测 + Lane 重排序     │ │                        │
    │   │ - Lane 去偏斜 + AM 删除     │ │                        │
    │   │ - 解扰                      │ │                        │
    │   │ - 64B/66B 解码              │ │                        │
    │   │ - Idle 删除 (速率匹配)      │ │                        │
    │   └─────────────────────────────┘ │                        │
    │                                   │                        │
    └───────────────────────────────────┼────────────────────────┘
                                        │
                              ┌─────────▼─────────┐
                              │   CDC FIFO        │
                              │   clk_pma_rx →   │
                              │   clk_core       │
                              └─────────┬─────────┘
                                        │
    ┌───────────────────────────────────┼────────────────────────┐
    │                                   │                        │
    │   MAC RX ◄────────────────────────┘                        │
    │   (XLGMII)                                                   │
    │                                                             │
    │                              clk_core 域                    │
    └─────────────────────────────────────────────────────────────┘
```

### 3.2 TX 数据流

```
MAC (XLGMII 格式) @ clk_core
    │
    │ 128-bit data + 16-bit ctrl
    ▼
┌─────────────────────┐
│   eth_pcs_tx        │
│  ┌───────────────┐  │
│  │ 64B/66B 编码  │  │
│  └───────┬───────┘  │
│          │          │
│  ┌───────▼───────┐  │
│  │ 加扰器        │  │
│  └───────┬───────┘  │
│          │          │
│  ┌───────▼───────┐  │
│  │ AM 插入指示   │  │
│  └───────┬───────┘  │
│          │          │
│  ┌───────▼───────┐  │
│  │ Lane 分布     │  │
│  │ + BIP 计算    │  │
│  └───────┬───────┘  │
│          │          │
│  ┌───────▼───────┐  │
│  │ TX Gearbox    │  │
│  │ + CDC         │  │
│  └───────┬───────┘  │
└──────────┼──────────┘
           │
           │ 4×32-bit @ clk_pma_tx
           ▼
        PMA TX
```

### 3.3 RX 数据流

```
        PMA RX
           │
           │ 4×32-bit @ clk_pma_rx (远端恢复时钟)
           ▼
┌──────────┴──────────┐
│   eth_pcs_rx        │
│  ┌───────────────┐  │
│  │ Gearbox       │  │  32:66 转换
│  │ (32:66)       │  │
│  └───────┬───────┘  │
│          │          │
│  ┌───────▼───────┐  │
│  │ 块同步        │  │  检测 sync header
│  └───────┬───────┘  │
│          │          │
│  ┌───────▼───────┐  │
│  │ AM 检测       │  │  Lane 重排序
│  │ + Lane 重排序 │  │
│  └───────┬───────┘  │
│          │          │
│  ┌───────▼───────┐  │
│  │ Lane 去偏斜   │  │  AM 删除
│  │ + AM 删除     │  │
│  └───────┬───────┘  │
│          │          │
│  ┌───────▼───────┐  │
│  │ 解扰器        │  │
│  └───────┬───────┘  │
│          │          │
│  ┌───────▼───────┐  │
│  │ 64B/66B 解码  │  │
│  └───────┬───────┘  │
│          │          │
│  ┌───────▼───────┐  │
│  │ Idle 删除     │  │  速率匹配
│  └───────┬───────┘  │
└──────────┼──────────┘
           │
           │ 128-bit data + 16-bit ctrl @ clk_pma_rx
           ▼
    ┌───────────────┐
    │ async_fifo    │  CDC
    │ (144-bit)     │
    └───────┬───────┘
            │
            │ 128-bit data + 16-bit ctrl @ clk_core
            ▼
        MAC (XLGMII 格式)
```

### 3.4 子模块列表

| 子模块 | 功能 | 时钟域 |
|--------|------|--------|
| eth_pcs_tx | TX 路径顶层 | clk_core → clk_pma_tx |
| eth_pcs_rx | RX 路径顶层 | clk_pma_rx → clk_core |

**eth_pcs_tx 内部子模块**:
| 子模块 | 功能 | 时钟域 |
|--------|------|--------|
| eth_pcs_64b66b_enc | 128-bit data/ctrl → 2×66-bit 块编码 | clk_core |
| eth_pcs_scrambler | 64-bit payload 加扰 | clk_core |
| eth_pcs_am_insert | 块计数，每 16383 块插入 AM 指示 | clk_core |
| eth_pcs_lane_dist | 分发到 4 个 lane，插入 AM，计算 BIP | clk_core |
| eth_pcs_gearbox_tx | 66-bit → 32-bit 转换 + CDC | clk_core → clk_pma_tx |

**eth_pcs_rx 内部子模块**:
| 子模块 | 功能 | 时钟域 |
|--------|------|--------|
| eth_pcs_gearbox_rx | 32-bit → 66-bit 转换 | clk_pma_rx |
| eth_pcs_block_sync | 检测 sync header，锁定块边界 | clk_pma_rx |
| eth_pcs_am_detect | 检测 AM，建立 lane 映射，重排序数据 | clk_pma_rx |
| eth_pcs_lane_deskew | 补偿 lane skew，删除 AM | clk_pma_rx |
| eth_pcs_descrambler | 64-bit payload 解扰 | clk_pma_rx |
| eth_pcs_64b66b_dec | 2×66-bit 块 → 128-bit data/ctrl 解码 | clk_pma_rx |
| eth_pcs_idle_delete | 删除 Idle，实现速率匹配 | clk_pma_rx |
| async_fifo | 跨时钟域传输 | clk_pma_rx → clk_core |

### 3.5 速率匹配原理

**问题**:
- `clk_pma_rx` 是远端发送时钟恢复，与本地 `clk_core` 不同源
- 存在 ±100 ppm 频偏
- 直接 CDC 会导致 FIFO 溢出或读空

**解决方案**:
1. 整个 PCS RX 处理链在 `clk_pma_rx` 域运行
2. 解码后识别 Idle 字符
3. 删除帧间 Idle 实现速率匹配
4. CDC 在 Idle 删除后进行

**计算**:
```
频偏: ±100 ppm
数据率变化: 10.3125G × 100ppm ≈ 1.03 Mbps
Idle 删除速率: ~129k 字节/秒
相对于 5.16G 字节/秒，删除比例极小
```

## 4. 详细设计

### 4.1 模块实例化

```systemverilog
module eth_pcs_top (
    input  wire         clk_core,
    input  wire         rst_n_core,

    input  wire         clk_pma_tx,
    input  wire         rst_n_pma_tx,

    input  wire         clk_pma_rx,
    input  wire         rst_n_pma_rx,

    input  wire [127:0] mac_tx_data,
    input  wire [15:0]  mac_tx_ctrl,
    input  wire         mac_tx_valid,
    output wire         mac_tx_ready,

    output wire [127:0] mac_rx_data,
    output wire [15:0]  mac_rx_ctrl,
    output wire         mac_rx_valid,
    input  wire         mac_rx_ready,

    output wire [31:0]  lane0_tx_data,
    output wire [31:0]  lane1_tx_data,
    output wire [31:0]  lane2_tx_data,
    output wire [31:0]  lane3_tx_data,
    output wire         tx_valid,
    input  wire         tx_ready,

    input  wire [31:0]  lane0_rx_data,
    input  wire [31:0]  lane1_rx_data,
    input  wire [31:0]  lane2_rx_data,
    input  wire [31:0]  lane3_rx_data,
    input  wire         rx_valid,
    output wire         rx_ready,

    output wire [3:0]   block_lock,
    output wire         deskew_done,
    output wire [3:0]   bip_error
);

    eth_pcs_tx u_pcs_tx (
        .clk_core     (clk_core),
        .rst_n_core   (rst_n_core),

        .mac_tx_data  (mac_tx_data),
        .mac_tx_ctrl  (mac_tx_ctrl),
        .mac_tx_valid (mac_tx_valid),
        .mac_tx_ready (mac_tx_ready),

        .clk_pma      (clk_pma_tx),
        .rst_n_pma    (rst_n_pma_tx),

        .lane0_tx_data(lane0_tx_data),
        .lane1_tx_data(lane1_tx_data),
        .lane2_tx_data(lane2_tx_data),
        .lane3_tx_data(lane3_tx_data),
        .tx_valid     (tx_valid),
        .tx_ready     (tx_ready)
    );

    eth_pcs_rx u_pcs_rx (
        .clk_pma      (clk_pma_rx),
        .rst_n_pma    (rst_n_pma_rx),

        .lane0_rx_data(lane0_rx_data),
        .lane1_rx_data(lane1_rx_data),
        .lane2_rx_data(lane2_rx_data),
        .lane3_rx_data(lane3_rx_data),
        .rx_valid     (rx_valid),
        .rx_ready     (rx_ready),

        .clk_core     (clk_core),
        .rst_n_core   (rst_n_core),

        .mac_rx_data  (mac_rx_data),
        .mac_rx_ctrl  (mac_rx_ctrl),
        .mac_rx_valid (mac_rx_valid),
        .mac_rx_ready (mac_rx_ready),

        .block_lock   (block_lock),
        .deskew_done  (deskew_done),
        .bip_error    (bip_error)
    );

endmodule
```

### 4.2 复位策略

```
复位信号:
  - rst_n_core:   clk_core 域复位
  - rst_n_pma_tx: clk_pma_tx 域复位
  - rst_n_pma_rx: clk_pma_rx 域复位

复位要求:
  1. 所有复位均为同步复位，低有效
  2. 外部异步复位需在顶层通过同步器同步
  3. 各时钟域复位可独立释放

复位顺序:
  1. rst_n_core 释放 → MAC 和 PCS TX 核心逻辑开始工作
  2. rst_n_pma_tx 释放 → TX Gearbox 开始工作
  3. rst_n_pma_rx 释放 → RX 处理链开始工作
```

### 4.3 时钟域隔离

```
TX 路径:
  clk_core → eth_pcs_tx 内部逻辑 → eth_pcs_gearbox_tx (CDC FIFO) → clk_pma_tx
  两个时钟同源 (本地时钟)，无频偏问题

RX 路径:
  clk_pma_rx → eth_pcs_rx 全部处理 → Idle 删除 → async_fifo (CDC) → clk_core
  两个时钟不同源，存在频偏
  通过 Idle 删除实现速率匹配

CDC FIFO 深度:
  - TX Gearbox: 64 entries × 66-bit (每个 lane)
  - RX CDC: 64 entries × 144-bit
```

### 4.4 流水线延迟

**TX 路径**:
| 模块 | 延迟 (周期) | 说明 |
|------|-------------|------|
| eth_pcs_64b66b_enc | 2 | 编码流水线 |
| eth_pcs_scrambler | 2 | 加扰流水线 |
| eth_pcs_am_insert | 0 | 直通 |
| eth_pcs_lane_dist | 0 | 直通 (AM 插入时暂停) |
| eth_pcs_gearbox_tx | 变化 | CDC FIFO + 位宽转换 |

**RX 路径**:
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

**总延迟**:
- TX: 约 4-6 个 clk_core 周期 + CDC FIFO 深度
- RX: 约 5-7 个 clk_pma 周期 + deskew FIFO 深度 + CDC FIFO 深度

### 4.5 反压传递

**TX 路径**:
```
tx_ready (PMA) → gearbox → dist_ready → am_ready → scr_ready → enc_ready → mac_tx_ready
```

**RX 路径**:
```
mac_rx_ready (MAC) → fifo_rd_en → fifo_full → idle_ready → dec_ready → desc_ready → deskew_ready → am_ready → sync_ready → gb_ready → rx_ready
```

## 5. 状态指示

### 5.1 块锁定状态

```
block_lock[3:0]:
  - 各 lane 独立的块锁定状态
  - 全部为 1 时表示所有 lane 已锁定
  - 由 eth_pcs_block_sync 模块输出

锁定条件:
  - 连续检测到有效的 sync header (01 或 10)
  - 滑动窗口内 sync header 正确率 > 阈值
```

### 5.2 Lane 去偏斜状态

```
deskew_done:
  - Lane 去偏斜完成
  - 由 eth_pcs_lane_deskew 模块输出
  - 此时输出数据已对齐，AM 已删除

去偏斜条件:
  - 所有 lane 检测到 AM
  - 各 lane 从 AM 之后开始同步读取
```

### 5.3 BIP 校验状态

```
bip_error[3:0]:
  - BIP 校验错误指示
  - 每 bit 对应一个逻辑 lane
  - 由 eth_pcs_am_detect 模块输出

用途:
  - 链路质量监测
  - 可用于触发告警或统计
```

### 5.4 链路状态判断

```
链路就绪条件:
  1. block_lock == 4'b1111 (所有 lane 块锁定)
  2. deskew_done == 1'b1 (去偏斜完成)
  3. bip_error == 4'b0000 (无 BIP 错误，可选)

链路状态机:
  LINK_DOWN → (block_lock 全部为 1) → BLOCK_LOCKED
  BLOCK_LOCKED → (deskew_done 为 1) → LINK_UP
  LINK_UP → (block_lock 任一为 0) → LINK_DOWN
```

## 6. 时序图

### 6.1 初始化流程

```
clk_pma_rx:    |  0  |  1  | ... | 64  | 65  | ... | 100 | ... | 200 | ... |
                |     |     |     |     |     |     |     |     |     |     |
rst_n_pma_rx:  |  0  |  1  |  1  |  1  |  1  |  1  |  1  |  1  |  1  |  1  |
                |     |     |     |     |     |     |     |     |     |     |
block_lock:     |  0  |  0  | ... |  7  |  F  |  F  |  F  |  F  |  F  |  F  |
                |     |     |     |     |     |     |     |     |     |     |
deskew_done:    |  0  |  0  | ... |  0  |  0  |  0  |  1  |  1  |  1  |  1  |
                |     |     |     |     |     |     |     |     |     |     |
mac_rx_valid:   |  0  |  0  | ... |  0  |  0  |  0  |  0  |  1  |  1  |  1  |
```

### 6.2 正常数据流

```
TX 路径:
clk_core:       |  N  | N+1 | N+2 | N+3 | N+4 |
                |     |     |     |     |     |
mac_tx_data:    | D0  | D1  | D2  | D3  | D4  |
mac_tx_valid:   |  1  |  1  |  1  |  1  |  1  |
                |     |     |     |     |     |
lane0~3_tx:     |     |     |     | L0~3| L0~3|
tx_valid:       |     |     |     |  1  |  1  |

RX 路径:
clk_pma_rx:     |  N  | N+1 | N+2 | N+3 | N+4 |
                |     |     |     |     |     |
lane0~3_rx:     | L0~3| L0~3| L0~3| L0~3| L0~3|
rx_valid:       |  1  |  1  |  1  |  1  |  1  |
                |     |     |     |     |     |
mac_rx_data:    |     |     | D0  | D1  | D2  |
mac_rx_valid:   |     |     |  1  |  1  |  1  |
```

## 7. 错误处理

### 7.1 TX 错误处理

| 错误类型 | 处理方式 |
|----------|----------|
| PMA 反压 (tx_ready=0) | 数据缓存在 CDC FIFO，FIFO 满时反压到 MAC |
| CDC FIFO 溢出 | 不应发生，设计保证 FIFO 深度足够 |

### 7.2 RX 错误处理

| 错误类型 | 处理方式 |
|----------|----------|
| 块同步失败 (block_lock[i]=0) | 对应 lane 数据无效，等待重新锁定 |
| Lane 映射失败 | 等待检测到所有 lane 的 AM |
| 去偏斜失败 | 等待所有 lane 检测到 AM |
| BIP 校验错误 | 标记 bip_error，可用于告警 |
| MAC 反压 (mac_rx_ready=0) | 数据缓存在 CDC FIFO，FIFO 满时反压到 PMA |
| 频偏过大 | Idle 删除不足以匹配，FIFO 可能溢出 |

### 7.3 错误传播

```
RX 错误传播路径:
  PMA → Gearbox → Block Sync → AM Detect → Lane Deskew → Descrambler → Decoder → Idle Delete → CDC FIFO → MAC

错误标记:
  - block_lock[i]=0: lane i 块同步失败
  - deskew_done=0: 去偏斜未完成
  - bip_error[i]=1: lane i BIP 校验错误
```

## 8. 资源估算

| 资源 | TX 路径 | RX 路径 | 总计 | 说明 |
|------|---------|---------|------|------|
| FF | ~1500 | ~2500 | ~4000 | 流水线寄存器 + FIFO + 状态机 |
| LUT | ~1200 | ~1800 | ~3000 | 编解码/加解扰/同步逻辑 |
| BRAM | 0 | 0 | 0 | 使用分布式 RAM |

## 9. 测试要点

| 测试项 | 说明 |
|--------|------|
| TX 数据流 | 验证数据正确编码、加扰、分发、CDC |
| RX 数据流 | 验证数据正确解码、解扰、对齐、CDC |
| 块同步 | 验证各 lane 正确锁定块边界 |
| Lane 重排序 | 验证物理 lane 到逻辑 lane 映射正确 |
| Lane 去偏斜 | 验证各 lane 数据正确对齐 |
| AM 处理 | 验证 TX AM 插入和 RX AM 删除 |
| Idle 删除 | 验证帧间 Idle 正确删除 |
| 速率匹配 | 验证不同频偏下 FIFO 不溢出/不读空 |
| BIP 校验 | 验证 TX BIP 计算和 RX BIP 校验 |
| CDC | 验证跨时钟域数据正确传输 |
| 反压处理 | 验证 TX/RX 反压时数据不丢失 |
| 复位行为 | 验证复位后状态正确 |
| 环回测试 | TX → RX 环回验证完整数据流 |

## 10. 与其他模块的关系

```
┌─────────────────────────────────────────────────────────────┐
│                        eth_mac_top                          │
│                                                             │
│  AXI-Stream TX ─────► MAC TX ─────► XLGMII TX              │
│                                          │                  │
└──────────────────────────────────────────┼──────────────────┘
                                           │
                                           ▼
┌─────────────────────────────────────────────────────────────┐
│                       eth_pcs_top                           │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    eth_pcs_tx                        │   │
│  │  编码 → 加扰 → AM 插入 → Lane 分布 → Gearbox + CDC  │   │
│  │  (clk_core 域)                        (clk_pma_tx)  │   │
│  └─────────────────────────────────────────────────────┘   │
│                                           │                  │
│                                           ▼                  │
│                              4×32-bit @ clk_pma_tx          │
│                                           │                  │
│                                           ▼                  │
│                                        PMA TX                │
│                                                             │
│                                        PMA RX                │
│                                           │                  │
│                              4×32-bit @ clk_pma_rx          │
│                                           │                  │
│                                           ▼                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    eth_pcs_rx                        │   │
│  │  Gearbox → 块同步 → AM 检测 → 去偏斜 → 解扰 → 解码  │   │
│  │  → Idle 删除 → CDC FIFO                             │   │
│  │  (全部在 clk_pma_rx 域)            (clk_core)       │   │
│  └─────────────────────────────────────────────────────┘   │
│                                           │                  │
└───────────────────────────────────────────┼──────────────────┘
                                           │
                                           ▼
┌─────────────────────────────────────────────────────────────┐
│                        eth_mac_top                          │
│                                                             │
│  XLGMII RX ─────► MAC RX ─────► AXI-Stream RX              │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## 11. 参考文献

- IEEE 802.3-2018 Clause 82 (PCS for 40GBASE-R)
- IEEE 802.3-2018 Clause 82.2.3 (64B/66B Encoding)
- IEEE 802.3-2018 Clause 82.2.5 (Scrambling)
- IEEE 802.3-2018 Clause 82.2.6 (Block Distribution)
- IEEE 802.3-2018 Clause 82.2.7 (Alignment Marker Insertion)
- IEEE 802.3-2018 Clause 82.2.8 (Alignment Marker Detection)
- IEEE 802.3-2018 Clause 82.2.9 (Lane Deskew)
- IEEE 802.3-2018 Clause 82.2.10 (Block Synchronization)
- IEEE 802.3-2018 Clause 46.3.4 (Rate Matching)

## 12. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-13 | 初始版本 |
| 2.0 | 2026-04-13 | RX 处理链移到 clk_pma_rx 域，添加 Idle 删除模块实现速率匹配 |
