# eth_mac_tx_fcs 模块详细设计

## 1. 概述

### 1.1 功能
在每帧数据末尾追加 4 字节的 FCS (CRC32 校验值)。
- **CRC 计算范围**: 仅对以太网帧数据计算 (目的 MAC ~ payload 末尾)，**跳过 Preamble/SFD (前 8 字节)**。
- **合并输出策略**: 将 FCS 与帧尾数据合并在一个 128-bit 周期内输出 (当帧尾有效字节 ≤ 12 时)。
- **分周期输出**: 若帧尾有效字节 > 12，则分两周期输出 (周期 1 输出数据，周期 2 输出 FCS)。
- 内部实例化 `crc32` 模块，CRC 输入数据直接来自上游 (不含 Preamble/SFD)，通过 2 级延迟线匹配 CRC 计算延迟。

### 1.2 关键参数
| 参数 | 值 | 说明 |
|------|-----|------|
| 数据位宽 | 128-bit | 输入输出数据宽度 |
| FCS 长度 | 4 字节 | IEEE 802.3 CRC32 |
| CRC 延迟 | 2 周期 | 匹配内部 crc32 模块流水线 |

### 1.3 CRC 计算与数据路径分离
```
CRC 计算路径:  in_data (含 Preamble/SFD) ──► 跳过前 8 字节 ──► crc32 模块
数据输出路径:  in_data ──► 2 级延迟线 ──► 输出 + FCS 追加
```

Preamble/SFD 占前 8 字节 (Bytes 0-7)。CRC 计算从 Byte 8 开始 (目的 MAC 地址)。
实现方式: 在 SOP 检测后，跳过第一个周期的低 8 字节 (即 Preamble/SFD 所在位置)。

---

## 2. 接口定义

```systemverilog
module eth_mac_tx_fcs (
    input  wire         clk,
    input  wire         rst_n,          // 同步复位，低有效

    // 输入流 (来自 Preamble 插入)
    input  wire         in_valid,
    input  wire [127:0] in_data,
    input  wire [15:0]  in_tkeep,
    input  wire         in_tlast,
    output wire         in_ready,

    // 输出流 (去往 MAC TX 顶层)
    output wire         out_valid,
    output wire [127:0] out_data,
    output wire [15:0]  out_tkeep,
    output wire         out_tlast,
    input  wire         out_ready
);
```

---

## 3. 架构设计

### 3.1 CRC 计算 (跳过 Preamble/SFD)

CRC 输入数据流与输出数据流相同，但在送入 crc32 模块时跳过前 8 字节:

```
SOP 周期:
    in_data[63:0]  = Preamble/SFD (跳过，不送入 CRC)
    in_data[127:64] = 帧数据 Byte 0-7 (送入 CRC)

后续周期:
    in_data[127:0] = 完整帧数据 (全部送入 CRC)
```

实现: SOP 周期使用掩码屏蔽低 8 字节，后续周期正常传递。

### 3.2 延迟匹配
`crc32` 模块有 2 周期流水线延迟。为使 FCS 与帧尾数据对齐，输入数据通过 2 级延迟寄存器：

```
crc_data_in ──► [D1] ──► [D2] ──► delayed_crc_data (用于 CRC 计算)
in_data ──► [D1] ──► [D2] ──► delayed_data (用于输出)
in_tkeep ─► [D1] ──► [D2] ──► delayed_tkeep
in_tlast ─► [D1] ──► [D2] ──► delayed_tlast
```

当 `delayed_tlast=1` 时，`crc_out` 刚好有效 (同为 2 周期延迟)。

### 3.3 FCS 追加策略
检测 `delayed_tlast` 时的有效字节数 `N` (`delayed_tkeep` 中 1 的个数)：

| 情况 | 有效字节 N | 处理方式 |
|------|-----------|----------|
| N ≤ 12 | 0~12 字节 | 合并输出: `{data[MSB:32], FCS}` |
| N > 12 | 13~15 字节 | 分两周期: 周期 1 输出数据 (tlast=0), 周期 2 输出 FCS (tlast=1) |

**合并输出 (N ≤ 12):**
- `out_data` = `{delayed_data[127:32], fcs}`
- `out_tkeep` = `{delayed_tkeep[15:4], 4'hF}`
- `out_tlast` = 1

**分两周期输出 (N > 12):**
- **Cycle 1**:
  - `out_data` = `delayed_data`
  - `out_tkeep` = `delayed_tkeep`
  - `out_tlast` = 0
  - `fcs_pending` = 1
- **Cycle 2**:
  - `out_data` = `{124'h0, fcs}`
  - `out_tkeep` = `16'h000F`
  - `out_tlast` = 1
  - `fcs_pending` = 0

### 3.4 CRC 计算模块接口
```systemverilog
// CRC 输入数据: SOP 周期屏蔽低 8 字节 (Preamble/SFD)
wire [127:0] crc_data_in;
wire [15:0]  crc_byte_en;

assign crc_data_in = sop ? {in_data[127:64], 64'h0} : in_data;
assign crc_byte_en = sop ? {in_tkeep[15:8], 8'h00} : in_tkeep;

crc32 u_crc32 (
    .clk       (clk),
    .rst_n     (rst_n),
    .start     (sop),
    .data_in   (crc_data_in),
    .byte_en   (crc_byte_en),
    .crc_out   (fcs_raw),
    .crc_valid ()
);

// FCS 是 CRC 余式的反码
wire [31:0] fcs = ~fcs_raw;
```

---

## 4. 详细设计

### 4.1 内部信号
```systemverilog
reg [127:0] dly_data [0:1];
reg [15:0]  dly_tkeep [0:1];
reg         dly_tlast [0:1];
reg         in_pkt;

wire        sop = in_valid && !in_pkt;
wire [31:0] fcs;
wire [31:0] fcs_raw;

reg         fcs_pending;  // 标记 FCS 待发送 (N > 12 情况)

// CRC 输入: 跳过 Preamble/SFD (低 8 字节)
wire [127:0] crc_data_in = sop ? {in_data[127:64], 64'h0} : in_data;
wire [15:0]  crc_byte_en = sop ? {in_tkeep[15:8], 8'h00} : in_tkeep;
```

### 4.2 核心逻辑

```systemverilog
// CRC 实例化
crc32 u_crc32 (
    .clk       (clk),
    .rst_n     (rst_n),
    .start     (sop),
    .data_in   (crc_data_in),
    .byte_en   (crc_byte_en),
    .crc_out   (fcs_raw),
    .crc_valid ()
);

assign fcs = ~fcs_raw;

// 延迟线
always @(posedge clk) begin
    if (!rst_n) begin
        dly_data[0]  <= 128'h0; dly_data[1]  <= 128'h0;
        dly_tkeep[0] <= 16'h0;  dly_tkeep[1] <= 16'h0;
        dly_tlast[0] <= 1'b0;   dly_tlast[1] <= 1'b0;
    end else if (in_valid && in_ready) begin
        dly_data[0]  <= in_data;  dly_data[1]  <= dly_data[0];
        dly_tkeep[0] <= in_tkeep; dly_tkeep[1] <= dly_tkeep[0];
        dly_tlast[0] <= in_tlast; dly_tlast[1] <= dly_tlast[0];
    end
end

// 包状态跟踪
always @(posedge clk) begin
    if (!rst_n) in_pkt <= 1'b0;
    else if (out_valid && out_ready) begin
        if (sop) in_pkt <= 1'b1;
        else if (out_tlast) in_pkt <= 1'b0;
    end
end

// 输入就绪
assign in_ready = !fcs_pending && (out_ready || !out_valid);

// 输出有效
assign out_valid = in_valid || fcs_pending;

// 有效字节计数
function automatic [4:0] count_ones(input [15:0] val);
    integer i, count;
    begin
        count = 0;
        for (i = 0; i < 16; i++) count = count + val[i];
        count_ones = count;
    end
endfunction

wire [4:0] n_bytes = count_ones(dly_tkeep[1]);
wire       can_merge = (n_bytes <= 12);

// 输出组合逻辑
always @(*) begin
    if (fcs_pending) begin
        out_data  = {124'h0, fcs};
        out_tkeep = 16'h000F;
        out_tlast = 1'b1;
    end else if (dly_tlast[1]) begin
        if (can_merge) begin
            // 合并输出 FCS
            out_data  = {dly_data[1][127:32], fcs};
            out_tkeep = {dly_tkeep[1][15:4], 4'hF};
            out_tlast = 1'b1;
        end else begin
            // 分两周期，先输出数据
            out_data  = dly_data[1];
            out_tkeep = dly_tkeep[1];
            out_tlast = 1'b0;
        end
    end else begin
        out_data  = dly_data[1];
        out_tkeep = dly_tkeep[1];
        out_tlast = dly_tlast[1];
    end
end

// FCS pending 状态
always @(posedge clk) begin
    if (!rst_n) fcs_pending <= 1'b0;
    else if (out_valid && out_ready) begin
        if (fcs_pending) fcs_pending <= 1'b0;
        else if (dly_tlast[1] && !can_merge) fcs_pending <= 1'b1;
    end
end
```

---

## 5. 资源估算
| 资源 | 估算值 | 说明 |
|------|--------|------|
| CRC32 | ~800 LUT + 100 FF | 128-bit 并行 CRC |
| 延迟线 | ~300 FF | 2 级 128+16+1 bit |
| 控制逻辑 | ~100 LUT | 状态机 + 多路选择 |

---

## 6. 测试要点
| 测试项 | 说明 |
|--------|------|
| CRC 跳过 Preamble/SFD | 验证 CRC 计算不包含前 8 字节 |
| 正常 FCS 追加 | 验证帧尾 ≤ 12 字节时 FCS 正确合并 |
| 分周期 FCS | 验证帧尾 > 12 字节时 FCS 分两周期输出 |
| CRC 正确性 | 验证 FCS 值与标准 CRC32 一致 |
| 背靠背帧 | 验证连续帧 FCS 不混淆 |
| 反压处理 | 验证 `out_ready=0` 时数据/FCS 不丢失 |
| 复位行为 | 验证复位后状态正确 |
