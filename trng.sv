// ============================================================================
// mcu_trng_test.sv
//
// TRNG Manual Mode Verification
//
// 依照目前確認過的 RTL / Register 行為：
//
//   1. FIGA enable
//      assign figa_enable = reg_04_ctrl[7];
//
//   2. Health debug input
//      health_debug_mode 0 -> 1
//              |
//              v
//      debug_trng_data <= SW_TRNG_DATA
//
//      health debug mode 維持 1 時：
//      debug_trng_data 每個 clock rotate 8-bit。
//      Health-test 實際吃 debug_trng_data[7:0]。
//
//   3. Conditioning input
//
//      trng_data_select =
//          conditioning_random_number_debug_mode ?
//              SW_TRNG_DATA :
//              trng_data[511:0];
//
//      所以 conditioning debug 不需要 0->1 capture pulse。
//
//   4. Startup FSM
//
//      IDLE
//        |
//        | figa_enable == 1
//        | bypass_start_test == 0
//        | start_test_counter == start_test_threshold
//        v
//      START_TEST
//        |
//        | adaptation_test_block_counter == 127
//        | no startup error
//        v
//      HEALTH_TEST
//
//   5. bypass_start_test == 1
//
//      IDLE -> HEALTH_TEST
//
//   6. conditioning_valid
//
//      trng_req_sw
//      && trng_cs == TRNG_HEALTH_TEST
//      && !health_test_fail
//      && !trng_debug_mode
//
//   7. conditioning_finish
//
//      conditioning_done
//      && trng_cs == TRNG_HEALTH_TEST
//      && !health_test_fail
//      && !trng_debug_mode
//
// ============================================================================

class mcu_trng_test extends host_base_test;

    `uvm_component_utils(mcu_trng_test)


    // ========================================================================
    // Register word address
    //
    // byte offset = word_addr << 2
    // ========================================================================

    localparam bit [5:0] TRNG_FIGA_CTRL            = 6'h04; // 0x10
    localparam bit [5:0] TRNG_CTRL                 = 6'h05; // 0x14
    localparam bit [5:0] TRNG_FIGA_OUT_SEL         = 6'h06; // 0x18
    localparam bit [5:0] TRNG_SW_FIGA_ENABLE_MODE  = 6'h07; // 0x1C
    localparam bit [5:0] TRNG_SW_FIGA_LOCAL_ENABLE = 6'h08; // 0x20

    localparam bit [5:0] TRNG_REQ_SW               = 6'h09; // 0x24

    localparam bit [5:0] TRNG_CLEAR_FAIL_STATE     = 6'h0A; // 0x28
    localparam bit [5:0] TRNG_CLEAR_START_FINISH   = 6'h0B; // 0x2C
    localparam bit [5:0] TRNG_CLEAR_COND_FINISH    = 6'h0C; // 0x30

    localparam bit [5:0] TRNG_BYPASS_START_TEST    = 6'h0D; // 0x34

    localparam bit [5:0] TRNG_START_THRESHOLD      = 6'h0E; // 0x38
    localparam bit [5:0] TRNG_REP_THRESHOLD        = 6'h0F; // 0x3C
    localparam bit [5:0] TRNG_ADAPT_THRESHOLD      = 6'h10; // 0x40

    localparam bit [5:0] TRNG_SW_RESET             = 6'h11; // 0x44

    localparam bit [5:0] TRNG_DEBUG_MODE           = 6'h12; // 0x48
    localparam bit [5:0] TRNG_HEALTH_DEBUG_MODE    = 6'h13; // 0x4C
    localparam bit [5:0] TRNG_COND_DEBUG_MODE      = 6'h14; // 0x50

    localparam bit [5:0] TRNG_STATUS               = 6'h15; // 0x54

    // Conditioning random number readback
    localparam bit [5:0] TRNG_RANDOM_31_0          = 6'h18;
    localparam bit [5:0] TRNG_RANDOM_63_32         = 6'h19;
    localparam bit [5:0] TRNG_RANDOM_95_64         = 6'h1A;
    localparam bit [5:0] TRNG_RANDOM_127_96        = 6'h1B;

    // SW_TRNG_DATA[511:0]
    localparam bit [5:0] TRNG_SW_DATA_BASE         = 6'h20;


    // ========================================================================
    // STATUS[7:0]
    // ========================================================================

    localparam int START_REP_ONE_FAIL_BIT  = 7;
    localparam int START_REP_ZERO_FAIL_BIT = 6;
    localparam int START_ADAPT_FAIL_BIT    = 5;

    localparam int REP_ONE_FAIL_BIT        = 4;
    localparam int REP_ZERO_FAIL_BIT       = 3;
    localparam int ADAPT_FAIL_BIT          = 2;

    localparam int START_FINISH_BIT        = 1;
    localparam int COND_FINISH_BIT         = 0;


    // ========================================================================
    // STATUS 其他 field
    //
    // 由 register RTL concat 推回：
    //
    // [31:27] reserved
    // [26:24] trng_cs
    // [23:19] reserved
    // [18:8]  adaptation_test_fail_value
    // [7:0]   health / finish status
    // ========================================================================

    localparam int TRNG_CS_MSB = 26;
    localparam int TRNG_CS_LSB = 24;


    // ========================================================================
    // 原 legacy test / RTL threshold
    // ========================================================================

    localparam bit [31:0] START_THRESHOLD_VALUE = 32'd300;
    localparam bit [31:0] REP_THRESHOLD_VALUE   = 32'd35;
    localparam bit [31:0] ADAPT_THRESHOLD_VALUE = 32'd748;


    // ========================================================================
    // Timeout
    // ========================================================================

    localparam int TRNG_TIMEOUT_CYCLE = 20000;


    // ========================================================================
    // Test variables
    // ========================================================================

    bit [31:0]  status;

    bit [511:0] normal_data;
    bit [511:0] rep_one_data;
    bit [511:0] rep_zero_data;
    bit [511:0] adaptive_data;

    bit [511:0] conditioning_data;

    bit [127:0] conditioning_result;


    // ========================================================================
    // Constructor
    // ========================================================================

    function new(
        string name = "mcu_trng_test",
        uvm_component parent = null
    );

        super.new(name, parent);

    endfunction


    // ========================================================================
    // build_phase
    // ========================================================================

    virtual function void build_phase(uvm_phase phase);

        super.build_phase(phase);

    endfunction


    // ========================================================================
    // Register write wrapper
    // ========================================================================

    virtual task trng_write(
        input bit [5:0]  word_addr,
        input bit [31:0] data
    );

        `uvm_info(
            "TRNG_REG",
            $sformatf(
                "WRITE word=0x%02h byte_offset=0x%02h data=0x%08h",
                word_addr,
                {word_addr, 2'b00},
                data
            ),
            UVM_HIGH
        )


        ahb_word_write(
            host_top_cfg.trng_page_addr,
            word_addr,
            2'd0,
            data
        );

    endtask


    // ========================================================================
    // Register read wrapper
    // ========================================================================

    virtual task trng_read(
        input  bit [5:0]  word_addr,
        output bit [31:0] data
    );

        ahb_word_read(
            host_top_cfg.trng_page_addr,
            word_addr,
            2'd0,
            data
        );


        `uvm_info(
            "TRNG_REG",
            $sformatf(
                "READ word=0x%02h byte_offset=0x%02h data=0x%08h",
                word_addr,
                {word_addr, 2'b00},
                data
            ),
            UVM_HIGH
        )

    endtask


    // ========================================================================
    // 建立 deterministic pattern
    // ========================================================================

    virtual task build_test_pattern();

        // --------------------------------------------------------------------
        // Normal data
        //
        // AA = 10101010
        //
        // 特性：
        //
        // 1/0 比例完全 50/50。
        // 最大連續 1 = 1。
        // 最大連續 0 = 1。
        //
        // 對 repetition threshold=35 非常安全。
        //
        // 1024-bit adaptive window：
        //
        // one_count = 512
        //
        // PASS range：
        //
        // 1024 - 748 = 276
        //
        // 276 <= 512 <= 748
        //
        // 所以理論上必須 PASS。
        // --------------------------------------------------------------------

        normal_data = {64{8'hAA}};


        // --------------------------------------------------------------------
        // Repetition-one
        //
        // FF FF FF ...
        //
        // 會產生大量連續 1。
        // --------------------------------------------------------------------

        rep_one_data = {64{8'hFF}};


        // --------------------------------------------------------------------
        // Repetition-zero
        //
        // 00 00 00 ...
        // --------------------------------------------------------------------

        rep_zero_data = {64{8'h00}};


        // --------------------------------------------------------------------
        // Adaptive fail
        //
        // EE = 1110_1110
        //
        // one ratio = 75%
        //
        // 1024 * 75% = 768
        //
        // 768 > threshold 748
        //
        // 所以理論上觸發 adaptive fail。
        //
        // 但最大連續 1 只有 3，
        // 低於 repetition threshold 35。
        // --------------------------------------------------------------------

        adaptive_data = {64{8'hEE}};


        // --------------------------------------------------------------------
        // Conditioning input
        //
        // conditioning debug mode 直接 mux SW_TRNG_DATA。
        //
        // 這裡使用固定 pattern，
        // 方便 waveform debug。
        // --------------------------------------------------------------------

        conditioning_data = {
            32'h0123_4567,
            32'h89AB_CDEF,
            32'h1020_3040,
            32'h5060_7080,

            32'h1122_3344,
            32'h5566_7788,
            32'h99AA_BBCC,
            32'hDDEE_FF00,

            32'hCAFE_BABE,
            32'hDEAD_BEEF,
            32'h1357_9BDF,
            32'h2468_ACE0,

            32'hA5A5_5A5A,
            32'h0F0F_F0F0,
            32'h55AA_33CC,
            32'hC3C3_3C3C
        };

    endtask


    // ========================================================================
    // Read TRNG status
    // ========================================================================

    virtual task read_status(
        output bit [31:0] data
    );

        trng_read(
            TRNG_STATUS,
            data
        );

    endtask


    // ========================================================================
    // Print status decode
    // ========================================================================

    virtual task print_status(
        input string tag = "TRNG_STATUS"
    );

        read_status(status);


        `uvm_info(
            tag,
            $sformatf(
                {"status=0x%08h  "
                 "cs=0x%0h  "
                 "start_rep1=%0b start_rep0=%0b start_adapt=%0b  "
                 "rep1=%0b rep0=%0b adapt=%0b  "
                 "start_finish=%0b cond_finish=%0b  "
                 "adapt_fail_value=%0d"},
                status,
                status[TRNG_CS_MSB:TRNG_CS_LSB],
                status[START_REP_ONE_FAIL_BIT],
                status[START_REP_ZERO_FAIL_BIT],
                status[START_ADAPT_FAIL_BIT],
                status[REP_ONE_FAIL_BIT],
                status[REP_ZERO_FAIL_BIT],
                status[ADAPT_FAIL_BIT],
                status[START_FINISH_BIT],
                status[COND_FINISH_BIT],
                status[18:8]
            ),
            UVM_LOW
        )

    endtask


    // ========================================================================
    // Write SW_TRNG_DATA
    // ========================================================================

    virtual task write_sw_trng_data(
        input bit [511:0] data
    );

        for (int i = 0; i < 16; i++) begin

            trng_write(
                TRNG_SW_DATA_BASE + i,
                data[i*32 +: 32]
            );

        end

    endtask


    // ========================================================================
    // Enable / Disable FIGA
    //
    // RTL：
    //
    // assign figa_enable = reg_04_ctrl[7];
    //
    // 所以：
    //
    // enable = 0x80
    // disable = 0x00
    // ========================================================================

    virtual task set_figa_enable(
        input bit enable
    );

        if (enable) begin

            trng_write(
                TRNG_FIGA_CTRL,
                32'h0000_0080
            );

        end
        else begin

            trng_write(
                TRNG_FIGA_CTRL,
                32'h0000_0000
            );

        end

    endtask


    // ========================================================================
    // TRNG software reset pulse
    // ========================================================================

    virtual task trng_sw_reset();

        trng_write(
            TRNG_SW_RESET,
            32'h1
        );


        repeat(4)
            @(posedge system.sscg_clk);

    endtask


    // ========================================================================
    // Clear command
    // ========================================================================

    virtual task clear_fail_state();

        trng_write(
            TRNG_CLEAR_FAIL_STATE,
            32'h1
        );

    endtask


    virtual task clear_start_finish();

        trng_write(
            TRNG_CLEAR_START_FINISH,
            32'h1
        );

    endtask


    virtual task clear_conditioning_finish();

        trng_write(
            TRNG_CLEAR_COND_FINISH,
            32'h1
        );

    endtask


    virtual task clear_all_status();

        clear_fail_state();

        clear_start_finish();

        clear_conditioning_finish();


        repeat(3)
            @(posedge system.sscg_clk);

    endtask


    // ========================================================================
    // Restore normal threshold
    // ========================================================================

    virtual task restore_threshold();

        trng_write(
            TRNG_START_THRESHOLD,
            START_THRESHOLD_VALUE
        );

        trng_write(
            TRNG_REP_THRESHOLD,
            REP_THRESHOLD_VALUE
        );

        trng_write(
            TRNG_ADAPT_THRESHOLD,
            ADAPT_THRESHOLD_VALUE
        );

    endtask


    // ========================================================================
    // Health Debug Data Loader
    //
    // RTL 已確認：
    //
    // health_test_debug_mode 0 -> 1 時，
    //
    // debug_trng_data <= SW_TRNG_DATA
    //
    // 因此順序一定必須：
    //
    // 1. mode = 0
    // 2. write SW_TRNG_DATA
    // 3. mode = 1
    //
    // Pattern 全部使用相同 byte repeated，
    // 因此後續 8-bit rotate 不影響內容。
    // ========================================================================

    virtual task load_health_debug_data(
        input bit [511:0] data
    );

        // 一定先回 0。
        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h0
        );


        repeat(2)
            @(posedge system.sscg_clk);


        // Data 必須在 rising pulse 前先準備完成。
        write_sw_trng_data(
            data
        );


        repeat(2)
            @(posedge system.sscg_clk);


        // 0 -> 1
        //
        // 產生 health debug capture pulse。
        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h1
        );


        repeat(2)
            @(posedge system.sscg_clk);

    endtask


    // ========================================================================
    // Common case preparation
    //
    // 每個 case 都重新 reset TRNG internal state，
    // 避免上一個 test 的 counter / FSM / sticky flag 干擾下一個 case。
    // ========================================================================

    virtual task prepare_case(
        input bit bypass_start_test
    );

        // ------------------------------------------------------------
        // 先關 FIGA。
        //
        // 避免 configuration 還沒設完 FSM 就開始跑。
        // ------------------------------------------------------------

        set_figa_enable(1'b0);


        // ------------------------------------------------------------
        // Reset internal TRNG state。
        // ------------------------------------------------------------

        trng_sw_reset();


        // ------------------------------------------------------------
        // 關所有 debug path。
        // ------------------------------------------------------------

        trng_write(
            TRNG_DEBUG_MODE,
            32'h0
        );

        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h0
        );

        trng_write(
            TRNG_COND_DEBUG_MODE,
            32'h0
        );


        // ------------------------------------------------------------
        // 原本額外 FIGA control 保持 legacy setting。
        // ------------------------------------------------------------

        trng_write(
            TRNG_CTRL,
            32'h0
        );

        trng_write(
            TRNG_FIGA_OUT_SEL,
            32'h0
        );

        trng_write(
            TRNG_SW_FIGA_ENABLE_MODE,
            32'h0
        );

        trng_write(
            TRNG_SW_FIGA_LOCAL_ENABLE,
            32'h0
        );


        // ------------------------------------------------------------
        // Normal thresholds。
        // ------------------------------------------------------------

        restore_threshold();


        // ------------------------------------------------------------
        // Startup bypass mode。
        // ------------------------------------------------------------

        trng_write(
            TRNG_BYPASS_START_TEST,
            bypass_start_test
        );


        clear_all_status();

    endtask


    // ========================================================================
    // Wait normal startup test finish
    //
    // 正常 case：
    //
    // expected:
    //
    // start_test_finish = 1
    // 所有 error = 0
    //
    // 如果 error 先出現，不要繼續 polling 20000 次，
    // 直接 fatal 把真正 status 印出來。
    // ========================================================================

    virtual task wait_normal_start_finish();

        bit done;

        done = 0;


        for (int i = 0; i < TRNG_TIMEOUT_CYCLE; i++) begin

            read_status(status);


            // 正常進 HEALTH_TEST。
            if (status[START_FINISH_BIT] === 1'b1) begin

                done = 1;

                break;

            end


            // Normal pattern 不可以有任何 health error。
            if (status[7:2] !== 6'b0) begin

                print_status(
                    "NORMAL_START_FAIL"
                );

                `uvm_fatal(
                    "TRNG_NORMAL",
                    "Normal startup health test unexpectedly failed"
                )

            end


            @(posedge system.sscg_clk);

        end


        if (!done) begin

            print_status(
                "START_TIMEOUT"
            );

            `uvm_fatal(
                "TRNG_TIMEOUT",
                "Timeout waiting for start_test_finish"
            )

        end


        // finish 之後再確認一次。
        if (status[7:2] !== 6'b0) begin

            print_status(
                "START_FINISH_ERROR"
            );

            `uvm_fatal(
                "TRNG_NORMAL",
                "Health error found after start_test_finish"
            )

        end

    endtask


    // ========================================================================
    // Generic wait error flag
    // ========================================================================

    virtual task wait_error_flag(
        input int bit_idx,
        input string flag_name
    );

        bit hit;

        hit = 0;


        for (int i = 0; i < TRNG_TIMEOUT_CYCLE; i++) begin

            read_status(status);


            if (status[bit_idx] === 1'b1) begin

                hit = 1;

                break;

            end


            @(posedge system.sscg_clk);

        end


        if (!hit) begin

            print_status(
                "ERROR_TIMEOUT"
            );

            `uvm_fatal(
                "TRNG_ERROR_TIMEOUT",
                $sformatf(
                    "Expected flag %s did not assert",
                    flag_name
                )
            )

        end


        `uvm_info(
            "TRNG_ERROR",
            $sformatf(
                "%s asserted correctly, status=0x%08h",
                flag_name,
                status
            ),
            UVM_LOW
        )

    endtask


    // ========================================================================
    // Check health error all clear
    // ========================================================================

    virtual task check_health_error_clear();

        read_status(status);


        if (status[7:2] !== 6'b0) begin

            print_status(
                "CLEAR_FAIL"
            );

            `uvm_error(
                "TRNG_CLEAR",
                "Health error flags are not cleared"
            )

        end
        else begin

            `uvm_info(
                "TRNG_CLEAR",
                "All health error flags are clear",
                UVM_LOW
            )

        end

    endtask


    // ========================================================================
    // Read conditioning result
    // ========================================================================

    virtual task read_conditioning_result(
        output bit [127:0] result
    );

        bit [31:0] d0;
        bit [31:0] d1;
        bit [31:0] d2;
        bit [31:0] d3;


        trng_read(
            TRNG_RANDOM_31_0,
            d0
        );

        trng_read(
            TRNG_RANDOM_63_32,
            d1
        );

        trng_read(
            TRNG_RANDOM_95_64,
            d2
        );

        trng_read(
            TRNG_RANDOM_127_96,
            d3
        );


        result = {
            d3,
            d2,
            d1,
            d0
        };


        `uvm_info(
            "TRNG_RANDOM",
            $sformatf(
                "conditioning_random_number = 0x%032h",
                result
            ),
            UVM_LOW
        )

    endtask


    // ========================================================================
    // CASE 1
    //
    // VPlan:
    //
    // Use manual mode to test health test function works properly.
    //
    // Normal startup health test。
    // ========================================================================

    virtual task test_health_normal();

        `uvm_info(
            "TRNG_CASE",
            "==================================================",
            UVM_LOW
        )

        `uvm_info(
            "TRNG_CASE",
            "CASE 1 : NORMAL MANUAL HEALTH TEST",
            UVM_LOW
        )


        prepare_case(
            1'b0
        );


        // ------------------------------------------------------------
        // 先把 AA pattern capture 到 debug_trng_data。
        //
        // 此時 FIGA 還是 disable，
        // 所以 START_TEST 不會偷跑。
        // ------------------------------------------------------------

        load_health_debug_data(
            normal_data
        );


        // ------------------------------------------------------------
        // 所有設定完成後最後才 enable FIGA。
        //
        // FSM：
        //
        // IDLE
        //   -> start counter
        //   -> START_TEST
        //   -> HEALTH_TEST
        // ------------------------------------------------------------

        set_figa_enable(
            1'b1
        );


        wait_normal_start_finish();


        check_health_error_clear();


        print_status(
            "NORMAL_HEALTH_PASS"
        );


        `uvm_info(
            "TRNG_CASE",
            "CASE 1 PASS",
            UVM_LOW
        )

    endtask


    // ========================================================================
    // CASE 2
    //
    // Startup repetition-one error
    // ========================================================================

    virtual task test_start_rep_one_error();

        `uvm_info(
            "TRNG_CASE",
            "CASE 2 : START REPETITION-ONE ERROR",
            UVM_LOW
        )


        prepare_case(
            1'b0
        );


        load_health_debug_data(
            rep_one_data
        );


        set_figa_enable(
            1'b1
        );


        wait_error_flag(
            START_REP_ONE_FAIL_BIT,
            "start_repetition_one_test_fail"
        );


        // ------------------------------------------------------------
        // START_TEST 到 block counter=127 後會因 startup fail 回 IDLE。
        //
        // 先關 FIGA，避免 IDLE 後重新開始下一輪 startup。
        // ------------------------------------------------------------

        set_figa_enable(
            1'b0
        );


        repeat(300)
            @(posedge system.sscg_clk);


        // ------------------------------------------------------------
        // 驗一次 clear_fail_state 的 software-visible 行為。
        // ------------------------------------------------------------

        clear_fail_state();


        repeat(3)
            @(posedge system.sscg_clk);


        check_health_error_clear();

    endtask


    // ========================================================================
    // CASE 3
    //
    // Startup repetition-zero error
    // ========================================================================

    virtual task test_start_rep_zero_error();

        `uvm_info(
            "TRNG_CASE",
            "CASE 3 : START REPETITION-ZERO ERROR",
            UVM_LOW
        )


        prepare_case(
            1'b0
        );


        load_health_debug_data(
            rep_zero_data
        );


        set_figa_enable(
            1'b1
        );


        wait_error_flag(
            START_REP_ZERO_FAIL_BIT,
            "start_repetition_zero_test_fail"
        );

    endtask


    // ========================================================================
    // CASE 4
    //
    // Startup adaptive error
    //
    // EE repeated:
    //
    // one-count = 768 / 1024
    // threshold = 748
    //
    // 最大 run = 3，所以不容易撞 repetition threshold=35。
    // ========================================================================

    virtual task test_start_adaptive_error();

        `uvm_info(
            "TRNG_CASE",
            "CASE 4 : START ADAPTATION ERROR",
            UVM_LOW
        )


        prepare_case(
            1'b0
        );


        load_health_debug_data(
            adaptive_data
        );


        set_figa_enable(
            1'b1
        );


        wait_error_flag(
            START_ADAPT_FAIL_BIT,
            "start_adaptation_test_fail"
        );


        `uvm_info(
            "TRNG_ADAPT",
            $sformatf(
                "adaptation_test_fail_value = %0d",
                status[18:8]
            ),
            UVM_LOW
        )

    endtask


    // ========================================================================
    // CASE 5
    //
    // Runtime repetition-one error
    //
    // bypass_start_test=1:
    //
    // IDLE -> HEALTH_TEST
    // ========================================================================

    virtual task test_rep_one_error();

        `uvm_info(
            "TRNG_CASE",
            "CASE 5 : RUNTIME REPETITION-ONE ERROR",
            UVM_LOW
        )


        prepare_case(
            1'b1
        );


        load_health_debug_data(
            rep_one_data
        );


        set_figa_enable(
            1'b1
        );


        wait_error_flag(
            REP_ONE_FAIL_BIT,
            "repetition_one_test_fail"
        );

    endtask


    // ========================================================================
    // CASE 6
    //
    // Runtime repetition-zero error
    // ========================================================================

    virtual task test_rep_zero_error();

        `uvm_info(
            "TRNG_CASE",
            "CASE 6 : RUNTIME REPETITION-ZERO ERROR",
            UVM_LOW
        )


        prepare_case(
            1'b1
        );


        load_health_debug_data(
            rep_zero_data
        );


        set_figa_enable(
            1'b1
        );


        wait_error_flag(
            REP_ZERO_FAIL_BIT,
            "repetition_zero_test_fail"
        );

    endtask


    // ========================================================================
    // CASE 7
    //
    // Runtime adaptive error
    // ========================================================================

    virtual task test_adaptive_error();

        `uvm_info(
            "TRNG_CASE",
            "CASE 7 : RUNTIME ADAPTATION ERROR",
            UVM_LOW
        )


        prepare_case(
            1'b1
        );


        load_health_debug_data(
            adaptive_data
        );


        set_figa_enable(
            1'b1
        );


        wait_error_flag(
            ADAPT_FAIL_BIT,
            "adaptation_test_fail"
        );


        `uvm_info(
            "TRNG_ADAPT",
            $sformatf(
                "adaptation_test_fail_value = %0d",
                status[18:8]
            ),
            UVM_LOW
        )

    endtask


    // ========================================================================
    // CASE 8
    //
    // VPlan:
    //
    // Use manual mode to test conditioning component works properly.
    //
    // 正確 RTL flow：
    //
    // 1. 正常完成 START_TEST
    // 2. 進 HEALTH_TEST
    // 3. health_test_fail == 0
    // 4. trng_debug_mode == 0
    // 5. conditioning debug mode = 1
    // 6. SW_TRNG_DATA 直接成為 trng_data_select
    // 7. pulse trng_req_sw
    // 8. conditioning_valid = 1
    // 9. DRBG conditioning_done
    // 10. conditioning_finish = 1
    // ========================================================================

    virtual task test_conditioning();

        `uvm_info(
            "TRNG_CASE",
            "==================================================",
            UVM_LOW
        )

        `uvm_info(
            "TRNG_CASE",
            "CASE 8 : CONDITIONING MANUAL TEST",
            UVM_LOW
        )


        // ------------------------------------------------------------
        // 正常 startup。
        // ------------------------------------------------------------

        prepare_case(
            1'b0
        );


        // ------------------------------------------------------------
        // Health path 持續吃 AA。
        //
        // 所以後面即使我們把 SW_TRNG_DATA register 改成
        // conditioning_data，也不會影響 debug_trng_data。
        //
        // debug_trng_data 已經在 0->1 pulse 時 capture AA。
        // ------------------------------------------------------------

        load_health_debug_data(
            normal_data
        );


        set_figa_enable(
            1'b1
        );


        wait_normal_start_finish();


        check_health_error_clear();


        // ------------------------------------------------------------
        // RTL conditioning_finish 要求：
        //
        // !trng_debug_mode
        //
        // 所以一定保持 0。
        // ------------------------------------------------------------

        trng_write(
            TRNG_DEBUG_MODE,
            32'h0
        );


        // ------------------------------------------------------------
        // Conditioning debug mode：
        //
        // RTL 是 combinational mux，
        // 不需要 0->1 capture pulse。
        //
        // trng_data_select =
        //
        // cond_debug ? SW_TRNG_DATA : trng_data
        //
        // 因此先寫 data 再 enable 即可。
        // ------------------------------------------------------------

        write_sw_trng_data(
            conditioning_data
        );


        trng_write(
            TRNG_COND_DEBUG_MODE,
            32'h1
        );


        clear_conditioning_finish();


        repeat(2)
            @(posedge system.sscg_clk);


        // ------------------------------------------------------------
        // 現在已確認 RTL：
        //
        // conditioning_valid <=
        //     trng_req_sw
        //     && trng_cs == HEALTH_TEST
        //     && !health_test_fail
        //     && !trng_debug_mode;
        //
        // 所以這個 request 必須等 HEALTH_TEST 後才寫。
        // ------------------------------------------------------------

        trng_write(
            TRNG_REQ_SW,
            32'h1
        );


        // ------------------------------------------------------------
        // 等 conditioning_finish。
        // ------------------------------------------------------------

        wait_conditioning_finish();


        read_conditioning_result(
            conditioning_result
        );


        // ------------------------------------------------------------
        // Clear behavior。
        // ------------------------------------------------------------

        clear_conditioning_finish();


        repeat(3)
            @(posedge system.sscg_clk);


        read_status(status);


        if (status[COND_FINISH_BIT] !== 1'b0) begin

            `uvm_error(
                "TRNG_CONDITIONING",
                "conditioning_finish cannot be cleared"
            )

        end


        trng_write(
            TRNG_COND_DEBUG_MODE,
            32'h0
        );


        `uvm_info(
            "TRNG_CASE",
            "CASE 8 PASS",
            UVM_LOW
        )

    endtask


    // ========================================================================
    // Wait conditioning finish
    // ========================================================================

    virtual task wait_conditioning_finish();

        bit done;

        done = 0;


        for (int i = 0; i < TRNG_TIMEOUT_CYCLE; i++) begin

            read_status(status);


            if (status[COND_FINISH_BIT] === 1'b1) begin

                done = 1;

                break;

            end


            // Conditioning 正常執行期間不可以出現 health error。
            if (status[7:2] !== 6'b0) begin

                print_status(
                    "COND_HEALTH_FAIL"
                );

                `uvm_fatal(
                    "TRNG_CONDITIONING",
                    "Health test failed while waiting conditioning_finish"
                )

            end


            @(posedge system.sscg_clk);

        end


        if (!done) begin

            print_status(
                "COND_TIMEOUT"
            );

            `uvm_fatal(
                "TRNG_TIMEOUT",
                "Timeout waiting conditioning_finish"
            )

        end


        `uvm_info(
            "TRNG_CONDITIONING",
            "conditioning_finish asserted",
            UVM_LOW
        )

    endtask


    // ========================================================================
    // CASE 9
    //
    // Recovery
    //
    // 所有 error injection 後重新 reset，
    // 再跑一次正常 AA startup。
    //
    // 用來抓：
    //
    // - sticky fail 沒清乾淨
    // - counter 沒 reset
    // - FSM 卡住
    // - debug mode 殘留
    // ========================================================================

    virtual task test_recovery();

        `uvm_info(
            "TRNG_CASE",
            "CASE 9 : RECOVERY TEST",
            UVM_LOW
        )


        prepare_case(
            1'b0
        );


        load_health_debug_data(
            normal_data
        );


        set_figa_enable(
            1'b1
        );


        wait_normal_start_finish();


        check_health_error_clear();


        `uvm_info(
            "TRNG_CASE",
            "CASE 9 PASS : TRNG recovered successfully",
            UVM_LOW
        )

    endtask


    // ========================================================================
    // run_phase
    // ========================================================================

    virtual task run_phase(
        uvm_phase phase
    );

        super.run_phase(phase);


        phase.raise_objection(
            this
        );


        `uvm_info(
            get_type_name(),
            "==========================================================",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            "TRNG COMPLETE UVM TEST START",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            "==========================================================",
            UVM_LOW
        )


        // ------------------------------------------------------------
        // 不用 @(posedge rst_n)，避免進 run_phase 時 reset 已經 high
        // 導致永遠等不到下一個 posedge。
        // ------------------------------------------------------------

        wait(
            system.rst_n === 1'b1
        );


        repeat(10)
            @(posedge system.sscg_clk);


        build_test_pattern();


        // ====================================================================
        // VPlan normal health
        // ====================================================================

        test_health_normal();


        // ====================================================================
        // Startup error flags
        // ====================================================================

        test_start_rep_one_error();

        test_start_rep_zero_error();

        test_start_adaptive_error();


        // ====================================================================
        // Runtime health-test error flags
        // ====================================================================

        test_rep_one_error();

        test_rep_zero_error();

        test_adaptive_error();


        // ====================================================================
        // VPlan conditioning
        // ====================================================================

        test_conditioning();


        // ====================================================================
        // Recovery
        // ====================================================================

        test_recovery();


        `uvm_info(
            get_type_name(),
            "==========================================================",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            "TRNG COMPLETE UVM TEST PASS",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            "==========================================================",
            UVM_LOW
        )


        phase.drop_objection(
            this
        );

    endtask


endclass
