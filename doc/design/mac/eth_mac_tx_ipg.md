# eth_mac_tx_ipg 模块详细设计

## 1. 概述

### 1.1 功能
在每帧结束后计算需要插入的 IPG (Inter-Packet Gap) 字节数，传递给下游 `eth_mac_xgmii_enc` 模块执行。
- **IPG 计算**: 根据配置的 IPG 值和帧尾空闲字节，计算剩余需要的 IPG 字节数。
- **智能扣除**: 利用帧尾 (`tlast` 周期) 的无效字节空间自动扣除 IPG 长度。
- **输出 ipg_bytes**: 告知下游模块需要插入的 IPG 字节数 (0-15)。

> **职责划分**: 本模块仅计算 IPG 需求，实际的 /I/ 字符输出由 `eth_mac_xgmii_enc` 负责。

### 1.2 IPG 定义
- **IPG**: 从 /T/ 结束到下一帧 /S/ 开始之间的字节数
- **帧尾空闲字节**: `tlast` 周期的无效字节位置会填充 /T/ + /I/
- **ipg_bytes**: 除帧尾空闲字节外，还需要额外插入的 /I/ 字节数 (0-15)

### 1.3 关键参数
| 参数 | 默认值 | 说明 |
|------|--------|------|
| IPG 范围 | 8~64 字节 | 可配置 |
| 默认值 | 12 字节 | IEEE 802.3 标准 |

---

## 2. 接口定义

```systemverilog
module eth_mac_tx_ipg (
    input  wire         clk,
    input  wire         rst_n,          // 同步复位，低有效
    input  wire [7:0]   ipg_cfg,        // 配置 IPG 字节数 (默认 12)

    // 输入流 (来自 FCS 模块, AXI-Stream)
    input  wire         in_valid,
    input  wire [127:0] in_data,
    input  wire [15:0]  in_tkeep,
    input  wire         in_tlast,
    output wire         in_ready,

    // 输出流 (去往 XGMII 编码器, AXI-Stream)
    output wire         out_valid,
    output wire [127:0] out_data,
    output wire [15:0]  out_tkeep,
    output wire         out_tlast,
    output wire [3:0]   ipg_bytes,      // 需要插入的 IPG 字节数 (0-15)
    output wire         need_t_cycle,   // 是否需要额外的 T 周期 (tkeep=0xFFFF 时)
    input  wire         out_ready
);
```

---

## 3. 架构设计

### 3.1 IPG 计算逻辑
1. 帧尾周期 (`in_tlast=1`) 的无效字节数 = `16 - popcount(in_tkeep)`
2. 其中第一个无效字节是 /T/，剩余的是 /I/
3. 帧尾贡献的 IPG = `16 - popcount(in_tkeep) - 1` (减去 /T/)
4. 剩余需要的 IPG = `ipg_cfg - 帧尾贡献的IPG`
5. 如果剩余 IPG > 0，输出 `ipg_bytes` 给下游

### 3.2 示例
假设 IPG=12：
- **情况1**: `tkeep=0xFFFF` (16字节全有效)
  - 帧尾贡献 IPG = 0
  - 剩余 IPG = 12
  - `ipg_bytes = 12`，下游插入 12 个 /I/

- **情况2**: `tkeep=0x03FF` (10字节有效)
  - 帧尾贡献 IPG = 16 - 10 - 1 = 5
  - 剩余 IPG = 12 - 5 = 7
  - `ipg_bytes = 7`，下游插入 7 个 /I/

- **情况3**: `tkeep=0x0007` (3字节有效)
  - 帧尾贡献 IPG = 16 - 3 - 1 = 12
  - 剩余 IPG = 12 - 12 = 0
  - `ipg_bytes = 0`，无需额外插入

### 3.3 数据流
```
正常数据周期: out_valid=in_valid, ipg_bytes=0
帧尾周期:     out_valid=in_valid, ipg_bytes=计算值
```

---

## 4. 详细设计

### 4.1 内部信号
```systemverilog
reg [127:0] out_data_reg;
reg [15:0]  out_tkeep_reg;
reg         out_tlast_reg;
reg [3:0]   ipg_bytes_reg;
```

### 4.2 核心逻辑

```systemverilog
// 计算有效字节数 (popcount)
function automatic [4:0] popcount(input [15:0] val);
    integer i;
    begin
        popcount = 0;
        for (i = 0; i < 16; i++) popcount = popcount + val[i];
    end
endfunction

wire [4:0] valid_bytes = popcount(in_tkeep);
wire [5:0] tail_ipg = 16 - valid_bytes - 1;  // 帧尾贡献的 IPG (/T/ 后的 /I/)
wire [8:0] ipg_rem = (ipg_cfg > tail_ipg) ? (ipg_cfg - tail_ipg) : 0;

// 输出控制
assign in_ready  = out_ready;
assign out_valid = in_valid;

// 数据透传 + IPG 计算
always @(posedge clk) begin
    if (!rst_n) begin
        out_data_reg  <= 128'h0;
        out_tkeep_reg <= 16'h0;
        out_tlast_reg <= 1'b0;
        ipg_bytes_reg <= 4'h0;
    end else if (in_valid && in_ready) begin
        out_data_reg  <= in_data;
        out_tkeep_reg <= in_tkeep;
        out_tlast_reg <= in_tlast;
        ipg_bytes_reg <= in_tlast ? ipg_rem[3:0] : 4'h0;
    end
end

assign out_data  = out_data_reg;
assign out_tkeep = out_tkeep_reg;
assign out_tlast = out_tlast_reg;
assign ipg_bytes = ipg_bytes_reg;
```

---

## 5. 资源估算
| 资源 | 估算值 | 说明 |
|------|--------|------|
| FF | ~160 | 输出数据寄存器 + IPG 计算 |
| LUT | ~50 | popcount + 控制逻辑 |

---

## 6. 测试要点
| 测试项 | 说明 |
|--------|------|
| IPG 计算 | 验证不同 tkeep 下 ipg_bytes 计算正确 |
| 智能扣除 | 验证帧尾空闲字节自动扣除 IPG |
| 无插入情况 | 验证帧尾空闲字节 >= IPG 时 ipg_bytes=0 |
| 配置变更 | 验证运行时修改 ipg_cfg 立即生效 |
| 数据透传 | 验证数据、tkeep、tlast 正确透传 |
| 复位行为 | 验证复位后状态正确 |
