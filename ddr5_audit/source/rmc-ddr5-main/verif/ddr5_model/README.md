# ddr5_model — behavioral DDR5 SDRAM device model

A pin-level DDR5 SDRAM model written from **JEDEC JESD79-5**, built to sit on the
other end of the RMC controller's DFI/PHY and fail loudly when the controller
gets a timing or protocol rule wrong.

This is verification collateral. It lives outside `rtl/` and is not part of the
controller RTL.

## Status

| Stage | Scope | State |
|---|---|---|
| 1 | CA decode (Table 241), bank FSM, core timing matrix, mode registers, sparse array, DQ/DQS read+write datapath | **done** |
| 2 | Initialisation sequence, refresh management (RAA/MR58/MR59), tREFI, power-down / self-refresh, ZQCal windows | **done** |
| 3 | On-die ECC (SEC 128b+8b), ECS scrub and transparency registers, write CRC, ALERT_n | **done** |
| 4 | Training: CA / CS, write levelling, read training patterns, PDA, Vref shadowing, preambles | **done** |
| 5 | DFI 5.2 PHY bridge so `rmc_top` plugs in without pin-level wiring | **done** |

Every `TODO stage N` comment in the source marks the hook a later stage attaches to.

## Layout

| Path | Contents |
|---|---|
| `rtl/ddr5_pkg.sv` | Organization, command enum, CA decode, MPC opcodes, MR map, burst order |
| `rtl/ddr5_timing_pkg.sv` | Speed-bin timing tables, resolved to whole nCK at elaboration |
| `rtl/ddr5_ecc_pkg.sv` | SEC(136,128) code and the ATM-8 CRC |
| `rtl/ddr5_device.sv` | The device model |
| `rtl/dfi_pkg.sv` | DFI constants and the latency placement arithmetic |
| `rtl/dfi_if.sv` | DFI 5.2 interface, signal set per the fabric spec |
| `rtl/dfi_ddr5_phy.sv` | DFI <-> DDR5 pin bridge (PHY model), owns CK and dfi_clk |
| `tb/tb_ddr5_smoke.sv` | Pin-level smoke test: MRW / ACT / WR / RD / PRE plus a tRCD negative test |
| `tb/tb_dfi_smoke.sv` | DFI-level smoke test: same traffic driven as DFI phases |
| `tb/tb_ddr5_refresh.sv` | Stage 2: init ordering, RAA/RFM, tREFI, power states, ZQ windows |
| `tb/tb_ecc.sv` | Unit checks for the SEC code and the CRC, no DRAM involved |
| `tb/tb_ddr5_ecc.sv` | Stage 3: silent correction, ECS scrub, write CRC and ALERT_n |
| `tb/tb_ddr5_training.sv` | Stage 4: CATM, CSTM, write levelling, read patterns, PDA, Vref, tWPRE |
| `sim/run.sh` | Verilator-in-podman runner |

## Running

```sh
./sim/run.sh                        # tb_ddr5_smoke, pin level
./sim/run.sh tb_dfi_smoke           # through the DFI bridge, 1:2 gear ratio
./sim/run.sh tb_dfi_smoke -GG=1     # 1:1
./sim/run.sh tb_dfi_smoke -GG=4     # 1:4
./sim/run.sh tb_ddr5_refresh        # init, refresh management, power states
./sim/run.sh tb_ecc                 # SEC / CRC unit checks
./sim/run.sh tb_ddr5_ecc            # on-die ECC, ECS, write CRC
./sim/run.sh tb_ddr5_training       # training modes, PDA, Vref, preamble
```

All eight configurations pass with zero unexpected DRAM protocol or timing
errors and no Verilator warnings.

## Initialisation

The device now comes up in `DS_RESET` and will refuse traffic until it has been
brought up properly, so a testbench has to run the real sequence (JESD79-5
3.3.1 step 7):

```
MPC 1000xxxxB (MR13 tDLLK/tCCD_L) -> MPC DLL RESET
                                  -> MPC ZQCal Start -> [tZQCAL, 1 us]
                                  -> MPC ZQCal Latch -> [tZQLAT]  -> ready
```

Only MRR, MRW, MPC and VrefCA/CS are legal while configuring, and the CA bus
must hold deselect for the whole of tZQLAT. `INIT_FAST` (default on) collapses
tINIT3/tINIT4/tXPR — 4 ms of tINIT3 alone is ~9.6 million cycles — while still
enforcing every ordering rule. Set it to 0 for the real numbers.

## Refresh management

`MR58` and `MR59` are read-only vendor fields, so they are device parameters and
are published for `MRR` to read back:

| Parameter | MR | Default |
|---|---|---|
| `RFM_REQUIRED` | MR58 OP[0] | 1 |
| `RAAIMT_CODE` | MR58 OP[4:1] | `1001B` = 72 normal / 36 FGR |
| `RAAMMT_CODE` | MR58 OP[7:5] | `100B` = 4x RAAIMT |
| `RAADEC_CODE` | MR59 OP[7:6] | `00B` = REF decrements by RAAIMT |

Each ACT adds one to that bank's rolling accumulated ACT count. REF subtracts
RAADEC, RFM subtracts RAAIMT, both flooring at zero. **At RAAMMT no further ACT
to that bank is legal** until a REF or RFM brings it down — that is the rule a
scheduler actually breaks, and the model reports it as a protocol error.

`tREFI` is policed separately: the gap between two REFab may stretch to 5 x tREFI
in normal mode and 9 x tREFI in FGR (4.13.3). Beyond that the model reports once
per missed interval rather than every cycle.

## On-die ECC, ECS and CRC

**On-die ECC is invisible by design.** The DRAM computes 8 check bits over each
128 data bits, and on a read it corrects any single-bit error before the data
reaches DQ. A controller sees clean data and no signal at all — which is exactly
what the tests assert. Per 4.35 a read does **not** repair the array; only ECS
scrubs, and `tb_ddr5_ecc` checks that distinction directly.

Geometry follows the standard: a x8 maps its burst to one code word, a x16
splits into two (DQ[7:0] and DQ[15:8]) checked in parallel. `inject_bit_error()`
flips a bit in the array without touching the check bits, so the next read of
that block sees a genuine correctable error.

The standard says the code is "fully specified by the H matrix" but leaves the
matrix to the vendor. It is unobservable from outside the die, so this model
builds its own valid SEC code with the required behaviour — zero syndrome means
clean, a syndrome matching a column locates the bit, a syndrome matching nothing
is a DUE. `tb_ecc` proves all 128 single-bit positions are located exactly, and
that no double-bit error is ever silently accepted.

ECS follows 4.36: manual mode via `MPC Manual ECS` (rejected unless MR14 OP[7]
is set), spaced by tECSc, scrubbing corrections back into the array and feeding
the transparency registers — EC in MR20, the worst row and its count in
MR16–MR19, both behind the MR15 threshold filter.

Write CRC is the ATM-8 HEC, `X^8 + X^2 + X^1 + 1`, initial state zero, D[63]
sent first. The shift-register implementation was checked term for term against
the standard's published `NewCRC[0]` equation — all 29 XOR terms agree. A
mismatch sets MR50 OP[3] and pulls **ALERT_n** low.

One convention the model had to choose: the standard fixes that D[63] goes
first, but not the order of the four bits a nibble presents within a single UI.
The model uses DQ-ascending inside each UI, for the data and for the two CRC
UIs. A controller checked against this model must use the same convention.

## Training

All three loopback modes work the same way from the host's side — put the DRAM
in the mode, drive one signal, read the answer back as a static level on every
DQ pin. What differs is which signal is being measured:

| Mode | Entered by | DQ reports |
|---|---|---|
| CA training (4.19) | `MPC Enter CA Training` | `XOR(CA[13:0])`, sampled when CS_n asserts |
| CS training (4.20) | `MPC Enter CS Training` | CS_n sampled four at a time, evaluated in pairs then ORed |
| Write levelling (4.21) | `MR2 OP[1]=1` | CK_t sampled on the rising edge of DQS |

CA training owns the CA bus: CS_n assertion is a sample, not a command, so
nothing is decoded, assertions must be 4 tCK or more apart, and two consecutive
assertions exit the mode. CS training still decodes commands, so a CS_n
assertion there has to carry a real NOP encoding — an all-zero CA bus decodes as
ACT.

An `MRR` to **MR31** returns a BL16 read training pattern instead of register
contents, in serial mode from MR26/MR27 or from the Galois LFSR
(`x^8+x^6+x^5+x^4+1`) seeded by them, inverted per DQ by MR28/MR29 and assigned
by MR30. Read CRC must be off.

**PDA** works: `MPC PDA Enumerate ID` (only inside enumerate programming mode)
sets the device's ID, `MPC PDA Select ID` picks one, and an `MRW` only lands on
the selected device. ID 15 is broadcast, and is the reset state.

**Vref and RTT are shadowed.** A `VrefCA`/`VrefCS` command writes a shadow
register; nothing reaches MR11/MR12 until `MPC Apply VrefCA, VrefCS and
RTT_CA/CS/CK` commits it. The same holds for the `MPC` RTT_CK/CS/CA/PARK
settings.

The DRAM emits a **read preamble** of the MR8 OP[2:0] duration ahead of each
burst, and checks the **write preamble** duration against MR8 OP[4:3] when the
capture window opens. Only durations are enforced — not the exact toggle
patterns, and not postamble length.

Corrected along the way: **MR2 OP[2] is 2N mode, OP[1] is write-levelling
training.** An earlier revision of this model had them swapped.

## No CA parity

DDR4 had CA parity on a `PAR` pin. **JESD79-5 dropped it** — the word "parity"
appears exactly once in the standard, referring to ECC parity, and `ALERT_n`'s
only defined use in DDR5 is signalling a write-CRC error. A controller CSR map
carrying `cfg_ca_parity_en` / `err_ca_parity` has nothing to drive them.

**Verilator is required — Icarus will not do.** The pinned `hdlc/iverilog` image
in this workspace rejects interfaces as module ports, has no associative arrays,
and aborts with an internal assertion on multi-dimensional unpacked arrays. The
runner uses `docker.io/verilator/verilator:latest` (5.050 at time of writing),
which handles all three. Override with `DDR5_SIM_IMAGE`.

## Configuration

Defaults are the **32 Gb x16** part from JESD79-5 Table 7 — 4 bank groups x 4
banks = 16 banks, R0~R16, C0~C9, 2 KB page, 4 GB. That is exactly the RMC anchor
in `rmc_pkg.sv` (`BG_BITS=2`, `BANK_BITS=2`, `ROW_BITS=17`, `COL_BITS=10`) and
exactly one device per channel.

For the 32-bit subchannel used in `rmc_theory/docs/datapath_busy_timing.md`,
instantiate two devices side by side.

```systemverilog
ddr5_device #(
  .DQ_BITS(16), .BG_BITS(2), .BA_BITS(2), .ROW_BITS(17), .COL_BITS(10),
  .SPEED_BIN(BIN_DDR5_4800B), .DENSITY(DEN_32G),
  .CHECK(1'b1), .VERBOSE(1'b0)
) u_dram ( ... );
```

`SPEED_BIN` also accepts `BIN_TOY_200MHZ` — the 5 ns column from
`datapath_busy_timing.md`, kept so waveforms stay readable and the
`RMC_Handoff §18` worked example still cross-checks.

## How timing is checked

Every check is an integer compare on a free-running CK counter. JEDEC states many
parameters as `max(nCK floor, ns floor)`; that `max` is resolved once, at
elaboration, in `ddr5_timing_pkg`. Nothing at runtime depends on simulator time
resolution, and the numbers the checker enforces are the same numbers the
scheduler's CSRs are loaded with.

Spacing for a two-cycle command is measured from its **first** CA cycle, per
JEDEC, not from the cycle where the model finally has all the operands.

Violations print and increment a counter; they do not stop the simulation. A
testbench decides what is fatal:

```systemverilog
if (u_dram.error_count() != 0) $fatal(1, "DRAM protocol errors");
```

Checks live in Stage 1: tRCD, tRP, tRAS, tRC, tRTP, tWR, tRRD_S/L, tFAW,
tCCD_S/L, tCCD_L_WR, tWTR_S/L, tPPD, tRTW, tRFC1/2, tRFCsb, tMRW/tMRR/tMRD, tXP,
plus CAS-to-closed-bank, ACT-to-open-bank, row/column range, RFU encodings, and
the Table 241 NOTE 11 rule that a two-cycle command with no ODT control is
abandoned if CS_n is low again on its second cycle.

## What this is not

Not a signoff model. JEDEC compliance is a claim a VIP vendor validates, not one
this repo can make. Use it for controller bring-up and regression; if the project
ever needs a compliance signoff, that is Cadence DDR5 VIP or Denali, not this.

## The DFI bridge

`dfi_ddr5_phy` sits between the RMC exchange fabric and the device:

```
fabric --dfi_if.ctrl--> [ dfi_ddr5_phy ] --CK/CS_n/CA/DQ/DQS--> ddr5_device
```

The signal set follows `rmc_theory/docs/sched_rebuild/01_dfi_exchange_fabric.md`.
Per-phase signals are packed rather than suffixed: phase N of a W-bit field is
`[N*W +: W]`, which is `dfi_<sig>_pN`.

The PHY owns the DRAM clock and therefore **produces** `dfi_clk`, because a real
PHY holds the PLL and hands the controller its clock. Modelling it the other way
round hides a divider in the testbench and lets the gear ratio drift.

### One pipeline rule

Phase N of the DFI group sampled at dfi cycle D reaches the DRAM pins at absolute
tCK slot `D*G + N`. CA, write data and read capture all obey it, so every latency
falls out of one piece of arithmetic (`dfi_pkg::lat_cycles` / `lat_phase`):

| Exported | Value | Meaning |
|---|---|---|
| `t_phy_wrlat` | `WL / G` | RD/WR command cycle -> assert `dfi_wrdata_en` |
| `t_rddata_en` | `RL / G` | command cycle -> open the read capture window |
| `t_phy_rdlat` | `RL / G + 2` | command cycle -> `dfi_rddata` / `dfi_rddata_valid` |

`RL` and `WL` are MR0 state, so the init FSM calls `u_phy.set_latency(rl, wl)`
after programming MR0 and the controller reloads its `t_phy_*` CSRs from these
outputs. That is the DFI-intended direction: the PHY declares its latencies.

**The phase term is not optional.** The exported cycle counts are the phase-0
case. When `WL % G` or `RL % G` is nonzero the burst does not start on phase 0 —
at 1:4 with WL=38, `WL/G` is 9 but `WL%G` is 2, so write data belongs on phase 2
of that cycle. Placing it on phase 0 puts the burst two tCK early and the DRAM
captures its tail. `lat_phase()` is what the fabric's launch aligner must apply
alongside `t_phy_wrlat`.

### Two pin-level details worth keeping

- **CA is launched on the falling edge.** Driving it combinationally off the
  phase counter changes the pin on the very edge the DRAM samples, and the DRAM
  latches the previous slot — a silent one-slot skew of CA against DQ.
- **Write DQS strobes mid-beat.** DQ changes on the tCK boundary and DQS a
  quarter cycle in, which is DDR5's centre-aligned write DQS and also the reason
  the device and the PHY are never resolving the same signal on the same edge.
  The device therefore captures write data on DQS edges, not CK edges; the DQS
  lead before the burst is the write preamble, and the capture window ignores it.

Not modelled yet: DQS gate training, per-bit deskew, ODT timing, DBI, CRC, CA
parity generation, frequency change, `phyupd` / `phymstr` request generation.
DDR5 has no CKE and no ODT ball, so `dfi.cke` and `dfi.odt` are accepted and
ignored rather than routed to pins that do not exist.

## Sources

- JESD79-5, Tables 4-8 (addressing), 24-26 (mode registers), 241 (command truth
  table), 242/243 (burst order), 281-283 (refresh), 289-291 (MPC)
- `rmc_theory/docs/datapath_busy_timing.md` §1 — the DDR5-4800B timing column,
  already cross-checked against JESD79-5
- `rmc_theory/docs/sched_rebuild/01_dfi_exchange_fabric.md` — DFI signal groups,
  gear ratio, and the `t_phy_*` CSR set the bridge exports into
