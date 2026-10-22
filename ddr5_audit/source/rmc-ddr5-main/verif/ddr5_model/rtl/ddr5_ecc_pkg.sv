// ---------------------------------------------------------------------------
// ddr5_ecc_pkg.sv — on-die SEC ECC and write/read CRC
//
// On-die ECC (JESD79-5 4.35): the DRAM computes 8 check bits over each 128
// data bits, corrects any single-bit error on read, and does NOT write the
// correction back during a read. A x16 part fetches two 136-bit code words
// from two internal banks at the same external bank address, one mapped to
// DQ[7:0] and the other to DQ[15:8], checked separately and in parallel.
//
// The standard says the code is "fully specified by the H matrix" but the
// matrix itself is a device-vendor detail, and it is invisible to a memory
// controller: the DRAM corrects silently and the controller never sees a check
// bit. What has to be right is the behaviour --
//     syndrome zero               -> no error
//     syndrome matching a column  -> flip that bit
//     syndrome matching no column -> DUE (detected, uncorrected)
// -- so this package builds its own valid SEC code with those properties.
// Columns are distinct, nonzero, and never a unit vector (those belong to the
// check bits). Odd-weight patterns are allocated first so that as many
// double-bit errors as possible land on an unused syndrome and report DUE
// rather than miscorrecting.
//
// CRC (4.37.1): ATM-8 HEC, X^8 + X^2 + X^1 + 1, initial state zero, first
// serial data bit is D[63]. Implemented as a shift register rather than by
// transcribing the spec's XOR trees; the two were checked term for term
// against the published NewCRC[0] equation and agree exactly.
// ---------------------------------------------------------------------------
`timescale 1ps/1fs

package ddr5_ecc_pkg;

  parameter int ECC_DATA_BITS  = 128;
  parameter int ECC_CHECK_BITS = 8;

  typedef logic [ECC_CHECK_BITS-1:0] ecc_col_t;

  function automatic int popcount8(input logic [7:0] v);
    int n;
    n = 0;
    for (int i = 0; i < 8; i++) if (v[i]) n++;
    return n;
  endfunction

  function automatic bit is_unit_vector(input logic [7:0] v);
    return (popcount8(v) == 1);
  endfunction

  // Build the H matrix once. Odd-weight non-unit columns first (weights 3, 5
  // and 7 supply 120 of the 128 needed), then even-weight non-unit columns.
  function automatic void build_h(output ecc_col_t h [ECC_DATA_BITS]);
    int n;
    logic [7:0] col;
    n = 0;
    for (int pass = 0; pass < 2; pass++) begin
      for (int v = 1; v < 256; v++) begin
        col = 8'(v);
        if (is_unit_vector(col)) continue;
        if ((popcount8(col) % 2) != (pass == 0 ? 1 : 0)) continue;
        if (n < ECC_DATA_BITS) begin
          h[n] = col;
          n++;
        end
      end
    end
  endfunction

  function automatic ecc_col_t ecc_check_bits(input logic [ECC_DATA_BITS-1:0] d,
                                              input ecc_col_t h [ECC_DATA_BITS]);
    ecc_col_t c;
    c = '0;
    for (int i = 0; i < ECC_DATA_BITS; i++) if (d[i]) c ^= h[i];
    return c;
  endfunction

  function automatic ecc_col_t ecc_syndrome(input logic [ECC_DATA_BITS-1:0] d,
                                            input ecc_col_t stored,
                                            input ecc_col_t h [ECC_DATA_BITS]);
    return ecc_check_bits(d, h) ^ stored;
  endfunction

  // Returns the data bit index to flip, ECC_DATA_BITS + n for check bit n,
  // -1 for a clean code word, and -2 for a syndrome matching no column (DUE).
  function automatic int ecc_locate(input ecc_col_t syn,
                                    input ecc_col_t h [ECC_DATA_BITS]);
    if (syn == '0) return -1;
    for (int i = 0; i < ECC_DATA_BITS; i++) if (h[i] == syn) return i;
    if (is_unit_vector(syn)) begin
      for (int b = 0; b < ECC_CHECK_BITS; b++)
        if (syn[b]) return ECC_DATA_BITS + b;
    end
    return -2;   // DUE
  endfunction

  // -------------------------------------------------------------------------
  // CRC-8 / ATM HEC over 64 bits. D[63] is transferred first.
  // -------------------------------------------------------------------------
  function automatic logic [7:0] crc8_d64(input logic [63:0] d);
    logic [7:0] c;
    logic       top;
    c = '0;
    for (int i = 63; i >= 0; i--) begin
      top = c[7];
      c   = {c[6:0], 1'b0};
      if (top ^ d[i]) c ^= 8'h07;      // X^8 + X^2 + X^1 + 1
    end
    return c;
  endfunction

endpackage : ddr5_ecc_pkg
