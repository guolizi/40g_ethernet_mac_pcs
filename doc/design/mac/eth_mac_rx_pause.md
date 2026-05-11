# eth_mac_rx_pause 模块详细设计

## 1. 概述

### 1.1 功能
检测并解析 IEEE 802.3x Pause 帧，提取 pause_time 用于流量控制。
- 检测 Pause 帧特征: DA + EtherType + Opcode
- 提取 Pause Time 字段 (16-bit)
- 输出 pause_req 和 pause_time 给 TX 路径
- Pause 帧数据正常透传 (可选丢弃)

### 1.2 关键参数
| 参数 | 值 | 说明 |
|------|-----|------|
| Pause DA | 01:80:C2:00:00:01 | 标准组播 MAC |
| EtherType | 0x8808 | Pause 帧类型 |
| Opcode | 0x0001 | Pause 操作码 |
| Pause Time 单位 | 512 bit times | IEEE 802.3 标准 |

### 1.3 Pause 帧格式
```
Bytes 0-5:   DA = 01:80:C2:00:00:01
Bytes 6-11:  SA (任意)
Bytes 12-13: Type = 0x8808
Bytes 14-15: Opcode = 0x0001
Bytes 16-17: Pause Time (16-bit, 单位 512 bit times)
Bytes 18-59: Padding (0x00)
Bytes 60-63: FCS
```

### 1.4 数据流位置
```
eth_mac_rx_fcs → eth_mac_rx_pause → AXI-Stream 输出
                                    ↓
                              pause_req/pause_time → eth_mac_tx_pause
```

---

## 2. 接口定义

```systemverilog
module eth_mac_rx_pause (
    input  wire         clk,
    input  wire         rst_n,          // 同步复位，低有效

    // 输入流 (来自 FCS 校验)
    input  wire         in_valid,
    input  wire [127:0] in_data,
    input  wire [15:0]  in_tkeep,
    input  wire         in_tlast,
    input  wire         fcs_error,      // FCS 错误标志
    output wire         in_ready,

    // 输出流 (去往 AXI-Stream 输出)
    output wire         out_valid,
    output wire [127:0] out_data,
    output wire [15:0]  out_tkeep,
    output wire         out_tlast,
    input  wire         out_ready,

    // Pause 控制输出
    output wire         pause_req,      // Pause 请求
    output wire [15:0]  pause_time,     // Pause 时间 (512 bit times)

    // 状态输出
    output wire         pause_detected  // 检测到 Pause 帧
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
| fcs_error | input | 1 | FCS 错误标志 |
| in_ready | output | 1 | 输入就绪 |
| out_valid | output | 1 | 输出数据有效 |
| out_data | output | 127:0 | 输出数据 |
| out_tkeep | output | 15:0 | 输出字节有效 |
| out_tlast | output | 1 | 输出帧结束 |
| out_ready | input | 1 | 输出就绪 |
| pause_req | output | 1 | Pause 请求 (脉冲) |
| pause_time | output | 15:0 | Pause 时间 |
| pause_detected | output | 1 | 检测到 Pause 帧 |

---

## 3. 架构设计

### 3.1 Pause 帧检测方法

在 128-bit 数据总线上，Pause 帧特征分布在前两个周期:

```
Cycle 0 (SOP):
    Bytes 0-5:   DA (检查是否为 01:80:C2:00:00:01)
    Bytes 6-11:  SA (不检查)
    Bytes 12-13: Type (检查是否为 0x8808)
    Bytes 14-15: Opcode (检查是否为 0x0001)

Cycle 1:
    Bytes 0-1:   Pause Time (提取)
    Bytes 2-15:  Padding (不检查)
```

### 3.2 检测逻辑

```
pause_da_match   = (in_data[47:0] == 48'h01_80_C2_00_00_01)
pause_type_match = (in_data[111:96] == 16'h8808)
pause_opcode_match = (in_data[127:112] == 16'h0001)

is_pause_frame = sop && pause_da_match && pause_type_match && pause_opcode_match
```

### 3.3 Pause Time 提取

Pause Time 在 Cycle 1 的 Bytes 0-1:
```
pause_time = in_data[15:0]  // Cycle 1 时
```

### 3.4 输出策略

**方案 A: 丢弃 Pause 帧**
- Pause 帧不输出到 RX FIFO
- 仅输出 pause_req/pause_time

**方案 B: 透传 Pause 帧**
- Pause 帧正常输出
- 同时输出 pause_req/pause_time

**选择方案 B**: 保持数据完整性，由软件决定是否处理。

---

## 4. 详细设计

### 4.1 内部信号

```systemverilog
reg         in_pkt;             // 帧内状态
reg [1:0]   cycle_cnt;          // 帧内周期计数
reg         pause_frame;        // 当前帧是 Pause 帧
reg         pause_frame_reg;    // Pause 帧寄存
reg [15:0]  pause_time_reg;     // Pause Time 寄存

// Pause 帧常量
localparam [47:0] PAUSE_DA     = 48'h01_80_C2_00_00_01;
localparam [15:0] PAUSE_TYPE   = 16'h8808;
localparam [15:0] PAUSE_OPCODE = 16'h0001;
```

### 4.2 Pause 帧检测

```systemverilog
// SOP 检测
wire sop = in_valid && !in_pkt;

// Pause 帧特征检测 (仅在 SOP 周期)
wire pause_da_match     = (in_data[47:0]    == PAUSE_DA);
wire pause_type_match   = (in_data[111:96]  == PAUSE_TYPE);
wire pause_opcode_match = (in_data[127:112] == PAUSE_OPCODE);

wire pause_detected_now = sop && pause_da_match && 
                          pause_type_match && pause_opcode_match;
```

### 4.3 Pause Time 提取

```systemverilog
// Pause Time 在 Cycle 1 (Bytes 0-1)
always @(posedge clk) begin
    if (!rst_n) begin
        pause_time_reg <= 16'h0;
    end else if (in_valid && in_ready && pause_frame && (cycle_cnt == 2'd1)) begin
        pause_time_reg <= in_data[15:0];
    end
end
```

### 4.4 状态机

```systemverilog
// 帧状态跟踪
always @(posedge clk) begin
    if (!rst_n) begin
        in_pkt        <= 1'b0;
        cycle_cnt     <= 2'd0;
        pause_frame   <= 1'b0;
        pause_frame_reg <= 1'b0;
    end else if (in_valid && in_ready) begin
        if (sop) begin
            in_pkt      <= 1'b1;
            cycle_cnt   <= 2'd0;
            pause_frame <= pause_detected_now;
        end else begin
            cycle_cnt <= cycle_cnt + 1'b1;
        end
        
        if (in_tlast) begin
            in_pkt          <= 1'b0;
            pause_frame_reg <= pause_frame;
            pause_frame     <= 1'b0;
        end
    end
end
```

### 4.5 输出控制

```systemverilog
// Pause 请求输出 (脉冲)
reg pause_req_reg;
always @(posedge clk) begin
    if (!rst_n) begin
        pause_req_reg <= 1'b0;
    end else begin
        // 帧结束且是 Pause 帧且 FCS 正确
        pause_req_reg <= in_valid && in_ready && in_tlast && 
                         pause_frame && !fcs_error;
    end
end

assign pause_req    = pause_req_reg;
assign pause_time   = pause_time_reg;
assign pause_detected = pause_frame_reg;

// 数据透传
assign out_valid = in_valid;
assign out_data  = in_data;
assign out_tkeep = in_tkeep;
assign out_tlast = in_tlast;
assign in_ready  = out_ready;
```

---

## 5. 边界情况处理

### 5.1 FCS 错误的 Pause 帧
- 如果 fcs_error=1，不输出 pause_req
- Pause 帧数据仍然透传

### 5.2 短 Pause 帧
- 如果帧长度不足 (tlast 过早)
- 不输出 pause_req

### 5.3 Pause Time = 0
- Pause Time = 0 表示取消暂停
- 正常输出 pause_req

### 5.4 背靠背 Pause 帧
- 连续 Pause 帧各自独立检测
- pause_req 逐帧脉冲输出

---

## 6. 资源估算

| 资源 | 估算值 | 说明 |
|------|--------|------|
| FF | ~50 | 状态 + Pause Time 寄存 |
| LUT | ~50 | DA/Type/Opcode 比较 |

---

## 7. 测试要点

| 测试项 | 说明 |
|--------|------|
| 标准 Pause 帧 | 验证正确 Pause 帧的检测和 pause_time 提取 |
| 非 Pause 帧 | 验证普通帧不触发 pause_req |
| FCS 错误 Pause | 验证 FCS 错误时不输出 pause_req |
| Pause Time=0 | 验证取消暂停帧正确处理 |
| 连续 Pause | 验证背靠背 Pause 帧处理 |
| 数据透传 | 验证 Pause 帧数据正常输出 |
| 反压处理 | 验证 out_ready=0 时数据不丢失 |
| 复位行为 | 验证复位后状态正确 |
