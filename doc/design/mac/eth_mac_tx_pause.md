# eth_mac_tx_pause 模块详细设计

## 1. 概述

### 1.1 功能
- 生成 IEEE 802.3x Pause 帧 **payload** (不含 Preamble/SFD/FCS)
- 内部包含 MUX 和流控逻辑，自动暂停输入流并插入 Pause payload
- Pause payload 由内部状态机生成，源 MAC 地址通过寄存器配置
- 输出的 Pause payload 经由下游 tx_preamble (加 Preamble/SFD) 和 tx_fcs (加 FCS) 处理，与普通帧走相同路径

> **架构说明**: tx_pause 仅生成 Pause 帧的 MAC payload (DA + SA + Type + Opcode + PauseTime + Padding = 60 字节)。Preamble/SFD 由 tx_preamble 插入，FCS 由 tx_fcs 计算追加，IPG 由 tx_ipg 插入。这样 Pause 帧和普通帧走相同的处理路径，保证格式一致。

### 1.2 关键参数
| 参数 | 值 | 说明 |
|------|-----|------|
| 数据位宽 | 128-bit | 输入输出数据宽度 |
| Pause payload 长度 | 60 字节 | IEEE 802.3x 标准 (DA+SA+Type+Opcode+PauseTime+Padding) |
| 完整 Pause 帧 | 72 字节 | 含 Preamble/SFD (8B) + payload (60B) + FCS (4B) |
| 源 MAC 地址 | 寄存器输入 | 通过 `pause_src_mac` 配置 |

### 1.3 Pause 帧格式 (完整帧)
```
┌─────────────┬──────────┬──────────┬──────────┬──────────┬──────────┬──────────┬─────┐
│ 前导码 (7B) │ SFD (1B) │ 目的MAC  │ 源MAC    │ 类型     │ Opcode   │ Pause    │ FCS │
│             │          │01:80:C2: │ (6B)     │ (0x8808) │ (0x0001) │ Time(2B) │(4B) │
│             │          │00:00:01  │          │          │          │          │     │
└─────────────┴──────────┴──────────┴──────────┴──────────┴──────────┴──────────┴─────┘
  ↑ tx_preamble 插入      ↑ tx_pause 生成 (60B payload)            ↑ tx_fcs 计算追加
```

### 1.4 TX 数据流
```
AXI-Stream → tx_fifo → [MUX] → tx_preamble → tx_fcs → tx_ipg → xgmii_enc → PCS
                        ↑
                    tx_pause (生成 60B Pause payload)
```

- 正常帧: 从 tx_fifo 读取，经 MUX 直通
- Pause 帧: tx_pause 生成 payload，经 MUX 插入，后续同样经过 tx_preamble/tx_fcs/tx_ipg

---

## 2. 接口定义

```systemverilog
module eth_mac_tx_pause (
    input  wire         clk,
    input  wire         rst_n,          // 同步复位，低有效

    // 输入流 (来自 TX FIFO)
    input  wire         in_valid,
    input  wire [127:0] in_data,
    input  wire [15:0]  in_tkeep,
    input  wire         in_tlast,
    output wire         in_ready,

    // 输出流 (去往 Preamble 插入, AXI-Stream)
    output wire         out_valid,
    output wire [127:0] out_data,
    output wire [15:0]  out_tkeep,
    output wire         out_tlast,
    input  wire         out_ready,

    // Pause 控制
    input  wire         pause_req,      // Pause 帧发送请求
    input  wire [15:0]  pause_time,     // Pause 时间 (单位: 512 bit times)
    input  wire [47:0]  pause_src_mac,  // 源 MAC 地址

    // 状态输出
    output wire         pause_busy      // Pause 帧正在发送中
);
```

---

## 3. 架构设计

### 3.1 状态机
```
IDLE:
    正常透传输入流。
    若 pause_req=1 → 等待当前帧结束 (in_tlast=1) → 进入 PAUSE_INSERT

PAUSE_INSERT:
    输出 Pause payload (60 字节 = 4 个 128-bit 周期)。
    完成后 → 回到 IDLE
```

### 3.2 Pause Payload 数据布局 (4 个周期, 60 字节)
```
Cycle 0 (16 字节):
    Bytes 0-5:  DA = 01:80:C2:00:00:01
    Bytes 6-11: SA = pause_src_mac[47:0]
    Bytes 12-13: Type = 0x8808 (以太网帧中 Byte12=0x88, Byte13=0x08)
    Bytes 14-15: Opcode = 0x0001 (以太网帧中 Byte14=0x00, Byte15=0x01)

Cycle 1 (16 字节):
    Bytes 0-1:  Pause Time = pause_time (小端序)
    Bytes 2-15: Padding (0x00)

Cycle 2 (16 字节):
    Bytes 0-15: Padding (0x00)

Cycle 3 (12 字节, tlast=1):
    Bytes 0-11: Padding (0x00)
    Bytes 12-15: 无效 (tkeep=0)
```

> 以太网帧字节序: Type/Opcode 字段在帧中按大端序传输（高字节在前）。
> Verilog 实现: 16'h0888 表示 Type=0x8808, 其中高字节 0x08 对应 Byte13, 低字节 0x88 对应 Byte12。

### 3.3 FCS 计算
Pause 帧的 FCS 由下游 tx_fcs 模块统一计算。tx_fcs 的 crc32 模块会对 Pause payload (不含 Preamble/SFD) 进行 CRC32 计算，与正常帧处理方式完全一致。

---

## 4. 详细设计

### 4.1 内部信号
```systemverilog
// 状态编码
localparam IDLE          = 2'b00;
localparam WAIT_EOP      = 2'b01;  // 等待当前帧结束
localparam PAUSE_INSERT  = 2'b10;  // 发送 Pause payload

reg [1:0] state;
reg [1:0] pause_cycle;  // 0~3，Pause payload 的 4 个周期
```

### 4.2 核心逻辑

```systemverilog
// Pause 帧常量
localparam [47:0] PAUSE_DA = 48'h01_80_C2_00_00_01;  // 目的 MAC
localparam [15:0] PAUSE_TYPE = 16'h0888;              // EtherType 0x8808 (高字节=0x08, 低字节=0x88)
localparam [15:0] PAUSE_OPCODE = 16'h0100;            // Opcode 0x0001 (高字节=0x01, 低字节=0x00)

// 输入就绪: 仅在 IDLE 状态且无 pause_req 时接受输入
assign in_ready = (state == IDLE) && !pause_req;

// Pause 帧发送中
assign pause_busy = (state != IDLE);

// 输出有效
assign out_valid = (state == IDLE) ? in_valid : 1'b1;

// 输出数据
always @(*) begin
    case (state)
        IDLE, WAIT_EOP: begin
            // 透传输入流
            out_data  = in_data;
            out_tkeep = in_tkeep;
            out_tlast = in_tlast;
        end

        PAUSE_INSERT: begin
            case (pause_cycle)
                2'd0: begin
                    // DA(6) + SA(6) + Type(2) + Opcode(2) = 16 字节
                    out_data  = {PAUSE_OPCODE, PAUSE_TYPE, pause_src_mac, PAUSE_DA};
                    out_tkeep = 16'hFFFF;
                    out_tlast = 1'b0;
                end
                2'd1: begin
                    // PauseTime(2) + Padding(14) = 16 字节
                    out_data  = {112'h0, pause_time};
                    out_tkeep = 16'hFFFF;
                    out_tlast = 1'b0;
                end
                2'd2: begin
                    // Padding(16) = 16 字节
                    out_data  = 128'h0;
                    out_tkeep = 16'hFFFF;
                    out_tlast = 1'b0;
                end
                2'd3: begin
                    // Padding(12), tlast=1
                    out_data  = 128'h0;
                    out_tkeep = 16'h0FFF;  // 低 12 字节有效
                    out_tlast = 1'b1;
                end
            endcase
        end

        default: begin
            out_data  = 128'h0;
            out_tkeep = 16'h0;
            out_tlast = 1'b0;
        end
    endcase
end

// 状态机
always @(posedge clk) begin
    if (!rst_n) begin
        state       <= IDLE;
        pause_cycle <= 2'd0;
    end else begin
        case (state)
            IDLE: begin
                if (pause_req) begin
                    if (in_tlast && in_valid && in_ready) begin
                        // 当前帧刚好结束，直接插入 Pause
                        state <= PAUSE_INSERT;
                        pause_cycle <= 2'd0;
                    end else begin
                        // 当前帧未结束，等待
                        state <= WAIT_EOP;
                    end
                end
            end

            WAIT_EOP: begin
                if (in_tlast && in_valid && in_ready) begin
                    state <= PAUSE_INSERT;
                    pause_cycle <= 2'd0;
                end
            end

            PAUSE_INSERT: begin
                if (out_ready) begin
                    if (pause_cycle == 2'd3) begin
                        state <= IDLE;
                        pause_cycle <= 2'd0;
                    end else begin
                        pause_cycle <= pause_cycle + 1'b1;
                    end
                end
            end
        endcase
    end
end
```

---

## 5. 资源估算
| 资源 | 估算值 | 说明 |
|------|--------|------|
| FF | ~80 | 状态机 + 控制寄存器 |
| LUT | ~80 | 多路选择 + 常量生成 |

---

## 6. 测试要点
| 测试项 | 说明 |
|--------|------|
| 正常 Pause 插入 | 验证 pause_req 后 Pause payload 正确插入 |
| 帧中请求 | 验证帧中间收到 pause_req 时等待当前帧结束 |
| 背靠背 Pause | 验证连续 pause_req 的处理 |
| 反压处理 | 验证 out_ready=0 时状态机正确等待 |
| 复位行为 | 验证复位后回到 IDLE |
| 数据完整性 | 验证 Pause payload 60 字节内容正确 (DA/SA/Type/Opcode/PauseTime) |
