# eth_mac_tx_preamble 模块详细设计

## 1. 概述

### 1.1 功能
在每帧数据起始处插入 8 字节的前导码 (Preamble) + SFD。
- Preamble: 7 字节 `0x55`
- SFD: 1 字节 `0xD5`
- **合并输出策略**: 将 Preamble/SFD 与帧的前 8 字节合并在一个 128-bit 周期内输出，避免额外延迟。
- 自动处理短帧 (帧长 < 8 字节) 的 `tkeep` 截断。

### 1.2 关键参数
| 参数 | 值 | 说明 |
|------|-----|------|
| 数据位宽 | 128-bit | 输入输出数据宽度 |
| Preamble+SFD | 8 字节 | `55_55_55_55_55_55_55_D5` |

---

## 2. 接口定义

```systemverilog
module eth_mac_tx_preamble (
    input  wire         clk,
    input  wire         rst_n,          // 同步复位，低有效

    // 输入流 (来自 TX FIFO)
    input  wire         in_valid,
    input  wire [127:0] in_data,
    input  wire [15:0]  in_tkeep,
    input  wire         in_tlast,
    output wire         in_ready,

    // 输出流 (去往 FCS 插入)
    output wire         out_valid,
    output wire [127:0] out_data,
    output wire [15:0]  out_tkeep,
    output wire         out_tlast,
    input  wire         out_ready
);
```

---

## 3. 架构设计

### 3.1 SOP 检测
使用状态标志 `in_pkt` 跟踪当前是否处于包内。
```systemverilog
reg in_pkt;
wire sop = in_valid && !in_pkt;  // 当不在包内且 valid 有效时，为新帧开始

always @(posedge clk) begin
    if (!rst_n) in_pkt <= 1'b0;
    else if (out_valid && out_ready) begin
        if (sop) in_pkt <= 1'b1;       // 开始新包
        else if (out_tlast) in_pkt <= 1'b0; // 包结束
    end
end
```

### 3.2 合并输出策略
当检测到 SOP 时，当前输入周期的 128-bit 数据被拆分:
- `in_data[63:0]` (低 8 字节): 与 Preamble/SFD 合并输出
- `in_data[127:64]` (高 8 字节): 缓冲到寄存器，下一周期输出

**Cycle N (SOP):**
- `out_data` = `{in_data[63:0], PREAMBLE_SFD}`
  - Bytes 0-7: Preamble/SFD
  - Bytes 8-15: 输入数据的低 8 字节 (Data[0:7])
- `out_tkeep` = `16'hFFFF` (Preamble/SFD 总是完整)
- 缓冲: `buf = in_data[127:64]` (Data[8:15])

**Cycle N+1 (缓冲有效):**
- `out_data` = `{next_in_data[63:0], buf}`
  - Bytes 0-7: 缓冲数据 (Data[8:15])
  - Bytes 8-15: 新输入数据的低 8 字节 (Data[16:23])
- `out_tkeep` = `{next_in_tkeep[7:0], 8'hFF}`

### 3.3 短帧处理
如果帧长 < 8 字节 (`in_tkeep[7:0]` 不全为 1):
- `out_data` 高 8 字节仍为 Preamble/SFD，低 8 字节为有效数据。
- `out_tkeep` = `{8'h00, in_tkeep[7:0]}` (假设 Preamble/SFD 总是完整 8 字节，实际有效数据由 `in_tkeep` 决定)。
- `buf_valid` = 0 (因为 `in_tkeep[15:8]` 全 0，高 8 字节无效)。
- `out_tlast` = 1。

---

## 4. 详细设计

### 4.1 内部信号
```systemverilog
localparam PREAMBLE_SFD = 64'hD555555555555555; // 小端序：低字节是 0x55...0xD5

reg [63:0]      buf;
reg             buf_valid;
reg             buf_tlast;
reg             in_pkt;
```

### 4.2 核心逻辑

```systemverilog
// SOP 检测
wire sop = in_valid && !in_pkt;

// 输入就绪: 当缓冲区空，或缓冲区有效但下游就绪时可接受新数据
assign in_ready = !buf_valid || out_ready;

// 输出有效: 当输入有效，或缓冲区有待发送数据时
assign out_valid = in_valid || buf_valid;

// 输出数据组合逻辑
always @(*) begin
    if (buf_valid) begin
        // 发送缓冲的高 8 字节 + 当前输入的低 8 字节
        if (in_valid) begin
            out_data  = {in_data[63:0], buf};
            out_tkeep = {in_tkeep[7:0], 8'hFF};
            out_tlast = in_tlast;
        end else begin
            // 输入无效，仅发送缓冲数据 (填充 0)
            out_data  = {64'h0, buf};
            out_tkeep = {8'h00, 8'hFF};
            out_tlast = buf_tlast;
        end
    end else if (sop) begin
        // SOP: 插入 Preamble/SFD
        out_data  = {in_data[63:0], PREAMBLE_SFD};
        out_tkeep = 16'hFFFF;  // Preamble/SFD 总是完整 8 字节
        out_tlast = in_tlast;  // 极短帧可能 tlast=1
    end else begin
        // 直通
        out_data  = in_data;
        out_tkeep = in_tkeep;
        out_tlast = in_tlast;
    end
end

// 寄存器更新
always @(posedge clk) begin
    if (!rst_n) begin
        in_pkt    <= 1'b0;
        buf_valid <= 1'b0;
    end else begin
        // 更新包状态
        if (out_valid && out_ready) begin
            if (sop) in_pkt <= 1'b1;
            else if (out_tlast) in_pkt <= 1'b0;
        end

        // 更新缓冲区
        if (out_ready && out_valid) begin
            if (buf_valid) begin
                buf_valid <= 1'b0;  // 缓冲区已发送
            end else if (sop && (|in_tkeep[15:8])) begin
                // 高 8 字节有任意有效字节时才缓冲
                buf         <= in_data[127:64];
                buf_tlast   <= in_tlast;
                buf_valid   <= 1'b1;
            end
        end
    end
end
```

---

## 5. 资源估算
| 资源 | 估算值 | 说明 |
|------|--------|------|
| FF | ~100 | 缓冲寄存器 + 控制状态 |
| LUT | ~50 | 多路选择 + SOP 检测 |

---

## 6. 测试要点
| 测试项 | 说明 |
|--------|------|
| 正常帧插入 | 验证长帧的 Preamble/SFD 正确插入且数据不丢失 |
| 短帧处理 | 验证 < 8 字节帧的 `tkeep` 截断和 `tlast` 正确 |
| 背靠背帧 | 验证连续帧之间 Preamble/SFD 不重复插入 |
| 反压处理 | 验证 `out_ready=0` 时数据不丢失、不乱序 |
| 复位行为 | 验证复位后状态机回到 IDLE |
