// ============================================================================
// spi_fast_read_sha3_384_test.sv
//
// SA seven-step flow:
//   SA-1  Reset SHA3-384 digest: SHA FC[6] = 1
//   SA-2  SPI Fast Read #1 (3 bytes)
//   SA-3  SPI Fast Read #2 (3 bytes)
//   SA-4  SPI Fast Read #3 (2 bytes)
//   SA-5  Final trigger: SHA FC[3] = 1
//   SA-6  Poll SHA FC[5] digest_valid
//   SA-7  Read digest registers and compare SHA3-384 against golden
//
// NEW: Independent single UVM test. No new sequence or scoreboard.
// NEW: Use 3+3+2 segmented SPI downloads (8 total bytes).
// NEW: Disable SPI AHB RMW in each command, to request byte writes.
// NEW: SHA mcu_access_en=0 selects dlatch_cpu / flash_dout (SPI DMA).
// NEW: Build independent SHA3-384 golden from DLM readback of downloaded data.
// NEW: Optional +SHA3_USE_ISSUE_VECTOR: expects flash model preloaded with
//      80 0E 00 00 10 02 00 00, and does not call force_flash_data().
// NEW: Full digest checked through SHA RTL hierarchy; digest registers logged.
// NOTE: Host testbase API / RTL hierarchy require integration in your tree.
// NOTE: DLM readback checks SPI transfer data, but is not a substitute for
//       independently checking the source flash model against expected data.
// ============================================================================

class spi_fast_read_sha3_384_test extends host_mcu_spi_base_test;
    `uvm_component_utils(spi_fast_read_sha3_384_test)

    localparam int SHA3_RATE_BYTES = 104;
    localparam int SHA3_DIGEST_BYTES = 48;
    localparam int POLL_MAX = 10000;
    localparam int TOTAL_BYTES = 8;

    // MODIFY HERE ONLY IF the SPI helper uses another target memory.
    localparam logic [2:0] LOAD_TARGET_DRAM = 3'b000;

    bit [23:0] flash_base;
    bit [31:0] dram_base;
    byte unsigned downloaded[];
    bit [383:0] expected_digest, actual_digest;
    bit [31:0] sha_reg_dump[0:11];
    bit issue_vector_mode;
    int unsigned pass_cnt, fail_cnt;

    function new(string name="spi_fast_read_sha3_384_test", uvm_component parent=null);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------------------
    // SA-1: SHA reset. FC[6] is a write pulse; FC[2] must remain 0.
    // EC[1:0]=0 means one byte per SPI AHB write.
    // IMPORTANT: reset_hash may clear EC, so program EC AFTER FC[6].
    // ------------------------------------------------------------------------
    task automatic sa_step1_sha_reset();
        bit [31:0] rd;
        `uvm_info("SA_STEP1", "Reset SHA3-384; choose SPI DMA data path", UVM_LOW)
        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hD8, 32'h0000_0002); // SHA3-384
        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hF0, 32'h0000_0000); // salt off
        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hFC, 32'h0000_0040); // SA-1 reset_hash
        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hEC, 32'h0000_0000); // NEW: 1 byte/write AFTER reset
        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hD8, rd);
        if (rd[1:0] != 2'b10) `uvm_fatal("SHA_MODE", $sformatf("D8=%08h expected SHA3-384 mode=2", rd))
        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hEC, rd);
        if (rd[1:0] != 2'b00) `uvm_fatal("SHA_EC", $sformatf("EC=%08h expected block_wr_num=0", rd))
        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hFC, rd);
        if (rd[2] != 1'b0) `uvm_fatal("SHA_PATH", $sformatf("FC=%08h mcu_access_en must be 0", rd))
    endtask

    // ------------------------------------------------------------------------
    // SA-2/3/4: same MCU SPI Fast Read register flow as the provided base task.
    // The base mcu_spi_fast_read() invokes mcu_spi_preset() on EVERY call;
    // hence this wrapper explicitly disables AHB RMW after each preset.
    // This matters for partial 3/3/2 byte transfers into SHA.
    // ------------------------------------------------------------------------
    task automatic sa_spi_fast_read(input int step_no, input bit [15:0] byte_count,
                                    input bit [23:0] flash_addr, input bit [31:0] target_addr);
        bit [31:0] ec;
        `uvm_info("SA_SPI_READ", $sformatf("SA-%0d: SPI 0B flash=%06h target=%08h len=%0d",
                                          step_no, flash_addr, target_addr, byte_count), UVM_LOW)

        mcu_spi_preset();
        // NEW: SPI AHB RMW bits D2[5,3] cleared for byte transfers.
        // Original mcu_spi_preset() sets D2 mask 8'h28 to 8'h28.
        // Check this setting against your RTL if the SHA input count differs.
        mcu_reg_wr_bits(m_host_top_cfg.mcu_reg_page_addr_1, 8'hD2, 8'h28, 8'h00);

        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'h32, byte_count[7:0]);
        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'h33, byte_count[15:8]);
        mcu_spi_set_addr(flash_addr, target_addr);
        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'h3D, 8'h0B);
        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'h31, {5'b0, LOAD_TARGET_DRAM});
        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'h30, 8'h04);
        wait_spi_cmd_done();

        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hEC, ec);
        if (ec[1:0] != 0) `uvm_error("SHA_EC", $sformatf("After SPI read EC=%08h; expected 1 byte/write", ec))
    endtask

    // ------------------------------------------------------------------------
    // NEW: Read the actual DLM bytes that SPI DMA wrote.
    // This establishes the golden message independently of the SHA datapath.
    // AHB word read is aligned; byte lane is selected using address[1:0].
    // ------------------------------------------------------------------------
    task automatic read_downloaded_bytes();
        bit [31:0] addr, aligned_addr, rdata;
        downloaded = new[TOTAL_BYTES];
        for (int i=0; i<TOTAL_BYTES; i++) begin
            addr = dram_base + i;
            aligned_addr = addr & 32'hFFFF_FFFC;
            mcu_word_rd(aligned_addr[31:8], aligned_addr[7:0], rdata);
            downloaded[i] = rdata[8*addr[1:0] +: 8];
            `uvm_info("SPI_DLM", $sformatf("addr=%08h byte[%0d]=%02h word=%08h",
                                          addr, i, downloaded[i], rdata), UVM_LOW)
        end
    endtask

    // ------------------------------------------------------------------------
    // NEW: Issue reproduction mode. The external flash model must already
    // contain the eight bytes in the Jira issue. Do not force them here.
    // ------------------------------------------------------------------------
    task automatic check_issue_vector();
        byte unsigned issue_bytes[0:7] = '{8'h80, 8'h0E, 8'h00, 8'h00, 8'h10, 8'h02, 8'h00, 8'h00};
        for (int i=0; i<TOTAL_BYTES; i++) begin
            if (downloaded[i] !== issue_bytes[i])
                `uvm_fatal("FLASH_VECTOR", $sformatf("byte[%0d] expected=%02h got=%02h; preload flash before running",
                                                    i, issue_bytes[i], downloaded[i]))
        end
    endtask

    // ------------------------------------------------------------------------
    // SA-5: final_trigger is a one-cycle pulse. Do not reset SHA between reads.
    // ------------------------------------------------------------------------
    task automatic sa_step5_final_trigger();
        `uvm_info("SA_STEP5", "Final trigger FC[3]=1", UVM_LOW)
        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hFC, 32'h0000_0008);
    endtask

    // ------------------------------------------------------------------------
    // SA-6: poll digest_valid with a bounded timeout.
    // ------------------------------------------------------------------------
    task automatic sa_step6_wait_digest_valid();
        bit [31:0] fc;
        for (int retry=0; retry<POLL_MAX; retry++) begin
            mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hFC, fc);
            if (fc[5]) begin
                `uvm_info("SA_STEP6", $sformatf("digest_valid=1 retry=%0d FC=%08h", retry, fc), UVM_LOW)
                return;
            end
        end
        `uvm_fatal("SHA_TIMEOUT", $sformatf("FC[5] digest_valid timeout after %0d polls", POLL_MAX))
    endtask

    // ------------------------------------------------------------------------
    // SA-7: read 0xA4..0xB3 as SA explicitly requested (first 16 bytes).
    // Also read 0xB4..0xD3 for a complete 48-byte SHA3-384 register dump.
    // Compare the full digest using the RTL's verified digest[511:128] layout,
    // because the exact byte-order of the register map has not been supplied.
    // ------------------------------------------------------------------------
    task automatic sa_step7_read_digest();
        bit [511:0] full_digest;
        for (int i=0; i<12; i++) begin
            mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, byte'(8'hA4 + i*4), sha_reg_dump[i]);
            `uvm_info("SA_DIGEST_REG", $sformatf("SHA[%02h..%02h]=%08h",
                                                8'hA4+i*4, 8'hA7+i*4, sha_reg_dump[i]), UVM_LOW)
        end
        full_digest = system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.digest[511:0];
        actual_digest = full_digest[511 -: 384];
        `uvm_info("SA_DIGEST", $sformatf("actual=%096h", actual_digest), UVM_LOW)
    endtask

    task run_phase(uvm_phase phase);
        super.run_phase(phase);
        phase.raise_objection(this, "SA SPI fast read SHA3-384");
        pass_cnt = 0;
        fail_cnt = 0;
        issue_vector_mode = $test$plusargs("SHA3_USE_ISSUE_VECTOR");

        // NEW: Use the same environment preset as the supplied SPI DRAM test.
        mcu_test_preset();
        if (!reg_set.randomize()) `uvm_fatal("SPI_CFG", "reg_set.randomize() failed")
        flash_base = reg_set.flash_start_addr;
        dram_base  = reg_set.mcu_target_addr;
        mcu_set_spi_spd(reg_set.spi_clk_sel);
        #2us;

        `uvm_info("SA_SETUP", $sformatf("flash=%06h dram=%08h issue_vector=%0b", flash_base, dram_base, issue_vector_mode), UVM_LOW)

        // NEW: The existing helper supplies a known/repeatable flash pattern.
        // In issue-vector mode, preload the exact 8 bytes externally instead.
        if (!issue_vector_mode) force_flash_data(flash_base, dram_base, TOTAL_BYTES);

        // SA-1: reset digest and configure SPI-to-SHA path.
        sa_step1_sha_reset();

        // SA-2/3/4: three independent SPI Fast Read commands, no SHA reset.
        sa_spi_fast_read(2, 16'd3, flash_base,       dram_base);
        sa_spi_fast_read(3, 16'd3, flash_base+24'd3, dram_base+32'd3);
        sa_spi_fast_read(4, 16'd2, flash_base+24'd6, dram_base+32'd6);

        // SA-5/6/7: trigger, poll, then read the digest exactly in SA order.
        sa_step5_final_trigger();
        sa_step6_wait_digest_valid();
        sa_step7_read_digest();

        // NEW: SA-7 compare stage: reconstruct the 8-byte input from DLM.
        read_downloaded_bytes();
        if (issue_vector_mode) check_issue_vector();
        sha3_384(downloaded, expected_digest);
        if (issue_vector_mode &&
            expected_digest !== 384'hebf9b3b4e7717fd0ed1e70c60093d78fda784516bb663ee002f57ffc3a2244145088db84419ac5659cd78c9558e2d7b5)
            `uvm_fatal("SHA_GOLDEN", "Issue fixed-vector SHA3-384 golden mismatch")
        `uvm_info("SA_GOLDEN", $sformatf("expected=%096h actual=%096h", expected_digest, actual_digest), UVM_LOW)

        if (actual_digest !== expected_digest) begin
            fail_cnt++;
            `uvm_error("SA_SHA3_MISMATCH", $sformatf("SPI Fast Read -> SHA3-384 mismatch; expected=%096h actual=%096h",
                                                   expected_digest, actual_digest))
        end else begin
            pass_cnt++;
            `uvm_info("SA_SHA3_PASS", $sformatf("PASS: 3 Fast Reads, 8 bytes, SHA3-384=%096h", actual_digest), UVM_NONE)
        end

        `uvm_info("SA_REPORT", $sformatf("PASS=%0d FAIL=%0d", pass_cnt, fail_cnt), UVM_NONE)
        phase.drop_objection(this, "SA SPI fast read SHA3-384");
    endtask

    // ------------------------------------------------------------------------
    // Independent SHA3-384 golden reference model (Keccak-f[1600]).
    // Copied from the previously reviewed SHA3 test without modifying its math.
    // ------------------------------------------------------------------------
    function automatic bit [63:0]
        rotl64(input bit [63:0] value, input int unsigned sh);

        if (sh == 0) return value;

        return (value << sh) | (value >> (64-sh));

    endfunction

    // ============================================================
    // Keccak Rho offsets
    // ============================================================

    function automatic int unsigned
        rho_offset(input int x, input int y);

        case (y)

            0:
                case (x)
                    0:return 0;
                    1:return 1;
                    2:return 62;
                    3:return 28;
                    4:return 27;
                endcase

            1:
                case (x)
                    0:return 36;
                    1:return 44;
                    2:return 6;
                    3:return 55;
                    4:return 20;
                endcase

            2:
                case (x)
                    0:return 3;
                    1:return 10;
                    2:return 43;
                    3:return 25;
                    4:return 39;
                endcase

            3:
                case (x)
                    0:return 41;
                    1:return 45;
                    2:return 15;
                    3:return 21;
                    4:return 8;
                endcase

            4:
                case (x)
                    0:return 18;
                    1:return 2;
                    2:return 61;
                    3:return 56;
                    4:return 14;
                endcase

        endcase

        return 0;

    endfunction

    // ============================================================
    // Keccak round constants
    // ============================================================

    function automatic bit [63:0]
        keccak_rc(input int r);

        case (r)

             0:return 64'h0000000000000001;
             1:return 64'h0000000000008082;
             2:return 64'h800000000000808A;
             3:return 64'h8000000080008000;
             4:return 64'h000000000000808B;
             5:return 64'h0000000080000001;
             6:return 64'h8000000080008081;
             7:return 64'h8000000000008009;
             8:return 64'h000000000000008A;
             9:return 64'h0000000000000088;
            10:return 64'h0000000080008009;
            11:return 64'h000000008000000A;
            12:return 64'h000000008000808B;
            13:return 64'h800000000000008B;
            14:return 64'h8000000000008089;
            15:return 64'h8000000000008003;
            16:return 64'h8000000000008002;
            17:return 64'h8000000000000080;
            18:return 64'h000000000000800A;
            19:return 64'h800000008000000A;
            20:return 64'h8000000080008081;
            21:return 64'h8000000000008080;
            22:return 64'h0000000080000001;
            23:return 64'h8000000080008008;

        endcase

        return 64'h0;

    endfunction

    // ============================================================
    // Keccak-f[1600]
    // ============================================================

    task automatic keccak_f1600(inout bit [63:0] A [0:24]);

        bit [63:0] C [0:4];
        bit [63:0] D [0:4];
        bit [63:0] B [0:24];

        int x;
        int y;

        int new_x;
        int new_y;

        for (int round = 0; round < 24; round++) begin

            // ---------------- THETA ----------------

            for (x = 0; x < 5; x++) begin

                C[x] = A[x + 5*0] ^ A[x + 5*1] ^ A[x + 5*2] ^ A[x + 5*3] ^ A[x + 5*4];

            end

            for (x = 0; x < 5; x++) begin

                D[x] = C[(x+4)%5] ^ rotl64(C[(x+1)%5], 1);

            end

            for (y = 0; y < 5; y++) begin

                for (x = 0; x < 5; x++) begin

                    A[x + 5*y] ^= D[x];

                end

            end

            // ---------------- RHO + PI ----------------

            for (x = 0; x < 25; x++)
                B[x] = '0;

            for (y = 0; y < 5; y++) begin

                for (x = 0; x < 5; x++) begin

                    new_x = y;

                    new_y = (2*x + 3*y) % 5;

                    B[new_x + 5*new_y]
                        = rotl64(A[x + 5*y], rho_offset(x, y));

                end

            end

            // ---------------- CHI ----------------

            for (y = 0; y < 5; y++) begin

                for (x = 0; x < 5; x++) begin

                    A[x + 5*y]
                        = B[x + 5*y] ^ (~B[((x+1)%5) + 5*y] & B[((x+2)%5) + 5*y]);

                end

            end

            // ---------------- IOTA ----------------

            A[0] ^= keccak_rc(round);

        end

    endtask

    // ============================================================
    // Absorb one 104-byte block
    // ============================================================

    task automatic sha3_absorb_block(inout bit [63:0] A [0:24], input byte unsigned block [0:103]);

        int lane;
        int byte_pos;

        bit [63:0] temp;

        for (int i = 0; i < SHA3_RATE_BYTES; i++) begin

            lane = i / 8;

            byte_pos = i % 8;

            temp = { 56'h0, block[i] };

            A[lane] ^= temp << (byte_pos * 8);

        end

        keccak_f1600(A);

    endtask

    // ============================================================
    // SHA3-384 golden model
    // ============================================================

    task automatic sha3_384(input byte unsigned msg[], output bit [383:0] digest);

        bit [63:0] A [0:24];

        byte unsigned block [0:103];

        byte unsigned digest_byte [0:47];

        int offset;
        int remain;

        int lane;
        int byte_pos;

        for (int i = 0; i < 25; i++)
            A[i] = 64'h0;

        offset = 0;

        // ========================================================
        // Full blocks
        // ========================================================

        while ((msg.size() - offset) >= SHA3_RATE_BYTES) begin

            for (int i = 0; i < SHA3_RATE_BYTES; i++)
                block[i] = msg[offset+i];

            sha3_absorb_block(A, block);

            offset += SHA3_RATE_BYTES;

        end

        // ========================================================
        // Final block
        // ========================================================

        for (int i = 0; i < SHA3_RATE_BYTES; i++)
            block[i] = 8'h00;

        remain = msg.size() - offset;

        for (int i = 0; i < remain; i++)
            block[i] = msg[offset+i];

        // SHA3 domain separator
        block[remain] ^= 8'h06;

        // SHA3 pad10*1
        block[SHA3_RATE_BYTES-1] ^= 8'h80;

        sha3_absorb_block(A, block);

        // ========================================================
        // Squeeze 48 bytes
        // ========================================================

        for (int i = 0; i < SHA3_DIGEST_BYTES; i++) begin

            lane = i / 8;

            byte_pos = i % 8;

            digest_byte[i] = A[lane][byte_pos*8 +: 8];

        end

        // ========================================================
        // Pack exactly like hashlib.hexdigest()
        // ========================================================

        digest = '0;

        for (int i = 0; i < SHA3_DIGEST_BYTES; i++) begin

            digest[383-i*8 -: 8] = digest_byte[i];

        end

    endtask

    // ============================================================

endclass : spi_fast_read_sha3_384_test
