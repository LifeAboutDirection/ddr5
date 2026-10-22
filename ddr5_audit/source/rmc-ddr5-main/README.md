# RMC — Reconfigurable DDR5 Memory Controller (RTL)

SystemVerilog implementation of a parameterized, reconfigurable **DDR5 memory controller**. This repo holds the **RTL** and **architecture diagrams**. Theory, specifications, and design notes live in the companion repo **`rmc_theory`**.

- **Standards targeted:** JEDEC JESD79-5 (DDR5), DFI 5.2, AXI4
- **Anchor target:** 4 GB, single-channel, single-rank
- **Future ceiling:** 46-bit address, 8 channels, 8 ranks, 64 Gb ×3DS-8H (64 TB)
- **Style:** fully parameterized SystemVerilog — no hardcoded widths

## Layout

| Path | Contents |
|---|---|
| `rtl/cif/` | AXI clock-domain front end — `axi_rd_port`, `axi_wr_port`, `async_req_fifo`, `async_resp_fifo`, `burst_splitter`, `rob`, `merge_logic`, `amu` |
| `rtl/mc_core/` | Controller core — `scheduler`, `per_bank_fsm_table`, `rd_tcam`/`wr_tcam`, `read_data_path`/`write_data_path`, `wdb`, `config_regs`, `timing_reg_file`, `maintenance_engine`, `bank_partition_ctrl`, `raw_bypass_mgr`, watermark managers |
| `rtl/dfi/` | DFI interface |
| `rtl/me/` | Maintenance engine |
| `rtl/pkg/` | `rmc_pkg.sv` — shared params/types |
| `rtl/top/` | `rmc_top.sv` — top-level integration |
| `diagrams/` | Architecture diagrams — Excalidraw, d2, yEd graphml, SVG/PNG exports |

## Related

- **`rmc_theory`** — specifications, DDR timing reference, knowledge base, design notes, address-map tool.
