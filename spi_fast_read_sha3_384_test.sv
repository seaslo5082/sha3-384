// ============================================================================
// File: spi_fast_read_sha3_384_test.sv
//
// Purpose: Regress ALISHAN_TCON-10: segmented SPI Fast Read -> SHA3-384.
// Reuses existing host_mcu_spi_base_test helpers; no new sequence/scoreboard.
//
// Flow (SA's seven-step order, with additional DV checks):
//   STEP-0  Existing environment preset; self-check SHA3 golden model.
//   STEP-1  FC[6] reset_hash; D8=SHA3-384; EC=0 (1 byte/latch); FC[2]=0.
//   STEP-2  SPI 0B Fast Read, 3 bytes; monitor SHA's actual dlatch/flash_dout.
//   STEP-3  SPI 0B Fast Read, 3 bytes; NO SHA reset.
//   STEP-4  SPI 0B Fast Read, 2 bytes; NO SHA reset.
//   STEP-4A Check 3+3+2 SHA input bytes against independently read DLM bytes.
//   STEP-4B Check rcnt_sum=64 bits and block_cnt=8 bytes BEFORE final trigger.
//   STEP-5  FC[3] final_trigger.
//   STEP-6  Poll FC[5] digest_valid (bounded).
//   STEP-7  Read A4..D3 digest registers and compare all 384 bits to golden.
//
// Critical fixes vs previous version:
//   FIX-1  mcu_reg_wr_bits(page,addr,DATA,MASK), not (MASK,DATA).
//          The previous (D2, 8'h28, 8'h00) had MASK=0 and did NOTHING.
//          Clear D2[5] with (D2, 8'h00, 8'h20); SPI IRQ is DD[5].
//   FIX-2  Independently monitor the bytes *actually accepted* by SHA.
//          DLM readback alone does not prove SHA received the same bytes.
//   FIX-3  Check SHA rcnt_sum/block_cnt before final trigger.
//   FIX-4  Build the digest from the actual 12 AHB digest registers:
//          A4 is digest[31:0], D0 is digest[383:352] (observed in logs).
//   FIX-5  Reuse existing base-test helper APIs; no task name has an SA prefix.
//
// Default run: force_flash_data() from existing base and compare its 8 bytes.
// Exact Jira vector: +SHA3_USE_ISSUE_VECTOR, but flash must be preloaded with
//                   80 0E 00 00 10 02 00 00 at reg_set.flash_start_addr.
//
// Additional debug logs (no functional stimulus changes):
//   +SHA3_DEBUG             : Enable RTL state snapshots and event tracing.
//   +SHA3_DEBUG_MAX=<N>     : Limit detailed event logs (default 100).
//   SHA_STATE              : mode, rate, counters, latch source and flags.
//   SHA_EVENT              : SPI latch / SHA latch / block-ready transitions.
//   SHA_LATCH              : Data word and counters at each accepted latch.
//   SHA_SEGMENT_TRACE      : Counter/byte count after each Fast Read.
//   SHA_INPUT_DUMP         : Side-by-side actual SHA input and DLM bytes.
//   SHA_POLL               : Periodic digest-valid polling progress.
//   SHA_FAIL_CONTEXT       : Final state when the digest does not match.
// IMPORTANT: This test reports an error on defective RTL. It is not possible
// to guarantee PASS without running the exact simulator/RTL/flash model.
// ============================================================================

class spi_fast_read_sha3_384_test extends host_mcu_spi_base_test;
    `uvm_component_utils(spi_fast_read_sha3_384_test)

    localparam int SHA3_RATE_BYTES = 104;
    localparam int SHA3_DIGEST_BYTES = 48;
    localparam int POLL_MAX = 10000;
    localparam int TOTAL_BYTES = 8;
    localparam logic [2:0] LOAD_TARGET_DRAM = 3'b000;

    bit [23:0] flash_base;
    bit [31:0] dram_base;
    byte unsigned downloaded[];
    byte unsigned sha_accepted[$];
    bit [383:0] expected_digest, actual_digest;
    bit [31:0] sha_reg_dump[0:11];
    bit issue_vector_mode, stop_sha_monitor;
    bit sha_debug_en;
    int unsigned sha_debug_event_count, sha_debug_event_limit;
    int unsigned active_segment, sha_latch_count;
    int unsigned segment_bytes[0:2];
    int unsigned pass_cnt, fail_cnt;

    function new(string name="spi_fast_read_sha3_384_test", uvm_component parent=null);
        super.new(name, parent);
    endfunction

    // [DEBUG] Passive white-box snapshot: no register writes and no DUT forces.
    // Read these signals only at stable milestones, never as a substitute for
    // the SHA_ACCEPT data capture at the clock edge.
    task automatic dump_sha_debug_state(input string where_at);
        if (!sha_debug_en) return;
        `uvm_info("SHA_STATE", $sformatf("[%s] mode=%0d rate_bytes=%0d block_wr_num=%0d rcnt_sum=%0d bits block_cnt=%0d block_cnt_for_fw=%0d",
                  where_at,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.mode,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.rate_bytes,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.block_wr_num,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.rcnt_sum,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.block_cnt,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.block_cnt_for_fw), UVM_LOW)
        `uvm_info("SHA_STATE", $sformatf("[%s] dlatch=%b dlatch_cpu=%b mcu_access_en=%b mcu_access_dlatch=%b salt_dlatch=%b flash_dout=%08h",
                  where_at,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.dlatch,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.dlatch_cpu,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.mcu_access_en,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.mcu_access_dlatch,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.salt_dlatch,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.flash_dout), UVM_LOW)
        `uvm_info("SHA_STATE", $sformatf("[%s] reset_hash=%b final_trigger=%b block_ready_flg=%b final_fill_flg=%b digest_valid=%b",
                  where_at,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.reset_hash,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.final_trigger,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.block_ready_flg,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.final_fill_flg,
                  system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.digest_valid), UVM_LOW)
    endtask

    // STEP-0: Prove the software SHA3-384 reference implementation is sound.
    // "abc" is a public standard vector. The Jira vector is also checked.
    task automatic check_sha3_golden_model();
        byte unsigned msg[];
        bit [383:0] got;
        msg = new[3]; msg[0]=8'h61; msg[1]=8'h62; msg[2]=8'h63;
        sha3_384(msg, got);
        if (got !== 384'hec01498288516fc926459f58e2c6ad8df9b473cb0fc08c2596da7cf0e49be4b298d88cea927ac7f539f1edf228376d25)
            `uvm_fatal("SHA_GOLDEN", $sformatf("SHA3-384(abc) mismatch: %096h", got))
        msg = new[8];
        msg[0]=8'h80; msg[1]=8'h0e; msg[2]=8'h00; msg[3]=8'h00;
        msg[4]=8'h10; msg[5]=8'h02; msg[6]=8'h00; msg[7]=8'h00;
        sha3_384(msg, got);
        if (got !== 384'hebf9b3b4e7717fd0ed1e70c60093d78fda784516bb663ee002f57ffc3a2244145088db84419ac5659cd78c9558e2d7b5)
            `uvm_fatal("SHA_GOLDEN", $sformatf("SHA3-384(issue vector) mismatch: %096h", got))
        `uvm_info("SHA_GOLDEN", "PASS: abc and Jira issue vectors", UVM_LOW)
    endtask

    // STEP-1: Configure SHA3-384 and select SPI flash data path.
    // RTL: dlatch = salt_dlatch ? 1 : mcu_access_en ? mcu_access_dlatch : dlatch_cpu;
    // With salt_en=0 and FC[2]=0, SHA must consume dlatch_cpu / flash_dout.
    task automatic reset_sha3_for_spi();
        bit [31:0] rd;
        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hD8, 32'h0000_0002);
        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hF0, 32'h0000_0000);
        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hFC, 32'h0000_0040);
        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hEC, 32'h0000_0000);
        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hD8, rd);
        if (rd[1:0] !== 2'b10) `uvm_fatal("SHA_MODE", $sformatf("D8=%08h expected mode=2", rd))
        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hEC, rd);
        if (rd[1:0] !== 2'b00) `uvm_fatal("SHA_EC", $sformatf("EC=%08h expected block_wr_num=0", rd))
        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hFC, rd);
        if (rd[2] !== 1'b0) `uvm_fatal("SHA_PATH", $sformatf("FC=%08h expected mcu_access_en=0", rd))
        `uvm_info("SHA_SETUP", "STEP-1: reset_hash=1, mode=SHA3-384, salt=off, SPI path, 1 byte/latch", UVM_LOW)
        dump_sha_debug_state("STEP-1 after SHA reset");
    endtask

    // STEP-2/3/4: Existing base tasks are reused for the SPI register flow.
    // Keep the three transactions separate and do not reset SHA in between.
    // The base mcu_spi_preset() may change D2; fix D2[5] after EVERY preset.
    task automatic spi_fast_read_chunk(input int step_no, input bit [15:0] byte_count,
                                       input bit [23:0] flash_addr, input bit [31:0] target_addr);
        bit [31:0] rd;
        `uvm_info("SPI_SHA_READ", $sformatf("STEP-%0d: SPI 0B flash=%06h target=%08h len=%0d", step_no, flash_addr, target_addr, byte_count), UVM_LOW)
        mcu_spi_preset();

        // FIX-1: mcu_reg_wr_bits(page,addr,data,mask). Clear D2[5] ONLY.
        // In the old log: data=0x28, mask=0, original=0x20, written=0x20.
        // Hence the old call did not clear RMW at all.
        mcu_reg_wr_bits(m_host_top_cfg.mcu_reg_page_addr_1, 8'hD2, 8'h00, 8'h20);
        mcu_word_rd(m_host_top_cfg.mcu_reg_page_addr_1, 8'hD0, rd);
        `uvm_info("SPI_D2", $sformatf("D0..D3=%08h, D2=%02h, D2[5](RMW)=%0b, D2[3]=%0b", rd, rd[23:16], rd[21], rd[19]), UVM_LOW)
        if (rd[21] !== 1'b0) begin
            fail_cnt++;
            `uvm_error("SPI_RMW", $sformatf("D2[5] AHB RMW was not cleared; word=%08h", rd))
        end

        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'h32, byte_count[7:0]);
        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'h33, byte_count[15:8]);
        mcu_spi_set_addr(flash_addr, target_addr);
        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'h3D, 8'h0B);
        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'h31, {5'b0, LOAD_TARGET_DRAM});
        dump_sha_debug_state($sformatf("STEP-%0d before SPI command", step_no));
        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'h30, 8'h04);
        wait_spi_cmd_done();
        dump_sha_debug_state($sformatf("STEP-%0d after SPI command", step_no));
        `uvm_info("SHA_SEGMENT_TRACE", $sformatf("STEP-%0d completed: segment=%0d SHA_bytes=%0d total_SHA_bytes=%0d SHA_latches=%0d",
                  step_no, active_segment+1, segment_bytes[active_segment], sha_accepted.size(), sha_latch_count), UVM_LOW)

        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hEC, rd);
        if (rd[1:0] !== 2'b00) begin
            fail_cnt++;
            `uvm_error("SHA_EC", $sformatf("After STEP-%0d EC=%08h; expected one byte per SHA latch", step_no, rd))
        end
    endtask

    // FIX-2: This monitor observes the actual SHA datapath on sha3_top.clk.
    // The sampled flash_dout and block_wr_num are the same pre-NBA values
    // consumed by block_tmp <= flash_dout on that rising edge.
    // Capture starts BEFORE the first SPI command and stops AFTER the third.
    task automatic monitor_sha_spi_input();
        bit [31:0] data_word;
        int unsigned bytes_this_latch;
        logic prev_digest_valid;
        logic [1:0] prev_block_ready;
        logic spi_pulse, sha_pulse;
        prev_digest_valid=1'b0; prev_block_ready='0;
        while (!stop_sha_monitor) begin
            @(posedge system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.clk);
            if (stop_sha_monitor) break;
            spi_pulse = (system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.dlatch_cpu === 1'b1);
            sha_pulse = (system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.dlatch === 1'b1);

            // [DEBUG] Only report interesting events; do not log every clock.
            // In particular, SPI dlatch_cpu=1 with SHA dlatch=0 reveals a
            // data-path selection/gating problem, even if DLM is correct.
            if (sha_debug_en && sha_debug_event_count < sha_debug_event_limit) begin
                if (spi_pulse || sha_pulse ||
                    system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.block_ready_flg !== prev_block_ready ||
                    system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.digest_valid !== prev_digest_valid) begin
                    sha_debug_event_count++;
                    `uvm_info("SHA_EVENT", $sformatf("event=%0d seg=%0d spi_dlatch=%b sha_dlatch=%b mcu_en=%b salt_dlatch=%b data=%08h block_wr_num=%0d rcnt=%0d block_cnt=%0d ready=%b fill=%b valid=%b",
                              sha_debug_event_count, active_segment+1, spi_pulse, sha_pulse,
                              system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.mcu_access_en,
                              system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.salt_dlatch,
                              system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.flash_dout,
                              system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.block_wr_num,
                              system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.rcnt_sum,
                              system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.block_cnt,
                              system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.block_ready_flg,
                              system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.final_fill_flg,
                              system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.digest_valid), UVM_LOW)
                    if (spi_pulse && !sha_pulse)
                        `uvm_info("SHA_PATH_DEBUG", "SPI dlatch_cpu=1 but SHA dlatch=0: check mcu_access_en and salt_dlatch", UVM_LOW)
                end
                if (sha_debug_event_count == sha_debug_event_limit)
                    `uvm_info("SHA_DEBUG_LIMIT", $sformatf("Detailed event trace capped at %0d; use +SHA3_DEBUG_MAX=<N> to increase", sha_debug_event_limit), UVM_LOW)
            end
            prev_block_ready = system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.block_ready_flg;
            prev_digest_valid = system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.digest_valid;

            if (sha_pulse) begin
                if (system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.mcu_access_en !== 1'b0 ||
                    system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.salt_dlatch !== 1'b0) begin
                    fail_cnt++;
                    `uvm_error("SHA_SOURCE", "Unexpected MCU/salt source while monitoring SPI SHA input")
                end
                data_word = system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.flash_dout;
                bytes_this_latch = int'(system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.block_wr_num) + 1;
                sha_latch_count++;
                if (sha_debug_en)
                    `uvm_info("SHA_LATCH", $sformatf("seg=%0d latch=%0d data=%08h bytes=%0d pre_rcnt=%0d pre_block_cnt=%0d pre_fw_cnt=%0d",
                              active_segment+1, sha_latch_count, data_word, bytes_this_latch,
                              system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.rcnt_sum,
                              system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.block_cnt,
                              system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.block_cnt_for_fw), UVM_LOW)
                for (int j=0; j<bytes_this_latch; j++) begin
                    sha_accepted.push_back(data_word[j*8 +: 8]);
                    segment_bytes[active_segment]++;
                    `uvm_info("SHA_ACCEPT", $sformatf("seg=%0d latch=%0d sha_byte[%0d]=%02h flash_dout=%08h block_wr_num=%0d",
                              active_segment+1, sha_latch_count, sha_accepted.size()-1, data_word[j*8 +: 8],
                              data_word, bytes_this_latch-1), UVM_LOW)
                end
            end
        end
    endtask

    // STEP-4A: Read DLM through the existing AHB word-read helper.
    // The golden input comes from DLM, NOT from SHA's internal buffer.
    task automatic read_downloaded_bytes();
        bit [31:0] addr, aligned_addr, rdata;
        downloaded = new[TOTAL_BYTES];
        for (int i=0; i<TOTAL_BYTES; i++) begin
            addr = dram_base + i;
            aligned_addr = addr & 32'hFFFF_FFFC;
            mcu_word_rd(aligned_addr[31:8], aligned_addr[7:0], rdata);
            downloaded[i] = rdata[8*addr[1:0] +: 8];
            `uvm_info("SPI_DLM", $sformatf("DLM[%0d] addr=%08h data=%02h word=%08h", i, addr, downloaded[i], rdata), UVM_LOW)
        end
    endtask

    // Optional exact issue reproduction. The flash model must be preloaded;
    // this check prevents claiming the Jira vector was tested when it was not.
    task automatic check_issue_vector();
        byte unsigned issue_bytes[0:7] = '{8'h80,8'h0e,8'h00,8'h00,8'h10,8'h02,8'h00,8'h00};
        for (int i=0; i<TOTAL_BYTES; i++) begin
            if (downloaded[i] !== issue_bytes[i])
                `uvm_fatal("FLASH_VECTOR", $sformatf("Issue vector not preloaded: DLM[%0d]=%02h expected=%02h", i, downloaded[i], issue_bytes[i]))
        end
        `uvm_info("FLASH_VECTOR", "PASS: exact Jira vector 80 0E 00 00 10 02 00 00", UVM_NONE)
    endtask

    // STEP-4A/4B: Distinguish bad SPI-to-SHA data from a broken SHA engine.
    task automatic check_sha_input();
        bit [63:0] rcnt;
        bit [7:0] block_cnt;
        string sha_bytes_text, dlm_bytes_text;
        int unsigned expected_segment[0:2] = '{3,3,2};
        sha_bytes_text=""; dlm_bytes_text="";
        for (int i=0; i<sha_accepted.size(); i++) sha_bytes_text={sha_bytes_text, $sformatf("%02h ", sha_accepted[i])};
        for (int i=0; i<downloaded.size(); i++) dlm_bytes_text={dlm_bytes_text, $sformatf("%02h ", downloaded[i])};
        `uvm_info("SHA_INPUT_DUMP", $sformatf("SHA actual input (%0d bytes): %s", sha_accepted.size(), sha_bytes_text), UVM_LOW)
        `uvm_info("SHA_INPUT_DUMP", $sformatf("DLM golden input (%0d bytes): %s", downloaded.size(), dlm_bytes_text), UVM_LOW)
        for (int s=0; s<3; s++) begin
            `uvm_info("SHA_SEGMENT", $sformatf("segment %0d accepted=%0d expected=%0d", s+1, segment_bytes[s], expected_segment[s]), UVM_LOW)
            if (segment_bytes[s] != expected_segment[s]) begin
                fail_cnt++;
                `uvm_error("SHA_SEGMENT", $sformatf("segment %0d SHA accepted %0d bytes; expected %0d", s+1, segment_bytes[s], expected_segment[s]))
            end
        end
        if (sha_accepted.size() != TOTAL_BYTES) begin
            fail_cnt++;
            `uvm_error("SHA_BYTE_COUNT", $sformatf("SHA accepted %0d bytes (%0d latches), expected 8", sha_accepted.size(), sha_latch_count))
        end else begin
            for (int i=0; i<TOTAL_BYTES; i++) begin
                if (sha_accepted[i] !== downloaded[i]) begin
                    fail_cnt++;
                    `uvm_error("SHA_INPUT", $sformatf("byte[%0d] SHA=%02h DLM=%02h", i, sha_accepted[i], downloaded[i]))
                end
            end
        end
        rcnt = system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.rcnt_sum;
        block_cnt = system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.block_cnt;
        `uvm_info("SHA_COUNT", $sformatf("before final: rcnt_sum=%0d bits block_cnt=%0d bytes", rcnt, block_cnt), UVM_LOW)
        if (rcnt !== 64'd64 || block_cnt !== 8'd8) begin
            fail_cnt++;
            `uvm_error("SHA_COUNT", $sformatf("Expected rcnt_sum=64, block_cnt=8; got %0d and %0d", rcnt, block_cnt))
        end
    endtask

    // STEP-6: Bounded polling for FC[5], not a fixed-delay approximation.
    task automatic wait_sha3_digest_valid();
        bit [31:0] fc;
        for (int retry=0; retry<POLL_MAX; retry++) begin
            mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hFC, fc);
            if (sha_debug_en && (retry == 0 || (retry % 1000) == 0))
                `uvm_info("SHA_POLL", $sformatf("retry=%0d FC=%08h valid=%b RTL_valid=%b RTL_final_fill=%b",
                          retry, fc, fc[5],
                          system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.digest_valid,
                          system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.final_fill_flg), UVM_LOW)
            if (fc[5]) begin
                `uvm_info("SHA_DONE", $sformatf("digest_valid=1 retry=%0d FC=%08h", retry, fc), UVM_LOW)
                return;
            end
        end
        dump_sha_debug_state("SHA digest-valid TIMEOUT");
        `uvm_fatal("SHA_TIMEOUT", $sformatf("FC[5] digest_valid timeout after %0d polls, last FC=%08h", POLL_MAX, fc))
    endtask

    // STEP-7: Digest register order observed in the previous simulation:
    //   A4..A7 = digest[31:0], A8..AB = digest[63:32], ... D0..D3 = [383:352].
    // Reconstruct 384 bits from AHB reads, then cross-check internal digest.
    task automatic read_sha3_digest();
        bit [511:0] full_digest;
        actual_digest = '0;
        for (int i=0; i<12; i++) begin
            mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, byte'(8'hA4 + i*4), sha_reg_dump[i]);
            actual_digest[32*i +: 32] = sha_reg_dump[i];
            `uvm_info("SHA_DIGEST_REG", $sformatf("reg[%02h..%02h]=%08h", 8'hA4+i*4, 8'hA7+i*4, sha_reg_dump[i]), UVM_LOW)
        end
        full_digest = system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.digest[511:0];
        if (actual_digest !== full_digest[511 -: 384]) begin
            fail_cnt++;
            `uvm_error("SHA_DIGEST_MAP", $sformatf("AHB digest=%096h RTL digest=%096h", actual_digest, full_digest[511 -: 384]))
        end
        `uvm_info("SHA_DIGEST", $sformatf("AHB actual=%096h", actual_digest), UVM_LOW)
    endtask

    task run_phase(uvm_phase phase);
        super.run_phase(phase);
        phase.raise_objection(this, "SPI Fast Read -> SHA3-384 regression");
        pass_cnt=0; fail_cnt=0; sha_latch_count=0; active_segment=0; stop_sha_monitor=0;
        sha_accepted.delete();
        for (int s=0; s<3; s++) segment_bytes[s]=0;
        issue_vector_mode = $test$plusargs("SHA3_USE_ISSUE_VECTOR");
        sha_debug_en = $test$plusargs("SHA3_DEBUG");
        sha_debug_event_count=0; sha_debug_event_limit=100;
        void'($value$plusargs("SHA3_DEBUG_MAX=%d", sha_debug_event_limit));
        if (sha_debug_event_limit == 0) sha_debug_event_limit=100;
        `uvm_info("SHA_DEBUG_CFG", $sformatf("SHA3_DEBUG=%0b event_limit=%0d (enable with +SHA3_DEBUG)", sha_debug_en, sha_debug_event_limit), UVM_LOW)

        // STEP-0: Existing environment and SPI flash model helpers.
        mcu_test_preset();
        if (!reg_set.randomize()) `uvm_fatal("SPI_CFG", "reg_set.randomize() failed")
        flash_base = reg_set.flash_start_addr;
        dram_base = reg_set.mcu_target_addr;
        mcu_set_spi_spd(reg_set.spi_clk_sel);
        #2us;
        check_sha3_golden_model();
        `uvm_info("SPI_SHA_SETUP", $sformatf("flash=%06h DLM=%08h issue_vector=%0b", flash_base, dram_base, issue_vector_mode), UVM_LOW)
        if (!issue_vector_mode) force_flash_data(flash_base, dram_base, TOTAL_BYTES);

        reset_sha3_for_spi();

        // STEP-2/3/4: Capture actual SHA input while issuing three commands.
        // Only the existing SPI helpers drive the DUT; the monitor is passive.
        fork
            monitor_sha_spi_input();
            begin
                active_segment=0; spi_fast_read_chunk(2, 16'd3, flash_base,       dram_base);
                repeat (4) @(posedge system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.clk);
                active_segment=1; spi_fast_read_chunk(3, 16'd3, flash_base+24'd3, dram_base+32'd3);
                repeat (4) @(posedge system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.clk);
                active_segment=2; spi_fast_read_chunk(4, 16'd2, flash_base+24'd6, dram_base+32'd6);
                repeat (8) @(posedge system.i_NT71801.i01_grp_tcon.i1_apr_top.u_crypto_top.i_sha3_top.clk);
                stop_sha_monitor=1;
            end
        join

        read_downloaded_bytes();
        if (issue_vector_mode) check_issue_vector();
        check_sha_input();
        sha3_384(downloaded, expected_digest);
        `uvm_info("SHA_GOLDEN", $sformatf("expected SHA3-384=%096h", expected_digest), UVM_LOW)
        dump_sha_debug_state("Before final trigger");

        // STEP-5: Finalize only after all three Fast Reads; never reset in between.
        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hFC, 32'h0000_0008);
        `uvm_info("SHA_FINAL", "STEP-5: FC[3] final_trigger pulse", UVM_LOW)
        dump_sha_debug_state("After final trigger write");
        wait_sha3_digest_valid();
        dump_sha_debug_state("After digest_valid=1");
        read_sha3_digest();

        if (actual_digest !== expected_digest) begin
            fail_cnt++;
            `uvm_error("SHA3_MISMATCH", $sformatf("SPI Fast Read SHA3-384 expected=%096h actual=%096h", expected_digest, actual_digest))
            `uvm_info("SHA_FAIL_CONTEXT", $sformatf("segment_counts=%0d/%0d/%0d accepted=%0d latches=%0d; check SHA_INPUT_DUMP, SHA_COUNT and SHA_EVENT",
                      segment_bytes[0], segment_bytes[1], segment_bytes[2], sha_accepted.size(), sha_latch_count), UVM_NONE)
            dump_sha_debug_state("Digest mismatch");
        end
        if (fail_cnt == 0) begin
            pass_cnt++;
            `uvm_info("SPI_SHA_PASS", $sformatf("PASS: 3+3+2 Fast Reads, 8 SHA bytes, SHA3-384=%096h", actual_digest), UVM_NONE)
        end
        `uvm_info("SPI_SHA_REPORT", $sformatf("PASS=%0d FAIL=%0d", pass_cnt, fail_cnt), UVM_NONE)
        phase.drop_objection(this, "SPI Fast Read -> SHA3-384 regression");
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
