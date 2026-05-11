# eth_mac_xgmii_enc 模块详细设计

## 1. 概述

### 1.1 功能
将 MAC 内部 AXI-Stream 流 (`data`, `tkeep`, `tlast`, `ipg_bytes`) 转换为 XLGMII 格式 (`data`, `ctrl`)。
- **帧尾处理**: 在 `tlast` 周期，将无效字节位置填充为 `/T/` (0xFD) + `/I/` (0x07)，并设置对应的 `ctrl` 位。
- **IPG 插入**: 根据 `ipg_bytes` 在帧尾后精确插入指定数量的 `/I/` 字符。
- **连续输出**: XLGMII 为连续流，`out_valid` 始终为 1。

### 1.2 IPG 处理流程
1. `tlast` 周期：无效字节填充 /T/ (第一个) + /I/ (其余)
2. `ipg_bytes` 周期：在帧尾后额外插入 `ipg_bytes` 个 /I/ 字符
3. 后续周期：输出 /I/ 直到下一帧开始

### 1.3 关键参数
| 参数 | 值 | 说明 |
|------|-----|------|
| 数据位宽 | 128-bit | 输入输出数据宽度 |
| 控制位宽 | 16-bit | 每 bit 对应 1 字节 (0=数据, 1=控制字符) |

---

## 2. 接口定义

```systemverilog
module eth_mac_xgmii_enc (
    input  wire         clk,
    input  wire         rst_n,          // 同步复位，低有效

    // 输入流 (来自 IPG 模块, AXI-Stream 格式)
    input  wire         in_valid,
    input  wire [127:0] in_data,
    input  wire [15:0]  in_tkeep,
    input  wire         in_tlast,
    input  wire [3:0]   ipg_bytes,      // 需要插入的 IPG 字节数 (0-15)
    input  wire         need_t_cycle,   // 是否需要额外的 T 周期
    output wire         in_ready,

    // 输出流 (去往 PCS - XLGMII 格式)
    output wire         out_valid,      // 始终为 1 (XLGMII 连续流)
    output wire [127:0] out_data,
    output wire [15:0]  out_ctrl,
    input  wire         out_ready
);
```

---

## 3. 架构设计

### 3.1 状态机
```
IDLE:
    等待输入数据。
    若 in_valid=1:
        若 in_tlast=1 → 进入 IPG_INSERT (插入 ipg_bytes 个 /I/)
        否则 → 保持在 IDLE，输出数据

IPG_INSERT:
    插入 ipg_bytes 个 /I/ 字符。
    每周期输出 16 个 /I/，计数递减。
    若 ipg_cnt=0 → 回到 IDLE
```

### 3.2 数据转换逻辑
| 场景 | `out_data` | `out_ctrl` |
|------|------------|------------|
| 正常数据 | `in_data` | `16'h0000` (全 0) |
| 帧尾 (tkeep 指示有效字节) | 有效字节: `in_data`，无效字节: /T/ + /I/ | 有效字节: 0，无效字节: 1 |
| IPG 插入 | 全 `0x07` (`/I/`) | `16'hFFFF` (全 1) |

### 3.3 帧尾字节填充规则
假设 `tkeep = 0x03FF` (10 字节有效)：
- Bytes 0-9: 数据 (ctrl=0)
- Byte 10: /T/ (0xFD, ctrl=1)
- Bytes 11-15: /I/ (0x07, ctrl=1)

### 3.4 IPG 插入示例
假设 `ipg_bytes = 12`：
- 帧尾周期：输出帧尾数据 + /T/ + 部分 /I/
- IPG 周期：输出 16 个 /I/，但只有前 12 个是 IPG，后 4 个是下一帧前的预填充
- 实际上，IPG 插入需要精确控制每个字节

**简化方案**：IPG 插入以 16 字节为单位
- `ipg_bytes = 0`: 无需额外插入
- `ipg_bytes = 1~16`: 插入 1 个周期的 /I/ (16 字节)

**精确方案**：需要状态机跟踪当前字节位置
- 维护 `byte_pos` 指示当前输出位置
- 根据 `ipg_bytes` 精确控制 /I/ 数量

---

## 4. 详细设计

### 4.1 内部信号
```systemverilog
reg [127:0] out_data_reg;
reg [15:0]  out_ctrl_reg;

// IPG 插入状态
reg         ipg_state;          // 0=IDLE, 1=IPG_INSERT
reg [3:0]   ipg_cnt;            // 剩余 IPG 字节数
reg [3:0]   byte_pos;           // 当前字节位置 (用于精确 IPG 控制)
```

### 4.2 核心逻辑

```systemverilog
// 输出始终有效 (XLGMII 连续流)
assign out_valid = 1'b1;

// 输入就绪: 非IPG状态或IPG已完成
assign in_ready = !ipg_state && out_ready;

// 计算帧尾输出 (组合逻辑)
wire [127:0] tail_data;
wire [15:0]  tail_ctrl;

genvar i;
generate
    for (i = 0; i < 16; i++) begin : gen_tail
        assign tail_data[i*8 +: 8] = in_tkeep[i] ? in_data[i*8 +: 8] : 
                                     (i == popcount(in_tkeep)) ? 8'hFD : 8'h07;
        assign tail_ctrl[i] = in_tkeep[i] ? 1'b0 : 1'b1;
    end
endgenerate

// 状态机
always @(posedge clk) begin
    if (!rst_n) begin
        ipg_state   <= 1'b0;
        ipg_cnt     <= 4'h0;
        out_data_reg <= {16{8'h07}};
        out_ctrl_reg <= 16'hFFFF;
    end else if (out_ready) begin
        if (ipg_state) begin
            // IPG 插入状态
            if (ipg_cnt == 0) begin
                ipg_state <= 1'b0;
            end else begin
                ipg_cnt <= ipg_cnt - 4'd16;  // 简化: 以16字节为单位
            end
            out_data_reg <= {16{8'h07}};
            out_ctrl_reg <= 16'hFFFF;
        end else if (in_valid && in_ready) begin
            if (in_tlast) begin
                // 帧尾: 输出 /T/ + /I/
                out_data_reg <= tail_data;
                out_ctrl_reg <= tail_ctrl;
                // 如果有额外IPG需要插入
                if (ipg_bytes > 0) begin
                    ipg_state <= 1'b1;
                    ipg_cnt   <= ipg_bytes;
                end
            end else begin
                // 正常数据
                out_data_reg <= in_data;
                out_ctrl_reg <= 16'h0000;
            end
        end else begin
            // 空闲: 输出 /I/
            out_data_reg <= {16{8'h07}};
            out_ctrl_reg <= 16'hFFFF;
        end
    end
end

assign out_data = out_data_reg;
assign out_ctrl = out_ctrl_reg;
```

---

## 5. 资源估算
| 资源 | 估算值 | 说明 |
|------|--------|------|
| FF | ~160 | 输出寄存器 + 状态机 |
| LUT | ~150 | /T/ 生成 + IPG 控制 |

---

## 6. 测试要点
| 测试项 | 说明 |
|--------|------|
| 正常数据透传 | 验证 `ctrl=0` 且数据不变 |
| 帧尾 /T/ 插入 | 验证 `tlast` 时无效字节变为 `/T/` + `/I/` 且 `ctrl` 正确 |
| IPG 插入 | 验证 `ipg_bytes` 指定数量的 `/I/` 插入 |
| 连续输出 | 验证 `out_valid` 始终为 1 |
| 反压处理 | 验证 `out_ready=0` 时数据不丢失 |
| 复位行为 | 验证复位后输出正确 |
