# async_fifo 模块设计

## 1. 模块概述

**模块名称**: async_fifo

**功能**: 异步 FIFO，用于跨时钟域数据传输

**位置**: rtl/common/async_fifo.sv

## 2. 接口定义

```systemverilog
module async_fifo #(
    parameter DATA_WIDTH = 64,
    parameter DEPTH      = 16,
    parameter PROG_FULL  = 0,    // 可编程满阈值 (0 = 禁用)
    parameter PROG_EMPTY = 0     // 可编程空阈值 (0 = 禁用)
) (
    // 写时钟域
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output wire                  full,
    output wire                  prog_full,

    // 读时钟域
    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire                  empty,
    output wire                  prog_empty
);
```

### 2.1 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| DATA_WIDTH | 64 | 数据位宽 |
| DEPTH | 16 | FIFO 深度 (必须是 2 的幂次) |
| PROG_FULL | 0 | 可编程满阈值，0 表示禁用 |
| PROG_EMPTY | 0 | 可编程空阈值，0 表示禁用 |

### 2.2 信号说明

**写时钟域**:
| 信号 | 方向 | 说明 |
|------|------|------|
| wr_clk | input | 写时钟 |
| wr_rst_n | input | 写时钟域同步复位 (低有效) |
| wr_en | input | 写使能 |
| wr_data | input | 写数据 |
| full | output | FIFO 满标志 |
| prog_full | output | 可编程满标志 (可选) |

**读时钟域**:
| 信号 | 方向 | 说明 |
|------|------|------|
| rd_clk | input | 读时钟 |
| rd_rst_n | input | 读时钟域同步复位 (低有效) |
| rd_en | input | 读使能 |
| rd_data | output | 读数据 |
| empty | output | FIFO 空标志 |
| prog_empty | output | 可编程空标志 (可选) |

## 3. 设计原理

### 3.1 异步 FIFO 架构

```
写时钟域 (wr_clk)              读时钟域 (rd_clk)
       │                              │
       ▼                              ▼
┌──────────────┐              ┌──────────────┐
│  写指针      │              │  读指针      │
│  (二进制)    │              │  (二进制)    │
└──────┬───────┘              └──────┬───────┘
       │                              │
       ▼                              ▼
┌──────────────┐              ┌──────────────┐
│  格雷码转换  │              │  格雷码转换  │
└──────┬───────┘              └──────┬───────┘
       │                              │
       │    ┌─────────────────┐       │
       └───►│  格雷码同步器   │◄──────┘
            │  (2 级触发器)   │
            └────────┬────────┘
                     │
                     ▼
            ┌─────────────────┐
            │  比较逻辑       │
            │  (满/空判断)    │
            └─────────────────┘
```

### 3.2 格雷码指针

使用格雷码指针避免跨时钟域时的亚稳态问题：

```
二进制 → 格雷码: gray = binary ^ (binary >> 1)
格雷码 → 二进制: 见转换函数

格雷码特性: 相邻值只有 1 位变化
```

### 3.3 满/空判断

**满条件** (写时钟域判断):
```
写指针格雷码 == {~读指针格雷码最高位, 读指针格雷码其他位}
即: wr_ptr_gray == {~rd_ptr_gray_sync[ADDR_WIDTH], rd_ptr_gray_sync[ADDR_WIDTH-1:0]}
```

**空条件** (读时钟域判断):
```
读指针格雷码 == 写指针格雷码 (同步后)
即: rd_ptr_gray == wr_ptr_gray_sync
```

### 3.4 深度要求

FIFO 深度必须是 2 的幂次，便于格雷码转换和地址计算：

```
ADDR_WIDTH = $clog2(DEPTH)
实际深度 = 2^ADDR_WIDTH
```

## 4. 详细设计

### 4.1 内部信号

```systemverilog
localparam ADDR_WIDTH = $clog2(DEPTH);

// 写时钟域
reg [ADDR_WIDTH:0]   wr_ptr_bin;      // 写指针 (二进制，多 1 位用于判断满)
reg [ADDR_WIDTH:0]   wr_ptr_gray;     // 写指针 (格雷码)
reg [ADDR_WIDTH:0]   rd_ptr_gray_sync;// 读指针同步到写时钟域
reg [DATA_WIDTH-1:0] mem [0:DEPTH-1]; // 存储阵列

// 读时钟域
reg [ADDR_WIDTH:0]   rd_ptr_bin;      // 读指针 (二进制)
reg [ADDR_WIDTH:0]   rd_ptr_gray;     // 读指针 (格雷码)
reg [ADDR_WIDTH:0]   wr_ptr_gray_sync;// 写指针同步到读时钟域
```

### 4.2 格雷码转换函数

```systemverilog
// 二进制转格雷码
function automatic [ADDR_WIDTH:0] bin2gray(input [ADDR_WIDTH:0] bin);
    bin2gray = bin ^ (bin >> 1);
endfunction

// 格雷码转二进制
function automatic [ADDR_WIDTH:0] gray2bin(input [ADDR_WIDTH:0] gray);
    integer i;
    reg [ADDR_WIDTH:0] bin;
    begin
        bin[ADDR_WIDTH] = gray[ADDR_WIDTH];
        for (i = ADDR_WIDTH-1; i >= 0; i = i - 1) begin
            bin[i] = gray[i] ^ bin[i+1];
        end
        gray2bin = bin;
    end
endfunction
```

### 4.3 写时钟域逻辑

```systemverilog
// 读指针同步到写时钟域 (2 级触发器)
always @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
        rd_ptr_gray_sync <= {(ADDR_WIDTH+1){1'b0}};
    end else begin
        rd_ptr_gray_sync <= {rd_ptr_gray_sync[ADDR_WIDTH:0]};
    end
end

// 写指针更新
wire wr_ptr_gray_next;
wire [ADDR_WIDTH:0] wr_ptr_bin_next;

assign wr_ptr_bin_next  = wr_ptr_bin + (wr_en && !full);
assign wr_ptr_gray_next = bin2gray(wr_ptr_bin_next);

always @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
        wr_ptr_bin  <= {(ADDR_WIDTH+1){1'b0}};
        wr_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
    end else begin
        wr_ptr_bin  <= wr_ptr_bin_next;
        wr_ptr_gray <= wr_ptr_gray_next;
    end
end

// 写数据
always @(posedge wr_clk) begin
    if (wr_en && !full) begin
        mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
    end
end

// 满判断
assign full = (wr_ptr_gray == {~rd_ptr_gray_sync[ADDR_WIDTH], 
                                rd_ptr_gray_sync[ADDR_WIDTH-1:0]});
```

### 4.4 读时钟域逻辑

```systemverilog
// 写指针同步到读时钟域 (2 级触发器)
always @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
        wr_ptr_gray_sync <= {(ADDR_WIDTH+1){1'b0}};
    end else begin
        wr_ptr_gray_sync <= {wr_ptr_gray_sync[ADDR_WIDTH:0]};
    end
end

// 读指针更新
wire rd_ptr_gray_next;
wire [ADDR_WIDTH:0] rd_ptr_bin_next;

assign rd_ptr_bin_next  = rd_ptr_bin + (rd_en && !empty);
assign rd_ptr_gray_next = bin2gray(rd_ptr_bin_next);

always @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
        rd_ptr_bin  <= {(ADDR_WIDTH+1){1'b0}};
        rd_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
    end else begin
        rd_ptr_bin  <= rd_ptr_bin_next;
        rd_ptr_gray <= rd_ptr_gray_next;
    end
end

// 读数据
assign rd_data = mem[rd_ptr_bin[ADDR_WIDTH-1:0]];

// 空判断
assign empty = (rd_ptr_gray == wr_ptr_gray_sync);
```

### 4.5 可编程满/空 (可选)

```systemverilog
// 可编程满: 当 FIFO 中数据量 >= PROG_FULL 时置位
generate
    if (PROG_FULL > 0) begin : gen_prog_full
        wire [ADDR_WIDTH:0] wr_count = wr_ptr_bin - gray2bin(rd_ptr_gray_sync);
        assign prog_full = (wr_count >= PROG_FULL);
    end else begin
        assign prog_full = 1'b0;
    end
endgenerate

// 可编程空: 当 FIFO 中数据量 <= PROG_EMPTY 时置位
generate
    if (PROG_EMPTY > 0) begin : gen_prog_empty
        wire [ADDR_WIDTH:0] rd_count = gray2bin(wr_ptr_gray_sync) - rd_ptr_bin;
        assign prog_empty = (rd_count <= PROG_EMPTY);
    end else begin
        assign prog_empty = 1'b0;
    end
endgenerate
```

## 5. 完整实现

```systemverilog
module async_fifo #(
    parameter DATA_WIDTH = 64,
    parameter DEPTH      = 16,
    parameter PROG_FULL  = 0,
    parameter PROG_EMPTY = 0
) (
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output wire                  full,
    output wire                  prog_full,

    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire                  empty,
    output wire                  prog_empty
);

    localparam ADDR_WIDTH = $clog2(DEPTH);

    function automatic [ADDR_WIDTH:0] bin2gray(input [ADDR_WIDTH:0] bin);
        bin2gray = bin ^ (bin >> 1);
    endfunction

    function automatic [ADDR_WIDTH:0] gray2bin(input [ADDR_WIDTH:0] gray);
        integer i;
        reg [ADDR_WIDTH:0] bin;
        begin
            bin[ADDR_WIDTH] = gray[ADDR_WIDTH];
            for (i = ADDR_WIDTH-1; i >= 0; i = i - 1) begin
                bin[i] = gray[i] ^ bin[i+1];
            end
            gray2bin = bin;
        end
    endfunction

    // 存储阵列
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // 写时钟域
    reg [ADDR_WIDTH:0] wr_ptr_bin;
    reg [ADDR_WIDTH:0] wr_ptr_gray;
    reg [ADDR_WIDTH:0] rd_ptr_gray_sync0;
    reg [ADDR_WIDTH:0] rd_ptr_gray_sync1;

    wire [ADDR_WIDTH:0] wr_ptr_bin_next = wr_ptr_bin + (wr_en && !full);
    wire [ADDR_WIDTH:0] wr_ptr_gray_next = bin2gray(wr_ptr_bin_next);

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_bin        <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray       <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray_sync0 <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray_sync1 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            wr_ptr_bin        <= wr_ptr_bin_next;
            wr_ptr_gray       <= wr_ptr_gray_next;
            rd_ptr_gray_sync0 <= rd_ptr_gray_sync1;
            rd_ptr_gray_sync1 <= rd_ptr_gray;
        end
    end

    always @(posedge wr_clk) begin
        if (wr_en && !full) begin
            mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
        end
    end

    assign full = (wr_ptr_gray_next == {~rd_ptr_gray_sync1[ADDR_WIDTH], 
                                         rd_ptr_gray_sync1[ADDR_WIDTH-1:0]});

    // 读时钟域
    reg [ADDR_WIDTH:0] rd_ptr_bin;
    reg [ADDR_WIDTH:0] rd_ptr_gray;
    reg [ADDR_WIDTH:0] wr_ptr_gray_sync0;
    reg [ADDR_WIDTH:0] wr_ptr_gray_sync1;

    wire [ADDR_WIDTH:0] rd_ptr_bin_next = rd_ptr_bin + (rd_en && !empty);
    wire [ADDR_WIDTH:0] rd_ptr_gray_next = bin2gray(rd_ptr_bin_next);

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin        <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray       <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray_sync0 <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray_sync1 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            rd_ptr_bin        <= rd_ptr_bin_next;
            rd_ptr_gray       <= rd_ptr_gray_next;
            wr_ptr_gray_sync0 <= wr_ptr_gray_sync1;
            wr_ptr_gray_sync1 <= wr_ptr_gray;
        end
    end

    assign rd_data = mem[rd_ptr_bin[ADDR_WIDTH-1:0]];
    assign empty = (rd_ptr_gray_next == wr_ptr_gray_sync1);

    // 可编程满/空
    generate
        if (PROG_FULL > 0) begin : gen_prog_full
            wire [ADDR_WIDTH:0] wr_count = wr_ptr_bin_next - gray2bin(rd_ptr_gray_sync1);
            assign prog_full = (wr_count >= PROG_FULL);
        end else begin
            assign prog_full = 1'b0;
        end

        if (PROG_EMPTY > 0) begin : gen_prog_empty
            wire [ADDR_WIDTH:0] rd_count = gray2bin(wr_ptr_gray_sync1) - rd_ptr_bin_next;
            assign prog_empty = (rd_count <= PROG_EMPTY);
        end else begin
            assign prog_empty = 1'b0;
        end
    endgenerate

endmodule
```

## 6. 时序图

### 6.1 写操作

```
wr_clk:       |  0  |  1  |  2  |  3  |  4  |
              |     |     |     |     |     |
wr_en:        |  1  |  1  |  0  |  1  |  1  |
wr_data:      | D0  | D1  |  -  | D2  | D3  |
              |     |     |     |     |     |
wr_ptr_bin:   |  0  |  1  |  2  |  2  |  3  |
              |     |     |     |     |     |
full:         |  0  |  0  |  0  |  0  |  0  |
```

### 6.2 读操作

```
rd_clk:       |  0  |  1  |  2  |  3  |  4  |
              |     |     |     |     |     |
rd_en:        |  1  |  0  |  1  |  1  |  0  |
              |     |     |     |     |     |
rd_data:      | D0  |  -  | D1  | D2  |  -  |
              |     |     |     |     |     |
rd_ptr_bin:   |  0  |  1  |  1  |  2  |  3  |
              |     |     |     |     |     |
empty:        |  0  |  0  |  0  |  0  |  0  |
```

## 7. 复位处理

### 7.1 复位要求

- 两个时钟域的复位信号独立
- 复位后，所有指针归零
- 复位释放后，FIFO 处于空状态

### 7.2 复位同步

如果系统只有一个全局复位信号，需要在每个时钟域分别同步：

```systemverilog
// 在顶层模块中
reg [2:0] wr_rst_n_sync;
reg [2:0] rd_rst_n_sync;

always @(posedge wr_clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_rst_n_sync <= 3'b000;
    end else begin
        wr_rst_n_sync <= {wr_rst_n_sync[1:0], 1'b1};
    end
end

assign wr_rst_n = wr_rst_n_sync[2];
```

## 8. 资源估算

| 资源 | 公式 | DEPTH=64, DATA_WIDTH=66 |
|------|------|-------------------------|
| FF | 4 × (ADDR_WIDTH+1) × 2 + DATA_WIDTH × DEPTH (如用 BRAM 则无) | ~280 (不用 BRAM) |
| LUT | 格雷码转换 + 比较逻辑 | ~100 |
| BRAM | DATA_WIDTH × DEPTH / 36K | 2 (使用 BRAM 时) |

## 9. 测试要点

| 测试项 | 说明 |
|--------|------|
| 基本读写 | 验证数据正确传输 |
| 满/空标志 | 验证 full/empty 正确置位和清除 |
| 跨时钟域 | 验证不同频率时钟下正确工作 |
| 复位行为 | 验证复位后 FIFO 为空 |
| 连续读写 | 验证满写空读边界条件 |
| 格雷码同步 | 验证指针同步正确 |

## 10. 使用示例

```systemverilog
// 66-bit 宽度，深度 64
async_fifo #(
    .DATA_WIDTH(66),
    .DEPTH(64)
) u_cdc_fifo (
    .wr_clk    (clk_core),
    .wr_rst_n  (rst_n_core),
    .wr_en     (wr_en),
    .wr_data   (wr_data),
    .full      (full),
    .prog_full (),
    
    .rd_clk    (clk_pma),
    .rd_rst_n  (rst_n_pma),
    .rd_en     (rd_en),
    .rd_data   (rd_data),
    .empty     (empty),
    .prog_empty()
);
```

## 11. 参考文献

- Clifford E. Cummings, "Simulation and Synthesis Techniques for Asynchronous FIFO Design"
- IEEE 802.3-2018 Clause 82 (CDC 设计参考)

## 12. 修订历史

| 版本 | 日期 | 描述 |
|------|------|------|
| 1.0 | 2026-04-10 | 初始版本 |
