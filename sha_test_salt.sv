class mcu_sha_read_salt_test extends host_base_test;

    `uvm_component_utils(mcu_sha_read_salt_test)


    // ============================================================
    // SHA3-384 固定參數
    // SHA3-384 fixed parameters
    // ============================================================

    localparam int SHA3_RATE_BYTES   = 104;
    localparam int SHA3_DIGEST_BYTES = 48;


    // ============================================================
    // Test data
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

    bit mask_en;

    int unsigned mask_start_byte;

    bit [63:0] start_mask_rcnt;


    // ============================================================
    // Digest
    // ============================================================

    bit [383:0] expected_digest;
    bit [383:0] actual_digest;


    // ============================================================
    // Statistics
    // ============================================================

    int unsigned pass_cnt;
    int unsigned fail_cnt;



    // ============================================================
    // Constructor
    // ============================================================

    function new(
        string name = "mcu_sha_read_salt_test",
        uvm_component parent = null
    );

        super.new(name, parent);

    endfunction



    // ============================================================
    // Main run phase
    // ============================================================

    task run_phase(uvm_phase phase);

        super.run_phase(phase);

        phase.raise_objection(this);

        pass_cnt = 0;
        fail_cnt = 0;


        // --------------------------------------------------------
        // 原本 MCU / Host 初始化。
        // Perform the original MCU/Host initialization.
        // --------------------------------------------------------

        mcu_test_preset();


        // --------------------------------------------------------
        // 先確認 SV golden model 本身。
        // Verify the SV golden model before checking the DUT.
        // --------------------------------------------------------

        sha3_384_self_test();


        // ========================================================
        // TC0：最基本 SHA3-384("abc")
        // ========================================================

        run_plain_abc_test(0);


        // ========================================================
        // TC1~TC3：VPlan 154
        //
        // rate = 104 bytes
        //
        // nearly multiple of rate:
        //     103
        //     104
        //     105
        // ========================================================

        run_boundary_plain_test(1, 103);
        run_boundary_plain_test(2, 104);
        run_boundary_plain_test(3, 105);


        // ========================================================
        // TC4：salt + message
        // ========================================================

        run_salt_prepend_test(4);


        // ========================================================
        // TC5：message + salt
        // ========================================================

        run_salt_append_test(5);


        // ========================================================
        // TC6：Mask replacement
        // ========================================================

        run_mask_test(6);


        // ========================================================
        // TC7：VPlan 155/156 case #1
        //
        // CLEAR_SALT = 0
        //
        // SHA HW 應該可以使用 salt。
        // SHA HW should be able to access/use salt.
        // ========================================================

        run_clear_salt_0_test(7);


        // ========================================================
        // TC8：VPlan 155/156 case #2
        //
        // CLEAR_SALT = 1
        //
        // 1. salt value 必須被清掉
        // 2. SHA HW 不可以再使用原 salt
        // ========================================================

        run_clear_salt_1_test(8);


        // ========================================================
        // Summary
        // ========================================================

        `uvm_info(
            "SHA3_REPORT",
            $sformatf(
                {
                    "\n==========================================",
                    "\n mcu_sha_read_salt_test finished",
                    "\n TOTAL = %0d",
                    "\n PASS  = %0d",
                    "\n FAIL  = %0d",
                    "\n=========================================="
                },
                pass_cnt + fail_cnt,
                pass_cnt,
                fail_cnt
            ),
            UVM_NONE
        )


        if (fail_cnt != 0) begin

            `uvm_error(
                "SHA3_REPORT",
                $sformatf(
                    "%0d testcase(s) failed",
                    fail_cnt
                )
            )

        end


        phase.drop_objection(this);

    endtask



    // ============================================================
    // TC0
    //
    // Plain SHA3-384("abc")
    // ============================================================

    task automatic run_plain_abc_test(input int tc);

        reset_feature_setting();


        sha_data = new[3];

        sha_data[0] = 8'h61; // a
        sha_data[1] = 8'h62; // b
        sha_data[2] = 8'h63; // c


        prepare_message_length();

        copy_message_to_golden();


        sha3_384(
            golden_data,
            expected_digest
        );


        configure_common_sha3();

        configure_salt(
            1'b0,
            1'b0,
            32'h0000_0000
        );

        reset_sha3_state();

        set_mask_enable(1'b0);


        write_sha3_message(1'b0);

        wait_sha3_done();

        read_sha3_digest(actual_digest);

        compare_result(
            tc,
            "PLAIN_ABC"
        );

    endtask



    // ============================================================
    // VPlan 154
    //
    // Test lengths near SHA3-384 rate boundary.
    // ============================================================

    task automatic run_boundary_plain_test(
        input int tc,
        input int unsigned len
    );

        reset_feature_setting();


        sha_data = new[len];


        // --------------------------------------------------------
        // 使用 deterministic pattern，不用 random。
        //
        // 這樣 mismatch 時可以完全重現。
        // Use deterministic data so every failure is reproducible.
        // --------------------------------------------------------

        foreach (sha_data[i]) begin

            sha_data[i] =
                byte'(i & 8'hFF);

        end


        prepare_message_length();

        copy_message_to_golden();


        sha3_384(
            golden_data,
            expected_digest
        );


        configure_common_sha3();

        configure_salt(
            1'b0,
            1'b0,
            32'h0
        );

        reset_sha3_state();

        set_mask_enable(1'b0);


        write_sha3_message(1'b0);

        wait_sha3_done();

        read_sha3_digest(actual_digest);


        compare_result(
            tc,
            $sformatf(
                "RATE_BOUNDARY_%0d",
                len
            )
        );

    endtask



    // ============================================================
    // salt + message
    //
    // F0[2] salt_mode = 0
    // ============================================================

    task automatic run_salt_prepend_test(
        input int tc
    );

        reset_feature_setting();


        set_abc_message();


        salt_en       = 1'b1;
        salt_mode     = 1'b0;
        salt_debug_en = 1'b1;

        salt_value =
            32'h1234_5678;


        build_salt_golden(
            sha_data,
            salt_value,
            salt_mode,
            golden_data
        );


        sha3_384(
            golden_data,
            expected_digest
        );


        configure_common_sha3();


        configure_salt(
            salt_en,
            salt_mode,
            salt_value
        );


        // --------------------------------------------------------
        // Prefix salt 的 RTL 可能在 reset_hash 時 preload salt，
        // 因此 salt 設定要先完成再 reset hash。
        // Configure salt before reset_hash for prepend operation.
        // --------------------------------------------------------

        reset_sha3_state();

        set_mask_enable(1'b0);


        write_sha3_message(1'b0);

        wait_sha3_done();

        read_sha3_digest(actual_digest);


        compare_result(
            tc,
            "SALT_PREPEND"
        );

    endtask



    // ============================================================
    // message + salt
    //
    // F0[2] salt_mode = 1
    // ============================================================

    task automatic run_salt_append_test(
        input int tc
    );

        reset_feature_setting();


        set_abc_message();


        salt_en       = 1'b1;
        salt_mode     = 1'b1;
        salt_debug_en = 1'b1;

        salt_value =
            32'h1234_5678;


        build_salt_golden(
            sha_data,
            salt_value,
            salt_mode,
            golden_data
        );


        sha3_384(
            golden_data,
            expected_digest
        );


        configure_common_sha3();


        configure_salt(
            salt_en,
            salt_mode,
            salt_value
        );


        reset_sha3_state();

        set_mask_enable(1'b0);


        write_sha3_message(1'b0);

        wait_sha3_done();

        read_sha3_digest(actual_digest);


        compare_result(
            tc,
            "SALT_APPEND"
        );

    endtask



    // ============================================================
    // Mask replacement
    // ============================================================

    task automatic run_mask_test(
        input int tc
    );

        reset_feature_setting();


        sha_data = new[16];


        foreach (sha_data[i]) begin

            sha_data[i] =
                byte'(i);

        end


        prepare_message_length();


        // --------------------------------------------------------
        // 從 message byte 4 開始換成：
        //
        // AA BB CC DD
        // --------------------------------------------------------

        mask_data = new[4];

        mask_data[0] = 8'hAA;
        mask_data[1] = 8'hBB;
        mask_data[2] = 8'hCC;
        mask_data[3] = 8'hDD;


        mask_en = 1'b1;

        mask_start_byte = 4;


        // --------------------------------------------------------
        // start_mask_rcnt 的單位是 bit。
        // start_mask_rcnt is measured in bits.
        // --------------------------------------------------------

        start_mask_rcnt =
            mask_start_byte * 8;


        build_mask_golden(
            sha_data,
            mask_start_byte,
            mask_data,
            golden_data
        );


        sha3_384(
            golden_data,
            expected_digest
        );


        configure_common_sha3();

        configure_salt(
            1'b0,
            1'b0,
            32'h0
        );


        reset_sha3_state();


        configure_mask(
            start_mask_rcnt,
            mask_data
        );


        set_mask_enable(1'b1);


        write_sha3_message(1'b1);

        wait_sha3_done();

        read_sha3_digest(actual_digest);


        compare_result(
            tc,
            "MASK_REPLACE"
        );

    endtask



    // ============================================================
    // VPlan 155/156 - CLEAR_SALT = 0
    //
    // VPlan：
    //
    // Set CLEAR_SALT = 0:
    //
    // SHA HW can access salt.
    //
    // 驗證方式：
    //
    // 1. 寫入 known salt
    // 2. CLEAR_SALT=0
    // 3. SHA 執行 salt+msg
    // 4. DUT digest 必須等於 salted golden
    // ============================================================

    task automatic run_clear_salt_0_test(
        input int tc
    );

        reset_feature_setting();


        set_abc_message();


        salt_en       = 1'b1;
        salt_mode     = 1'b0;
        salt_debug_en = 1'b1;

        salt_value =
            32'h1234_5678;


        // --------------------------------------------------------
        // CLEAR_SALT = 0。
        // Set CLEAR_SALT to 0.
        // --------------------------------------------------------

        set_clear_salt(1'b0);


        // --------------------------------------------------------
        // Golden：
        //
        // 78 56 34 12 + abc
        // --------------------------------------------------------

        build_salt_golden(
            sha_data,
            salt_value,
            salt_mode,
            golden_data
        );


        sha3_384(
            golden_data,
            expected_digest
        );


        configure_common_sha3();


        configure_salt(
            1'b1,
            1'b0,
            salt_value
        );


        reset_sha3_state();

        set_mask_enable(1'b0);


        write_sha3_message(1'b0);

        wait_sha3_done();

        read_sha3_digest(actual_digest);


        compare_result(
            tc,
            "CLEAR_SALT_0_SHA_CAN_READ_SALT"
        );


        // --------------------------------------------------------
        // 清理 CLEAR_SALT state。
        // Restore CLEAR_SALT state.
        // --------------------------------------------------------

        set_clear_salt(1'b0);

    endtask



    // ============================================================
    // VPlan 155/156 - CLEAR_SALT = 1
    //
    // VPlan：
    //
    // Set CLEAR_SALT = 1:
    //
    // 1. clear salt value
    // 2. SHA HW can't access salt
    //
    //
    // 注意：
    //
    // 這裡分兩層驗證：
    //
    // A. Salt register value 確實被清除/阻擋。
    //
    // B. 原本的 known salt 不可以再影響 SHA digest。
    // ============================================================

    task automatic run_clear_salt_1_test(
        input int tc
    );

        bit [31:0] salt_readback;


        reset_feature_setting();


        set_abc_message();


        salt_en       = 1'b1;
        salt_mode     = 1'b0;
        salt_debug_en = 1'b1;

        salt_value =
            32'h1234_5678;


        // ========================================================
        // STEP 1
        //
        // 先寫 known salt。
        // Program a known salt value first.
        // ========================================================

        configure_salt(
            1'b1,
            1'b0,
            salt_value
        );


        // ========================================================
        // STEP 2
        //
        // CLEAR_SALT = 1。
        // ========================================================

        set_clear_salt(1'b1);


        // ========================================================
        // STEP 3
        //
        // 讀 F8~FB，確認 salt value 已清。
        //
        // 如果 CLEAR_SALT 的 security policy 是直接 block read，
        // 可能會得到 0，這同樣符合「cannot access」。
        // ========================================================

        mcu_word_rd(
            m_host_top_cfg.sha384_page_addr_1,
            8'hF8,
            salt_readback
        );


        if (
            salt_readback !==
            32'h0000_0000
        ) begin

            `uvm_error(
                "CLEAR_SALT",
                $sformatf(
                    {
                        "CLEAR_SALT=1 but salt is not cleared/blocked. ",
                        "readback=%08h"
                    },
                    salt_readback
                )
            )

        end
        else begin

            `uvm_info(
                "CLEAR_SALT",
                "CLEAR_SALT=1 salt readback is 0",
                UVM_LOW
            )

        end


        // ========================================================
        // STEP 4
        //
        // 這裡的 Golden 我故意用 plain "abc"。
        //
        // 原因是 VPlan 明確要求：
        //
        // "SHA HW can't access salt"
        //
        // 因此 SHA 不應該再使用原本 0x12345678 salt。
        //
        // 如果你之後 RTL 顯示 CLEAR_SALT=1 仍會 append/prepend
        // 4 bytes 的 00 00 00 00，
        // 那這裡要改成 zero-salt golden。
        //
        // 目前不能拿 0x12345678 當 golden。
        // ========================================================

        copy_message_to_golden();


        sha3_384(
            golden_data,
            expected_digest
        );


        configure_common_sha3();


        // --------------------------------------------------------
        // 保持 salt enable，
        // 故意確認 CLEAR_SALT 能阻止 SHA 使用 salt。
        // Keep salt enabled intentionally to test the access block.
        // --------------------------------------------------------

        configure_salt_ctrl_only(
            1'b1,
            1'b0
        );


        reset_sha3_state();

        set_mask_enable(1'b0);


        write_sha3_message(1'b0);

        wait_sha3_done();

        read_sha3_digest(actual_digest);


        compare_result(
            tc,
            "CLEAR_SALT_1_SHA_CANNOT_READ_SALT"
        );


        // --------------------------------------------------------
        // testcase 結束後解除 CLEAR_SALT。
        // Deassert CLEAR_SALT after the testcase.
        // --------------------------------------------------------

        set_clear_salt(1'b0);

    endtask



    // ============================================================
    // CLEAR_SALT adapter
    //
    // ★ 這是目前唯一缺少專案資訊的地方。
    //
    // VPlan 說它是 Boot Rom control，
    // 但目前你給我的 Excel 沒有它的 address/page/bit。
    //
    // 請不要把 SHA 0xF4 salt_clr 自動當成 CLEAR_SALT，
    // 除非 RTL / Boot-ROM register spec 明確證明兩者是同一個控制。
    //
    // 你把 CLEAR_SALT 的 register 那張圖給我，
    // 我就可以把這個 task 最後一行直接補死。
    // ============================================================

    task automatic set_clear_salt(
        input bit value
    );

        `uvm_info(
            "CLEAR_SALT",
            $sformatf(
                "Set Boot-ROM CLEAR_SALT = %0b",
                value
            ),
            UVM_LOW
        )


        // ========================================================
        // TODO_PROJECT_SPEC：
        //
        // 這裡換成真正 CLEAR_SALT control。
        //
        // 例如「假設」未來 spec 顯示：
        //
        // mcu_word_wr(
        //     boot_page,
        //     CLEAR_SALT_OFFSET,
        //     value
        // );
        //
        // 我目前不會亂填地址。
        // ========================================================

        `uvm_fatal(
            "CLEAR_SALT_ADDR_UNKNOWN",
            {
                "Boot-ROM CLEAR_SALT address/bit is not provided. ",
                "Please fill set_clear_salt() using the real project register."
            }
        )

    endtask



    // ============================================================
    // Helper：固定 abc
    // ============================================================

    task automatic set_abc_message();

        sha_data = new[3];

        sha_data[0] = 8'h61;
        sha_data[1] = 8'h62;
        sha_data[2] = 8'h63;

        prepare_message_length();

    endtask



    // ============================================================
    // Reset feature software state
    // ============================================================

    task automatic reset_feature_setting();

        salt_en       = 1'b0;
        salt_mode     = 1'b0;
        salt_debug_en = 1'b0;

        salt_value = 32'h0;


        mask_en = 1'b0;

        mask_start_byte = 0;

        start_mask_rcnt = 64'h0;


        mask_data   = new[0];
        golden_data = new[0];

    endtask



    // ============================================================
    // Prepare message size + write size
    // ============================================================

    task automatic prepare_message_length();

        sha_data_len_byte =
            sha_data.size();


        sha_data_len_bit =
            sha_data_len_byte * 8;


        block_wr_num =
            calc_block_wr_num(
                sha_data_len_byte
            );

    endtask



    // ============================================================
    // Plain golden input
    // ============================================================

    task automatic copy_message_to_golden();

        golden_data =
            new[sha_data.size()];


        foreach (sha_data[i]) begin

            golden_data[i] =
                sha_data[i];

        end

    endtask



    // ============================================================
    // block_wr_num
    //
    // EC[1:0]
    //
    // bytes/write = block_wr_num + 1
    // ============================================================

    function automatic bit [1:0]
        calc_block_wr_num(
            input int unsigned len_byte
        );


        if ((len_byte % 4) == 0)
            return 2'd3;

        else if ((len_byte % 3) == 0)
            return 2'd2;

        else if ((len_byte % 2) == 0)
            return 2'd1;

        else
            return 2'd0;

    endfunction



    // ============================================================
    // Common SHA3 config
    // ============================================================

    task automatic configure_common_sha3();


        // --------------------------------------------------------
        // D8[1:0] = 2'b10 => SHA3-384
        // --------------------------------------------------------

        mcu_word_wr(
            m_host_top_cfg.sha384_page_addr_1,
            8'hD8,
            32'h0000_0002
        );


        // --------------------------------------------------------
        // EC[1:0] = block_wr_num
        // --------------------------------------------------------

        mcu_word_wr(
            m_host_top_cfg.sha384_page_addr_1,
            8'hEC,
            {
                30'h0,
                block_wr_num
            }
        );

    endtask



    // ============================================================
    // SHA state reset
    //
    // FC[6] reset_hash
    // FC[4] reset_block_tmp
    // ============================================================

    task automatic reset_sha3_state();

        mcu_word_wr(
            m_host_top_cfg.sha384_page_addr_1,
            8'hFC,
            32'h0000_0050
        );


        mcu_word_wr(
            m_host_top_cfg.sha384_page_addr_1,
            8'hFC,
            32'h0000_0000
        );

    endtask



    // ============================================================
    // Salt configuration
    //
    // F8~FB = reg_salt
    //
    // F0:
    //
    // bit2 salt_mode
    // bit1 salt_debug_en
    // bit0 salt_en
    // ============================================================

    task automatic configure_salt(
        input bit en,
        input bit mode,
        input bit [31:0] salt
    );

        bit [31:0] ctrl;


        mcu_word_wr(
            m_host_top_cfg.sha384_page_addr_1,
            8'hF8,
            salt
        );


        ctrl = 32'h0;

        ctrl[2] = mode;

        // --------------------------------------------------------
        // 使用 reg_salt 做 deterministic verification，
        // 所以 en 時把 salt_debug_en 拉高。
        // --------------------------------------------------------

        ctrl[1] = en;

        ctrl[0] = en;


        mcu_word_wr(
            m_host_top_cfg.sha384_page_addr_1,
            8'hF0,
            ctrl
        );

    endtask



    // ============================================================
    // 只設定 Salt control，不重新寫 F8 salt。
    //
    // CLEAR_SALT=1 case 會用到，
    // 避免清掉之後又被 test 自己重新寫回去。
    // ============================================================

    task automatic configure_salt_ctrl_only(
        input bit en,
        input bit mode
    );

        bit [31:0] ctrl;


        ctrl = 32'h0;

        ctrl[2] = mode;
        ctrl[1] = en;
        ctrl[0] = en;


        mcu_word_wr(
            m_host_top_cfg.sha384_page_addr_1,
            8'hF0,
            ctrl
        );

    endtask



    // ============================================================
    // Build salt golden
    //
    // reg_salt = 32'h12345678
    //
    // effective byte stream:
    //
    // 78 56 34 12
    // ============================================================

    task automatic build_salt_golden(
        input  byte unsigned msg[],
        input  bit [31:0] salt,
        input  bit mode,
        output byte unsigned result[]
    );

        byte unsigned salt_byte[0:3];


        salt_byte[0] = salt[7:0];
        salt_byte[1] = salt[15:8];
        salt_byte[2] = salt[23:16];
        salt_byte[3] = salt[31:24];


        result =
            new[msg.size() + 4];


        // --------------------------------------------------------
        // mode = 0:
        //
        // salt + msg
        // --------------------------------------------------------

        if (mode == 1'b0) begin

            for (int i = 0; i < 4; i++) begin

                result[i] =
                    salt_byte[i];

            end


            foreach (msg[i]) begin

                result[i + 4] =
                    msg[i];

            end

        end


        // --------------------------------------------------------
        // mode = 1:
        //
        // msg + salt
        // --------------------------------------------------------

        else begin

            foreach (msg[i]) begin

                result[i] =
                    msg[i];

            end


            for (int i = 0; i < 4; i++) begin

                result[
                    msg.size() + i
                ] =
                    salt_byte[i];

            end

        end

    endtask



    // ============================================================
    // Mask configuration
    // ============================================================

    task automatic configure_mask(
        input bit [63:0] start_rcnt,
        input byte unsigned mask[]
    );

        bit [31:0] wdata;

        int idx;


        idx = 0;


        // --------------------------------------------------------
        // 0x00~0x8F = maskblock
        // --------------------------------------------------------

        while (idx < mask.size()) begin

            wdata = '0;


            for (
                int b = 0;
                b < 4;
                b++
            ) begin

                if ((idx + b) < mask.size()) begin

                    wdata[
                        b*8 +: 8
                    ] =
                        mask[
                            idx + b
                        ];

                end

            end


            mcu_word_wr(
                m_host_top_cfg.sha384_page_addr_1,
                byte'(idx),
                wdata
            );


            idx += 4;

        end


        // --------------------------------------------------------
        // 0x90：start_mask_len，單位 byte。
        // --------------------------------------------------------

        mcu_word_wr(
            m_host_top_cfg.sha384_page_addr_1,
            8'h90,
            mask.size()
        );


        // --------------------------------------------------------
        // E0~E7：start_mask_rcnt，單位 bit。
        // --------------------------------------------------------

        mcu_word_wr(
            m_host_top_cfg.sha384_page_addr_1,
            8'hE0,
            start_rcnt[31:0]
        );


        mcu_word_wr(
            m_host_top_cfg.sha384_page_addr_1,
            8'hE4,
            start_rcnt[63:32]
        );

    endtask



    // ============================================================
    // Mask golden = replacement
    // ============================================================

    task automatic build_mask_golden(
        input byte unsigned msg[],
        input int unsigned start_byte,
        input byte unsigned mask[],
        output byte unsigned result[]
    );


        result =
            new[msg.size()];


        foreach (msg[i]) begin

            result[i] =
                msg[i];

        end


        for (
            int i = 0;
            i < mask.size();
            i++
        ) begin

            if (
                (start_byte + i)
                <
                result.size()
            ) begin

                result[
                    start_byte + i
                ] =
                    mask[i];

            end

        end

    endtask



    // ============================================================
    // FC[7] = start_mask_en
    // ============================================================

    task automatic set_mask_enable(
        input bit en
    );


        mcu_word_wr(
            m_host_top_cfg.sha384_page_addr_1,
            8'hFC,
            en
                ?
            32'h0000_0080
                :
            32'h0000_0000
        );

    endtask



    // ============================================================
    // Message write
    //
    // D4~D7 = MCU access block data
    // ============================================================

    task automatic write_sha3_message(
        input bit mask_enable
    );

        int idx;

        int bytes_per_write;

        bit [31:0] pwdata;

        bit [31:0] access_ctrl;

        bit [31:0] final_ctrl;


        idx = 0;


        bytes_per_write =
            int'(block_wr_num) + 1;


        // --------------------------------------------------------
        // FC[2] MCU access enable。
        //
        // Mask 時 FC[7] 也必須維持為 1。
        // --------------------------------------------------------

        access_ctrl =
            32'h0000_0004;


        if (mask_enable)
            access_ctrl[7] = 1'b1;


        mcu_word_wr(
            m_host_top_cfg.sha384_page_addr_1,
            8'hFC,
            access_ctrl
        );


        while (
            idx < sha_data.size()
        ) begin


            pwdata =
                32'h0000_0000;


            for (
                int b = 0;
                b < bytes_per_write;
                b++
            ) begin

                if (
                    (idx + b)
                    <
                    sha_data.size()
                ) begin

                    pwdata[
                        b*8 +: 8
                    ] =
                        sha_data[
                            idx + b
                        ];

                end

            end


            mcu_word_wr(
                m_host_top_cfg.sha384_page_addr_1,
                8'hD4,
                pwdata
            );


            idx +=
                bytes_per_write;

        end


        // --------------------------------------------------------
        // FC[3] final_trigger。
        // --------------------------------------------------------

        final_ctrl =
            32'h0000_0008;


        if (mask_enable)
            final_ctrl[7] = 1'b1;


        mcu_word_wr(
            m_host_top_cfg.sha384_page_addr_1,
            8'hFC,
            final_ctrl
        );

    endtask



    // ============================================================
    // Wait digest_valid
    //
    // FC[5] = 1
    // ============================================================

    task automatic wait_sha3_done();

        mcu_polling_reg(
            m_host_top_cfg.sha384_page_addr_1,
            8'hFC,
            5,
            1'b1
        );

    endtask



    // ============================================================
    // Read internal SHA3-384 digest
    // ============================================================

    task automatic read_sha3_digest(
        output bit [383:0] digest
    );

        bit [511:0] full_digest;


        full_digest =
            system
            .i_NT71801
            .i01_grp_tcon
            .i1_apr_top
            .u_crypto_top
            .i_sha3_top
            .digest[511:0];


        digest =
            full_digest[
                511 -: 384
            ];

    endtask



    // ============================================================
    // Compare
    // ============================================================

    task automatic compare_result(
        input int tc,
        input string test_name
    );


        if (
            actual_digest
            !==
            expected_digest
        ) begin


            fail_cnt++;


            `uvm_error(
                "SHA3_MISMATCH",
                $sformatf(
                    {
                        "\n==========================================",
                        "\nTC          = %0d",
                        "\nTEST        = %s",
                        "\nLEN_BYTE    = %0d",
                        "\nBLOCK_WR    = %0d",
                        "\nEXPECTED    = %096h",
                        "\nACTUAL      = %096h",
                        "\n=========================================="
                    },
                    tc,
                    test_name,
                    sha_data_len_byte,
                    block_wr_num,
                    expected_digest,
                    actual_digest
                )
            )


        end
        else begin


            pass_cnt++;


            `uvm_info(
                "SHA3_PASS",
                $sformatf(
                    "TC=%0d %s PASS digest=%096h",
                    tc,
                    test_name,
                    actual_digest
                ),
                UVM_LOW
            )

        end

    endtask



    // ============================================================
    // 64-bit rotate-left
    // ============================================================

    function automatic bit [63:0]
        rotl64(
            input bit [63:0] value,
            input int unsigned sh
        );


        if (sh == 0)
            return value;


        return
            (value << sh)
            |
            (value >> (64-sh));

    endfunction



    // ============================================================
    // Keccak Rho offset
    // ============================================================

    function automatic int unsigned
        rho_offset(
            input int x,
            input int y
        );


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
    // Keccak round constant
    // ============================================================

    function automatic bit [63:0]
        keccak_rc(
            input int r
        );


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

    task automatic keccak_f1600(
        inout bit [63:0] A [0:24]
    );

        bit [63:0] C [0:4];
        bit [63:0] D [0:4];
        bit [63:0] B [0:24];

        int x;
        int y;

        int new_x;
        int new_y;


        for (
            int round = 0;
            round < 24;
            round++
        ) begin


            // ---------------- Theta ----------------

            for (
                x = 0;
                x < 5;
                x++
            ) begin

                C[x] =
                      A[x + 5*0]
                    ^ A[x + 5*1]
                    ^ A[x + 5*2]
                    ^ A[x + 5*3]
                    ^ A[x + 5*4];

            end


            for (
                x = 0;
                x < 5;
                x++
            ) begin

                D[x] =
                      C[(x+4)%5]
                    ^
                    rotl64(
                        C[(x+1)%5],
                        1
                    );

            end


            for (
                y = 0;
                y < 5;
                y++
            ) begin

                for (
                    x = 0;
                    x < 5;
                    x++
                ) begin

                    A[x + 5*y] ^=
                        D[x];

                end

            end


            // ---------------- Rho + Pi ----------------

            for (
                x = 0;
                x < 25;
                x++
            )
                B[x] = 64'h0;


            for (
                y = 0;
                y < 5;
                y++
            ) begin

                for (
                    x = 0;
                    x < 5;
                    x++
                ) begin

                    new_x =
                        y;

                    new_y =
                        (2*x + 3*y) % 5;


                    B[
                        new_x + 5*new_y
                    ]
                    =
                    rotl64(
                        A[
                            x + 5*y
                        ],
                        rho_offset(
                            x,
                            y
                        )
                    );

                end

            end


            // ---------------- Chi ----------------

            for (
                y = 0;
                y < 5;
                y++
            ) begin

                for (
                    x = 0;
                    x < 5;
                    x++
                ) begin

                    A[
                        x + 5*y
                    ]
                    =
                    B[
                        x + 5*y
                    ]
                    ^
                    (
                        ~B[
                            ((x+1)%5)
                            + 5*y
                        ]
                        &
                        B[
                            ((x+2)%5)
                            + 5*y
                        ]
                    );

                end

            end


            // ---------------- Iota ----------------

            A[0] ^=
                keccak_rc(
                    round
                );

        end

    endtask



    // ============================================================
    // Absorb SHA3-384 rate block
    // ============================================================

    task automatic sha3_absorb_block(
        inout bit [63:0] A [0:24],
        input byte unsigned block [0:103]
    );

        int lane;
        int byte_pos;

        bit [63:0] temp;


        for (
            int i = 0;
            i < SHA3_RATE_BYTES;
            i++
        ) begin

            lane =
                i / 8;

            byte_pos =
                i % 8;


            temp =
                {
                    56'h0,
                    block[i]
                };


            A[lane] ^=
                temp
                <<
                (byte_pos * 8);

        end


        keccak_f1600(A);

    endtask



    // ============================================================
    // SHA3-384 golden model
    // ============================================================

    task automatic sha3_384(
        input byte unsigned msg[],
        output bit [383:0] digest
    );

        bit [63:0] A [0:24];

        byte unsigned block [0:103];

        byte unsigned digest_byte [0:47];

        int offset;
        int remain;

        int lane;
        int byte_pos;


        for (
            int i = 0;
            i < 25;
            i++
        )
            A[i] = 64'h0;


        offset = 0;


        // --------------------------------------------------------
        // Full 104-byte blocks。
        // --------------------------------------------------------

        while (
            (msg.size() - offset)
            >=
            SHA3_RATE_BYTES
        ) begin

            for (
                int i = 0;
                i < SHA3_RATE_BYTES;
                i++
            ) begin

                block[i] =
                    msg[
                        offset + i
                    ];

            end


            sha3_absorb_block(
                A,
                block
            );


            offset +=
                SHA3_RATE_BYTES;

        end


        // --------------------------------------------------------
        // Final padded block。
        // --------------------------------------------------------

        for (
            int i = 0;
            i < SHA3_RATE_BYTES;
            i++
        )
            block[i] = 8'h00;


        remain =
            msg.size() - offset;


        for (
            int i = 0;
            i < remain;
            i++
        )
            block[i] =
                msg[offset+i];


        // SHA3 domain separator
        block[remain] ^= 8'h06;


        // Final padding bit
        block[103] ^= 8'h80;


        sha3_absorb_block(
            A,
            block
        );


        // --------------------------------------------------------
        // Squeeze 48 bytes。
        // --------------------------------------------------------

        for (
            int i = 0;
            i < SHA3_DIGEST_BYTES;
            i++
        ) begin

            lane =
                i / 8;

            byte_pos =
                i % 8;


            digest_byte[i] =
                A[lane][
                    byte_pos*8 +: 8
                ];

        end


        digest = '0;


        // --------------------------------------------------------
        // Pack to Python hashlib hexdigest ordering。
        // --------------------------------------------------------

        for (
            int i = 0;
            i < SHA3_DIGEST_BYTES;
            i++
        ) begin

            digest[
                383-i*8 -: 8
            ] =
                digest_byte[i];

        end

    endtask



    // ============================================================
    // Golden self test
    //
    // 這幾組我已再次用 Python hashlib.sha3_384() 核對。
    // ============================================================

    task automatic sha3_384_self_test();

        byte unsigned msg[];
        byte unsigned tmp[];
        byte unsigned mask[];

        bit [383:0] result;


        // ========================================================
        // SHA3-384("abc")
        // ========================================================

        msg = new[3];

        msg[0] = 8'h61;
        msg[1] = 8'h62;
        msg[2] = 8'h63;


        sha3_384(
            msg,
            result
        );


        if (
            result
            !==
            384'hec01498288516fc926459f58e2c6ad8d
                 f9b473cb0fc08c2596da7cf0e49be4b2
                 98d88cea927ac7f539f1edf228376d25
        )
            `uvm_fatal(
                "SHA3_REF",
                "SHA3-384 abc self-test failed"
            )


        // ========================================================
        // salt + abc
        // ========================================================

        build_salt_golden(
            msg,
            32'h1234_5678,
            1'b0,
            tmp
        );


        sha3_384(
            tmp,
            result
        );


        if (
            result
            !==
            384'h25e17559803f2bf31fcc9ead4c692824
                 7d5abdf16c7c3f83d427d94c9d64c5d
                 bcdf698db133450268210316799e92015
        )
            `uvm_fatal(
                "SHA3_REF",
                "SHA3-384 salt prepend self-test failed"
            )


        // ========================================================
        // abc + salt
        // ========================================================

        build_salt_golden(
            msg,
            32'h1234_5678,
            1'b1,
            tmp
        );


        sha3_384(
            tmp,
            result
        );


        if (
            result
            !==
            384'hc96982a5ae5ad078286cd6b3a0245efe
                 5291a8fdf46a8a76fdb59d1107d40548
                 787a845b9922f26c252a2f1185ed46f0
        )
            `uvm_fatal(
                "SHA3_REF",
                "SHA3-384 salt append self-test failed"
            )


        // ========================================================
        // Mask replacement
        // ========================================================

        msg = new[16];


        foreach (msg[i]) begin

            msg[i] =
                byte'(i);

        end


        mask = new[4];

        mask[0] = 8'hAA;
        mask[1] = 8'hBB;
        mask[2] = 8'hCC;
        mask[3] = 8'hDD;


        build_mask_golden(
            msg,
            4,
            mask,
            tmp
        );


        sha3_384(
            tmp,
            result
        );


        if (
            result
            !==
            384'h8fbc172cfcf66ba4b15095354ad5eb48
                 18c3e1ca6c6a014a1c178cb72a5ea17e
                 2f8bf73b03be6e03ae59db580e732d47
        )
            `uvm_fatal(
                "SHA3_REF",
                "SHA3-384 mask self-test failed"
            )


        `uvm_info(
            "SHA3_REF",
            "SHA3 reference model self-test PASS",
            UVM_LOW
        )

    endtask


endclass
