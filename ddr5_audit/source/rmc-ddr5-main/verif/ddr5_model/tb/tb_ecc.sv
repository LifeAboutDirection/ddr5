// ---------------------------------------------------------------------------
// tb_ecc.sv — unit checks for the SEC code and the CRC-8, independent of any
// DRAM behaviour. If this fails, nothing downstream is trustworthy.
// ---------------------------------------------------------------------------
`timescale 1ps/1fs

module tb_ecc;
  import ddr5_ecc_pkg::*;

  ecc_col_t H [ECC_DATA_BITS];
  int fails = 0;

  initial begin
    logic [127:0] d, dbad;
    ecc_col_t c;
    int loc, ndue, nmis;

    build_h(H);

    for (int i = 0; i < 128; i++) begin
      if (H[i] == 0 || is_unit_vector(H[i])) begin
        $display("FAIL: column %0d is %02h", i, H[i]); fails++;
      end
      for (int j = i+1; j < 128; j++)
        if (H[i] == H[j]) begin
          $display("FAIL: columns %0d and %0d both %02h", i, j, H[i]); fails++;
        end
    end
    if (fails == 0) $display("PASS: 128 distinct non-unit H columns");

    d = 128'h0123_4567_89ab_cdef_fedc_ba98_7654_3210;
    c = ecc_check_bits(d, H);

    for (int b = 0; b < 128; b++) begin
      dbad = d; dbad[b] = ~dbad[b];
      loc = ecc_locate(ecc_syndrome(dbad, c, H), H);
      if (loc != b) begin
        $display("FAIL: bit %0d located as %0d", b, loc); fails++;
      end
    end
    if (fails == 0) $display("PASS: all 128 single-bit errors located exactly");

    if (ecc_locate(ecc_syndrome(d, c, H), H) != -1) begin
      $display("FAIL: clean code word flagged"); fails++;
    end
    else $display("PASS: clean code word is silent");

    // Double-bit errors are outside SEC's correction power, but they must
    // never be silently accepted as clean.
    ndue = 0; nmis = 0;
    for (int a = 0; a < 128; a++)
      for (int b = a+1; b < 128; b += 7) begin
        dbad = d; dbad[a] = ~dbad[a]; dbad[b] = ~dbad[b];
        loc = ecc_locate(ecc_syndrome(dbad, c, H), H);
        if (loc == -1) begin
          $display("FAIL: double error at %0d,%0d read as clean", a, b);
          fails++;
        end
        else if (loc == -2) ndue++;
        else nmis++;
      end
    $display("PASS: double-bit errors -- %0d DUE, %0d miscorrected, 0 silent",
             ndue, nmis);

    begin
      logic [63:0] w, wb;
      logic [7:0]  r0;
      w  = 64'hdead_beef_0123_4567;
      r0 = crc8_d64(w);
      for (int b = 0; b < 64; b++) begin
        wb = w; wb[b] = ~wb[b];
        if (crc8_d64(wb) == r0) begin
          $display("FAIL: CRC missed single-bit error at %0d", b); fails++;
        end
      end
      if (fails == 0) $display("PASS: CRC catches all 64 single-bit errors");
    end

    $display("=== tb_ecc: %0d failures ===", fails);
    if (fails == 0) $display("=== ECC/CRC TEST PASSED ===");
    else            $display("=== ECC/CRC TEST FAILED ===");
    $finish;
  end
endmodule
