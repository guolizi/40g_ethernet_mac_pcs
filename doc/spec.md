# 40G Ethernet MAC + PCS 设计规格

## 1. 概述

### 1.1 设计目标
实现一个符合 IEEE 802.3ba 标准的 40GBASE-LR4 以太网 MAC + PCS 层，用于 Xilinx UltraScale+ FPGA。

### 1.2 设计范围
| 项目 | 说明 |
|------|------|
| 包含层级 | MAC (Media Access Control) + PCS (Physical Coding Sublayer) |
| 不包含 | PMA (Physical Medium Attachment) / SerDes / GT 收发器 |
| 目标器件 | Xilinx UltraScale+ |
| 物理层标准 | 40GBASE-LR4 (4波分复用，长距离单模光纤) |
| 验证框架 | Cocotb (Python) |

### 1.3 关键参数
| 参数 | 值 |
|------|-----|
| 线速 | 40.625 Gbps |
| 内部数据位宽 | 128-bit |
| 时钟频率 (MAC/PCS 核心) | 312.5 MHz |
| 时钟频率 (PMA 接口) | 由 PMA 提供 (TX/RX 时钟独立) |
| 时钟架构 | 多时钟域 (MAC/PCS 核心 312.5MHz + PMA 接口时钟由 PMA 提供) |
| Lane 数 | 4 (每 lane 64-bit 数据) |
| 编码方式 | 64B/66B |
| Jumbo 帧 | 最大 9216 字节 |

---

## 2. 系统架构

### 2.1 顶层框图

```
                    AXI-Stream (128-bit, 312.5 MHz)
                    ┌─────────────────────────────┐
                    │  s_axis_tdata  [127:0]      │
                    │  s_axis_tkeep  [15:0]       │
                    │  s_axis_tlast               │
                    │  s_axis_tvalid              │
                    │  s_axis_tready              │
                    │  s_axis_tuser   [7:0]       │
                    └──────────────┬──────────────┘
                                   │
                          ┌────────▼────────┐
                          │                 │
                          │     MAC 层      │
                          │                 │
                          └────────┬────────┘
                                   │ 128-bit XGMII-like
                          ┌────────▼────────┐
                          │                 │
                          │     PCS 层      │
                          │                 │
                          └────────┬────────┘
                                   │
              ┌────────────┬───────┴───────┬────────────┐
              │            │               │            │
       ┌──────▼──────┐ ┌──▼──────┐ ┌──────▼──────┐ ┌──▼──────┐
       │ Lane 0      │ │ Lane 1  │ │ Lane 2      │ │ Lane 3  │
       │ 64-bit数据  │ │ 64-bit  │ │ 64-bit数据  │ │ 64-bit  │
       └─────────────┘ └─────────┘ └─────────────┘ └─────────┘
              │            │               │            │
              └────────────┴───────────────┴────────────┘
                                   │
                            (to PMA / SerDes)
```

### 2.2 数据流

**TX 路径:**
```
AXI-Stream → MAC (前导码/FCS/Pause) → PCS (64B/66B编码/加扰/Lane分布) → 4x 66-bit lanes
```

**RX 路径:**
```
4x 66-bit lanes → PCS (Lane去偏斜/解码/解扰) → MAC (FCS校验/Pause解析) → AXI-Stream
```

---

## 3. 项目目录结构

```
eth_40g/
├── rtl/
│   ├── mac/              # MAC 层模块
│   │   ├── eth_mac_top.sv
│   │   ├── eth_mac_tx.sv
│   │   ├── eth_mac_tx_fifo.sv
│   │   ├── eth_mac_tx_preamble.sv
│   │   ├── eth_mac_tx_fcs.sv
│   │   ├── eth_mac_tx_pause.sv
│   │   ├── eth_mac_tx_ipg.sv
│   │   ├── eth_mac_xgmii_enc.sv
│   │   ├── eth_mac_rx.sv
│   │   ├── eth_mac_rx_preamble.sv
│   │   ├── eth_mac_rx_fcs.sv
│   │   ├── eth_mac_rx_pause.sv
│   │   ├── eth_mac_xgmii_dec.sv
│   │   └── eth_mac_stats.sv
│   ├── pcs/              # PCS 层模块
│   │   ├── eth_pcs_top.sv
│   │   ├── eth_pcs_tx.sv
│   │   ├── eth_pcs_64b66b_enc.sv
│   │   ├── eth_pcs_scrambler.sv
│   │   ├── eth_pcs_am_insert.sv
│   │   ├── eth_pcs_lane_dist.sv
│   │   ├── eth_pcs_gearbox_tx.sv
│   │   ├── eth_pcs_rx.sv
│   │   ├── eth_pcs_gearbox_rx.sv
│   │   ├── eth_pcs_lane_deskew.sv
│   │   ├── eth_pcs_am_detect.sv
│   │   ├── eth_pcs_descrambler.sv
│   │   ├── eth_pcs_64b66b_dec.sv
│   │   ├── eth_pcs_block_sync.sv
│   │   └── eth_pcs_idle_delete.sv
│   └── common/           # 通用模块
│       ├── crc32.sv
│       ├── sync_fifo.sv
│       └── lfsr.sv
├── tb/                   # Cocotb 测试平台
│   ├── test_mac_tx.py
│   ├── test_mac_rx.py
│   ├── test_pcs_tx.py
│   ├── test_pcs_rx.py
│   ├── test_mac_pcs_integration.py
│   └── models/           # Python 参考模型
│       ├── mac_model.py
│       ├── pcs_model.py
│       └── crc32_model.py
├── sim/                  # 仿真脚本
│   ├── Makefile
│   └── run_sim.sh
├── scripts/              # 综合/实现脚本
│   └── synth.tcl
└── doc/                  # 设计文档
    └── spec.md           # 本文件
```

---

## 4. MAC 层设计

### 4.1 功能列表

| 功能 | 说明 |
|------|------|
| 帧收发 | 前导码 (Preamble) + SFD 生成/解析 |
| FCS | CRC32 生成 (TX) / 校验 (RX)，IEEE 802.3 多项式 |
| 帧间隔 | IPG (Inter-Packet Gap) 插入，TX 可配置，RX 不检测 |
| 流量控制 | IEEE 802.3x Pause 帧生成与解析 |
| VLAN | 802.1Q tag (4 字节) 透传与可选剥离 |
| Jumbo 帧 | 最大 9216 字节 payload |
| 统计计数器 | 详细统计 (见 4.5 节) |

### 4.2 MAC 模块划分

#### 4.2.1 eth_mac_top.sv - MAC 顶层
- 实例化 TX/RX 路径子模块
- 管理控制信号和状态
- 连接 AXI-Stream 接口和内部 XGMII-like 接口
- 实例化 XGMII 编解码模块 (eth_mac_xgmii_enc/dec)

#### 4.2.2 eth_mac_tx.sv - TX 路径
- 从 AXI-Stream 接收数据
- 协调前导码、FCS、Pause 帧插入
- 输出类 AXI-Stream 流 (data, tkeep, tlast, valid, ready)

**子模块:**
| 模块 | 功能 |
|------|------|
| eth_mac_tx_fifo.sv | TX 数据缓冲，速率匹配 |
| eth_mac_tx_pause.sv | Pause 帧 payload 生成 (60B)，MUX 插入到数据流 |
| eth_mac_tx_preamble.sv | 前导码 (7字节 0x55) + SFD (1字节 0xD5) 插入 |
| eth_mac_tx_fcs.sv | CRC32 计算与 FCS 追加 (跳过 Preamble/SFD) |
| eth_mac_tx_ipg.sv | IPG (帧间间隔) 插入，长度可配置 |

**TX 数据流:**
```
AXI-Stream → tx_fifo → [tx_pause MUX] → tx_preamble → tx_fcs → tx_ipg → xgmii_enc → PCS
```

- Pause 帧仅生成 60 字节 payload (DA+SA+Type+Opcode+PauseTime+Padding)
- Preamble/SFD 由 tx_preamble 统一插入，FCS 由 tx_fcs 统一计算
- Pause 帧和普通帧走相同的处理路径，保证格式一致

#### 4.2.3 eth_mac_tx_pause.sv - Pause 帧插入
- 生成 IEEE 802.3x Pause 帧 payload (60 字节，不含 Preamble/SFD/FCS)
- 自动暂停输入流，等待当前帧结束后插入 Pause payload
- 下游 tx_preamble 加 Preamble/SFD，tx_fcs 加 FCS，tx_ipg 加 IPG

#### 4.2.4 eth_mac_tx_preamble.sv - 前导码插入
- 在每帧起始处插入 8 字节 Preamble (7×0x55) + SFD (0xD5)
- 合并输出策略: Preamble/SFD 与帧前 8 字节合并在一个 128-bit 周期

#### 4.2.5 eth_mac_tx_fcs.sv - FCS 追加
- 对以太网帧数据 (跳过 Preamble/SFD) 进行 CRC32 计算
- 在帧尾追加 4 字节 FCS (支持合并输出和分周期输出)

#### 4.2.6 eth_mac_tx_ipg.sv - IPG 插入
- 在每帧结束后插入可配置的 IPG (默认 12 字节，范围 8~64)
- 智能扣除: 利用帧尾 (`tlast` 周期) 的无效字节空间自动扣除 IPG 长度
- 仅对剩余不足部分插入空闲周期 (拉低 `out_valid` 和 `in_ready`)

#### 4.2.7 eth_mac_xgmii_enc.sv - XGMII TX 编码
- 将内部流 (data, tkeep, tlast) 转换为 XLGMII 格式 (data, ctrl)
- 帧尾插入 `/T/` (Terminate) 控制字符
- 帧间插入 `/I/` (Idle) 控制字符 (检测 `in_valid=0` 时)
- 输出: `mac_tx_data[127:0]`, `mac_tx_ctrl[15:0]`, `mac_tx_valid`, `mac_tx_ready`

#### 4.2.8 eth_mac_rx.sv - RX 路径
- 从 PCS 层接收数据
- 剥离前导码/SFD
- FCS 校验与错误标记
- 输出到 AXI-Stream

**子模块:**
| 模块 | 功能 |
|------|------|
| eth_mac_rx_preamble.sv | 前导码/SFD 检测与剥离 |
| eth_mac_rx_fcs.sv | CRC32 校验，错误指示 |
| eth_mac_rx_pause.sv | Pause 帧检测与解析，提取 pause_time |

> RX 方向不需要 FIFO：MAC 处理速度 ≥ PCS 处理速度，纯流水线即可。

#### 4.2.5 eth_mac_xgmii_dec.sv - XGMII RX 解码
- 解析 XLGMII 格式 (data, ctrl) 为内部流 (data, tkeep, tlast)
- 检测 `/S/` (Start) 和 `/T/` (Terminate) 控制字符
- 恢复帧边界信息 (tlast, tkeep)
- 输入: `pcs_rx_data[127:0]`, `pcs_rx_ctrl[15:0]`, `pcs_rx_valid`, `pcs_rx_ready`

#### 4.2.6 eth_mac_stats.sv - 统计计数器
- 所有统计寄存器的集中管理
- 支持软件读取 (可选 AXI-Lite 寄存器接口)

### 4.3 帧格式

#### 4.3.1 标准以太网帧
```
┌─────────────┬──────────┬──────────┬──────────┬──────┬─────────┬─────┐
│ 前导码 (7B) │ SFD (1B) │ 目的MAC  │ 源MAC    │ 类型 │ Payload│ FCS │
│ 0x55...     │ 0xD5     │ (6B)     │ (6B)     │(2B)  │(46-9170)│(4B) │
└─────────────┴──────────┴──────────┴──────────┴──────┴─────────┴─────┘
```

#### 4.3.2 VLAN 标记帧
```
┌─────────────┬──────────┬──────────┬──────────┬──────────┬──────────┬──────┬─────────┬─────┐
│ 前导码 (7B) │ SFD (1B) │ 目的MAC  │ 源MAC    │ TPID     │ TCI      │ 类型 │ Payload │ FCS │
│             │          │ (6B)     │ (6B)     │ (0x8100) │ (2B)     │(2B)  │         │(4B) │
└─────────────┴──────────┴──────────┴──────────┴──────────┴──────────┴──────┴─────────┴─────┘
```

#### 4.3.3 Pause 帧
```
┌─────────────┬──────────┬──────────┬──────────┬──────────┬──────────┬──────────┬─────┐
│ 前导码 (7B) │ SFD (1B) │ 目的MAC  │ 源MAC    │ 类型     │ Opcode   │ Pause    │ FCS │
│             │          │01:80:C2: │ (6B)     │ (0x8808) │ (0x0001) │ Time(2B) │(4B) │
│             │          │00:00:01  │          │          │          │          │     │
└─────────────┴──────────┴──────────┴──────────┴──────────┴──────────┴──────────┴─────┘
```

### 4.4 错误处理

| 错误类型 | 检测方式 | 处理方式 |
|----------|----------|----------|
| FCS 错误 | CRC 校验不匹配 | 标记 tuser 错误位，计数，可配置丢弃 |
| 帧过短 | 帧长 < 64 字节 | 标记错误，计数 |
| 帧过长 | 帧长 > 配置的最大值 (默认 9216 字节) | 标记错误，计数，丢弃 |
| 对齐错误 | 非字节对齐 | 标记错误，计数 |

> 注意: RX 方向不检测 IPG，任意 IPG 长度的报文均可正常处理。

### 4.5 IPG (Inter-Packet Gap) 处理

#### 4.5.1 TX 方向
- IPG 长度可通过寄存器配置 (单位: 字节)
- 默认值: 12 字节 (IEEE 802.3 标准)
- 可配置范围: 8 ~ 64 字节
- 在连续帧发送时，自动在帧间插入配置的 IPG 字节数 (用 Idle 填充)

#### 4.5.2 RX 方向
- 不检测 IPG 长度
- 任意 IPG 长度的报文均可正常接收和处理

### 4.5 统计计数器

| 计数器 | 位宽 | 说明 |
|--------|------|------|
| tx_frames | 48 | 发送帧总数 |
| tx_bytes | 48 | 发送字节总数 |
| tx_pause_frames | 48 | 发送 Pause 帧数 |
| rx_frames | 48 | 接收帧总数 |
| rx_bytes | 48 | 接收字节总数 |
| rx_fcs_errors | 48 | FCS 错误帧数 |
| rx_short_frames | 48 | 过短帧数 (< 64B) |
| rx_long_frames | 48 | 过长帧数 (> 配置最大值) |
| rx_alignment_errors | 48 | 对齐错误数 |
| rx_pause_frames | 48 | 接收 Pause 帧数 |
| rx_vlan_frames | 48 | VLAN 标记帧数 |
| rx_dropped | 48 | 丢弃帧数 (FIFO满/错误) |
| rx_frames_64 | 48 | 64 字节帧数 |
| rx_frames_65_127 | 48 | 65-127 字节帧数 |
| rx_frames_128_255 | 48 | 128-255 字节帧数 |
| rx_frames_256_511 | 48 | 256-511 字节帧数 |
| rx_frames_512_1023 | 48 | 512-1023 字节帧数 |
| rx_frames_1024_1518 | 48 | 1024-1518 字节帧数 |
| rx_frames_1519_max | 48 | 1519-最大帧长 字节数 |

---

## 5. PCS 层设计

### 5.1 功能列表

| 功能 | 说明 |
|------|------|
| 64B/66B 编码 | 数据块 (sync=01) 和控制块 (sync=10) 编码，sync 位于 bit[1:0] |
| 64B/66B 解码 | 接收端解码，恢复数据和控制信息 |
| 加扰 | 自同步加扰器，多项式 G(x) = 1 + x + x^39 + x^58 |
| 解扰 | 自同步解扰器 |
| Lane 分布 | TX: 128-bit 分发到 4 lanes (每 lane 32-bit) |
| Lane 聚合 | RX: 4 lanes 聚合回 128-bit |
| 对齐标记插入 | TX: 每 16383 个 66-bit 块插入一次 66-bit AM |
| 对齐标记检测 | RX: 检测 AM 用于 lane 对齐和去偏斜 |
| BIP 计算 | TX: 计算并插入 BIP3/BIP7 到 AM 中 |
| Lane 去偏斜 | 补偿 lane 间 skew，最大 ±66 block |

### 5.2 PCS 模块划分

#### 5.2.1 eth_pcs_top.sv - PCS 顶层
- 实例化 TX/RX 路径子模块
- 管理 lane 时钟和控制信号

#### 5.2.2 eth_pcs_tx.sv - TX 路径
- 从 MAC 接口接收 66-bit 块流
- 加扰
- 对齐标记插入
- Lane 分布
- Gearbox (66-bit → 64-bit)

**子模块:**
| 模块 | 功能 |
|------|------|
| eth_pcs_64b66b_enc.sv | 64-bit 数据/控制 → 66-bit 块编码 |
| eth_pcs_scrambler.sv | 自同步加扰 G(x) = 1 + x + x^39 + x^58 |
| eth_pcs_am_insert.sv | 对齐标记插入 (每 16383 块) |
| eth_pcs_lane_dist.sv | 128-bit → 4x 66-bit lane 分布 + BIP 计算 |
| eth_pcs_gearbox_tx.sv | TX Gearbox: 66-bit → 64-bit 位宽转换 |

#### 5.2.3 eth_pcs_rx.sv - RX 路径
- 从 4 lanes 接收 32-bit 数据
- 整个处理链在 clk_pma_rx 域运行
- Gearbox 位宽转换 (32-bit → 66-bit)
- Lane 去偏斜
- 对齐标记检测
- 解扰
- 64B/66B 解码
- Idle 删除 (速率匹配)
- CDC 到 clk_core 域

**子模块:**
| 模块 | 功能 |
|------|------|
| eth_pcs_gearbox_rx.sv | RX Gearbox: 32-bit → 66-bit 位宽转换 (无 CDC) |
| eth_pcs_block_sync.sv | 块边界同步 (确定 66-bit 块起始) |
| eth_pcs_am_detect.sv | 对齐标记检测与提取 |
| eth_pcs_lane_deskew.sv | Lane 去偏斜 (补偿 skew) |
| eth_pcs_descrambler.sv | 自同步解扰 |
| eth_pcs_64b66b_dec.sv | 66-bit 块 → 64-bit 数据/控制解码 |
| eth_pcs_idle_delete.sv | Idle 删除，实现速率匹配 |

### 5.3 64B/66B 编码

#### 5.3.1 块格式

**Bit 顺序** (IEEE 802.3-2018 Clause 82.2.3.3):
- **Bit 0** 是第一个发送的位（LSB first）
- **Sync Header**: Bit 1:0
- **Payload**: Bit 65:2

```
66-bit 块:
┌──────┬──────────────────────────────────────────────────────────────┐
│ Sync │ Block Payload (64-bit)                                       │
│(2-bit)│                                                             │
├──────┼──────────────────────────────────────────────────────────────┤
│ 01   │ D[0] D[1] D[2] D[3] D[4] D[5] D[6] D[7]  (纯数据块)         │
│ 10   │ 控制块 (见下表)                                              │
└──────┴──────────────────────────────────────────────────────────────┘

注意: Sync Header 位于 Bit 1:0（不是 Bit 65:64）！
```

#### 5.3.2 控制块格式
```
控制块 (sync=10):
┌──────┬──────┬───────────────────────────────────────────────────────┐
│ Sync │ Type │ Block Payload                                         │
│ 10   │(8B)  │ (56-bit)                                              │
├──────┼──────┼───────────────────────────────────────────────────────┤
│ 10   │ 0x1E │ /I/   /I/   /I/   /I/   /I/   /I/   /I/   /I/         │  Idle
│ 10   │ 0x78 │ /S/   D[0]  D[1]  D[2]  D[3]  D[4]  D[5]  D[6]      │  Start
│ 10   │ 0x87 │ /T/   D[0]  D[1]  D[2]  D[3]  D[4]  D[5]  D[6]      │  Term (1 T)
│ 10   │ 0x99 │ /T/   /T/   D[0]  D[1]  D[2]  D[3]  D[4]  D[5]      │  Term (2 T)
│ 10   │ 0xAA │ /T/   /T/   /T/   D[0]  D[1]  D[2]  D[3]  D[4]      │  Term (3 T)
│ 10   │ 0xB4 │ /T/   /T/   /T/   /T/   D[0]  D[1]  D[2]  D[3]      │  Term (4 T)
│ 10   │ 0xCC │ /T/   /T/   /T/   /T/   /T/   D[0]  D[1]  D[2]      │  Term (5 T)
│ 10   │ 0xD2 │ /T/   /T/   /T/   /T/   /T/   /T/   D[0]  D[1]      │  Term (6 T)
│ 10   │ 0xE1 │ /T/   /T/   /T/   /T/   /T/   /T/   /T/   D[0]      │  Term (7 T)
│ 10   │ 0xFF │ /T/   /T/   /T/   /T/   /T/   /T/   /T/   /T/       │  Term (8 T)
│ 10   │ 0x4B │ /O/   O0    D[1]  D[2]  Z4    Z5    Z6    Z7        │  Ordered Set
└──────┴──────┴───────────────────────────────────────────────────────┘

/S/ = Start (0xFB on XLGMII)
/D/ = Data (任意字节)
/T/ = Terminate (0xFD 或 0xFE on XLGMII)
/O/ = Ordered Set control (0x9C on XLGMII)
/I/ = Idle (0x07 on XLGMII)
O0 = O code (identifies the ordered set type)
Z4-Z7 = Zero padding (0x00)

说明:
- Idle块 (Type=0x1E): 8个Idle字符，用于帧间填充
- Start块 (Type=0x78): 帧起始，/S/后跟7字节数据
- Terminate块 (Type=0x87~0xFF): 帧结束，包含1-8个/T/字符
- Ordered Set块 (Type=0x4B): 用于链路信令（远端故障、FlexE等）
```

#### 5.3.3 控制字符编码

**XLGMII 控制字符与 40/100GBASE-R 控制码对应关系**:

| 字符 | XLGMII 编码 (hex) | 40/100GBASE-R 控制码 (7-bit) | 说明 |
|------|-------------------|------------------------------|------|
| /I/  | 0x07              | 0x00                         | Idle (空闲) |
| /LI/ | 0x06              | 0x06                         | LPI Idle |
| /S/  | 0xFB              | 由 Type 隐含                 | Start (帧开始) |
| /T/  | 0xFD              | 由 Type 隐含                 | Terminate (帧结束) |
| /E/  | 0xFE              | 0x1E                         | Error (错误) |
| /Q/  | 0x9C              | 0x0D                         | Sequence Ordered Set |

**说明**:
- /S/ 和 /T/ 在 64B/66B 编码中由控制块的 Type 字段隐含表示
- 控制块 payload 中每个控制字符占用 7-bit（非 8-bit）
- 数据字节在控制块 payload 中仍为 8-bit

### 5.4 加扰/解扰

**多项式:** G(x) = 1 + x + x^39 + x^58 (IEEE 802.3-2018 Clause 49.2.6)

**加扰公式:**
```
scrambled[i] = data[i] XOR scrambled[i-58] XOR scrambled[i-39]
```

**加扰器:**
- 自同步加扰器，不需要初始同步
- 对每个 66-bit 块的 64-bit payload (bit[65:2]) 进行加扰
- sync header (bit[1:0]) 不加扰，原样传递
- LFSR 长度 58 位

**解扰器:**
- 同样使用 G(x) = 1 + x + x^39 + x^58
- 自同步特性确保自动对齐

### 5.5 对齐标记 (Alignment Marker)

#### 5.5.1 插入周期
- 每 **16383** 个 66-bit 块插入一次对齐标记（IEEE 802.3-2018 Clause 82.2.7）
- 对齐标记替换一个数据/控制块的位置
- AM 不加扰，sync header = 10

#### 5.5.2 AM 格式 (66-bit)

**Bit 定义**:
```
Bit 1:0:   Sync Header = 10 (control block)
Bit 9:2:   M0
Bit 17:10: M1
Bit 25:18: M2
Bit 33:26: BIP3
Bit 41:34: M4 (= ~M0)
Bit 49:42: M5 (= ~M1)
Bit 57:50: M6 (= ~M2)
Bit 65:58: BIP7 (= ~BIP3)
```

#### 5.5.3 每 Lane 的 AM 值 (IEEE 802.3-2018 Table 82-3)

| Lane | M0 | M1 | M2 | M4 | M5 | M6 |
|------|------|------|------|------|------|------|
| 0 | 0x90 | 0x76 | 0x47 | 0x6F | 0x89 | 0xB8 |
| 1 | 0xF0 | 0xC4 | 0xE6 | 0x0F | 0x3B | 0x19 |
| 2 | 0xC5 | 0x65 | 0x9B | 0x3A | 0x9A | 0x64 |
| 3 | 0xA2 | 0x79 | 0x3D | 0x5D | 0x86 | 0xC2 |

#### 5.5.4 BIP 计算 (IEEE 802.3-2018 Table 82-4)

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

### 5.6 Lane 分布与去偏斜

#### 5.6.1 TX: Lane 分布
```
128-bit 数据流 (每时钟 2 个 66-bit 块)
        │
        ▼
┌───────────────┐
│ Round-Robin   │
│ 分发器        │
└───┬───┬───┬───┘
    │   │   │   │
   L0  L1  L2  L3
   66  66  66  66
   bit bit bit bit
```

- 每时钟周期产生 2 个 66-bit 块
- 4 个 lane 轮询分发
- 每 lane 每 2 个时钟周期获得 1 个 66-bit 块

#### 5.6.2 TX: Gearbox (66-bit → 32-bit)

**位宽与时钟关系:**
```
66-bit @ clk_core (312.5 MHz)  →  32-bit @ clk_pma_tx (322.266 MHz, 由 PMA 提供)
```

**转换原理:**
- 每个 66-bit 块包含 2-bit sync header + 64-bit payload
- Gearbox 将 66-bit 块重新打包为 32-bit 输出
- 每 16 个 66-bit 块 → 33 个 32-bit 输出
- clk_pma_tx 由 PMA 提供，与 clk_core 为异步时钟关系

**实现方式:**
- 通过 CDC FIFO 隔离 clk_core 和 clk_pma_tx 两个时钟域
- CDC FIFO 深度: 64 entries
- 移位寄存器将 66-bit 重新打包为 32-bit

#### 5.6.3 RX: Gearbox (32-bit → 66-bit)

**位宽与时钟关系:**
```
32-bit @ clk_pma_rx (322.266 MHz, 由 PMA 提供)  →  66-bit @ clk_pma_rx
```

**注意:** RX Gearbox 仅做位宽转换，不做 CDC。整个 PCS RX 处理链在 clk_pma_rx 域运行。

**实现方式:**
- 移位寄存器将 32-bit 重新打包为 66-bit
- 每 33 个 32-bit 输入 → 16 个 66-bit 块
- 块同步模块 (block_sync) 在 66-bit 流中确定块边界

#### 5.6.4 RX: Lane 去偏斜
- 每个 lane 独立检测对齐标记
- 比较各 lane AM 的到达时间
- 使用 FIFO 缓冲快 lane，等待慢 lane
- 最大可补偿 skew: ±66 块 (约 ±4 个 128-bit 周期)

---

## 6. 接口定义

### 6.1 AXI-Stream 接口 (上游)

| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| s_axis_tclk | input | 1 | 时钟 (312.5 MHz) |
| s_axis_tresetn | input | 1 | 异步复位 (低有效) |
| s_axis_tdata | input | 127:0 | 数据 |
| s_axis_tkeep | input | 15:0 | 字节有效掩码 |
| s_axis_tlast | input | 1 | 帧结束指示 |
| s_axis_tvalid | input | 1 | 数据有效 |
| s_axis_tready | output | 1 | 接收就绪 |
| s_axis_tuser | input | 7:0 | 用户定义 (错误指示等) |

### 6.2 MAC-PCS 内部接口 (XLGMII-like, 128-bit)

**TX 方向 (MAC → PCS):**
| 信号 | 位宽 | 说明 |
|------|------|------|
| mac_tx_data | 127:0 | 数据 (每 8-bit 对应 1 字节) |
| mac_tx_ctrl | 15:0 | 控制标志 (每 8-bit 对应 1-bit ctrl: 0=数据, 1=控制字符) |
| mac_tx_valid | 1 | 数据有效 |
| mac_tx_ready | 1 | PCS 就绪 |

**RX 方向 (PCS → MAC):**
| 信号 | 位宽 | 说明 |
|------|------|------|
| pcs_rx_data | 127:0 | 数据 |
| pcs_rx_ctrl | 15:0 | 控制标志 (每 8-bit 对应 1-bit ctrl: 0=数据, 1=控制字符) |
| pcs_rx_valid | 1 | 数据有效 |
| pcs_rx_ready | 1 | MAC 就绪 |

**控制字符编码 (8-bit, 当 ctrl=1 时):**
| 字符 | 编码 | 说明 |
|------|------|------|
| /I/ (Idle) | 0x07 | 帧间空闲 |
| /S/ (Start) | 0xFB | 帧开始 (可选，通常由 Preamble 隐含) |
| /T/ (Terminate) | 0xFD | 帧结束 |
| /E/ (Error) | 0xFE | 错误传播 |
| /LI/ (Local Idle) | 0x06 | 本地空闲 |
| /R/ (Remote Fault) | 0x1E | 远端故障 |

**TX 编码示例 (eth_mac_xgmii_enc):**
| 场景 | `data` 内容 | `ctrl` 值 |
|------|-------------|-----------|
| 正常数据 | 原始数据 | `16'h0000` (全 0) |
| 帧尾 (`tlast=1`, 有效 10 字节) | 前 10 字节为数据，后 6 字节为 `/T/` (0xFD) | `16'hFC00` (低 10 位 0，高 6 位 1) |
| 帧间空闲 (`valid=0`) | 全 `/I/` (0x07) | `16'hFFFF` (全 1) |

**RX 解码示例 (eth_mac_xgmii_dec):**
- 检测 `ctrl=1` 且 `data=0xFD` (`/T/`) → 生成 `tlast=1`
- 根据 `ctrl` 中 1 的位置确定 `/T/` 位置，恢复 `tkeep`
- 帧间 `/I/` 被丢弃，不传递给内部模块

### 6.3 PCS-PMA 输出接口 (4 Lanes, 32-bit)

**TX 方向 (PCS → PMA):**

| 信号 | 位宽 | 时钟域 | 说明 |
|------|------|--------|------|
| lane0_tx_data | 31:0 | clk_pma_tx (322.266 MHz) | Lane 0 的 32-bit 数据 |
| lane1_tx_data | 31:0 | clk_pma_tx | Lane 1 的 32-bit 数据 |
| lane2_tx_data | 31:0 | clk_pma_tx | Lane 2 的 32-bit 数据 |
| lane3_tx_data | 31:0 | clk_pma_tx | Lane 3 的 32-bit 数据 |
| tx_valid | 1 | clk_pma_tx | 数据有效 (所有 lane 共用) |
| tx_ready | 1 | clk_pma_tx | PMA 就绪 (反压) |

**RX 方向 (PMA → PCS):**

| 信号 | 位宽 | 时钟域 | 说明 |
|------|------|--------|------|
| lane0_rx_data | 31:0 | clk_pma_rx (PMA 恢复时钟) | Lane 0 的 32-bit 数据 |
| lane1_rx_data | 31:0 | clk_pma_rx | Lane 1 的 32-bit 数据 |
| lane2_rx_data | 31:0 | clk_pma_rx | Lane 2 的 32-bit 数据 |
| lane3_rx_data | 31:0 | clk_pma_rx | Lane 3 的 32-bit 数据 |
| rx_valid | 1 | clk_pma_rx | 数据有效 (所有 lane 共用) |
| rx_ready | 1 | clk_pma_rx | PCS 就绪 (反压) |

> 注意: PMA 恢复时钟可能有 ±100 ppm 频偏，RX 侧通过 CDC FIFO 隔离时钟域。

### 6.4 管理接口 (AXI4-Lite)

| 信号 | 位宽 | 说明 |
|------|------|------|
| s_axi_awaddr | 15:0 | 写地址 |
| s_axi_awvalid | 1 | 写地址有效 |
| s_axi_awready | 1 | 写地址就绪 |
| s_axi_wdata | 31:0 | 写数据 |
| s_axi_wstrb | 3:0 | 写字节选通 |
| s_axi_wvalid | 1 | 写数据有效 |
| s_axi_wready | 1 | 写数据就绪 |
| s_axi_bresp | 1:0 | 写响应 |
| s_axi_bvalid | 1 | 写响应有效 |
| s_axi_bready | 1 | 写响应就绪 |
| s_axi_araddr | 15:0 | 读地址 |
| s_axi_arvalid | 1 | 读地址有效 |
| s_axi_arready | 1 | 读地址就绪 |
| s_axi_rdata | 31:0 | 读数据 |
| s_axi_rresp | 1:0 | 读响应 |
| s_axi_rvalid | 1 | 读数据有效 |
| s_axi_rready | 1 | 读数据就绪 |

---

## 7. 时钟与复位

### 7.1 时钟
| 时钟 | 频率 | 用途 |
|------|------|------|
| clk_core | 312.5 MHz | MAC 和 PCS 核心时钟 (统一时钟域) |
| clk_pma_tx | 由 PMA 提供 | PCS → PMA TX 接口时钟 |
| clk_pma_rx | 由 PMA 提供 (PMA 恢复时钟) | PMA → PCS RX 接口时钟 |

### 7.2 时钟域
| 时钟域 | 模块 | 时钟源 |
|--------|------|--------|
| clk_core | MAC 全部 + PCS TX 核心 (编解码/加扰/AM/lane分布) | 本地 312.5 MHz |
| clk_pma_tx | TX Gearbox (读侧) | 本地时钟 (PMA 提供) |
| clk_pma_rx | PCS RX 全部 (Gearbox/同步/检测/去偏斜/解扰/解码/Idle删除) | 远端恢复时钟 (PMA 提供) |

### 7.3 跨时钟域 (CDC)
| 位置 | 方向 | 方式 |
|------|------|------|
| TX Gearbox | 66-bit @ clk_core → 32-bit @ clk_pma_tx | CDC FIFO (64 entries) |
| RX MAC 接口 | 144-bit @ clk_pma_rx → 144-bit @ clk_core | CDC FIFO (64 entries) + Idle 删除 |

### 7.4 速率匹配
| 方向 | 机制 | 说明 |
|------|------|------|
| TX | 无需速率匹配 | clk_core 和 clk_pma_tx 同源 (本地时钟) |
| RX | Idle 删除 | clk_pma_rx (远端恢复) 与 clk_core (本地) 不同源，通过删除帧间 Idle 实现速率匹配 |

### 7.4 复位
| 复位 | 类型 | 用途 |
|------|------|------|
| rst_n | 同步，低有效 | 全局复位 (所有模块统一使用同步复位) |
| soft_rst | 同步，高有效 | 软件可控复位 |

> 注意: 所有模块统一使用同步复位。外部异步复位信号 (如有) 需在顶层通过两级同步器同步后使用。

---

## 8. 验证计划

### 8.1 验证框架
- **工具**: Cocotb + Icarus Verilog 或 Xcelium/VCS
- **语言**: Python (测试) + SystemVerilog (DUT)

### 8.2 测试用例

#### MAC 层测试
| 测试项 | 说明 |
|--------|------|
| test_single_frame_tx | 单帧发送，验证前导码/SFD/FCS |
| test_single_frame_rx | 单帧接收，验证前导码/SFD剥离/FCS校验 |
| test_back_to_back_frames | 背靠背帧发送/接收 |
| test_pause_frame_tx | Pause 帧生成 |
| test_pause_frame_rx | Pause 帧解析，验证 pause_time |
| test_vlan_frame | VLAN 标记帧透传 |
| test_jumbo_frame | 9216 字节 Jumbo 帧 |
| test_short_frame | 过短帧检测 |
| test_fcs_error | FCS 错误检测 |
| test_ipg_config | TX IPG 可配置性验证 |
| test_rx_any_ipg | RX 接收任意 IPG 长度的帧 |
| test_flow_control | 流量控制 (TX 暂停响应 RX Pause) |
| test_axi_backpressure | AXI-Stream 反压测试 |

#### PCS 层测试
| 测试项 | 说明 |
|--------|------|
| test_64b66b_enc_dec | 64B/66B 编解码环回 |
| test_scrambler_descrambler | 加扰/解扰环回 |
| test_lane_distribution | Lane 分布正确性 |
| test_am_insert_detect | 对齐标记插入与检测 |
| test_lane_deskew | Lane 去偏斜功能 |
| test_pcs_full_tx_rx | PCS 完整 TX→RX 环回 |
| test_pcs_with_skew | 注入 lane skew，验证去偏斜 |

#### 集成测试
| 测试项 | 说明 |
|--------|------|
| test_mac_pcs_loopback | MAC → PCS → MAC 环回 |
| test_full_throughput | 满线速吞吐量测试 |
| test_error_propagation | 错误传播测试 |

---

## 9. 已确认事项

### 9.1 设计决策
| 事项 | 决策 |
|------|------|
| 对齐标记值 | 先用占位值搭框架，标准值后续填入 |
| Auto-Negotiation | 不支持 (40GBASE-LR4 不需要) |
| Link Fault Signaling | 支持，基础实现 (Local/Remote Fault) |
| 统计计数器清零 | 饱和计数，不清零 |
| MAC 地址过滤 | 不支持 (接收所有帧) |
| RS-FEC | 不支持 (40GBASE-LR4 不要求) |
| Idle 插入 | 需要，TX 无帧时自动插入 Idle 控制字符 |
| 错误传播 | 不需要，仅标记错误，不通过 /E/ 传播 |
| Pause 响应 | 自动响应，收到 Pause 后自动暂停 TX |
| VLAN 剥离 | 不支持，VLAN tag 透传 |
| 广播/多播 | 全部接收 |
| TX FIFO 深度 | 2KB |
| RX FIFO | 不需要 (纯流水线) |
| Pause 时间单位 | 512 bit times (IEEE 802.3 标准) |
| 块同步算法 | 滑动窗口 (检测 sync header 10/01 模式) |
| MTU 配置 | 寄存器可配 (默认 9216) |
| 速率适配 | Idle 插入/删除 (TX 空闲插 Idle，RX 删除 Idle 做速率匹配) |
| 管理接口 | AXI4-Lite 协议 |
| Pause 响应延迟 | < 100ns (从 Pause 请求到 Pause 帧开始发送，不含等待当前帧结束) |
| 64B/66B 流水线 | 2 周期流水线 |
| 控制字符集 | 完整集 (/I/, /S/, /T/, /O/, /LI/, /RF/, /LF/, /E/ 等) |
| BIP 校验 | 需要，AM 中包含 BIP 用于链路质量监测 |
| TX IPG | 可配置 (寄存器配置，范围 8~64 字节，默认 12 字节) |
| RX IPG | 不检测，任意 IPG 均可处理 |
| 统计计数器位宽 | 全部 48-bit |
| 复位策略 | 全部同步复位 (无异步复位) |
| PCS-PMA 接口位宽 | 4x 32-bit @ 322.266 MHz |
| TX Gearbox | 66-bit @ clk_core → 32-bit @ clk_pma_tx, CDC FIFO (64 entries) |
| RX 处理链 | 全部在 clk_pma_rx 域运行，Idle 删除实现速率匹配，CDC 在 MAC 接口处 |
| 速率匹配 | RX 方向通过 Idle 删除实现，补偿 ±100 ppm 频偏 |
| PMA 接口时钟 | TX: 本地时钟，RX: 远端恢复时钟 |

### 9.2 仍需确认
- [ ] 目标 FPGA 的具体型号 (影响 PLL 和 GT 原语选择)
- [ ] 时序约束 (312.5 MHz 和 322.266 MHz 下的时序余量)
- [ ] 资源预算 (LUT/FF/BRAM 上限)
- [ ] 功耗要求
- [ ] PMA 恢复时钟的频偏范围 (±50 ppm 还是 ±100 ppm)
- [ ] PMA 侧 32-bit 接口是否有 ready/flow control 信号

---

## 10. 参考文档

| 文档 | 说明 |
|------|------|
| IEEE 802.3ba-2010 | 40GbE 和 100GbE 标准 |
| IEEE 802.3-2018 Clause 49 | 64B/66B 编码 |
| IEEE 802.3-2018 Clause 82 | PCS for 40GBASE-R |
| IEEE 802.3-2018 Clause 83 | 64B/66B 编码细节 |
| IEEE 802.3-2018 Clause 84 | 40GBASE-LR4 PMA |
| IEEE 802.3-2018 Clause 22 | MAC 规范 |
| IEEE 802.3-2018 Clause 30 | Management |
| AMBA AXI4-Stream Protocol | AXI-Stream 接口规范 |

---

## 11. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-08 | 初始版本 |
| 1.1 | 2026-04-14 | 修正 5.6.2/5.6.3 Gearbox 描述：TX 为 66-bit → 32-bit，RX 为 32-bit → 66-bit |
