// ============================================================================
// MCU RSA-3072 TEST
//
// Verification:
//   1. TB math self-test
//   2. Generate RSA M/N/D
//   3. Golden = M^D mod N
//   4. Compute nprime0
//   5. Program DUT through AHB
//   6. Verify C/N/D byte reverse mode
//   7. Start RSA
//   8. Wait complete
//   9. Read m_bar RESULT THROUGH AHB REGISTER
//  10. Verify m_bar byte reverse mode
//  11. Compare 3072-bit DUT result against Golden
//
// ============================================================================


// ---------------------------------------------------------------------------
// Keep YOUR ORIGINAL include files here.
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// Keep YOUR ORIGINAL hierarchy macros here.
// ---------------------------------------------------------------------------

`define DUT_MOD_EXP   /* KEEP YOUR ORIGINAL VALUE */
`define DUT_COMPLETE  `DUT_MOD_EXP.complete_s


parameter int RSA_BITS  = 3072;
parameter int RSA_BYTES = RSA_BITS / 8;       // 384
parameter int RSA_WORDS = RSA_BITS / 32;      // 96


class mcu_rsa_test extends host_base_test;

    `uvm_component_utils(mcu_rsa_test)


    // ========================================================================
    // Original RSA data
    // ========================================================================

    logic [RSA_BITS-1:0] d_rsa_M;
    logic [RSA_BITS-1:0] d_rsa_N;
    logic [RSA_BITS-1:0] d_rsa_priv;

    logic [63:0] d_nprime0;

    logic [RSA_BITS-1:0] d_expected_result;
    logic [RSA_BITS-1:0] d_dut_result;

    logic [63:0] random_seed;

    int match_count;
    int mismatch_count;
    int total_tests;


    // ========================================================================
    // [NEW]
    //
    // Endian test control
    //
    // Each input has an independent reverse mode.
    // Result m_bar also has its own read-side reverse mode.
    // ========================================================================

    bit c_reverse_mode;
    bit n_reverse_mode;
    bit d_reverse_mode;
    bit mbar_reverse_mode;



    // ========================================================================
    // Constructor
    // ========================================================================

    function new(
        string name = "mcu_rsa_test",
        uvm_component parent = null
    );

        super.new(name, parent);

        match_count    = 0;
        mismatch_count = 0;
        total_tests    = 0;

        // [NEW]
        c_reverse_mode    = 0;
        n_reverse_mode    = 0;
        d_reverse_mode    = 0;
        mbar_reverse_mode = 0;

    endfunction



    // ========================================================================
    // [NEW]
    // Reverse complete 3072-bit value BYTE-BY-BYTE.
    //
    // Input:
    //
    //   byte383 ... byte2 byte1 byte0
    //
    // Output:
    //
    //   byte0 byte1 byte2 ... byte383
    //
    // This matches the behavior visible in C/N/D RTL.
    // ========================================================================

    function automatic logic [RSA_BITS-1:0] rsa_byte_reverse(
        input logic [RSA_BITS-1:0] data
    );

        logic [RSA_BITS-1:0] reversed_data;

        reversed_data = '0;

        for (int byte_idx = 0;
             byte_idx < RSA_BYTES;
             byte_idx++) begin

            reversed_data[byte_idx*8 +: 8]
                =
            data[(RSA_BYTES-1-byte_idx)*8 +: 8];

        end

        return reversed_data;

    endfunction



    // ========================================================================
    // Original compute_nprime0()
    // ========================================================================

    function automatic logic [63:0] compute_nprime0(
        input logic [RSA_BITS-1:0] N
    );

        logic [63:0] n0;
        logic [63:0] inv;

        n0 = N[63:0];

        if (n0[0] !== 1'b1) begin

            `uvm_error(
                get_type_name(),
                "compute_nprime0: N must be odd"
            )

            return '0;

        end

        inv = 64'd1;

        repeat (6) begin

            inv =
                inv *
                (64'd2 - n0 * inv);

        end

        return (~inv) + 64'd1;

    endfunction



    // ========================================================================
    // Original Golden
    //
    // Expected = M^D mod N
    //
    // ========================================================================

    function automatic void power_mod_3072(
        input  logic [RSA_BITS-1:0] base,
        input  logic [RSA_BITS-1:0] exponent,
        input  logic [RSA_BITS-1:0] mod_n,
        output logic [RSA_BITS-1:0] result
    );

        logic [RSA_BITS-1:0] res;

        logic [6143:0] op_a;
        logic [6143:0] op_b;
        logic [6143:0] mult_temp;

        int msb_pos;


        if (mod_n == '0) begin

            result = '0;

            `uvm_error(
                get_type_name(),
                "power_mod_3072: modulus N is zero"
            )

            return;

        end


        msb_pos = -1;

        for (int i = RSA_BITS-1; i >= 0; i--) begin

            if (exponent[i] === 1'b1) begin

                msb_pos = i;
                break;

            end

        end


        if (msb_pos < 0) begin

            result = base;
            return;

        end


        res = base;


        for (int i = msb_pos-1; i >= 0; i--) begin

            op_a = {{RSA_BITS{1'b0}}, res};
            op_b = {{RSA_BITS{1'b0}}, res};

            mult_temp = op_a * op_b;

            res = mult_temp % mod_n;


            if (exponent[i] === 1'b1) begin

                op_a = {{RSA_BITS{1'b0}}, res};
                op_b = {{RSA_BITS{1'b0}}, base};

                mult_temp = op_a * op_b;

                res = mult_temp % mod_n;

            end

        end


        result = res;

    endfunction



    // ========================================================================
    // Original self-test
    // +
    // [MODIFY] add byte reverse self-test
    // ========================================================================

    virtual task rsa_math_self_test();

        logic [RSA_BITS-1:0] base;
        logic [RSA_BITS-1:0] exponent;
        logic [RSA_BITS-1:0] modulus;
        logic [RSA_BITS-1:0] result;

        logic [RSA_BITS-1:0] reverse_test;
        logic [RSA_BITS-1:0] reverse_result;

        logic [63:0] nprime;
        logic [127:0] nprime_product;

        int error_count;

        error_count = 0;


        // ------------------------------------------------------------
        // 3^5 mod 7 = 5
        // ------------------------------------------------------------

        base     = '0;
        exponent = '0;
        modulus  = '0;

        base     = 3072'd3;
        exponent = 3072'd5;
        modulus  = 3072'd7;

        power_mod_3072(
            base,
            exponent,
            modulus,
            result
        );

        if (result !== 3072'd5) begin

            error_count++;

            `uvm_error(
                get_type_name(),
                "RSA SELF TEST FAIL: 3^5 mod 7"
            )

        end


        // ------------------------------------------------------------
        // 5^13 mod 17 = 3
        // ------------------------------------------------------------

        base     = 3072'd5;
        exponent = 3072'd13;
        modulus  = 3072'd17;

        power_mod_3072(
            base,
            exponent,
            modulus,
            result
        );

        if (result !== 3072'd3) begin

            error_count++;

            `uvm_error(
                get_type_name(),
                "RSA SELF TEST FAIL: 5^13 mod 17"
            )

        end


        // ------------------------------------------------------------
        // nprime0 property
        // ------------------------------------------------------------

        modulus = '0;

        modulus[63:0] =
            64'hFEDC_BA98_7654_3211;

        nprime =
            compute_nprime0(modulus);

        nprime_product =
            {64'd0, modulus[63:0]}
            *
            {64'd0, nprime};

        if (
            nprime_product[63:0]
            !==
            64'hFFFF_FFFF_FFFF_FFFF
        ) begin

            error_count++;

            `uvm_error(
                get_type_name(),
                "RSA NPRIME SELF TEST FAIL"
            )

        end


        // ============================================================
        // [NEW]
        // Byte-reverse helper self-test.
        //
        // Put known values in first and last bytes.
        //
        // After reverse:
        //
        // byte 0   -> byte 383
        // byte 383 -> byte 0
        // ============================================================

        reverse_test = '0;

        reverse_test[7:0]       = 8'h12;
        reverse_test[15:8]      = 8'h34;

        reverse_test[3063:3056] = 8'hAB;
        reverse_test[3071:3064] = 8'hCD;


        reverse_result =
            rsa_byte_reverse(reverse_test);


        if (
            reverse_result[3071:3064] !== 8'h12 ||
            reverse_result[3063:3056] !== 8'h34 ||
            reverse_result[15:8]      !== 8'hAB ||
            reverse_result[7:0]       !== 8'hCD
        ) begin

            error_count++;

            `uvm_error(
                get_type_name(),
                "RSA BYTE REVERSE SELF TEST FAIL"
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                "RSA BYTE REVERSE SELF TEST PASS",
                UVM_LOW
            )

        end


        if (error_count != 0) begin

            `uvm_fatal(
                get_type_name(),
                $sformatf(
                    "RSA SELF TEST FAILED: %0d error(s)",
                    error_count
                )
            )

        end


        `uvm_info(
            get_type_name(),
            "RSA MATH SELF TEST: ALL PASS",
            UVM_LOW
        )

    endtask



    // ========================================================================
    // Generate vector
    //
    // [MODIFY]
    //
    // Keep small exponent 65537 for bring-up / simulation speed.
    //
    // ========================================================================

    virtual function void generate_test_vector();

        logic [RSA_BITS-1:0] m_candidate;

        logic [127:0] check_nprime;

        int retry_cnt;


        random_seed = $urandom();


        // ------------------------------------------------------------
        // N = random 3072-bit odd number
        // ------------------------------------------------------------

        retry_cnt = 0;

        while (retry_cnt < 1000) begin

            if (
                std::randomize(d_rsa_N)
                with {
                    d_rsa_N[RSA_BITS-1] == 1'b1;
                    d_rsa_N[0]          == 1'b1;
                }
            ) begin

                break;

            end

            retry_cnt++;

        end


        if (retry_cnt >= 1000) begin

            `uvm_fatal(
                get_type_name(),
                "Failed to generate N"
            )

        end


        // ============================================================
        // [MODIFY]
        //
        // Fixed exponent:
        //
        //     65537 = 0x10001
        //
        // This dramatically reduces SV golden-model runtime.
        // ============================================================

        d_rsa_priv = '0;

        d_rsa_priv[16:0] =
            17'h1_0001;


        // ------------------------------------------------------------
        // Generate M < N
        // ------------------------------------------------------------

        retry_cnt = 0;

        while (retry_cnt < 1000) begin

            if (
                std::randomize(m_candidate)
                with {
                    m_candidate[RSA_BITS-1] == 1'b1;
                    m_candidate < d_rsa_N;
                }
            ) begin

                d_rsa_M = m_candidate;
                break;

            end

            retry_cnt++;

        end


        if (retry_cnt >= 1000) begin

            `uvm_fatal(
                get_type_name(),
                "Failed to generate M"
            )

        end


        d_nprime0 =
            compute_nprime0(d_rsa_N);


        check_nprime =
            {64'd0, d_rsa_N[63:0]}
            *
            {64'd0, d_nprime0};


        if (
            check_nprime[63:0]
            !==
            64'hFFFF_FFFF_FFFF_FFFF
        ) begin

            `uvm_fatal(
                get_type_name(),
                "Generated nprime0 check failed"
            )

        end

    endfunction



    // ========================================================================
    // Generate vector + Golden
    // ========================================================================

    virtual task gen_test_vector(
        input int test_id
    );

        generate_test_vector();


        `uvm_info(
            get_type_name(),
            "Calculating RSA golden M^D mod N...",
            UVM_LOW
        )


        power_mod_3072(
            d_rsa_M,
            d_rsa_priv,
            d_rsa_N,
            d_expected_result
        );


        `uvm_info(
            get_type_name(),
            "RSA golden calculation complete",
            UVM_LOW
        )

    endtask



    // ========================================================================
    // [NEW]
    //
    // Set C/N/D/M_BAR byte reverse control.
    //
    // RTL proves:
    //
    //   *_byte_reverse_mode = reg_120_ctrl[0]
    //
    // reg_120 = 0x120 in local register addressing.
    //
    // IMPORTANT:
    //
    // Use your existing register access mapping.
    //
    // page_addr_2 + 0x80 is the word containing:
    //
    //   byte offset 0x80 : data byte 383
    //   byte offset 0x81 : byte_reverse_mode
    //
    // Therefore use READ-MODIFY-WRITE.
    // ========================================================================

    task automatic set_rsa_byte_reverse_mode(
        input string       tag,
        input logic [23:0] page_addr_2,
        input bit          reverse_mode
    );

        logic [31:0] ctrl_word;


        // Read word @ 0x80 first so byte 383 is preserved.
        ahb_word_read(
            page_addr_2,
            8'h80,
            ctrl_word
        );


        // byte offset 0x81 -> bit[8] of aligned 32-bit word.
        ctrl_word[8] =
            reverse_mode;


        ahb_word_write(
            page_addr_2,
            8'h80,
            ctrl_word
        );


        // Readback control.
        ahb_word_read(
            page_addr_2,
            8'h80,
            ctrl_word
        );


        if (ctrl_word[8] !== reverse_mode) begin

            `uvm_fatal(
                get_type_name(),
                $sformatf(
                    "[%s] byte_reverse_mode write failed exp=%0d act=%0d",
                    tag,
                    reverse_mode,
                    ctrl_word[8]
                )
            )

        end


        `uvm_info(
            get_type_name(),
            $sformatf(
                "[%s] byte_reverse_mode=%0d",
                tag,
                reverse_mode
            ),
            UVM_LOW
        )

    endtask



    // ========================================================================
    // [MODIFY]
    //
    // Common RSA writer.
    //
    // reverse_mode means:
    //
    // mode=0:
    //     write logical value directly
    //
    // mode=1:
    //     write byte-reversed representation
    //
    // RTL reverses it again when generating c_in/n/d_in.
    //
    // Therefore logical operand seen by ModExp remains identical.
    // ========================================================================

    task automatic write_rsa_3072_reg(
        input string               tag,
        input logic [23:0]         page_addr_1,
        input logic [23:0]         page_addr_2,
        input logic [RSA_BITS-1:0] logical_data,
        input bit                  reverse_mode = 1'b0
    );

        logic [RSA_BITS-1:0] bus_data;

        logic [31:0] ahb_addr;
        logic [31:0] ahb_wdata;

        int word_idx;


        // ============================================================
        // [NEW]
        //
        // If DUT will reverse register bytes, software must provide
        // reversed byte representation so internal logical operand
        // remains the same.
        // ============================================================

        if (reverse_mode) begin

            bus_data =
                rsa_byte_reverse(logical_data);

        end
        else begin

            bus_data =
                logical_data;

        end


        for (word_idx = 0;
             word_idx < RSA_WORDS;
             word_idx++) begin


            if (word_idx < 64) begin

                ahb_addr =
                    {page_addr_1, 8'h00}
                    +
                    word_idx * 4;

            end
            else begin

                ahb_addr =
                    {page_addr_2, 8'h00}
                    +
                    (word_idx-64) * 4;

            end


            ahb_wdata =
                bus_data[word_idx*32 +: 32];


            ahb_word_write(
                ahb_addr[31:8],
                ahb_addr[7:0],
                ahb_wdata
            );

        end


        // ============================================================
        // IMPORTANT:
        //
        // Set mode AFTER writing data.
        //
        // This makes the 0x80 RMW preserve the already-written
        // byte383.
        // ============================================================

        set_rsa_byte_reverse_mode(
            tag,
            page_addr_2,
            reverse_mode
        );

    endtask



    // ========================================================================
    // [MODIFY]
    //
    // Register readback checker.
    //
    // IMPORTANT:
    //
    // C/N/D RTL reverse is applied to INTERNAL c_in/n/d_in.
    //
    // CPU register readback still returns physical register storage.
    //
    // Therefore expected register contents are:
    //
    //   mode=0 -> logical_data
    //   mode=1 -> byte_reverse(logical_data)
    //
    // ========================================================================

    task automatic check_rsa_3072_reg(
        input string               tag,
        input logic [23:0]         page_addr_1,
        input logic [23:0]         page_addr_2,
        input logic [RSA_BITS-1:0] logical_data,
        input bit                  reverse_mode = 1'b0
    );

        logic [RSA_BITS-1:0] expected_bus_data;

        logic [31:0] ahb_addr;
        logic [31:0] ahb_rdata;
        logic [31:0] expected_word;

        int error_count;


        error_count = 0;


        if (reverse_mode) begin

            expected_bus_data =
                rsa_byte_reverse(logical_data);

        end
        else begin

            expected_bus_data =
                logical_data;

        end


        for (int word_idx = 0;
             word_idx < RSA_WORDS;
             word_idx++) begin


            if (word_idx < 64) begin

                ahb_addr =
                    {page_addr_1, 8'h00}
                    +
                    word_idx * 4;

            end
            else begin

                ahb_addr =
                    {page_addr_2, 8'h00}
                    +
                    (word_idx-64) * 4;

            end


            expected_word =
                expected_bus_data[
                    word_idx*32 +: 32
                ];


            ahb_word_read(
                ahb_addr[31:8],
                ahb_addr[7:0],
                ahb_rdata
            );


            if (ahb_rdata !== expected_word) begin

                error_count++;

                `uvm_error(
                    get_type_name(),
                    $sformatf(
                        {"[%s] READBACK FAIL\n",
                         "reverse=%0d word=%0d\n",
                         "expected=0x%08h actual=0x%08h"},
                        tag,
                        reverse_mode,
                        word_idx,
                        expected_word,
                        ahb_rdata
                    )
                )

            end

        end


        if (error_count != 0) begin

            `uvm_fatal(
                get_type_name(),
                $sformatf(
                    "[%s] REGISTER CHECK FAILED errors=%0d",
                    tag,
                    error_count
                )
            )

        end

    endtask



    // ========================================================================
    // [MODIFY]
    // C / plaintext writer
    // ========================================================================

    task write_rsa_M(
        input logic [RSA_BITS-1:0] rsa_M,
        input bit                  reverse_mode = 1'b0
    );

        write_rsa_3072_reg(
            "RSA C/M",
            m_host_top_cfg.rsa_c_page_addr_1,
            m_host_top_cfg.rsa_c_page_addr_2,
            rsa_M,
            reverse_mode
        );


        check_rsa_3072_reg(
            "RSA C/M",
            m_host_top_cfg.rsa_c_page_addr_1,
            m_host_top_cfg.rsa_c_page_addr_2,
            rsa_M,
            reverse_mode
        );

    endtask



    // ========================================================================
    // [MODIFY]
    // N writer
    // ========================================================================

    task write_rsa_N(
        input logic [RSA_BITS-1:0] rsa_N,
        input bit                  reverse_mode = 1'b0
    );

        write_rsa_3072_reg(
            "RSA N",
            m_host_top_cfg.rsa_n_page_addr_1,
            m_host_top_cfg.rsa_n_page_addr_2,
            rsa_N,
            reverse_mode
        );


        check_rsa_3072_reg(
            "RSA N",
            m_host_top_cfg.rsa_n_page_addr_1,
            m_host_top_cfg.rsa_n_page_addr_2,
            rsa_N,
            reverse_mode
        );

    endtask



    // ========================================================================
    // [MODIFY]
    // D writer
    // ========================================================================

    task write_rsa_priv_key(
        input logic [RSA_BITS-1:0] rsa_priv_key,
        input bit                  reverse_mode = 1'b0
    );

        write_rsa_3072_reg(
            "RSA D",
            m_host_top_cfg.rsa_d_page_addr_1,
            m_host_top_cfg.rsa_d_page_addr_2,
            rsa_priv_key,
            reverse_mode
        );


        check_rsa_3072_reg(
            "RSA D",
            m_host_top_cfg.rsa_d_page_addr_1,
            m_host_top_cfg.rsa_d_page_addr_2,
            rsa_priv_key,
            reverse_mode
        );

    endtask



    // ========================================================================
    // Original nprime0 write
    // ========================================================================

    task write_rsa_nprime_to_dut(
        input logic [63:0] nprime0
    );

        logic [23:0] base_addr_h;

        logic [31:0] wdata;
        logic [31:0] rdata;


        base_addr_h =
            m_host_top_cfg.rsa_nprime0_aes_page_addr;


        for (int word_idx = 0;
             word_idx < 2;
             word_idx++) begin

            wdata =
                nprime0[word_idx*32 +: 32];


            ahb_word_write(
                base_addr_h,
                word_idx*4,
                wdata
            );

        end


        for (int word_idx = 0;
             word_idx < 2;
             word_idx++) begin

            ahb_word_read(
                base_addr_h,
                word_idx*4,
                rdata
            );


            if (
                rdata
                !==
                nprime0[word_idx*32 +: 32]
            ) begin

                `uvm_fatal(
                    get_type_name(),
                    "RSA nprime0 readback failed"
                )

            end

        end

    endtask



    // ========================================================================
    // [MODIFY]
    // Program DUT using independently selectable reverse modes.
    // ========================================================================

    virtual task write_rsa_params_to_dut(
        input bit c_rev,
        input bit n_rev,
        input bit d_rev
    );

        write_rsa_M(
            d_rsa_M,
            c_rev
        );


        write_rsa_N(
            d_rsa_N,
            n_rev
        );


        write_rsa_priv_key(
            d_rsa_priv,
            d_rev
        );


        // nprime0 corresponds to LOGICAL N.
        //
        // Do NOT byte reverse nprime0 merely because N register
        // representation is reversed.
        write_rsa_nprime_to_dut(
            d_nprime0
        );

    endtask



    // ========================================================================
    // Keep YOUR ORIGINAL write_rsa_start()
    // ========================================================================

    virtual task write_rsa_start();

        logic [31:0] ahb_addr;

        ahb_addr = {
            m_host_top_cfg.rsa_nprime0_aes_page_addr,
            8'h08
        };


        ahb_word_write(
            ahb_addr[31:8],
            ahb_addr[7:0],
            32'h0000_0080
        );

    endtask



    // ========================================================================
    // Keep original wait
    // ========================================================================

    virtual task wait_rsa_compute_done(
        input int max_poll_count
    );

        int poll_count;

        poll_count = 0;


        while (
            (`DUT_COMPLETE !== 1'b1)
            &&
            poll_count < max_poll_count
        ) begin

            #160ns;

            poll_count++;

        end


        if (poll_count >= max_poll_count) begin

            `uvm_fatal(
                get_type_name(),
                "RSA compute timeout"
            )

        end

    endtask



    // ========================================================================
    // [NEW]
    //
    // Read complete 3072-bit register value.
    //
    // This is used for M_BAR RESULT.
    //
    // IMPORTANT:
    //
    // Unlike C/N/D:
    //
    // m_bar RTL applies m_bar_byte_reverse_mode directly in READ PATH.
    //
    // Therefore the AHB result itself changes according to mode.
    // ========================================================================

    task automatic read_rsa_3072_reg(
        input  string               tag,
        input  logic [23:0]         page_addr_1,
        input  logic [23:0]         page_addr_2,
        output logic [RSA_BITS-1:0] data
    );

        logic [31:0] ahb_addr;
        logic [31:0] ahb_rdata;


        data = '0;


        for (int word_idx = 0;
             word_idx < RSA_WORDS;
             word_idx++) begin


            if (word_idx < 64) begin

                ahb_addr =
                    {page_addr_1, 8'h00}
                    +
                    word_idx*4;

            end
            else begin

                ahb_addr =
                    {page_addr_2, 8'h00}
                    +
                    (word_idx-64)*4;

            end


            ahb_word_read(
                ahb_addr[31:8],
                ahb_addr[7:0],
                ahb_rdata
            );


            data[word_idx*32 +: 32]
                =
            ahb_rdata;

        end


        `uvm_info(
            get_type_name(),
            $sformatf(
                "[%s] 3072-bit register read complete",
                tag
            ),
            UVM_LOW
        )

    endtask



    // ========================================================================
    // [MODIFY]
    //
    // RESULT READ NOW USES AHB REGISTER.
    //
    // This replaces:
    //
    //     d_dut_result = `DUT_MOD_EXP.m_bar;
    //
    // mbar_reverse_mode:
    //
    //   0:
    //      register read returns normal result
    //
    //   1:
    //      RTL reverses result bytes on read
    //
    // To compare against the SAME mathematical Golden result,
    // TB reverses the AHB representation back after reading.
    //
    // ========================================================================

    virtual task read_rsa_result_from_dut(
        input bit reverse_mode
    );

        logic [RSA_BITS-1:0] raw_result;


        // ============================================================
        // [NEW]
        // Program m_bar read reverse mode.
        //
        // IMPORTANT:
        // Replace these cfg names with the EXACT m_bar page cfg names
        // from your environment if their names differ.
        // ============================================================

        set_rsa_byte_reverse_mode(
            "RSA M_BAR",
            m_host_top_cfg.rsa_m_bar_page_addr_2,
            reverse_mode
        );


        // ============================================================
        // [MODIFY]
        // Read result through AHB instead of hierarchy.
        // ============================================================

        read_rsa_3072_reg(
            "RSA M_BAR",
            m_host_top_cfg.rsa_m_bar_page_addr_1,
            m_host_top_cfg.rsa_m_bar_page_addr_2,
            raw_result
        );


        // ============================================================
        // RTL already reversed bytes in the register READ path.
        //
        // Convert bus representation back to logical mathematical
        // representation before scoreboard comparison.
        // ============================================================

        if (reverse_mode) begin

            d_dut_result =
                rsa_byte_reverse(raw_result);

        end
        else begin

            d_dut_result =
                raw_result;

        end


        `uvm_info(
            get_type_name(),
            $sformatf(
                "RSA M_BAR read complete reverse=%0d",
                reverse_mode
            ),
            UVM_LOW
        )

    endtask



    // ========================================================================
    // Original compare
    // ========================================================================

    virtual function void compare_result(
        input int test_id
    );

        if (
            d_expected_result
            ===
            d_dut_result
        ) begin

            match_count++;


            `uvm_info(
                get_type_name(),
                $sformatf(
                    {"RSA PASS test=%0d ",
                     "C_REV=%0d N_REV=%0d D_REV=%0d M_BAR_REV=%0d"},
                    test_id,
                    c_reverse_mode,
                    n_reverse_mode,
                    d_reverse_mode,
                    mbar_reverse_mode
                ),
                UVM_LOW
            )

        end
        else begin

            mismatch_count++;


            `uvm_error(
                get_type_name(),
                $sformatf(
                    {"RSA FAIL test=%0d\n",
                     "C_REV=%0d N_REV=%0d D_REV=%0d M_BAR_REV=%0d\n",
                     "Expected=0x%0h\n",
                     "Actual  =0x%0h"},
                    test_id,
                    c_reverse_mode,
                    n_reverse_mode,
                    d_reverse_mode,
                    mbar_reverse_mode,
                    d_expected_result,
                    d_dut_result
                )
            )


            for (int nibble = 768;
                 nibble >= 1;
                 nibble--) begin

                if (
                    d_expected_result[nibble*4-1 -: 4]
                    !==
                    d_dut_result[nibble*4-1 -: 4]
                ) begin

                    `uvm_info(
                        get_type_name(),
                        $sformatf(
                            "First mismatch bit[%0d:%0d] exp=%h act=%h",
                            nibble*4-1,
                            nibble*4-4,
                            d_expected_result[
                                nibble*4-1 -: 4
                            ],
                            d_dut_result[
                                nibble*4-1 -: 4
                            ]
                        ),
                        UVM_LOW
                    )

                    break;

                end

            end

        end


        total_tests++;

    endfunction



    // ========================================================================
    // [MODIFY]
    //
    // One RSA case now accepts four independent endian controls.
    //
    // ========================================================================

    virtual task run_rsa_one_test(
        input int test_id,
        input bit c_rev,
        input bit n_rev,
        input bit d_rev,
        input bit mbar_rev
    );

        c_reverse_mode    = c_rev;
        n_reverse_mode    = n_rev;
        d_reverse_mode    = d_rev;
        mbar_reverse_mode = mbar_rev;


        `uvm_info(
            get_type_name(),
            $sformatf(
                {"========== RSA CASE %0d ==========\n",
                 "C_REV=%0d N_REV=%0d D_REV=%0d M_BAR_REV=%0d"},
                test_id,
                c_rev,
                n_rev,
                d_rev,
                mbar_rev
            ),
            UVM_LOW
        )


        // ============================================================
        // Generate SAME logical RSA vector.
        // ============================================================

        gen_test_vector(
            test_id
        );


        // ============================================================
        // Write logical M/N/D.
        //
        // Individual writer converts them to physical bus
        // representation according to reverse mode.
        // ============================================================

        write_rsa_params_to_dut(
            c_rev,
            n_rev,
            d_rev
        );


        write_rsa_start();


        wait_rsa_compute_done(
            1_000_000
        );


        // ============================================================
        // [MODIFY]
        // Read RESULT THROUGH REGISTER.
        // ============================================================

        read_rsa_result_from_dut(
            mbar_rev
        );


        compare_result(
            test_id
        );

    endtask



    // ========================================================================
    // [NEW]
    //
    // Endian directed verification.
    //
    // Individual mode cases are important because each control is
    // independent.
    //
    // ========================================================================

    virtual task run_rsa_endian_test();

        // ------------------------------------------------------------
        // Case 0
        // Baseline
        // ------------------------------------------------------------

        run_rsa_one_test(
            0,
            1'b0,      // C
            1'b0,      // N
            1'b0,      // D
            1'b0       // M_BAR
        );


        // ------------------------------------------------------------
        // Case 1
        // C reverse only
        // ------------------------------------------------------------

        run_rsa_one_test(
            1,
            1'b1,
            1'b0,
            1'b0,
            1'b0
        );


        // ------------------------------------------------------------
        // Case 2
        // N reverse only
        // ------------------------------------------------------------

        run_rsa_one_test(
            2,
            1'b0,
            1'b1,
            1'b0,
            1'b0
        );


        // ------------------------------------------------------------
        // Case 3
        // D reverse only
        // ------------------------------------------------------------

        run_rsa_one_test(
            3,
            1'b0,
            1'b0,
            1'b1,
            1'b0
        );


        // ------------------------------------------------------------
        // Case 4
        // All input reverse
        // ------------------------------------------------------------

        run_rsa_one_test(
            4,
            1'b1,
            1'b1,
            1'b1,
            1'b0
        );


        // ------------------------------------------------------------
        // Case 5
        // M_BAR read reverse only
        // ------------------------------------------------------------

        run_rsa_one_test(
            5,
            1'b0,
            1'b0,
            1'b0,
            1'b1
        );


        // ------------------------------------------------------------
        // Case 6
        // Everything reverse
        // ------------------------------------------------------------

        run_rsa_one_test(
            6,
            1'b1,
            1'b1,
            1'b1,
            1'b1
        );

    endtask



    // ========================================================================
    // [MODIFY]
    // run_phase
    // ========================================================================

    virtual task run_phase(
        uvm_phase phase
    );

        phase.raise_objection(this);


        // ------------------------------------------------------------
        // Original environment initialization
        // ------------------------------------------------------------

        mcu_test_preset();


        // ============================================================
        // [MODIFY]
        // First validate TB math + byte reverse helper.
        // ============================================================

        rsa_math_self_test();


        // ============================================================
        // [NEW]
        // Run normal + endian cases.
        // ============================================================

        run_rsa_endian_test();


        // ------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------

        `uvm_info(
            get_type_name(),
            "============================================================",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            $sformatf(
                {"RSA TEST SUMMARY\n",
                 "Total    = %0d\n",
                 "PASS     = %0d\n",
                 "FAIL     = %0d"},
                total_tests,
                match_count,
                mismatch_count
            ),
            UVM_LOW
        )


        if (mismatch_count != 0) begin

            `uvm_error(
                get_type_name(),
                "RSA VERIFICATION FAILED"
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                "RSA VERIFICATION ALL PASS",
                UVM_LOW
            )

        end


        phase.drop_objection(this);

    endtask


endclass : mcu_rsa_test
