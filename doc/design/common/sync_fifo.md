# Sync FIFO 模块详细设计

## 1. 概述

### 1.1 功能
同步时钟域 FIFO，读写共用同一时钟，支持同时读写操作。

### 1.2 关键参数
| 参数 | 默认值 | 说明 |
|------|--------|------|
| DATA_WIDTH | 128 | 数据位宽 |
| DEPTH | 256 | FIFO 深度 (必须为 2 的幂) |
| ALMOST_FULL_THRESH | 0 | almost_full 阈值 (0=禁用) |
| ALMOST_EMPTY_THRESH | 0 | almost_empty 阈值 (0=禁用) |

### 1.3 特性
- 支持同时读写 (同一时钟周期)
- **0 周期读延迟**: 通过预取寄存器实现，rd_en 拉高同一周期 rd_data 输出有效数据
- 基于 data_count 的满/空判断
- 可选 almost_full / almost_empty 阈值标志

---

## 2. 接口定义

```systemverilog
module sync_fifo #(
    parameter DATA_WIDTH            = 128,
    parameter DEPTH                 = 256,
    parameter ALMOST_FULL_THRESH    = 0,
    parameter ALMOST_EMPTY_THRESH   = 0
) (
    input  wire                     clk,
    input  wire                     rst_n,          // 同步复位，低有效

    // 写接口
    input  wire                     wr_en,
    input  wire [DATA_WIDTH-1:0]    wr_data,
    output wire                     full,

    // 读接口
    input  wire                     rd_en,
    output wire [DATA_WIDTH-1:0]    rd_data,
    output wire                     empty,

    // 可选阈值标志
    output wire                     almost_full,
    output wire                     almost_empty
);
```

### 2.1 信号说明
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| clk | input | 1 | 时钟 |
| rst_n | input | 1 | 同步复位，低有效 |
| wr_en | input | 1 | 写使能 (高有效) |
| wr_data | input | DATA_WIDTH-1:0 | 写数据 |
| full | output | 1 | FIFO 满标志 |
| rd_en | input | 1 | 读使能 (高有效) |
| rd_data | output | DATA_WIDTH-1:0 | 读数据 (预取寄存器输出，0 周期延迟) |
| empty | output | 1 | FIFO 空标志 |
| almost_full | output | 1 | 接近满标志 (ALMOST_FULL_THRESH > 0 时有效) |
| almost_empty | output | 1 | 接近空标志 (ALMOST_EMPTY_THRESH > 0 时有效) |

---

## 3. 架构设计

### 3.1 内部结构

```
                    wr_en
    wr_data ────────►│
                     │   ┌─────────────┐
                     ├──►│  Memory     │
                     │   │  (BRAM/FF)  │
                     │   └──────┬──────┘
                     │          │
    wr_ptr ◄─────────┤    rd_data_reg (预取寄存器)
    rd_ptr ◄─────────┤    ▲
    data_count ◄─────┤    │ 每时钟预取 mem[rd_ptr]
                     │    │
    full ◄───────────┤    │
    empty ◄──────────┤    │
    almost_full ◄────┤    │
    almost_empty ◄───┘    │
                          │
              ┌───────────┘
              ▼
          rd_data (0周期延迟)
```

### 3.2 预取读原理

传统 FIFO 读数据有 1 周期延迟:
```
rd_en=1 → 时钟边沿 → rd_data_reg <= mem[rd_ptr] → 下个周期 rd_data 有效
```

预取 FIFO 通过**始终将 rd_ptr 指向的数据锁存到寄存器**实现 0 周期延迟:
```
每时钟: rd_data_reg <= mem[rd_ptr]  (无论 rd_en 是否拉高，始终预取)
rd_en=1: rd_data = rd_data_reg     (组合逻辑直接输出，无延迟)
```

### 3.3 读写时序 (0 周期延迟)

```
Cycle N (初始状态):
    rd_data_reg = mem[rd_ptr]     (已预取)
    rd_data = rd_data_reg = DATA_A

Cycle N (rd_en=1, wr_en=1):
    rd_data 立即输出 DATA_A       (0 周期延迟)
    wr_data = DATA_B 写入

Cycle N+1 (时钟边沿):
    rd_ptr++                      (指向下一个位置)
    wr_ptr++
    data_count 不变               (同时读写)
    rd_data_reg <= mem[新rd_ptr]  (预取 DATA_C)

Cycle N+1:
    rd_data = rd_data_reg = DATA_C (已就绪)
```

> 关键: rd_data_reg **每时钟**都预取 mem[rd_ptr] 的数据，因此 rd_en 拉高时 rd_data 立即可用。

### 3.4 指针管理

```
localparam PTR_WIDTH = $clog2(DEPTH);

wr_ptr:       [PTR_WIDTH-1:0]  写地址指针
rd_ptr:       [PTR_WIDTH-1:0]  读地址指针
data_count:   [PTR_WIDTH:0]    数据计数器 (0 ~ DEPTH)
```

---

## 4. 详细设计

### 4.1 存储器实例化

```systemverilog
generate
    if (DEPTH > 64) begin : gen_bram
        (* ram_style = "block" *)
        reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    end else begin : gen_reg
        reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    end
endgenerate
```

### 4.2 写逻辑

```systemverilog
always @(posedge clk) begin
    if (!rst_n) begin
        wr_ptr <= {PTR_WIDTH{1'b0}};
    end else if (wr_en && !full) begin
        mem[wr_ptr] <= wr_data;
        wr_ptr <= wr_ptr + 1'b1;
    end
end
```

### 4.3 读逻辑 (预取，0 周期延迟)

```systemverilog
// 读地址更新
always @(posedge clk) begin
    if (!rst_n) begin
        rd_ptr <= {PTR_WIDTH{1'b0}};
    end else if (rd_en && !empty) begin
        rd_ptr <= rd_ptr + 1'b1;
    end
end

// 预取寄存器: 始终锁存当前 rd_ptr 指向的数据
always @(posedge clk) begin
    if (!rst_n) begin
        rd_data_reg <= {DATA_WIDTH{1'b0}};
    end else begin
        rd_data_reg <= mem[rd_ptr];
    end
end

// 组合逻辑输出
assign rd_data = rd_data_reg;
```

### 4.4 数据计数器

```systemverilog
always @(posedge clk) begin
    if (!rst_n) begin
        data_count <= {(PTR_WIDTH+1){1'b0}};
    end else begin
        case ({wr_en && !full, rd_en && !empty})
            2'b10:   data_count <= data_count + 1'b1;  // 只写
            2'b01:   data_count <= data_count - 1'b1;  // 只读
            2'b11:   data_count <= data_count;          // 同时读写，不变
            default: data_count <= data_count;          // 无操作
        endcase
    end
end
```

### 4.5 标志信号

```systemverilog
// 满/空标志 (组合逻辑)
assign full  = (data_count == DEPTH);
assign empty = (data_count == 0);

// almost_full / almost_empty (可选)
generate
    if (ALMOST_FULL_THRESH > 0) begin : gen_af
        assign almost_full = (data_count >= ALMOST_FULL_THRESH);
    end else begin : gen_af_disabled
        assign almost_full = 1'b0;
    end

    if (ALMOST_EMPTY_THRESH > 0) begin : gen_ae
        assign almost_empty = (data_count <= ALMOST_EMPTY_THRESH);
    end else begin : gen_ae_disabled
        assign almost_empty = 1'b0;
    end
endgenerate
```

---

## 5. 使用场景

| 实例位置 | DATA_WIDTH | DEPTH | ALMOST_FULL | ALMOST_EMPTY | 说明 |
|----------|------------|-------|-------------|--------------|------|
| MAC TX FIFO | 145 | 128 | 112 | - | 2KB 缓冲，almost_full 在 87.5% 时触发 |
| MAC RX FIFO | 161 | 256 | 224 | - | 4KB 缓冲，almost_full 在 87.5% 时触发 |
| PCS CDC FIFO (TX) | 66 | 64 | 56 | 8 | Gearbox 跨时钟域缓冲 |
| PCS CDC FIFO (RX) | 66 | 64 | 56 | 8 | Gearbox 跨时钟域缓冲 |

---

## 6. 资源估算

### 6.1 寄存器实现 (DEPTH <= 64)
| 资源 | 公式 | 示例 (66-bit, 64 entries) |
|------|------|---------------------------|
| FF | DATA_WIDTH × DEPTH + 控制 | 66×64 + 20 ≈ 4244 |
| LUT | 计数器 + 标志逻辑 | ~50 |

### 6.2 BRAM 实现 (DEPTH > 64)
| 资源 | 公式 | 示例 (145-bit, 128 entries) |
|------|------|---------------------------|
| BRAM | ceil(DATA_WIDTH × DEPTH / 36864) | 1 × RAMB36E2 |
| FF | 控制逻辑 + 预取寄存器 | ~200 |
| LUT | 计数器 + 标志逻辑 | ~50 |

---

## 7. 测试要点

| 测试项 | 说明 |
|--------|------|
| 空 FIFO 读 | 验证 empty=1 时 rd_en 无效，rd_data 保持上次值 |
| 满 FIFO 写 | 验证 full=1 时 wr_en 无效，数据不覆盖 |
| 同时读写 | 验证 wr_en=1 且 rd_en=1 时数据正确传递 |
| 0周期读延迟 | 验证 rd_en 拉高同一周期 rd_data 输出有效数据 |
| 预取行为 | 验证 rd_data_reg 始终预取 mem[rd_ptr] |
| 写满后读空 | 验证从空到满再到空的完整循环 |
| almost_full | 验证阈值触发正确 |
| almost_empty | 验证阈值触发正确 |
| 复位行为 | 验证 rst_n 后 full=0, empty=1, data_count=0 |
| 背靠背操作 | 连续写满 + 连续读空 |
| 不同深度 | 验证 DEPTH=2, 4, 16, 64, 256 均正确 |
