# AGENTS.md - 40G Ethernet MAC + PCS

## Project Overview
IEEE 802.3ba 40GBASE-LR4 Ethernet MAC + PCS for Xilinx UltraScale+ FPGA.
- **RTL Language**: SystemVerilog
- **Verification**: Cocotb (Python) + Icarus Verilog
- **Clock**: 312.5 MHz, 128-bit data path
- **Reset**: All synchronous, active-low (`rst_n`)

## Build / Test Commands
*(Not yet implemented — planned commands)*
```bash
# Run all tests
make -C sim test

# Run a single test
make -C sim test TEST=test_single_frame_tx

# Run with GUI waveform
make -C sim wave TEST=test_mac_pcs_loopback

# Lint (Verible)
verible-verilog-syntax rtl/**/*.sv

# Synthesis (Vivado)
vivado -mode batch -source scripts/synth.tcl
```

## Directory Structure
```
eth_40g/
├── rtl/
│   ├── mac/          # MAC layer modules
│   ├── pcs/          # PCS layer modules
│   └── common/       # Shared modules (crc32, sync_fifo, lfsr)
├── tb/               # Cocotb testbenches
│   └── models/       # Python reference models
├── sim/              # Simulation Makefile & scripts
├── scripts/          # Synthesis scripts
└── doc/              # Design specs (spec.md, design/*.md)
```

## Code Style Guidelines

### File & Module Naming
- **Files**: `snake_case` with `eth_` prefix: `eth_mac_tx_preamble.sv`
- **Modules**: Match filename: `module eth_mac_tx_preamble (...)`
- **Instances**: `u_<short_name>`: `u_tx_fifo`, `u_crc32`

### Signal Naming
- **Clock**: `clk` (or `clk_core`, `clk_pma_tx`)
- **Reset**: `rst_n` (synchronous, active-low)
- **AXI-Stream**: `s_axis_tdata`, `s_axis_tkeep`, `s_axis_tlast`, `s_axis_tvalid`, `s_axis_tready`
- **Internal streams**: `in_valid/in_data/in_tkeep/in_tlast/in_ready` → `out_valid/out_data/out_tkeep/out_tlast/out_ready`
- **Control**: `_en` (enable), `_req` (request), `_busy` (busy flag)
- **XLGMII ctrl**: `ctrl[15:0]`, 1 bit per byte (0=data, 1=control character)

### Key Parameters
| Parameter | Value |
|-----------|-------|
| Data width | 128-bit |
| Control width | 16-bit (1 bit/byte) |
| Statistics counters | 48-bit (saturating, no clear) |
| TX FIFO depth | 128 entries (2KB) |
| RX FIFO depth | 256 entries (4KB) |
| IPG | Configurable 8–64 bytes, default 12 |
| Max frame | 9216 bytes (configurable) |

### Formatting
- **Indentation**: 4 spaces (no tabs)
- **Max line length**: 120 characters
- **Port declarations**: One signal per line, aligned
- **`begin`/`end`**: Always use for `always`/`if`/`case` blocks
- **Comments**: Chinese comments in design docs; English or Chinese OK in RTL

### Module Template
```systemverilog
module eth_module_name #(
    parameter DATA_WIDTH = 128,
    parameter DEPTH      = 256
) (
    input  wire                  clk,
    input  wire                  rst_n,
    // ... ports
);

// Internal signals
// ...

// Combinational logic
// ...

// Sequential logic (always synchronous reset)
always @(posedge clk) begin
    if (!rst_n) begin
        // reset values
    end else begin
        // normal operation
    end
end

endmodule
```

### Design Rules
1. **Synchronous reset only** — no `posedge rst_n` in sensitivity lists
2. **Non-blocking assignments** (`<=`) in all sequential `always` blocks
3. **Blocking assignments** (`=`) in combinational `always` blocks or `assign`
4. **No latches** — all combinational logic must be fully specified
5. **No async resets** — external async signals must be synchronized first
6. **CDC handling** — use `sync_fifo` for cross-clock-domain boundaries
7. **No magic numbers** — use `localparam` or named constants

### Error Handling
- FCS errors: mark `tuser` error bit, increment counter, optionally drop
- Frame too short/long: mark error, increment counter
- Counters saturate at max value (48-bit), never wrap or clear

### Verification (Cocotb)
- Test files: `tb/test_<module>.py`
- Reference models: `tb/models/<module>_model.py`
- Use `cocotb.triggers` for clock/edge synchronization
- Each test should be independent and self-checking

---

## Session History

### Goal

The user is developing an Ethernet 40G MAC TX/RX path project. The workflow is to implement RTL modules based on design documents, run unit simulations with cocotb, and confirm with the user before proceeding to the next module.

### Instructions

- After completing each module's coding and simulation, must confirm with user before proceeding to the next module
- Use synchronous reset style: `always @(posedge clk)` with `if (!rst_n)` inside
- All design documents are available in `doc/design/mac/`

### Discoveries

1. **TX preamble module tkeep fix**: Changed `out_tkeep_reg = {in_tkeep[7:0], 8'hFF}` to `{in_tkeep[7:0], buf_tkeep_high}` when `buf_valid && in_valid` to properly track valid bytes in buffered high 64-bit data.

2. **TX FCS module data_split handling**: Added `data_split` condition to handle cases where data is split between high and low bytes.

3. **TX FCS module need_split handling**: When last cycle has 13-15 bytes, FCS must be split across two output cycles. First cycle outputs 16 bytes (data + partial FCS), second cycle outputs remaining FCS bytes.

4. **RX FCS module split FCS handling**: Added `next_is_fcs_only` detection to handle cases where FCS is split across cycles. When next cycle contains only FCS bytes, current cycle's tkeep is adjusted to strip the FCS bytes present in current cycle.

5. **Test code preamble extraction**: Changed from 8 bytes to 7 bytes for preamble extraction because XLGMII Start character (0xFB) occupies byte 0, so only 7 bytes of preamble/SFD follow.

### Accomplished

- All TX submodules passing standalone tests
- All RX submodules passing standalone tests
- eth_mac_tx: 7/7 integration tests passing
- eth_mac_rx: 4/4 integration tests passing
- eth_mac_top: 7/7 tests passing (test_reset, test_tx_path, test_rx_path, test_loopback, test_statistics, test_loopback_variable_length, debug_485_tx)

### Relevant files / directories

**RTL files modified:**
- `rtl/mac/eth_mac_tx_preamble.sv` - Fixed tkeep propagation
- `rtl/mac/eth_mac_tx_fcs.sv` - Added need_split handling for 13-15 byte last cycles
- `rtl/mac/eth_mac_rx_fcs.sv` - Added next_is_fcs_only detection for split FCS handling

**Test files:**
- `sim/ut/eth_mac_top/test_eth_mac_top.py` - Contains all integration tests

**Design docs:**
- `doc/design/mac/eth_mac_tx_preamble.md`
- `doc/design/mac/eth_mac_tx_fcs.md`
