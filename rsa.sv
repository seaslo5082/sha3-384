// ============================================================================
// MCU RSA-3072 TEST
//
// DUT programming flow:
//   1. Generate M / N / D
//   2. Compute nprime0 = -N^-1 mod 2^64
//   3. Golden expected = M^D mod N
//   4. Write M / N / D / nprime0 through AHB
//   5. startCompute = 1
//   6. Wait complete_s
//   7. Read DUT m_bar
//   8. Compare DUT result with golden
//
// IMPORTANT:
//
//   - Golden model is plain MSB-first square-and-multiply.
//   - Golden model DOES NOT use Montgomery arithmetic.
//   - nprime0 is computed only because DUT requires it.
//   - R/T are NOT programmed here until RTL/original flow proves SW must write.
//   - rsa_math_self_test() runs before DUT access.
// ============================================================================


`include "./soc/na2le87/designer/nvt85441/CHIP_SIM_local/stm/jit_yueh/include/andes_internal_task.sv"
`include "./soc/na2le87/designer/nvt85441/CHIP_SIM_local/stm/jit_yueh/include/andes_ahb_task.sv"
`include "./soc/na2le87/designer/nvt85441/CHIP_SIM_local/stm/jit_yueh/include/write_rsa_ahb.sv"


// ============================================================================
// DUT hierarchy
//
// Keep these hierarchy names consistent with your current environment.
// ============================================================================

`define CRYPTO_TOP    `UVM_SYSTEM.i_NT71801.101_grp_tcon.i_apr_top.u_crypto_top
`define DUT_MOD_EXP   `CRYPTO_TOP.i_ModExp
`define DUT_START     `DUT_MOD_EXP.startCompute
`define DUT_COMPLETE  `DUT_MOD_EXP.complete_s


parameter int RSA_BITS = 3072;


// ============================================================================
// TEST CLASS
// ============================================================================

class mcu_rsa_test extends host_base_test;

    `uvm_component_utils(mcu_rsa_test)


    // ------------------------------------------------------------------------
    // RSA input
    // ------------------------------------------------------------------------

    logic [RSA_BITS-1:0] d_rsa_M;
    logic [RSA_BITS-1:0] d_rsa_N;
    logic [RSA_BITS-1:0] d_rsa_priv;


    // ------------------------------------------------------------------------
    // DUT Montgomery parameter
    //
    // nprime0 = -N^-1 mod 2^64
    // ------------------------------------------------------------------------

    logic [63:0] d_nprime0;


    // ------------------------------------------------------------------------
    // Result
    // ------------------------------------------------------------------------

    logic [RSA_BITS-1:0] d_expected_result;
    logic [RSA_BITS-1:0] d_dut_result;


    // ------------------------------------------------------------------------
    // Debug / statistics
    // ------------------------------------------------------------------------

    logic [63:0] random_seed;

    int match_count;
    int mismatch_count;
    int total_tests;



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

    endfunction



    // ========================================================================
    // Build phase
    // ========================================================================

    virtual function void build_phase(uvm_phase phase);

        super.build_phase(phase);

    endfunction



    // ========================================================================
    // compute_nprime0
    //
    // Python:
    //
    //   nprime0 = ext_euclid(
    //                 -(N % 2^64),
    //                 2^64
    //             )
    //
    // Equivalent:
    //
    //   nprime0 = -N^-1 mod 2^64
    //
    // For an odd N:
    //
    //   inverse modulo 2^64 exists.
    //
    // Newton iteration:
    //
    //   x_next = x * (2 - N*x)
    //
    // Each iteration doubles the number of correct bits.
    //
    // 1 -> 2 -> 4 -> 8 -> 16 -> 32 -> 64
    //
    // Therefore six iterations are enough.
    // ========================================================================

    function automatic logic [63:0] compute_nprime0(
        input logic [RSA_BITS-1:0] N
    );

        logic [63:0] n0;
        logic [63:0] inv;


        n0 = N[63:0];


        // N must be odd, otherwise inverse modulo 2^64 does not exist.
        if (n0[0] !== 1'b1) begin

            `uvm_error(
                get_type_name(),
                $sformatf(
                    "compute_nprime0: N must be odd, N[63:0]=0x%016h",
                    n0
                )
            )

            return 64'd0;

        end


        // Every odd integer is 1 modulo 2.
        // Therefore x=1 is a valid 1-bit inverse starting point.
        inv = 64'd1;


        repeat (6) begin

            // 64-bit truncation is intentional:
            // it implements modulo 2^64 arithmetic.
            inv = inv * (64'd2 - n0 * inv);

        end


        // DUT requires:
        //
        //   -N^-1 mod 2^64
        //
        // Two's complement:
        //
        //   -inv = ~inv + 1
        compute_nprime0 = (~inv) + 64'd1;

    endfunction



    // ========================================================================
    // Golden modular exponentiation
    //
    // Exact flow of the Python RSA_comp.py:
    //
    //   result = M
    //
    //   for remaining bits from exponent MSB to LSB:
    //
    //       result = result * result % N
    //
    //       if bit == 1:
    //           result = result * M % N
    //
    //
    // NOTE:
    //
    // This is NOT Montgomery arithmetic.
    //
    // Montgomery is a DUT implementation detail.
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


        // Modulus 0 is invalid.
        if (mod_n == '0) begin

            result = '0;

            `uvm_error(
                get_type_name(),
                "power_mod_3072: modulus N is zero"
            )

            return;

        end


        // Find highest set bit.
        //
        // Python bin(exponent)[2:] effectively removes leading zeros.
        msb_pos = -1;


        for (int i = RSA_BITS-1; i >= 0; i--) begin

            if (exponent[i] === 1'b1) begin

                msb_pos = i;
                break;

            end

        end


        // Preserve original Python behavior for exponent == 0.
        //
        // Python:
        //
        //   result = M
        //   loop executes zero times
        //
        // So result remains M.
        if (msb_pos < 0) begin

            result = base;
            return;

        end


        // Highest exponent bit is already 1.
        // Python initializes result directly to M.
        res = base;


        // Process all remaining exponent bits.
        for (int i = msb_pos - 1; i >= 0; i--) begin


            // ---------------------------------------------------------------
            // Square:
            //
            //   res = res^2 mod N
            //
            // Explicitly extend operand to 6144 bits so the multiplication
            // cannot accidentally truncate to 3072 bits.
            // ---------------------------------------------------------------

            op_a = {{RSA_BITS{1'b0}}, res};
            op_b = {{RSA_BITS{1'b0}}, res};

            mult_temp = op_a * op_b;

            res = mult_temp % mod_n;


            // ---------------------------------------------------------------
            // Multiply:
            //
            //   if exponent bit == 1:
            //
            //       res = res * base mod N
            // ---------------------------------------------------------------

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
    // RSA math self-test
    //
    // Same idea as sha3_384_self_test()/abc_test:
    //
    // First prove that the TESTBENCH reference implementation is working.
    //
    // If this test fails, DUT testing stops immediately.
    // ========================================================================

    virtual task rsa_math_self_test();

        logic [RSA_BITS-1:0] base;
        logic [RSA_BITS-1:0] exponent;
        logic [RSA_BITS-1:0] modulus;
        logic [RSA_BITS-1:0] result;

        logic [63:0] nprime;
        logic [127:0] nprime_product;

        int error_count;


        error_count = 0;


        `uvm_info(
            get_type_name(),
            "============================================================",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            "RSA MATH SELF TEST START",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            "============================================================",
            UVM_LOW
        )


        // ====================================================================
        // KAT 1
        //
        // 3^5 mod 7 = 5
        // ====================================================================

        base     = '0;
        exponent = '0;
        modulus  = '0;

        base[63:0]     = 64'd3;
        exponent[63:0] = 64'd5;
        modulus[63:0]  = 64'd7;


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
                $sformatf(
                    "RSA SELF TEST KAT1 FAIL: 3^5 mod 7 expected=5 actual=0x%0h",
                    result
                )
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                "RSA SELF TEST KAT1 PASS: 3^5 mod 7 = 5",
                UVM_LOW
            )

        end



        // ====================================================================
        // KAT 2
        //
        // 5^13 mod 17 = 3
        // ====================================================================

        base     = '0;
        exponent = '0;
        modulus  = '0;

        base[63:0]     = 64'd5;
        exponent[63:0] = 64'd13;
        modulus[63:0]  = 64'd17;


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
                $sformatf(
                    "RSA SELF TEST KAT2 FAIL: 5^13 mod 17 expected=3 actual=0x%0h",
                    result
                )
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                "RSA SELF TEST KAT2 PASS: 5^13 mod 17 = 3",
                UVM_LOW
            )

        end



        // ====================================================================
        // KAT 3
        //
        // 10^17 mod 33 = 10
        // ====================================================================

        base     = '0;
        exponent = '0;
        modulus  = '0;

        base[63:0]     = 64'd10;
        exponent[63:0] = 64'd17;
        modulus[63:0]  = 64'd33;


        power_mod_3072(
            base,
            exponent,
            modulus,
            result
        );


        if (result !== 3072'd10) begin

            error_count++;

            `uvm_error(
                get_type_name(),
                $sformatf(
                    "RSA SELF TEST KAT3 FAIL: 10^17 mod 33 expected=10 actual=0x%0h",
                    result
                )
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                "RSA SELF TEST KAT3 PASS: 10^17 mod 33 = 10",
                UVM_LOW
            )

        end



        // ====================================================================
        // KAT 4
        //
        // nprime0 property test
        //
        // nprime0 = -N^-1 mod 2^64
        //
        // Therefore:
        //
        //   N * nprime0 == -1 mod 2^64
        //
        // Low 64 bits must equal:
        //
        //   FFFF_FFFF_FFFF_FFFF
        // ====================================================================

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
                $sformatf(
                    {"RSA NPRIME SELF TEST FAIL\n",
                     "N[63:0]       = 0x%016h\n",
                     "nprime0       = 0x%016h\n",
                     "N*nprime(low) = 0x%016h"},
                    modulus[63:0],
                    nprime,
                    nprime_product[63:0]
                )
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                $sformatf(
                    "RSA NPRIME SELF TEST PASS: nprime0=0x%016h",
                    nprime
                ),
                UVM_LOW
            )

        end



        // ====================================================================
        // Final self-test result
        // ====================================================================

        if (error_count != 0) begin

            `uvm_fatal(
                get_type_name(),
                $sformatf(
                    "RSA MATH SELF TEST FAILED: errors=%0d",
                    error_count
                )
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                "============================================================",
                UVM_LOW
            )

            `uvm_info(
                get_type_name(),
                "RSA MATH SELF TEST: ALL PASS",
                UVM_LOW
            )

            `uvm_info(
                get_type_name(),
                "============================================================",
                UVM_LOW
            )

        end

    endtask



    // ========================================================================
    // Generate one random RSA test vector
    // ========================================================================

    virtual function void generate_test_vector();

        logic [RSA_BITS-1:0] m_candidate;

        logic [127:0] check_nprime;

        int retry_cnt;


        // Debug seed.
        //
        // NOTE:
        // Python and SV do not use the same random generator, so the same seed
        // does not create the exact same vector.
        random_seed = $urandom();


        // ====================================================================
        // Generate N
        //
        // N[3071] = 1 : full 3072-bit modulus
        //
        // N[0] = 1    : N must be odd so inverse modulo 2^64 exists
        // ====================================================================

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
                "Failed to generate RSA N"
            )

        end



        // ====================================================================
        // Generate exponent D
        //
        // Python technically allows 0.
        //
        // For normal functional testing, exclude 0 because exponent 0 is not
        // useful and the original Python itself has a special edge behavior.
        // ====================================================================

        if (
            !std::randomize(d_rsa_priv)
            with {
                d_rsa_priv != '0;
            }
        ) begin

            `uvm_fatal(
                get_type_name(),
                "Failed to generate RSA exponent D"
            )

        end



        // ====================================================================
        // Generate M
        //
        // Python:
        //
        //   randint(2^3071, N)
        //
        // Normal functional random test:
        //
        //   2^3071 <= M < N
        //
        // M == N can be tested separately as a directed edge case.
        // ====================================================================

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
                "Failed to generate RSA M"
            )

        end



        // ====================================================================
        // Compute nprime0 for DUT
        // ====================================================================

        d_nprime0 =
            compute_nprime0(d_rsa_N);



        // ====================================================================
        // nprime0 sanity check
        //
        // Correct relation:
        //
        //   N * nprime0 == -1 mod 2^64
        // ====================================================================

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
                $sformatf(
                    {"Generated nprime0 is invalid\n",
                     "N[63:0]       = 0x%016h\n",
                     "nprime0       = 0x%016h\n",
                     "N*nprime(low) = 0x%016h"},
                    d_rsa_N[63:0],
                    d_nprime0,
                    check_nprime[63:0]
                )
            )

        end



        `uvm_info(
            get_type_name(),
            $sformatf(
                {"RSA VECTOR GENERATED\n",
                 "seed         = 0x%016h\n",
                 "M MSW        = 0x%08h\n",
                 "N MSW        = 0x%08h\n",
                 "D MSW        = 0x%08h\n",
                 "N[63:0]      = 0x%016h\n",
                 "nprime0      = 0x%016h"},
                random_seed,
                d_rsa_M[3071:3040],
                d_rsa_N[3071:3040],
                d_rsa_priv[3071:3040],
                d_rsa_N[63:0],
                d_nprime0
            ),
            UVM_LOW
        )

    endfunction



    // ========================================================================
    // Generate random vector and expected result
    // ========================================================================

    virtual task gen_test_vector(
        input int test_id
    );

        `uvm_info(
            get_type_name(),
            $sformatf(
                "========== RSA TEST VECTOR #%0d ==========",
                test_id
            ),
            UVM_LOW
        )


        // Generate M/N/D + nprime0.
        generate_test_vector();


        // Independent golden result:
        //
        //   expected = M^D mod N
        power_mod_3072(
            d_rsa_M,
            d_rsa_priv,
            d_rsa_N,
            d_expected_result
        );


        `uvm_info(
            get_type_name(),
            $sformatf(
                "Expected result MSW=0x%08h",
                d_expected_result[3071:3040]
            ),
            UVM_LOW
        )

    endtask



    // ========================================================================
    // Common 3072-bit register writer
    //
    // 3072 bits = 96 x 32-bit words
    //
    // Page 1:
    //   word 0 ~ 63
    //
    // Page 2:
    //   word 64 ~ 95
    //
    // Lowest word maps to lowest register offset.
    // ========================================================================

    task automatic write_rsa_3072_reg(
        input string               tag,
        input logic [23:0]         page_addr_1,
        input logic [23:0]         page_addr_2,
        input logic [RSA_BITS-1:0] data
    );

        logic [31:0] ahb_addr;
        logic [31:0] ahb_wdata;

        int word_idx;


        `uvm_info(
            get_type_name(),
            $sformatf("[%s] WRITE START", tag),
            UVM_LOW
        )


        for (
            word_idx = 0;
            word_idx < 96;
            word_idx++
        ) begin


            if (word_idx < 64) begin

                ahb_addr =
                    {page_addr_1, 8'h00}
                    +
                    (word_idx * 4);

            end
            else begin

                ahb_addr =
                    {page_addr_2, 8'h00}
                    +
                    ((word_idx - 64) * 4);

            end


            // Example:
            //
            // word 0 = data[31:0]
            // word 1 = data[63:32]
            ahb_wdata =
                data[word_idx*32 +: 32];


            ahb_word_write(
                ahb_addr[31:8],
                ahb_addr[7:0],
                ahb_wdata
            );

        end


        `uvm_info(
            get_type_name(),
            $sformatf("[%s] WRITE COMPLETE", tag),
            UVM_LOW
        )

    endtask



    // ========================================================================
    // Common 3072-bit readback check
    // ========================================================================

    task automatic check_rsa_3072_reg(
        input string               tag,
        input logic [23:0]         page_addr_1,
        input logic [23:0]         page_addr_2,
        input logic [RSA_BITS-1:0] expected
    );

        logic [31:0] ahb_addr;
        logic [31:0] ahb_rdata;
        logic [31:0] expected_data;

        int word_idx;
        int error_count;


        error_count = 0;


        for (
            word_idx = 0;
            word_idx < 96;
            word_idx++
        ) begin


            if (word_idx < 64) begin

                ahb_addr =
                    {page_addr_1, 8'h00}
                    +
                    (word_idx * 4);

            end
            else begin

                ahb_addr =
                    {page_addr_2, 8'h00}
                    +
                    ((word_idx - 64) * 4);

            end


            expected_data =
                expected[word_idx*32 +: 32];


            ahb_word_read(
                ahb_addr[31:8],
                ahb_addr[7:0],
                ahb_rdata
            );


            if (ahb_rdata !== expected_data) begin

                error_count++;

                `uvm_error(
                    get_type_name(),
                    $sformatf(
                        {"[%s] READBACK ERROR\n",
                         "word     = %0d\n",
                         "addr     = 0x%08h\n",
                         "expected = 0x%08h\n",
                         "actual   = 0x%08h"},
                        tag,
                        word_idx,
                        ahb_addr,
                        expected_data,
                        ahb_rdata
                    )
                )

            end

        end


        if (error_count == 0) begin

            `uvm_info(
                get_type_name(),
                $sformatf(
                    "[%s] READBACK PASS",
                    tag
                ),
                UVM_LOW
            )

        end
        else begin

            `uvm_fatal(
                get_type_name(),
                $sformatf(
                    "[%s] READBACK FAIL errors=%0d",
                    tag,
                    error_count
                )
            )

        end

    endtask



    // ========================================================================
    // Write M/C
    // ========================================================================

    task write_rsa_M(
        input logic [RSA_BITS-1:0] rsa_M
    );

        write_rsa_3072_reg(
            "RSA M",
            m_host_top_cfg.rsa_c_page_addr_1,
            m_host_top_cfg.rsa_c_page_addr_2,
            rsa_M
        );


        check_rsa_3072_reg(
            "RSA M",
            m_host_top_cfg.rsa_c_page_addr_1,
            m_host_top_cfg.rsa_c_page_addr_2,
            rsa_M
        );

    endtask



    // ========================================================================
    // Write N
    // ========================================================================

    task write_rsa_N(
        input logic [RSA_BITS-1:0] rsa_N
    );

        write_rsa_3072_reg(
            "RSA N",
            m_host_top_cfg.rsa_n_page_addr_1,
            m_host_top_cfg.rsa_n_page_addr_2,
            rsa_N
        );


        check_rsa_3072_reg(
            "RSA N",
            m_host_top_cfg.rsa_n_page_addr_1,
            m_host_top_cfg.rsa_n_page_addr_2,
            rsa_N
        );

    endtask



    // ========================================================================
    // Write D / private exponent
    // ========================================================================

    task write_rsa_priv_key(
        input logic [RSA_BITS-1:0] rsa_priv_key
    );

        write_rsa_3072_reg(
            "RSA D",
            m_host_top_cfg.rsa_d_page_addr_1,
            m_host_top_cfg.rsa_d_page_addr_2,
            rsa_priv_key
        );


        check_rsa_3072_reg(
            "RSA D",
            m_host_top_cfg.rsa_d_page_addr_1,
            m_host_top_cfg.rsa_d_page_addr_2,
            rsa_priv_key
        );

    endtask



    // ========================================================================
    // Write nprime0
    //
    // Excel:
    //
    //   offset 0x00 = nprime0 byte 0 / LSB
    //   ...
    //   offset 0x07 = nprime0 byte 7 / MSB
    //
    // Therefore 64-bit nprime0 is written using two 32-bit accesses:
    //
    //   +0x00 -> nprime0[31:0]
    //   +0x04 -> nprime0[63:32]
    // ========================================================================

    task write_rsa_nprime_to_dut(
        input logic [63:0] nprime0
    );

        logic [23:0] base_addr_h;

        logic [31:0] wdata;
        logic [31:0] rdata;

        int word_idx;


        base_addr_h =
            m_host_top_cfg.rsa_nprime0_aes_page_addr;


        `uvm_info(
            get_type_name(),
            $sformatf(
                "[RSA NPRIME] write 0x%016h",
                nprime0
            ),
            UVM_LOW
        )


        // Write low 32-bit and high 32-bit.
        for (
            word_idx = 0;
            word_idx < 2;
            word_idx++
        ) begin

            wdata =
                nprime0[word_idx*32 +: 32];


            ahb_word_write(
                base_addr_h,
                word_idx * 4,
                wdata
            );

        end


        // Readback verification.
        for (
            word_idx = 0;
            word_idx < 2;
            word_idx++
        ) begin

            ahb_word_read(
                base_addr_h,
                word_idx * 4,
                rdata
            );


            if (
                rdata
                !==
                nprime0[word_idx*32 +: 32]
            ) begin

                `uvm_fatal(
                    get_type_name(),
                    $sformatf(
                        {"[RSA NPRIME] READBACK FAIL\n",
                         "word     = %0d\n",
                         "expected = 0x%08h\n",
                         "actual   = 0x%08h"},
                        word_idx,
                        nprime0[word_idx*32 +: 32],
                        rdata
                    )
                )

            end

        end


        `uvm_info(
            get_type_name(),
            "[RSA NPRIME] READBACK PASS",
            UVM_LOW
        )

    endtask



    // ========================================================================
    // Program all confirmed DUT parameters
    //
    // IMPORTANT:
    //
    // We intentionally program only:
    //
    //   M
    //   N
    //   D
    //   nprime0
    //
    // R/T are not programmed here until original RTL/APB flow confirms SW
    // needs to write them.
    // ========================================================================

    virtual task write_rsa_params_to_dut();

        write_rsa_M(
            d_rsa_M
        );


        write_rsa_N(
            d_rsa_N
        );


        write_rsa_priv_key(
            d_rsa_priv
        );


        write_rsa_nprime_to_dut(
            d_nprime0
        );


        `uvm_info(
            get_type_name(),
            "RSA M/N/D/nprime0 programming complete",
            UVM_LOW
        )

    endtask



    // ========================================================================
    // Start RSA
    //
    // Excel:
    //
    // nprime/AES page
    //
    // offset 0x08 bit[7]:
    //
    //   startCompute
    //
    //   write 1 -> start
    //
    //   auto clear when done
    // ========================================================================

    virtual task write_rsa_start();

        logic [31:0] ahb_addr;
        logic [31:0] ahb_wdata;


        ahb_addr = {
            m_host_top_cfg.rsa_nprime0_aes_page_addr,
            8'h08
        };


        // bit[7] = startCompute
        ahb_wdata = 32'h0000_0080;


        `uvm_info(
            get_type_name(),
            $sformatf(
                "RSA START: addr=0x%08h data=0x%08h",
                ahb_addr,
                ahb_wdata
            ),
            UVM_LOW
        )


        ahb_word_write(
            ahb_addr[31:8],
            ahb_addr[7:0],
            ahb_wdata
        );

    endtask



    // ========================================================================
    // Wait RSA complete
    //
    // Keep the same timed polling style as your existing reference test.
    //
    // max_poll_count is therefore a polling count, not literal clock cycles.
    // ========================================================================

    virtual task wait_rsa_compute_done(
        input int max_poll_count
    );

        int poll_count;


        poll_count = 0;


        `uvm_info(
            get_type_name(),
            "Waiting for RSA complete_s...",
            UVM_LOW
        )


        while (
            (`DUT_COMPLETE !== 1'b1)
            &&
            (poll_count < max_poll_count)
        ) begin

            #160ns;

            poll_count++;

        end


        if (poll_count >= max_poll_count) begin

            `uvm_fatal(
                get_type_name(),
                "RSA compute TIMEOUT: complete_s never asserted"
            )

        end


        `uvm_info(
            get_type_name(),
            $sformatf(
                "RSA compute DONE, poll_count=%0d",
                poll_count
            ),
            UVM_LOW
        )

    endtask



    // ========================================================================
    // Read result
    //
    // Keep the same white-box read path as your existing reference:
    //
    //   ModExp.m_bar
    //
    // This avoids inventing unconfirmed result-register cfg names.
    //
    // Once the functional flow passes, you can add an architectural AHB
    // M_BAR read test separately.
    // ========================================================================

    virtual task read_rsa_result_from_dut();


        if (`DUT_COMPLETE !== 1'b1) begin

            `uvm_error(
                get_type_name(),
                "DUT complete_s is not 1 when reading RSA result"
            )

        end


        d_dut_result =
            `DUT_MOD_EXP.m_bar;


        `uvm_info(
            get_type_name(),
            $sformatf(
                "DUT m_bar MSW = 0x%08h",
                d_dut_result[3071:3040]
            ),
            UVM_LOW
        )

    endtask



    // ========================================================================
    // Compare
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
                    "RSA PASS test=%0d seed=0x%016h",
                    test_id,
                    random_seed
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
                     "seed     = 0x%016h\n",
                     "M        = 0x%0h\n",
                     "N        = 0x%0h\n",
                     "D        = 0x%0h\n",
                     "nprime0  = 0x%016h\n",
                     "Expected = 0x%0h\n",
                     "Actual   = 0x%0h"},
                    test_id,
                    random_seed,
                    d_rsa_M,
                    d_rsa_N,
                    d_rsa_priv,
                    d_nprime0,
                    d_expected_result,
                    d_dut_result
                )
            )


            // Find first mismatch from MSB side.
            for (
                int nibble = 768;
                nibble >= 1;
                nibble--
            ) begin

                if (
                    d_expected_result[nibble*4-1 -: 4]
                    !==
                    d_dut_result[nibble*4-1 -: 4]
                ) begin

                    `uvm_info(
                        get_type_name(),
                        $sformatf(
                            {"First mismatch:\n",
                             "nibble=%0d\n",
                             "bit[%0d:%0d]\n",
                             "expected=0x%h actual=0x%h"},
                            nibble-1,
                            nibble*4-1,
                            nibble*4-4,
                            d_expected_result[nibble*4-1 -: 4],
                            d_dut_result[nibble*4-1 -: 4]
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
    // Run one complete RSA test
    //
    // Generate
    //   ->
    // Write M/N/D/nprime0
    //   ->
    // Start
    //   ->
    // Wait
    //   ->
    // Read m_bar
    //   ->
    // Compare
    // ========================================================================

    virtual task run_rsa_one_test(
        input int test_id
    );


        `uvm_info(
            get_type_name(),
            $sformatf(
                "========== RSA TEST #%0d START ==========",
                test_id
            ),
            UVM_LOW
        )


        // 1. Generate random input + golden result.
        gen_test_vector(
            test_id
        );


        // 2. Write all confirmed DUT inputs.
        write_rsa_params_to_dut();


        // 3. Start RSA.
        write_rsa_start();


        // 4. Wait complete.
        wait_rsa_compute_done(
            50_000_000
        );


        // 5. Read result.
        read_rsa_result_from_dut();


        // 6. Compare.
        compare_result(
            test_id
        );


        `uvm_info(
            get_type_name(),
            $sformatf(
                "========== RSA TEST #%0d END ==========",
                test_id
            ),
            UVM_LOW
        )

    endtask



    // ========================================================================
    // Run phase
    // ========================================================================

    virtual task run_phase(
        uvm_phase phase
    );

        int num_tests;


        // Start from one test because 3072-bit '%' operations are expensive.
        num_tests = 1;


        phase.raise_objection(this);


        // ====================================================================
        // STEP 0:
        //
        // Verify testbench math BEFORE testing DUT.
        //
        // Same idea as SHA abc_test.
        // ====================================================================

        rsa_math_self_test();


        // ====================================================================
        // Existing MCU / host initialization
        // ====================================================================

        mcu_test_preset();


        `uvm_info(
            get_type_name(),
            $sformatf(
                "Starting RSA-3072 verification: %0d tests",
                num_tests
            ),
            UVM_LOW
        )


        `uvm_info(
            get_type_name(),
            "Golden model: plain MSB-first Square-and-Multiply, M^D mod N",
            UVM_LOW
        )


        `uvm_info(
            get_type_name(),
            "DUT parameter: nprime0 = -N^-1 mod 2^64",
            UVM_LOW
        )


        for (
            int test_id = 0;
            test_id < num_tests;
            test_id++
        ) begin

            run_rsa_one_test(
                test_id
            );

        end



        // ====================================================================
        // Summary
        // ====================================================================

        `uvm_info(
            get_type_name(),
            "============================================================",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            "MCU RSA VERIFICATION SUMMARY",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            "============================================================",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            $sformatf(
                "Total      : %0d",
                total_tests
            ),
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            $sformatf(
                "Match      : %0d",
                match_count
            ),
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            $sformatf(
                "Mismatch   : %0d",
                mismatch_count
            ),
            UVM_LOW
        )


        if (mismatch_count == 0) begin

            `uvm_info(
                get_type_name(),
                "RESULT: ALL RSA TESTS PASSED",
                UVM_LOW
            )

        end
        else begin

            `uvm_error(
                get_type_name(),
                $sformatf(
                    "RESULT: %0d RSA TEST(S) FAILED",
                    mismatch_count
                )
            )

        end


        phase.drop_objection(this);

    endtask


endclass : mcu_rsa_test
