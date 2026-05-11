# eth_mac_rx_preamble 模块详细设计

## 1. 概述

### 1.1 功能
检测并剥离以太网帧的前导码 (Preamble) 和帧起始定界符 (SFD)。
- **Preamble**: 7 字节 `0x55`
- **SFD**: 1 字节 `0xD5`
- 按 IEEE 802.3 标准，SFD 固定在 Preamble 之后 (Byte 7)
- 输出跳过 Preamble/SFD 的纯帧数据 (从目的 MAC 地址开始)
- **前导码错误时直接丢弃整帧**

### 1.2 关键参数
| 参数 | 值 | 说明 |
|------|-----|------|
| 数据位宽 | 128-bit | 输入输出数据宽度 |
| Preamble+SFD | 8 字节 | `55_55_55_55_55_55_55_D5` |
| SFD 位置 | Byte 7 | 固定位置 (IEEE 802.3 标准) |

### 1.3 数据流位置
```
PCS → eth_mac_xgmii_dec → eth_mac_rx_preamble → eth_mac_rx_fcs → eth_mac_rx_pause → AXI-Stream 输出
```

---

## 2. 接口定义

```systemverilog
module eth_mac_rx_preamble (
    input  wire         clk,
    input  wire         rst_n,          // 同步复位，低有效

    // 输入流 (来自 XGMII 解码器)
    input  wire         in_valid,
    input  wire [127:0] in_data,
    input  wire [15:0]  in_tkeep,
    input  wire         in_tlast,
    output wire         in_ready,

    // 输出流 (去往 FCS 校验)
    output wire         out_valid,
    output wire [127:0] out_data,
    output wire [15:0]  out_tkeep,
    output wire         out_tlast,
    input  wire         out_ready,

    // 状态输出
    output wire         sop_detected,   // 帧起始检测 (SFD 正确)
    output wire         preamble_error  // 前导码错误 (丢弃帧)
);
```

### 2.1 信号说明
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| clk | input | 1 | 时钟，312.5 MHz |
| rst_n | input | 1 | 同步复位，低有效 |
| in_valid | input | 1 | 输入数据有效 |
| in_data | input | 127:0 | 输入数据 |
| in_tkeep | input | 15:0 | 输入字节有效 |
| in_tlast | input | 1 | 输入帧结束 |
| in_ready | output | 1 | 输入就绪 |
| out_valid | output | 1 | 输出数据有效 |
| out_data | output | 127:0 | 输出数据 (已剥离 Preamble/SFD) |
| out_tkeep | output | 15:0 | 输出字节有效 |
| out_tlast | output | 1 | 输出帧结束 |
| out_ready | input | 1 | 输出就绪 |
| sop_detected | output | 1 | 检测到有效帧起始 |
| preamble_error | output | 1 | 前导码格式错误 (脉冲) |

---

## 3. 架构设计

### 3.1 帧格式 (IEEE 802.3 标准)

```
Cycle 0 (SOP):
    Bytes 0-6:   Preamble = 55 55 55 55 55 55 55
    Byte  7:     SFD = D5
    Bytes 8-15:  目的 MAC (DA) 低 6 字节 + 源 MAC (SA) 高 2 字节
    
Cycle 1:
    Bytes 0-15:  源 MAC 低 4 字节 + EtherType + Payload 起始
```

### 3.2 SFD 检测

按标准，SFD 固定在 Byte 7:
```systemverilog
wire sfd_valid = (in_data[63:56] == 8'hD5);  // Byte 7 = 0xD5
wire preamble_valid = (in_data[55:0] == 56'h55_55_55_55_55_55_55);  // Bytes 0-6
```

### 3.3 数据剥离

SFD 在 Byte 7，帧数据从 Byte 8 开始:
```
out_data[63:0]  = in_data[127:64]   // Bytes 8-15
out_tkeep[7:0]  = in_tkeep[15:8]    // 对应 Bytes 8-15 有效
```

### 3.4 状态机

```
IDLE:
    等待 in_valid
    检测到有效 SFD → 进入 PASS_THROUGH，输出剥离后数据
    检测到无效前导码 → 进入 DROP，丢弃帧

PASS_THROUGH:
    透传帧数据
    检测到 in_tlast → 回到 IDLE

DROP:
    丢弃帧数据 (不输出)
    检测到 in_tlast → 回到 IDLE
```

---

## 4. 详细设计

### 4.1 内部信号

```systemverilog
// 状态编码
localparam IDLE         = 2'b00;
localparam PASS_THROUGH = 2'b01;
localparam DROP         = 2'b10;

reg [1:0] state;
reg       first_cycle;  // 第一个周期标记

// 前导码检测
wire sop = in_valid && in_ready && (state == IDLE);
wire sfd_valid = (in_data[63:56] == 8'hD5);
wire preamble_valid = (in_data[55:0] == 56'h55_55_55_55_55_55_55);
wire preamble_ok = sop && sfd_valid && preamble_valid;
wire preamble_err = sop && !preamble_ok;
```

### 4.2 状态机

```systemverilog
always @(posedge clk) begin
    if (!rst_n) begin
        state      <= IDLE;
        first_cycle <= 1'b0;
    end else begin
        case (state)
            IDLE: begin
                if (in_valid && in_ready) begin
                    if (preamble_ok) begin
                        state       <= PASS_THROUGH;
                        first_cycle <= 1'b1;
                    end else begin
                        state <= DROP;
                    end
                end
            end
            
            PASS_THROUGH: begin
                first_cycle <= 1'b0;
                if (in_valid && in_ready && in_tlast) begin
                    state <= IDLE;
                end
            end
            
            DROP: begin
                if (in_valid && in_ready && in_tlast) begin
                    state <= IDLE;
                end
            end
            
            default: state <= IDLE;
        endcase
    end
end
```

### 4.3 输出逻辑

```systemverilog
// 输出有效: PASS_THROUGH 状态
assign out_valid = (state == PASS_THROUGH) && in_valid;

// 输出数据: 第一周期剥离 Preamble/SFD，后续周期透传
always @(*) begin
    if (first_cycle) begin
        // 第一周期: 剥离 Bytes 0-7 (Preamble/SFD)
        out_data  = {64'h0, in_data[127:64]};  // Bytes 8-15 → 低 8 字节
        out_tkeep = {8'h0, in_tkeep[15:8]};
        out_tlast = 1'b0;  // 第一周期不可能是帧尾
    end else begin
        // 后续周期: 透传
        out_data  = in_data;
        out_tkeep = in_tkeep;
        out_tlast = in_tlast;
    end
end

// 输入就绪
assign in_ready = (state == DROP) || out_ready;

// 状态输出
assign sop_detected = preamble_ok;
assign preamble_error = preamble_err;
```

---

## 5. 边界情况处理

### 5.1 背靠背帧
- 前一帧 `in_tlast=1` 后，状态机回到 IDLE
- 下一周期可立即检测新帧的 SFD

### 5.2 前导码错误
- 检测到无效前导码 → 进入 DROP 状态
- 丢弃整帧数据，直到 `in_tlast=1`
- `preamble_error` 输出脉冲

### 5.3 帧长度不足
- 如果在 PASS_THROUGH 期间 `in_tlast` 过早到达
- 正常输出，由下游模块处理

---

## 6. 资源估算

| 资源 | 估算值 | 说明 |
|------|--------|------|
| FF | ~10 | 状态机 + first_cycle |
| LUT | ~30 | SFD 检测 + MUX |

---

## 7. 测试要点

| 测试项 | 说明 |
|--------|------|
| 标准帧 | 验证正确 Preamble/SFD 的剥离 |
| 前导码错误 | 验证无效前导码时帧被丢弃 |
| SFD 位置错误 | 验证 SFD 不在 Byte 7 时被丢弃 |
| 背靠背帧 | 验证连续帧正确处理 |
| 反压处理 | 验证 out_ready=0 时数据不丢失 |
| 复位行为 | 验证复位后状态正确 |
