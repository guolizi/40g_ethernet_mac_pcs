# eth_mac_xgmii_dec 模块详细设计

## 1. 概述

### 1.1 功能
将 PCS 输出的 XLGMII 格式 (`data`, `ctrl`) 转换为 AXI-Stream 格式 (`data`, `tkeep`, `tlast`)。
- **帧起始**: 检测 `/S/` (Start) 控制字符
- **帧结束**: 检测 `/T/` (Terminate) 控制字符，生成 `tlast`
- **空闲处理**: 丢弃 `/I/` (Idle) 控制字符
- **有效字节**: 根据 `/T/` 位置计算 `tkeep`

### 1.2 关键参数
| 参数 | 值 | 说明 |
|------|-----|------|
| 数据位宽 | 128-bit | 输入输出数据宽度 |
| 控制位宽 | 16-bit | 每 bit 对应 1 字节 |

### 1.3 数据流位置
```
PCS → eth_mac_xgmii_dec → eth_mac_rx_preamble → ...
```

---

## 2. 接口定义

```systemverilog
module eth_mac_xgmii_dec (
    input  wire         clk,
    input  wire         rst_n,          // 同步复位，低有效

    // XLGMII 输入 (来自 PCS)
    input  wire [127:0] pcs_rx_data,
    input  wire [15:0]  pcs_rx_ctrl,
    input  wire         pcs_rx_valid,
    output wire         pcs_rx_ready,

    // AXI-Stream 输出 (去往 MAC RX)
    output wire         out_valid,
    output wire [127:0] out_data,
    output wire [15:0]  out_tkeep,
    output wire         out_tlast,
    input  wire         out_ready
);
```

### 2.1 信号说明
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| clk | input | 1 | 时钟，312.5 MHz |
| rst_n | input | 1 | 同步复位，低有效 |
| pcs_rx_data | input | 127:0 | PCS 数据 |
| pcs_rx_ctrl | input | 15:0 | 控制标志 (0=数据, 1=控制字符) |
| pcs_rx_valid | input | 1 | PCS 数据有效 |
| pcs_rx_ready | output | 1 | MAC 就绪 |
| out_valid | output | 1 | 输出数据有效 |
| out_data | output | 127:0 | 输出数据 |
| out_tkeep | output | 15:0 | 字节有效掩码 |
| out_tlast | output | 1 | 帧结束 |
| out_ready | input | 1 | 下游就绪 |

---

## 3. 架构设计

### 3.1 控制字符编码

| 字符 | 编码 | 说明 |
|------|------|------|
| /I/ (Idle) | 0x07 | 空闲，丢弃 |
| /S/ (Start) | 0xFB | 帧开始 |
| /T/ (Terminate) | 0xFD | 帧结束 |

### 3.2 解码逻辑

```
场景 1: 空闲 (全 /I/)
    ctrl = 16'hFFFF, data = 全 0x07
    → 不输出 (out_valid=0)

场景 2: 帧起始 (/S/ + 数据)
    ctrl[0]=1, data[7:0]=0xFB
    → out_valid=1, 输出 Bytes 1-15 数据

场景 3: 帧内数据
    ctrl = 16'h0000
    → out_valid=1, 输出全部数据

场景 4: 帧结束 (/T/ 在某位置)
    ctrl = 16'hFC00 (Bytes 10-15 为 /T/)
    → out_valid=1, out_tlast=1, out_tkeep=16'h03FF
```

### 3.3 tkeep 生成

根据 `/T/` 位置确定有效字节数:
```
/T/ 在 Byte N → 有效字节数 = N
tkeep = (1 << N) - 1
```

---

## 4. 详细设计

### 4.1 内部信号

```systemverilog
reg         in_pkt;         // 帧内状态
reg         tlast_pending;  // /T/ 检测，等待输出

// 控制字符检测 (逐字节比较)
wire [15:0] byte_is_idle;
wire [15:0] byte_is_terminate;
wire [15:0] byte_is_start;

genvar gi;
generate
    for (gi = 0; gi < 16; gi++) begin : gen_ctrl_detect
        assign byte_is_idle[gi]       = pcs_rx_ctrl[gi] && (pcs_rx_data[gi*8 +: 8] == 8'h07);
        assign byte_is_terminate[gi]  = pcs_rx_ctrl[gi] && (pcs_rx_data[gi*8 +: 8] == 8'hFD);
        assign byte_is_start[gi]      = pcs_rx_ctrl[gi] && (pcs_rx_data[gi*8 +: 8] == 8'hFB);
    end
endgenerate

wire all_idle = (pcs_rx_ctrl == 16'hFFFF);  // 全 Idle 周期
```

### 4.2 /T/ 位置检测与 tkeep 生成

```systemverilog
// 查找第一个 /T/ 位置
function automatic [4:0] find_first_t(input [15:0] ctrl, input [127:0] data);
    integer i;
    begin
        find_first_t = 5'h1F;  // 未找到
        for (i = 0; i < 16; i++) begin
            if (ctrl[i] && (data[i*8 +: 8] == 8'hFD)) begin
                find_first_t = i[4:0];
            end
        end
    end
endfunction

wire [4:0] t_pos = find_first_t(pcs_rx_ctrl, pcs_rx_data);
wire       has_t = (t_pos != 5'h1F);

// tkeep 生成: /T/ 之前字节有效
wire [15:0] tkeep_from_t = (has_t) ? ((16'h1 << t_pos) - 1) : 16'hFFFF;
```

### 4.3 状态机

```systemverilog
always @(posedge clk) begin
    if (!rst_n) begin
        in_pkt <= 1'b0;
    end else if (pcs_rx_valid && pcs_rx_ready) begin
        if (!in_pkt && |is_start) begin
            in_pkt <= 1'b1;  // 检测到 /S/
        end else if (in_pkt && has_t) begin
            in_pkt <= 1'b0;  // 检测到 /T/
        end
    end
end
```

### 4.4 输出逻辑

```systemverilog
// 输出有效: 帧内数据且非全 Idle
assign out_valid = pcs_rx_valid && in_pkt && (pcs_rx_ctrl != 16'hFFFF);

// 输出数据: 移除控制字符
always @(*) begin
    out_data = pcs_rx_data;  // 控制字符位置数据无效
end

// tkeep: 根据 /T/ 位置
assign out_tkeep = (has_t) ? tkeep_from_t : 16'hFFFF;

// tlast: 检测到 /T/
assign out_tlast = has_t && in_pkt;

// 输入就绪
assign pcs_rx_ready = out_ready;
```

---

## 5. 边界情况处理

### 5.1 /S/ 和 /T/ 在同一周期
- 短帧情况: 帧数据在同一周期开始和结束
- 正确设置 tlast 和 tkeep

### 5.2 多个 /T/ 字符
- 只处理第一个 /T/ (最低位)
- 后续 /T/ 忽略

### 5.3 Idle 周期
- 全 /I/ 周期不输出 (out_valid=0)

---

## 6. 资源估算

| 资源 | 估算值 | 说明 |
|------|--------|------|
| FF | ~20 | 状态寄存器 |
| LUT | ~80 | 控制字符检测 + tkeep 生成 |

---

## 7. 测试要点

| 测试项 | 说明 |
|--------|------|
| 标准帧 | 验证 /S/ 开始、数据透传、/T/ 结束 |
| tkeep 生成 | 验证 /T/ 在不同位置时 tkeep 正确 |
| Idle 处理 | 验证全 /I/ 周期不输出 |
| 短帧 | 验证 /S/ 和 /T/ 同周期 |
| 反压处理 | 验证 out_ready=0 时数据不丢失 |
| 复位行为 | 验证复位后状态正确 |
