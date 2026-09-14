class mcu_sha_read_salt_test extends host_base_test;

    `uvm_component_utils(mcu_sha_read_salt_test)

    // ============================================================
    // SHA3-384 constant
    // SHA3-384 rate = 832 bits = 104 bytes
    // digest        = 384 bits = 48 bytes
    // ============================================================

    localparam int SHA3_RATE_BYTES   = 104;
    localparam int SHA3_DIGEST_BYTES = 48;
    localparam int SHA3_MAX_RETRY    = 10000;

    // ============================================================
    // Message / Golden data
    // ============================================================

    byte unsigned sha_data[];
    byte unsigned golden_data[];
    byte unsigned mask_data[];

    int unsigned sha_data_len_byte;
    int unsigned sha_data_len_bit;

    bit [1:0] block_wr_num;

    // ============================================================
    // Salt
    // ============================================================

    bit        salt_en;
    bit        salt_mode;
    bit        salt_debug_en;

    bit [31:0] salt_value;

    // ============================================================
    // Mask
    // ============================================================

    bit          mask_en;
    int unsigned mask_start_byte;
    bit [63:0]   start_mask_rcnt;

    // ============================================================
    // Digest
    // ============================================================

    bit [383:0] expected_digest;
    bit [383:0] actual_digest;

    // ============================================================
    // Result counter
    // ============================================================

    int unsigned pass_cnt;
    int unsigned fail_cnt;

    // ============================================================
    // Constructor
    // ============================================================

    function new(string name = "mcu_sha_read_salt_test", uvm_component parent = null);

        super.new(name, parent);

    endfunction

    // ============================================================
    // RUN PHASE
    //
    // TC0 : Plain ABC
    //
    // TC1 : 103 bytes
    // TC2 : 104 bytes
    // TC3 : 105 bytes
    //
    // TC4 : REG salt || message
    // TC5 : message || REG salt
    //
    // TC6 : OTP salt || message
    // TC7 : message || OTP salt
    //
    // TC8 : Mask
    //
    // TC9 : SHA local salt_clr
    //
    // 注意：
    // 這版不再驗 Boot-ROM clear_salt。
    //
    // Important:
    // This version no longer verifies Boot-ROM clear_salt.
    // ============================================================

    task run_phase(uvm_phase phase);

        super.run_phase(phase);

        phase.raise_objection(this);

        pass_cnt = 0;
        fail_cnt = 0;

        // --------------------------------------------------------
        // 原本 Host / MCU preset
        // Original Host / MCU preset
        // --------------------------------------------------------

        mcu_test_preset();

        // --------------------------------------------------------
        // Golden model 必須先自己過關
        // Golden model must first prove itself
        // --------------------------------------------------------

        sha3_384_self_test();

        // ========================================================
        // Basic SHA
        // ========================================================

        run_plain_abc_test(0);

        // ========================================================
        // SHA3-384 rate boundary
        //
        // rate = 104 bytes
        // ========================================================

        run_boundary_plain_test(1, 103);
        run_boundary_plain_test(2, 104);
        run_boundary_plain_test(3, 105);

        // ========================================================
        // REG SALT
        //
        // salt_debug_en = 1
        // ========================================================

        run_reg_salt_prepend_test(4);

        run_reg_salt_append_test(5);

        // ========================================================
        // OTP / external SALT
        //
        // salt_debug_en = 0
        // ========================================================

        run_otp_salt_prepend_test(6);

        run_otp_salt_append_test(7);

        // ========================================================
        // MASK
        // ========================================================

        run_mask_test(8);

        // ========================================================
        // SHA local salt_clr
        //
        // F4[0]
        //
        // ONLY CHECK:
        //
        // reg_salt -> 0
        // ========================================================

        run_salt_clr_test(9);

        // ========================================================
        // REPORT
        // ========================================================

        `uvm_info("SHA3_REPORT", $sformatf({ "\n==============================================", "\n mcu_sha_read_salt_test finished", "\n TOTAL = %0d", "\n PASS = %0d", "\n FAIL = %0d", "\n==============================================" }, pass_cnt + fail_cnt, pass_cnt, fail_cnt), UVM_NONE)

        if (fail_cnt != 0) begin

            `uvm_error("SHA3_REPORT", $sformatf("%0d testcase(s) failed", fail_cnt))

        end

        phase.drop_objection(this);

    endtask

    // ============================================================
    // TC0
    //
    // SHA3-384("abc")
    // ============================================================

    task automatic run_plain_abc_test(input int tc);

        reset_feature_setting();

        set_abc_message();

        copy_message_to_golden();

        sha3_384(golden_data, expected_digest);

        `uvm_info("SHA3_TEST", "TC0 PLAIN ABC START", UVM_LOW)

        configure_common_sha3();

        // Salt disabled
        configure_salt_source(1'b0, 1'b0, 1'b0, 32'h0);

        reset_sha3_state();

        set_mask_enable(1'b0);

        write_sha3_message(1'b0);

        wait_sha3_done();

        read_sha3_digest(actual_digest);

        compare_result(tc, "PLAIN_ABC");

    endtask

    // ============================================================
    // TC1 / TC2 / TC3
    //
    // 103 / 104 / 105 bytes
    // ============================================================

    task automatic run_boundary_plain_test(input int tc, input int unsigned len);

        reset_feature_setting();

        sha_data = new[len];

        // --------------------------------------------------------
        // 固定 pattern，避免 random 讓 debug 變困難
        //
        // 00 01 02 03 ...
        //
        // Deterministic pattern for reproducible debugging
        // --------------------------------------------------------

        foreach (sha_data[i]) begin

            sha_data[i] = byte'(i & 8'hFF);

        end

        prepare_message_length();

        copy_message_to_golden();

        sha3_384(golden_data, expected_digest);

        `uvm_info("SHA3_TEST", $sformatf("TC%0d RATE BOUNDARY len=%0d START", tc, len), UVM_LOW)

        configure_common_sha3();

        configure_salt_source(1'b0, 1'b0, 1'b0, 32'h0);

        reset_sha3_state();

        set_mask_enable(1'b0);

        write_sha3_message(1'b0);

        wait_sha3_done();

        read_sha3_digest(actual_digest);

        compare_result(tc, $sformatf("RATE_%0d", len));

    endtask

    // ============================================================
    // TC4
    //
    // REG SALT || MESSAGE
    //
    // salt_debug_en = 1
    //
    // reg_salt = 0x12345678
    //
    // RTL byte stream:
    //
    // 78 56 34 12
    //
    // Golden:
    //
    // 78 56 34 12 61 62 63
    // ============================================================

    task automatic run_reg_salt_prepend_test(input int tc);

        bit [31:0] reg_salt_value;

        reset_feature_setting();

        set_abc_message();

        reg_salt_value = 32'h1234_5678;

        build_reg_salt_golden(sha_data, reg_salt_value, 1'b0, golden_data);

        sha3_384(golden_data, expected_digest);

        `uvm_info("SHA3_TEST", "TC4 REG SALT || MESSAGE START", UVM_LOW)

        configure_common_sha3();

        configure_salt_source(1'b1, 1'b1, 1'b0, reg_salt_value);

        reset_sha3_state();

        set_mask_enable(1'b0);

        write_sha3_message(1'b0);

        wait_sha3_done();

        read_sha3_digest(actual_digest);

        compare_result(tc, "REG_SALT_PREPEND");

    endtask

    // ============================================================
    // TC5
    //
    // MESSAGE || REG SALT
    // ============================================================

    task automatic run_reg_salt_append_test(input int tc);

        bit [31:0] reg_salt_value;

        reset_feature_setting();

        set_abc_message();

        reg_salt_value = 32'h1234_5678;

        build_reg_salt_golden(sha_data, reg_salt_value, 1'b1, golden_data);

        sha3_384(golden_data, expected_digest);

        `uvm_info("SHA3_TEST", "TC5 MESSAGE || REG SALT START", UVM_LOW)

        configure_common_sha3();

        configure_salt_source(1'b1, 1'b1, 1'b1, reg_salt_value);

        reset_sha3_state();

        set_mask_enable(1'b0);

        write_sha3_message(1'b0);

        wait_sha3_done();

        read_sha3_digest(actual_digest);

        compare_result(tc, "REG_SALT_APPEND");

    endtask

    // ============================================================
    // TC6
    //
    // OTP / external SALT || MESSAGE
    //
    // salt_debug_en = 0
    //
    // RTL external salt byte stream:
    //
    // cnt0 -> salt[31:24]
    // cnt1 -> salt[23:16]
    // cnt2 -> salt[15:8]
    // cnt3 -> salt[7:0]
    //
    // 所以 external salt 是 MSB first
    //
    // External salt is MSB first
    // ============================================================

    task automatic run_otp_salt_prepend_test(input int tc);

        bit [31:0] otp_salt_value;

        reset_feature_setting();

        set_abc_message();

        // --------------------------------------------------------
        // 直接取得 DUT 當下真的收到的 external SALT
        //
        // Read the actual external SALT entering the DUT
        // --------------------------------------------------------

        otp_salt_value = get_external_otp_salt();

        `uvm_info("OTP_SALT", $sformatf("TC%0d external OTP SALT = %08h", tc, otp_salt_value), UVM_LOW)

        build_external_salt_golden(sha_data, otp_salt_value, 1'b0, golden_data);

        sha3_384(golden_data, expected_digest);

        configure_common_sha3();

        configure_salt_source(1'b1, 1'b0, 1'b0, 32'h0);

        reset_sha3_state();

        set_mask_enable(1'b0);

        write_sha3_message(1'b0);

        wait_sha3_done();

        read_sha3_digest(actual_digest);

        compare_result(tc, "OTP_SALT_PREPEND");

    endtask

    // ============================================================
    // TC7
    //
    // MESSAGE || OTP / external SALT
    // ============================================================

    task automatic run_otp_salt_append_test(input int tc);

        bit [31:0] otp_salt_value;

        reset_feature_setting();

        set_abc_message();

        otp_salt_value = get_external_otp_salt();

        `uvm_info("OTP_SALT", $sformatf("TC%0d external OTP SALT = %08h", tc, otp_salt_value), UVM_LOW)

        build_external_salt_golden(sha_data, otp_salt_value, 1'b1, golden_data);

        sha3_384(golden_data, expected_digest);

        configure_common_sha3();

        configure_salt_source(1'b1, 1'b0, 1'b1, 32'h0);

        reset_sha3_state();

        set_mask_enable(1'b0);

        write_sha3_message(1'b0);

        wait_sha3_done();

        read_sha3_digest(actual_digest);

        compare_result(tc, "OTP_SALT_APPEND");

    endtask

    // ============================================================
    // TC8
    //
    // MASK
    //
    // Original:
    //
    // 00 01 02 03 04 05 06 07
    // 08 09 0A 0B 0C 0D 0E 0F
    //
    // Replace byte 4~7 with:
    //
    // AA BB CC DD
    // ============================================================

    task automatic run_mask_test(input int tc);

        reset_feature_setting();

        sha_data = new[16];

        foreach (sha_data[i]) begin

            sha_data[i] = byte'(i);

        end

        prepare_message_length();

        mask_data = new[4];

        mask_data[0] = 8'hAA;
        mask_data[1] = 8'hBB;
        mask_data[2] = 8'hCC;
        mask_data[3] = 8'hDD;

        mask_en = 1'b1;

        mask_start_byte = 4;

        start_mask_rcnt = mask_start_byte * 8;

        build_mask_golden(sha_data, mask_start_byte, mask_data, golden_data);

        sha3_384(golden_data, expected_digest);

        `uvm_info("SHA3_TEST", "TC8 MASK START", UVM_LOW)

        configure_common_sha3();

        configure_salt_source(1'b0, 1'b0, 1'b0, 32'h0);

        reset_sha3_state();

        configure_mask(start_mask_rcnt, mask_data);

        set_mask_enable(1'b1);

        write_sha3_message(1'b1);

        wait_sha3_done();

        read_sha3_digest(actual_digest);

        compare_result(tc, "MASK_REPLACE");

    endtask

    // ============================================================
    // TC9
    //
    // SHA local salt_clr
    //
    // ONLY TEST:
    //
    // write non-zero reg_salt
    //
    //        ↓
    //
    // write F4[0] = 1
    //
    //        ↓
    //
    // reg_salt == 0
    //
    // 不驗 Boot-ROM CLEAR_SALT
    // 不驗 external SALT
    // 不比較 SHA digest
    //
    // Do not verify Boot-ROM CLEAR_SALT,
    // external SALT, or SHA digest here.
    // ============================================================

    task automatic run_salt_clr_test(input int tc);

        bit [31:0] rdata;

        bit [31:0] test_salt;

        test_salt = 32'h1234_5678;

        `uvm_info("SALT_CLR", "TC9 SHA local salt_clr START", UVM_LOW)

        // --------------------------------------------------------
        // STEP 1
        //
        // preload non-zero reg_salt
        // --------------------------------------------------------

        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hF8, test_salt);

        // --------------------------------------------------------
        // STEP 2
        //
        // verify preload
        // --------------------------------------------------------

        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hF8, rdata);

        if (rdata !== test_salt) begin

            `uvm_fatal("SALT_CLR_PRELOAD", $sformatf("reg_salt preload failed exp=%08h got=%08h", test_salt, rdata))

        end

        // --------------------------------------------------------
        // STEP 3
        //
        // F4[0] = salt_clr
        //
        // RTL 已經確認是 write pulse
        //
        // RTL confirms that salt_clr is a write pulse
        // --------------------------------------------------------

        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hF4, 32'h0000_0001);

        // --------------------------------------------------------
        // STEP 4
        //
        // 給 core 一點 clock 讓 clear 生效
        //
        // Give the core enough clocks for the clear to take effect
        // --------------------------------------------------------

        #100ns;

        // --------------------------------------------------------
        // STEP 5
        //
        // read reg_salt again
        // --------------------------------------------------------

        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hF8, rdata);

        if (rdata === 32'h0000_0000) begin

            pass_cnt++;

            `uvm_info("SALT_CLR_PASS", $sformatf("TC=%0d PASS reg_salt=%08h", tc, rdata), UVM_LOW)

        end
        else begin

            fail_cnt++;

            `uvm_error("SALT_CLR_FAIL", $sformatf({ "TC=%0d FAIL ", "after F4[0] salt_clr, ", "reg_salt=%08h ", "expected=00000000" }, tc, rdata))

        end

    endtask

    // ============================================================
    // External OTP SALT
    //
    // 這是整隻 test 唯一需要依照你實際 hierarchy
    // 調整的地方。
    //
    // This is the only place that may need hierarchy adjustment.
    //
    // 從你的 RTL：
    //
    // security_top u_crypto_top (
    //     ...
    //     .salt(SALT),
    //     ...
    // );
    //
    // ============================================================

    function automatic bit [31:0] get_external_otp_salt();

        bit [31:0] value;

        value = system.i_NT71801.i01_grp_tcon.i1_apr_top.SALT;

        return value;

    endfunction

    // ============================================================
    // Common SHA3 configuration
    //
    // D8[1:0]:
    //
    // 10 = SHA3-384
    //
    // EC[1:0]:
    //
    // reg_block_wr_num
    //
    // bytes/write = block_wr_num + 1
    // ============================================================

    task automatic configure_common_sha3();

        bit [31:0] rdata;

        // --------------------------------------------------------
        // SHA3-384 mode
        // --------------------------------------------------------

        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hD8, 32'h0000_0002);

        // --------------------------------------------------------
        // Message bytes / write
        // --------------------------------------------------------

        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hEC, {30'h0, block_wr_num});

        // --------------------------------------------------------
        // Verify SHA mode
        // --------------------------------------------------------

        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hD8, rdata);

        if (rdata[1:0] !== 2'b10) begin

            `uvm_fatal("SHA3_MODE_CFG", $sformatf("SHA3-384 mode mismatch read=%08h", rdata))

        end

        // --------------------------------------------------------
        // Verify block_wr_num
        // --------------------------------------------------------

        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hEC, rdata);

        `uvm_info("SHA3_BLOCK_WR_CHECK", $sformatf({ "SW=%0d ", "HW=%0d ", "EC=%08h" }, block_wr_num, rdata[1:0], rdata), UVM_LOW)

        if (rdata[1:0] !== block_wr_num) begin

            `uvm_fatal("SHA3_BLOCK_WR_CFG_ERROR", $sformatf({ "block_wr_num mismatch ", "SW=%0d HW=%0d EC=%08h" }, block_wr_num, rdata[1:0], rdata))

        end

    endtask

    // ============================================================
    // SHA reset
    //
    // FC[6] reset_hash
    // FC[4] reset_block_tmp
    //
    // RTL 已確認都是 write pulse
    //
    // Both are write pulses according to RTL
    // ============================================================

    task automatic reset_sha3_state();

        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hFC, 32'h0000_0050);

    endtask

    // ============================================================
    // Configure SALT source
    //
    // F0:
    //
    // bit[2] = salt_mode
    //
    //     0 = salt || message
    //     1 = message || salt
    //
    // bit[1] = salt_debug_en
    //
    //     0 = external OTP SALT
    //     1 = reg_salt
    //
    // bit[0] = salt_en
    // ============================================================

    task automatic configure_salt_source(input bit en, input bit debug_en, input bit mode, input bit [31:0] debug_salt);

        bit [31:0] ctrl;
        bit [31:0] rdata;

        // --------------------------------------------------------
        // REG source 時才需要寫 reg_salt
        //
        // Program reg_salt only for the debug source
        // --------------------------------------------------------

        if (debug_en) begin

            mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hF8, debug_salt);

            mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hF8, rdata);

            if (rdata !== debug_salt) begin

                `uvm_fatal("REG_SALT_CFG", $sformatf({ "reg_salt write/read mismatch ", "exp=%08h got=%08h" }, debug_salt, rdata))

            end

        end

        ctrl = 32'h0000_0000;

        ctrl[2] = mode;
        ctrl[1] = debug_en;
        ctrl[0] = en;

        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hF0, ctrl);

        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hF0, rdata);

        if (rdata[2:0] !== ctrl[2:0]) begin

            `uvm_fatal("SALT_CTRL_CFG", $sformatf({ "salt control mismatch ", "exp=%03b got=%03b" }, ctrl[2:0], rdata[2:0]))

        end

        `uvm_info("SALT_SOURCE", $sformatf({ "salt_en=%0b ", "salt_debug_en=%0b ", "salt_mode=%0b ", "source=%s" }, en, debug_en, mode, debug_en ? "REG_SALT" : "OTP_EXTERNAL"), UVM_LOW)

    endtask

    // ============================================================
    // Message write
    // ============================================================

    task automatic write_sha3_message(input bit mask_enable);

        int idx;
        int bytes_per_write;

        bit [31:0] pwdata;
        bit [31:0] access_ctrl;
        bit [31:0] final_ctrl;
        bit [31:0] ec_rdata;

        // --------------------------------------------------------
        // 再檢查一次 block_wr_num
        //
        // Recheck block_wr_num immediately before data write
        // --------------------------------------------------------

        mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hEC, ec_rdata);

        `uvm_info("SHA3_BEFORE_DATA_WRITE", $sformatf({ "SW block_wr_num=%0d ", "HW block_wr_num=%0d ", "EC=%08h" }, block_wr_num, ec_rdata[1:0], ec_rdata), UVM_LOW)

        if (ec_rdata[1:0] !== block_wr_num) begin

            `uvm_fatal("SHA3_BLOCK_WR_CHANGED", $sformatf({ "block_wr_num changed ", "SW=%0d HW=%0d" }, block_wr_num, ec_rdata[1:0]))

        end

        idx = 0;

        bytes_per_write = int'(block_wr_num) + 1;

        // --------------------------------------------------------
        // FC[2] = MCU access
        // FC[7] = mask enable
        // --------------------------------------------------------

        access_ctrl = 32'h0000_0004;

        if (mask_enable)
            access_ctrl[7] = 1'b1;

        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hFC, access_ctrl);

        // --------------------------------------------------------
        // Write message to D4
        // --------------------------------------------------------

        while (idx < sha_data.size()) begin

            pwdata = 32'h0000_0000;

            for (int b = 0; b < bytes_per_write; b++) begin

                if ((idx + b) < sha_data.size()) begin

                    pwdata[b*8 +: 8] = sha_data[idx+b];

                end

            end

            `uvm_info("SHA3_DATA_WRITE", $sformatf({ "idx=%0d ", "bytes_per_write=%0d ", "block_wr_num=%0d ", "pwdata=%08h" }, idx, bytes_per_write, block_wr_num, pwdata), UVM_HIGH)

            mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hD4, pwdata);

            idx += bytes_per_write;

        end

        // --------------------------------------------------------
        // FC[3] = final_trigger
        // --------------------------------------------------------

        final_ctrl = 32'h0000_0008;

        if (mask_enable)
            final_ctrl[7] = 1'b1;

        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hFC, final_ctrl);

    endtask

    // ============================================================
    // Wait SHA done
    //
    // FC[5] = digest_valid
    // ============================================================

    task automatic wait_sha3_done();

        bit [31:0] rdata;

        int unsigned retry;

        retry = 0;

        while (retry < SHA3_MAX_RETRY) begin

            mcu_word_rd(m_host_top_cfg.sha384_page_addr_1, 8'hFC, rdata);

            if (rdata[5] === 1'b1) begin

                `uvm_info("WAIT_SHA3_DONE", $sformatf({ "SHA3 DONE ", "retry=%0d FC=%08h" }, retry, rdata), UVM_LOW)

                return;

            end

            retry++;

            #100ns;

        end

        `uvm_fatal("SHA3_TIMEOUT", $sformatf({ "digest_valid timeout ", "FC=%08h retry=%0d" }, rdata, retry))

    endtask

    // ============================================================
    // Read SHA3-384 digest
    //
    // SHA3-384 = digest[511:128]
    // ============================================================

    task automatic read_sha3_digest(output bit [383:0] digest);

        bit [511:0] full_digest;

        full_digest = system .i_NT71801 .i01_grp_tcon .i1_apr_top .u_crypto_top .i_sha3_top .digest[511:0];

        digest = full_digest[511 -: 384];

        `uvm_info("SHA3_DIGEST", $sformatf("actual=%096h", digest), UVM_LOW)

    endtask

    // ============================================================
    // Mask enable
    // ============================================================

    task automatic set_mask_enable(input bit en);

        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hFC, en ? 32'h0000_0080 : 32'h0000_0000);

    endtask

    // ============================================================
    // Configure MASK
    // ============================================================

    task automatic configure_mask(input bit [63:0] start_rcnt, input byte unsigned mask[]);

        bit [31:0] wdata;

        int idx;

        idx = 0;

        while (idx < mask.size()) begin

            wdata = 32'h0;

            for (int b = 0; b < 4; b++) begin

                if ((idx+b) < mask.size()) begin

                    wdata[b*8 +: 8]
                        = mask[idx+b];

                end

            end

            mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, byte'(idx), wdata);

            idx += 4;

        end

        // start_mask_len
        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'h90, mask.size());

        // start_mask_rcnt[31:0]
        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hE0, start_rcnt[31:0]);

        // start_mask_rcnt[63:32]
        mcu_word_wr(m_host_top_cfg.sha384_page_addr_1, 8'hE4, start_rcnt[63:32]);

    endtask

    // ============================================================
    // ABC message
    // ============================================================

    task automatic set_abc_message();

        sha_data = new[3];

        sha_data[0] = 8'h61;
        sha_data[1] = 8'h62;
        sha_data[2] = 8'h63;

        prepare_message_length();

    endtask

    // ============================================================
    // Length / block_wr_num
    // ============================================================

    task automatic prepare_message_length();

        sha_data_len_byte = sha_data.size();

        sha_data_len_bit = sha_data_len_byte * 8;

        block_wr_num = calc_block_wr_num(sha_data_len_byte);

        `uvm_info("SHA3_LENGTH", $sformatf({ "len_byte=%0d ", "len_bit=%0d ", "block_wr_num=%0d ", "bytes_per_write=%0d" }, sha_data_len_byte, sha_data_len_bit, block_wr_num, block_wr_num + 1), UVM_LOW)

    endtask

    // ============================================================
    // Legacy Python rule
    //
    // divisible by 4 -> 4 bytes/write -> 3
    // divisible by 3 -> 3 bytes/write -> 2
    // divisible by 2 -> 2 bytes/write -> 1
    // otherwise      -> 1 byte/write  -> 0
    // ============================================================

    function automatic bit [1:0]
        calc_block_wr_num(input int unsigned len_byte);

        if ((len_byte % 4) == 0) return 2'd3;

        else if ((len_byte % 3) == 0) return 2'd2;

        else if ((len_byte % 2) == 0) return 2'd1;

        else
            return 2'd0;

    endfunction

    // ============================================================
    // Reset local state
    // ============================================================

    task automatic reset_feature_setting();

        salt_en       = 1'b0;
        salt_mode     = 1'b0;
        salt_debug_en = 1'b0;

        salt_value = 32'h0;

        mask_en = 1'b0;

        mask_start_byte = 0;

        start_mask_rcnt = 64'h0;

        golden_data = new[0];

        mask_data = new[0];

    endtask

    // ============================================================
    // Plain golden
    // ============================================================

    task automatic copy_message_to_golden();

        golden_data = new[sha_data.size()];

        foreach (sha_data[i]) begin

            golden_data[i] = sha_data[i];

        end

    endtask

    // ============================================================
    // REG SALT golden
    //
    // RTL:
    //
    // cnt0 = reg_salt[7:0]
    // cnt1 = reg_salt[15:8]
    // cnt2 = reg_salt[23:16]
    // cnt3 = reg_salt[31:24]
    //
    // 0x12345678 -> 78 56 34 12
    // ============================================================

    task automatic build_reg_salt_golden(input byte unsigned msg[], input bit [31:0] salt, input bit mode, output byte unsigned result[]);

        byte unsigned sb[0:3];

        sb[0] = salt[7:0];
        sb[1] = salt[15:8];
        sb[2] = salt[23:16];
        sb[3] = salt[31:24];

        result = new[msg.size()+4];

        if (mode == 1'b0) begin

            // salt || message

            for (int i = 0; i < 4; i++)
                result[i] = sb[i];

            foreach (msg[i])
                result[i+4] = msg[i];

        end
        else begin

            // message || salt

            foreach (msg[i])
                result[i] = msg[i];

            for (int i = 0; i < 4; i++)
                result[msg.size()+i] = sb[i];

        end

    endtask

    // ============================================================
    // External OTP SALT golden
    //
    // RTL:
    //
    // cnt0 = salt[31:24]
    // cnt1 = salt[23:16]
    // cnt2 = salt[15:8]
    // cnt3 = salt[7:0]
    //
    // 0x12345678 -> 12 34 56 78
    // ============================================================

    task automatic build_external_salt_golden(input byte unsigned msg[], input bit [31:0] salt, input bit mode, output byte unsigned result[]);

        byte unsigned sb[0:3];

        sb[0] = salt[31:24];
        sb[1] = salt[23:16];
        sb[2] = salt[15:8];
        sb[3] = salt[7:0];

        result = new[msg.size()+4];

        if (mode == 1'b0) begin

            // salt || message

            for (int i = 0; i < 4; i++)
                result[i] = sb[i];

            foreach (msg[i])
                result[i+4] = msg[i];

        end
        else begin

            // message || salt

            foreach (msg[i])
                result[i] = msg[i];

            for (int i = 0; i < 4; i++)
                result[msg.size()+i] = sb[i];

        end

    endtask

    // ============================================================
    // Mask golden
    // ============================================================

    task automatic build_mask_golden(input byte unsigned msg[], input int unsigned start_byte, input byte unsigned mask[], output byte unsigned result[]);

        result = new[msg.size()];

        foreach (msg[i])
            result[i] = msg[i];

        for (int i = 0; i < mask.size(); i++) begin

            if ((start_byte+i) < result.size()) begin

                result[start_byte+i] = mask[i];

            end

        end

    endtask

    // ============================================================
    // Compare
    // ============================================================

    task automatic compare_result(input int tc, input string test_name);

        if (actual_digest !== expected_digest) begin

            fail_cnt++;

            `uvm_error("SHA3_MISMATCH", $sformatf({ "\n==============================================", "\nTC = %0d", "\nTEST = %s", "\nLEN_BYTE = %0d", "\nBLOCK_WR_NUM = %0d", "\nEXPECTED = %096h", "\nACTUAL = %096h", "\n==============================================" }, tc, test_name, sha_data_len_byte, block_wr_num, expected_digest, actual_digest))

        end
        else begin

            pass_cnt++;

            `uvm_info("SHA3_PASS", $sformatf("TC=%0d %-24s PASS digest=%096h", tc, test_name, actual_digest), UVM_LOW)

        end

    endtask

    // ============================================================
    // ROTL64
    // ============================================================

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
    // SHA3 reference model SELF TEST
    //
    // These constants were independently checked against
    // Python hashlib.sha3_384().
    // ============================================================

    task automatic sha3_384_self_test();

        byte unsigned msg[];
        byte unsigned tmp[];

        bit [383:0] result;

        // ========================================================
        // TEST 1
        //
        // SHA3-384("abc")
        // ========================================================

        msg = new[3];

        msg[0] = 8'h61;
        msg[1] = 8'h62;
        msg[2] = 8'h63;

        sha3_384(msg, result);

        if (result !== 384'hec01498288516fc926459f58e2c6ad8df9b473cb0fc08c2596da7cf0e49be4b298d88cea927ac7f539f1edf228376d25) begin

            `uvm_fatal("SHA3_REF", $sformatf("abc self-test FAIL result=%096h", result))

        end

        // ========================================================
        // TEST 2
        //
        // REG SALT || abc
        //
        // 78 56 34 12 61 62 63
        // ========================================================

        build_reg_salt_golden(msg, 32'h1234_5678, 1'b0, tmp);

        sha3_384(tmp, result);

        if (result !== 384'h25e17559803f2bf31fcc9ead4c6928247d5abdf16c7c3f83d427d94c9d64c5dbcdf698db133450268210316799e92015) begin

            `uvm_fatal("SHA3_REF", $sformatf("REG salt||abc self-test FAIL result=%096h", result))

        end

        // ========================================================
        // TEST 3
        //
        // abc || REG SALT
        //
        // 61 62 63 78 56 34 12
        // ========================================================

        build_reg_salt_golden(msg, 32'h1234_5678, 1'b1, tmp);

        sha3_384(tmp, result);

        if (result !== 384'hc96982a5ae5ad078286cd6b3a0245efe5291a8fdf46a8a76fdb59d1107d40548787a845b9922f26c252a2f1185ed46f0) begin

            `uvm_fatal("SHA3_REF", $sformatf("abc||REG salt self-test FAIL result=%096h", result))

        end

        // ========================================================
        // TEST 4
        //
        // EXTERNAL SALT || abc
        //
        // external salt = 0x12345678
        //
        // byte stream:
        //
        // 12 34 56 78 61 62 63
        // ========================================================

        build_external_salt_golden(msg, 32'h1234_5678, 1'b0, tmp);

        sha3_384(tmp, result);

        if (result !== 384'he775a3059e62e9735d0a637746122f3a5d99b695b393fe7d7aefacecaa6afd802f9b7680c15ea24abf20ee27b29a6031) begin

            `uvm_fatal("SHA3_REF", $sformatf("OTP salt||abc self-test FAIL result=%096h", result))

        end

        // ========================================================
        // TEST 5
        //
        // abc || EXTERNAL SALT
        //
        // 61 62 63 12 34 56 78
        // ========================================================

        build_external_salt_golden(msg, 32'h1234_5678, 1'b1, tmp);

        sha3_384(tmp, result);

        if (result !== 384'hb7aebd6bd8a0731cced678d470564b2036d6eec65b389716ab7ea4b5edbd2d95518705d490ddf5a29948030c5843721f) begin

            `uvm_fatal("SHA3_REF", $sformatf("abc||OTP salt self-test FAIL result=%096h", result))

        end

        `uvm_info("SHA3_REF", { "SHA3-384 reference self-test PASS: ", "abc / REG prepend / REG append / ", "OTP prepend / OTP append" }, UVM_LOW)

    endtask

endclass
