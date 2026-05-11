# eth_mac_rx_fcs 模块详细设计

## 1. 概述

### 1.1 功能
对接收的以太网帧进行 CRC32 校验，检测 FCS 错误。
- 使用内部 `crc32` 模块计算帧数据的 CRC
- 在帧尾比较计算结果与接收的 FCS
- 输出 FCS 错误标志，供统计和错误处理使用

### 1.2 关键参数
| 参数 | 值 | 说明 |
|------|-----|------|
| 数据位宽 | 128-bit | 输入输出数据宽度 |
| FCS 长度 | 4 字节 | IEEE 802.3 CRC32 |
| CRC 延迟 | 2 周期 | 匹配内部 crc32 模块流水线 |
| 校验魔数 | 0x2144DF1C | CRC32 固定残值 |

### 1.3 数据流位置
```
eth_mac_rx_preamble → eth_mac_rx_fcs → eth_mac_rx_pause → AXI-Stream 输出
```

---

## 2. 接口定义

```systemverilog
module eth_mac_rx_fcs (
    input  wire         clk,
    input  wire         rst_n,          // 同步复位，低有效

    // 输入流 (来自前导码剥离)
    input  wire         in_valid,
    input  wire [127:0] in_data,
    input  wire [15:0]  in_tkeep,
    input  wire         in_tlast,
    output wire         in_ready,

    // 输出流 (去往 Pause 检测)
    output wire         out_valid,
    output wire [127:0] out_data,
    output wire [15:0]  out_tkeep,
    output wire         out_tlast,
    input  wire         out_ready,

    // 错误输出
    output wire         fcs_error,      // FCS 校验错误
    output wire         fcs_valid       // FCS 校验完成
);
```

### 2.1 信号说明
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| clk | input | 1 | 时钟，312.5 MHz |
| rst_n | input | 1 | 同步复位，低有效 |
| in_valid | input | 1 | 输入数据有效 |
| in_data | input | 127:0 | 输入数据 (从目的 MAC 开始) |
| in_tkeep | input | 15:0 | 输入字节有效 |
| in_tlast | input | 1 | 输入帧结束 |
| in_ready | output | 1 | 输入就绪 |
| out_valid | output | 1 | 输出数据有效 |
| out_data | output | 127:0 | 输出数据 (含 FCS) |
| out_tkeep | output | 15:0 | 输出字节有效 |
| out_tlast | output | 1 | 输出帧结束 |
| out_ready | input | 1 | 输出就绪 |
| fcs_error | output | 1 | FCS 校验错误 |
| fcs_valid | output | 1 | FCS 校验完成 |

---

## 3. 架构设计

### 3.1 CRC 校验原理

以太网帧 FCS 校验方法:
1. 对帧数据 (DA + SA + Type + Payload + FCS) 进行 CRC32 计算
2. 如果 FCS 正确，CRC32 结果应为固定残值 `0x2144DF1C`
3. 否则为 FCS 错误

### 3.2 延迟匹配

`crc32` 模块有 2 周期流水线延迟。为使校验与帧尾对齐:

```
数据路径:  in_data → [D1] → [D2] → out_data (延迟 2 周期)
CRC 路径:  in_data → crc32 → crc_out (延迟 2 周期)

帧尾时刻:  in_tlast=1 → 2 周期后 crc_out 有效
```

### 3.3 帧尾 FCS 处理

帧尾可能包含 FCS 的全部或部分字节:

```
情况 1: 帧尾包含完整 4 字节 FCS
    in_tkeep = 16'hFFFF (16 字节有效)
    最后 4 字节是 FCS

情况 2: 帧尾包含部分 FCS
    in_tkeep = 16'h00FF (8 字节有效)
    FCS 跨两个周期
```

### 3.4 数据输出策略

**方案**: 原样输出含 FCS 的数据，由下游模块 (eth_mac_rx_pause 或软件) 决定是否剥离 FCS。

优点:
- 保持数据完整性
- 下游可选择保留或剥离 FCS
- 简化本模块逻辑

---

## 4. 详细设计

### 4.1 内部信号

```systemverilog
reg         in_pkt;             // 帧内状态
reg         sop;                // 帧起始

// 延迟线 (匹配 CRC 延迟)
reg [127:0] dly_data [0:1];
reg [15:0]  dly_tkeep [0:1];
reg         dly_tlast [0:1];
reg         dly_valid [0:1];

// CRC 相关
wire [31:0] crc_out;
wire        crc_valid;
reg         fcs_error_reg;
reg         fcs_valid_reg;
```

### 4.2 CRC 实例化

```systemverilog
// CRC 输入: 整个帧 (DA ~ FCS)
crc32 u_crc32 (
    .clk       (clk),
    .rst_n     (rst_n),
    .start     (sop),
    .data_in   (in_data),
    .byte_en   (in_tkeep),
    .crc_out   (crc_out),
    .crc_valid (crc_valid)
);
```

### 4.3 延迟线

```systemverilog
always @(posedge clk) begin
    if (!rst_n) begin
        dly_data[0]  <= 128'h0;  dly_data[1]  <= 128'h0;
        dly_tkeep[0] <= 16'h0;   dly_tkeep[1] <= 16'h0;
        dly_tlast[0] <= 1'b0;    dly_tlast[1] <= 1'b0;
        dly_valid[0] <= 1'b0;    dly_valid[1] <= 1'b0;
    end else if (in_valid && in_ready) begin
        dly_data[0]  <= in_data;  dly_data[1]  <= dly_data[0];
        dly_tkeep[0] <= in_tkeep; dly_tkeep[1] <= dly_tkeep[0];
        dly_tlast[0] <= in_tlast; dly_tlast[1] <= dly_tlast[0];
        dly_valid[0] <= 1'b1;     dly_valid[1] <= dly_valid[0];
    end else if (out_ready) begin
        dly_valid[0] <= 1'b0;     dly_valid[1] <= dly_valid[0];
    end
end
```

### 4.4 FCS 校验

```systemverilog
// 帧尾检测
wire frame_end = dly_tlast[1] && dly_valid[1];

// CRC 校验: 帧尾时刻检查 crc_out
always @(posedge clk) begin
    if (!rst_n) begin
        fcs_error_reg <= 1'b0;
        fcs_valid_reg <= 1'b0;
    end else begin
        if (frame_end && crc_valid) begin
            // 帧尾且 CRC 有效: 进行校验
            fcs_error_reg <= (crc_out != 32'h2144DF1C);
            fcs_valid_reg <= 1'b1;
        end else if (out_valid && out_ready && out_tlast) begin
            // 帧输出完成: 清除标志
            fcs_error_reg <= 1'b0;
            fcs_valid_reg <= 1'b0;
        end
    end
end

assign fcs_error = fcs_error_reg;
assign fcs_valid = fcs_valid_reg;
```

### 4.5 输出控制

```systemverilog
// 帧状态跟踪
always @(posedge clk) begin
    if (!rst_n) begin
        in_pkt <= 1'b0;
        sop    <= 1'b0;
    end else if (in_valid && in_ready) begin
        if (!in_pkt) begin
            in_pkt <= 1'b1;
            sop    <= 1'b1;
        end else begin
            sop <= 1'b0;
        end
        
        if (in_tlast) begin
            in_pkt <= 1'b0;
        end
    end
end

// 输出有效: 延迟线有数据
assign out_valid = dly_valid[1];

// 输出数据: 直接来自延迟线
assign out_data  = dly_data[1];
assign out_tkeep = dly_tkeep[1];
assign out_tlast = dly_tlast[1];

// 输入就绪: 延迟线未满或下游就绪
assign in_ready = !dly_valid[0] || out_ready;
```

---

## 5. 边界情况处理

### 5.1 FCS 跨周期
如果 FCS 跨越两个周期:
- 第 N 周期: 帧数据尾部
- 第 N+1 周期: FCS 剩余字节 (tlast=1)

CRC 计算会正确处理这种情况，因为 crc32 模块支持多周期计算。

### 5.2 短帧 (< 4 字节)
- 极端情况，实际以太网最短帧为 64 字节
- 如果发生，CRC 校验仍然有效

### 5.3 背靠背帧
- 前一帧的 fcs_valid 在帧输出完成后清除
- 新帧的 sop 重新初始化 CRC

---

## 6. 资源估算

| 资源 | 估算值 | 说明 |
|------|--------|------|
| CRC32 | ~800 LUT + 100 FF | 128-bit 并行 CRC |
| 延迟线 | ~300 FF | 2 级 128+16+1 bit |
| 控制逻辑 | ~50 LUT | 状态机 + 校验 |

---

## 7. 测试要点

| 测试项 | 说明 |
|--------|------|
| 正确 FCS | 验证含正确 FCS 的帧 fcs_error=0 |
| 错误 FCS | 验证含错误 FCS 的帧 fcs_error=1 |
| CRC 连续性 | 验证跨多周期帧的 CRC 计算正确 |
| 背靠背帧 | 验证连续帧的 FCS 校验独立 |
| fcs_valid 时序 | 验证 fcs_valid 在帧尾时刻正确置位 |
| 反压处理 | 验证 out_ready=0 时数据不丢失 |
| 复位行为 | 验证复位后状态正确 |
