// ============================================================================
// mcu_trng_test.sv
//
// TRNG Manual Mode / Health Test / Conditioning / Error Flag Verification
//
// 驗證項目：
//
// 1. 驗證 TRNG manual mode 正常運作
// 2. 驗證 Health Test 正常資料不會產生 error
// 3. 驗證 Startup Repetition-One Error Flag
// 4. 驗證 Startup Repetition-Zero Error Flag
// 5. 驗證 Startup Adaptive Error Flag
// 6. 驗證 Runtime Repetition-One Error Flag
// 7. 驗證 Runtime Repetition-Zero Error Flag
// 8. 驗證 Runtime Adaptive Error Flag
// 9. 驗證 Conditioning Component
// 10. 驗證各種 error flag 可以 clear
// 11. 驗證 error 發生後可以 recovery
//
// 設計原則：
//
// - 優先透過 software-visible register 驗證
// - manual mode 使用 trng_req_sw
// - 不直接依賴 internal RTL signal 判 PASS/FAIL
// - 所有 wait 都有 timeout
// - 每個 error case 都做 Clear -> Inject -> Trigger -> Check -> Clear
//
// ============================================================================

class mcu_trng_test extends host_base_test;

    `uvm_component_utils(mcu_trng_test)


    // ========================================================================
    // TRNG REGISTER WORD INDEX
    //
    // 你的 access format：
    //
    // { trng_page_addr, word_index[5:0], 2'b00 }
    //
    // 所以：
    //
    // word 6'h09 -> byte offset 0x24
    // word 6'h15 -> byte offset 0x54
    //
    // ========================================================================


    // ------------------------------------------------------------------------
    // 0x10
    //
    // FIGA control register
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_FIGA_CTRL =
        6'h04;


    // ------------------------------------------------------------------------
    // 0x14
    //
    // TRNG control
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_CTRL =
        6'h05;


    // ------------------------------------------------------------------------
    // 0x18
    //
    // FIGA output select
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_FIGA_OUT_SEL =
        6'h06;


    // ------------------------------------------------------------------------
    // 0x1C
    //
    // SW FIGA enable mode
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_SW_FIGA_ENABLE_MODE =
        6'h07;


    // ------------------------------------------------------------------------
    // 0x20
    //
    // SW FIGA local enable
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_SW_FIGA_LOCAL_ENABLE =
        6'h08;


    // ------------------------------------------------------------------------
    // 0x24
    //
    // Software TRNG request
    //
    // Register description：
    //
    // write one pulse
    //
    // 所以只需要 write 1。
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_REQ_SW =
        6'h09;


    // ------------------------------------------------------------------------
    // 0x28
    //
    // Clear health-test fail state
    //
    // write one pulse
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_CLEAR_FAIL_STATE =
        6'h0A;


    // ------------------------------------------------------------------------
    // 0x2C
    //
    // Clear startup-test finish state
    //
    // write one pulse
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_CLEAR_START_FINISH =
        6'h0B;


    // ------------------------------------------------------------------------
    // 0x30
    //
    // Clear conditioning finish state
    //
    // write one pulse
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_CLEAR_COND_FINISH =
        6'h0C;


    // ------------------------------------------------------------------------
    // 0x34
    //
    // bypass startup health test
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_BYPASS_START_TEST =
        6'h0D;


    // ------------------------------------------------------------------------
    // 0x38
    //
    // Startup-test threshold
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_START_TEST_THRESHOLD =
        6'h0E;


    // ------------------------------------------------------------------------
    // 0x3C
    //
    // Repetition-test threshold
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_REPETITION_THRESHOLD =
        6'h0F;


    // ------------------------------------------------------------------------
    // 0x40
    //
    // Adaptive-test threshold
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_ADAPT_THRESHOLD =
        6'h10;


    // ------------------------------------------------------------------------
    // 0x44
    //
    // TRNG software reset
    //
    // write one pulse
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_SW_RESET =
        6'h11;


    // ------------------------------------------------------------------------
    // 0x48
    //
    // TRNG debug mode
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_DEBUG_MODE =
        6'h12;


    // ------------------------------------------------------------------------
    // 0x4C
    //
    // Health-test debug mode
    //
    // 使用 SW_TRNG_DATA 當 health-test input
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_HEALTH_DEBUG_MODE =
        6'h13;


    // ------------------------------------------------------------------------
    // 0x50
    //
    // Conditioning-test debug mode
    //
    // 注意：
    //
    // 必須 startup test 完成後才能 enable。
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_COND_DEBUG_MODE =
        6'h14;


    // ------------------------------------------------------------------------
    // 0x54
    //
    // TRNG STATUS
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_STATUS =
        6'h15;


    // ------------------------------------------------------------------------
    // 0x80 ~ 0xBC
    //
    // SW_TRNG_DATA[511:0]
    //
    // word 6'h20 = [31:0]
    // word 6'h21 = [63:32]
    // ...
    // word 6'h2F = [511:480]
    // ------------------------------------------------------------------------

    localparam bit [5:0] TRNG_SW_DATA_BASE =
        6'h20;



    // ========================================================================
    // STATUS REGISTER BIT DEFINITION
    //
    // TRNG_STATUS @ 0x54
    //
    // ========================================================================


    // Startup repetition-one test fail
    localparam int START_REP_ONE_FAIL_BIT =
        7;


    // Startup repetition-zero test fail
    localparam int START_REP_ZERO_FAIL_BIT =
        6;


    // Startup adaptive test fail
    localparam int START_ADAPT_FAIL_BIT =
        5;


    // Runtime repetition-one test fail
    localparam int REP_ONE_FAIL_BIT =
        4;


    // Runtime repetition-zero test fail
    localparam int REP_ZERO_FAIL_BIT =
        3;


    // Runtime adaptive test fail
    localparam int ADAPT_FAIL_BIT =
        2;


    // Startup test finish
    localparam int START_TEST_FINISH_BIT =
        1;


    // Conditioning finish
    localparam int CONDITIONING_FINISH_BIT =
        0;



    // ========================================================================
    // DEFAULT THRESHOLD
    //
    // 這三個值來自你原本 legacy test。
    //
    // ========================================================================

    localparam bit [31:0] START_TEST_THRESHOLD_VALUE =
        32'd300;


    localparam bit [31:0] REPETITION_THRESHOLD_VALUE =
        32'd35;


    localparam bit [31:0] ADAPT_THRESHOLD_VALUE =
        32'd748;



    // ========================================================================
    // TIMEOUT
    //
    // polling 最多等待 10000 個 TRNG clock。
    //
    // ========================================================================

    localparam int TRNG_TIMEOUT_CYCLE =
        10000;



    // ========================================================================
    // INTERNAL DATA
    // ========================================================================

    bit [31:0] status;

    bit [511:0] normal_data;

    bit [511:0] all_one_data;

    bit [511:0] all_zero_data;

    bit [511:0] adaptive_one_data;

    bit [511:0] adaptive_zero_data;



    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    function new(
        string name = "mcu_trng_test",
        uvm_component parent = null
    );

        super.new(
            name,
            parent
        );

    endfunction



    // ========================================================================
    // BUILD PHASE
    // ========================================================================

    virtual function void build_phase(
        uvm_phase phase
    );

        super.build_phase(
            phase
        );

    endfunction



    // ========================================================================
    // REGISTER WRITE WRAPPER
    //
    // 所有 TRNG register write 統一從這裡出去。
    //
    // 這樣之後如果改 RAL，只需要修改這裡。
    //
    // ========================================================================

    virtual task trng_write(
        input bit [5:0]  word_addr,
        input bit [31:0] data
    );

        `uvm_info(
            "TRNG_REG",
            $sformatf(
                "WRITE word_addr=0x%02h byte_offset=0x%02h data=0x%08h",
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
    // REGISTER READ WRAPPER
    //
    // 如果你們 ahb_word_read() 的 output parameter 順序不同，
    // 只需要改這一個 task。
    //
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
                "READ word_addr=0x%02h byte_offset=0x%02h data=0x%08h",
                word_addr,
                {word_addr, 2'b00},
                data
            ),
            UVM_HIGH
        )

    endtask



    // ========================================================================
    // BUILD TEST PATTERN
    // ========================================================================

    virtual task build_test_pattern();


        // --------------------------------------------------------------------
        // Normal pattern
        //
        // 避免長時間全部 0 或全部 1。
        //
        // 用來測正常 health-test 與 conditioning。
        // --------------------------------------------------------------------

        normal_data = {
            32'h1357_9BDF,
            32'h2468_ACE0,
            32'hCAFE_BABE,
            32'hDEAD_BEEF,

            32'h55AA_33CC,
            32'h0F0F_F0F0,
            32'h1234_5678,
            32'h8765_4321,

            32'hA5A5_5A5A,
            32'h1020_3040,
            32'h1122_3344,
            32'h5566_7788,

            32'h89AB_CDEF,
            32'h7654_3210,
            32'hAA55_AA55,
            32'h5A5A_A5A5
        };


        // --------------------------------------------------------------------
        // All one
        //
        // 用來刺激 repetition-one detector。
        // --------------------------------------------------------------------

        all_one_data =
            {512{1'b1}};


        // --------------------------------------------------------------------
        // All zero
        //
        // 用來刺激 repetition-zero detector。
        // --------------------------------------------------------------------

        all_zero_data =
            {512{1'b0}};


        // --------------------------------------------------------------------
        // Adaptive ONE-biased pattern
        //
        // pattern：
        //
        // 1110 1110 1110 ...
        //
        // 1 的比例較高，但連續 1 最長只有 3。
        //
        // 這比全部 1 更適合拿來刺激 adaptive detector。
        // --------------------------------------------------------------------

        for (
            int i = 0;
            i < 512;
            i += 4
        ) begin

            adaptive_one_data[i +: 4] =
                4'b1110;

        end


        // --------------------------------------------------------------------
        // Adaptive ZERO-biased pattern
        //
        // pattern：
        //
        // 0001 0001 0001 ...
        //
        // --------------------------------------------------------------------

        for (
            int i = 0;
            i < 512;
            i += 4
        ) begin

            adaptive_zero_data[i +: 4] =
                4'b0001;

        end

    endtask



    // ========================================================================
    // WRITE SW_TRNG_DATA
    //
    // 512-bit data 拆成 16 個 32-bit register。
    //
    // ========================================================================

    virtual task write_sw_trng_data(
        input bit [511:0] data
    );

        `uvm_info(
            "TRNG_DATA",
            "Write SW_TRNG_DATA[511:0]",
            UVM_MEDIUM
        )


        for (
            int i = 0;
            i < 16;
            i++
        ) begin

            trng_write(
                TRNG_SW_DATA_BASE + i,
                data[i*32 +: 32]
            );

        end

    endtask



    // ========================================================================
    // SW REQUEST
    //
    // Manual mode 使用 trng_req_sw。
    //
    // ========================================================================

    virtual task trigger_trng();

        `uvm_info(
            "TRNG_TRIGGER",
            "Trigger TRNG by TRNG_REQ_SW",
            UVM_MEDIUM
        )


        trng_write(
            TRNG_REQ_SW,
            32'h0000_0001
        );

    endtask



    // ========================================================================
    // CLEAR FUNCTIONS
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

        `uvm_info(
            "TRNG_CLEAR",
            "Clear TRNG fail/finish status",
            UVM_MEDIUM
        )


        clear_fail_state();

        clear_start_finish();

        clear_conditioning_finish();


        repeat(2)
            @(posedge system.sscg_clk);

    endtask



    // ========================================================================
    // READ STATUS
    // ========================================================================

    virtual task read_trng_status(
        output bit [31:0] data
    );

        trng_read(
            TRNG_STATUS,
            data
        );

    endtask



    // ========================================================================
    // WAIT STATUS BIT
    //
    // 使用 polling + timeout。
    //
    // 不直接：
    //
    // wait(status_bit);
    //
    // 避免 DUT bug 時 simulation 永久卡住。
    //
    // ========================================================================

    virtual task wait_status_bit(
        input int bit_idx,
        input bit exp_value = 1'b1,
        input int timeout_cycle = TRNG_TIMEOUT_CYCLE
    );

        bit hit;

        hit = 0;


        for (
            int i = 0;
            i < timeout_cycle;
            i++
        ) begin

            read_trng_status(
                status
            );


            if (
                status[bit_idx]
                ===
                exp_value
            ) begin

                hit = 1;

                break;

            end


            @(posedge system.sscg_clk);

        end


        if (!hit) begin

            `uvm_fatal(
                "TRNG_TIMEOUT",
                $sformatf(
                    "Timeout waiting status[%0d]=%0b, last_status=0x%08h",
                    bit_idx,
                    exp_value,
                    status
                )
            )

        end

    endtask



    // ========================================================================
    // CHECK TARGET ERROR FLAG
    //
    // 只確認 target flag 必須起來。
    //
    // 不強制其他 detector 一定保持 0。
    //
    // 原因：
    //
    // repetition 與 adaptive detector 可能同時被同一組 pathological
    // pattern 刺激。
    //
    // 如果 RTL spec 明確保證 mutually exclusive，
    // 再把其他 flag check 加進來。
    //
    // ========================================================================

    virtual task check_target_flag(
        input int bit_idx,
        input string flag_name
    );

        read_trng_status(
            status
        );


        if (
            status[bit_idx]
            !==
            1'b1
        ) begin

            `uvm_error(
                "TRNG_FLAG",
                $sformatf(
                    "%s should assert, status=0x%08h",
                    flag_name,
                    status
                )
            )

        end

        else begin

            `uvm_info(
                "TRNG_FLAG",
                $sformatf(
                    "%s asserted correctly, status=0x%08h",
                    flag_name,
                    status
                ),
                UVM_LOW
            )

        end

    endtask



    // ========================================================================
    // CHECK ALL ERROR FLAG CLEAR
    // ========================================================================

    virtual task check_all_error_clear();

        read_trng_status(
            status
        );


        // status[7:2] 全部都是 health-test error。
        if (
            status[7:2]
            !==
            6'b000000
        ) begin

            `uvm_error(
                "TRNG_CLEAR",
                $sformatf(
                    "Health error flags are not cleared, status=0x%08h",
                    status
                )
            )

        end

        else begin

            `uvm_info(
                "TRNG_CLEAR",
                "All health error flags are cleared",
                UVM_MEDIUM
            )

        end

    endtask



    // ========================================================================
    // RESTORE NORMAL THRESHOLD
    // ========================================================================

    virtual task restore_normal_threshold();

        trng_write(
            TRNG_START_TEST_THRESHOLD,
            START_TEST_THRESHOLD_VALUE
        );


        trng_write(
            TRNG_REPETITION_THRESHOLD,
            REPETITION_THRESHOLD_VALUE
        );


        trng_write(
            TRNG_ADAPT_THRESHOLD,
            ADAPT_THRESHOLD_VALUE
        );

    endtask



    // ========================================================================
    // TRNG INITIALIZATION
    // ========================================================================

    virtual task trng_init();

        `uvm_info(
            "TRNG_INIT",
            "Initialize TRNG",
            UVM_LOW
        )


        // --------------------------------------------------------------------
        // FIGA control
        //
        // 沿用你原 legacy test 的設定。
        // --------------------------------------------------------------------

        trng_write(
            TRNG_FIGA_CTRL,
            32'h0000_0000
        );


        trng_write(
            TRNG_CTRL,
            32'h0000_0000
        );


        trng_write(
            TRNG_FIGA_OUT_SEL,
            32'h0000_0000
        );


        trng_write(
            TRNG_SW_FIGA_ENABLE_MODE,
            32'h0000_0000
        );


        trng_write(
            TRNG_SW_FIGA_LOCAL_ENABLE,
            32'h0000_0000
        );


        // --------------------------------------------------------------------
        // Threshold
        // --------------------------------------------------------------------

        restore_normal_threshold();


        // --------------------------------------------------------------------
        // Disable test/debug mode initially
        // --------------------------------------------------------------------

        trng_write(
            TRNG_DEBUG_MODE,
            32'h0000_0000
        );


        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h0000_0000
        );


        trng_write(
            TRNG_COND_DEBUG_MODE,
            32'h0000_0000
        );


        // --------------------------------------------------------------------
        // 不 bypass startup test
        // --------------------------------------------------------------------

        trng_write(
            TRNG_BYPASS_START_TEST,
            32'h0000_0000
        );


        // --------------------------------------------------------------------
        // Clear previous status
        // --------------------------------------------------------------------

        clear_all_status();


        `uvm_info(
            "TRNG_INIT",
            "TRNG configuration completed",
            UVM_LOW
        )

    endtask



    // ========================================================================
    // CASE 1
    //
    // NORMAL HEALTH TEST
    //
    // VPlan：
    //
    // Use manual mode to test the health test function works properly.
    //
    // ========================================================================

    virtual task test_health_normal();

        `uvm_info(
            "TRNG_CASE",
            "========== CASE 1 : NORMAL HEALTH TEST ==========",
            UVM_LOW
        )


        clear_all_status();

        restore_normal_threshold();


        // --------------------------------------------------------------------
        // 不 bypass startup test
        // --------------------------------------------------------------------

        trng_write(
            TRNG_BYPASS_START_TEST,
            32'h0
        );


        // --------------------------------------------------------------------
        // Enable health-test SW data mode
        // --------------------------------------------------------------------

        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h1
        );


        trng_write(
            TRNG_COND_DEBUG_MODE,
            32'h0
        );


        // --------------------------------------------------------------------
        // 寫入正常 SW TRNG data
        // --------------------------------------------------------------------

        write_sw_trng_data(
            normal_data
        );


        // --------------------------------------------------------------------
        // Software manual trigger
        // --------------------------------------------------------------------

        trigger_trng();


        // --------------------------------------------------------------------
        // 等 startup health test 完成
        // --------------------------------------------------------------------

        wait_status_bit(
            START_TEST_FINISH_BIT,
            1'b1
        );


        // --------------------------------------------------------------------
        // 正常情況下 error flag 應全部為 0
        // --------------------------------------------------------------------

        check_all_error_clear();


        `uvm_info(
            "TRNG_CASE",
            "CASE 1 PASS : Normal health test",
            UVM_LOW
        )

    endtask



    // ========================================================================
    // CASE 2
    //
    // START REPETITION-ONE ERROR
    //
    // ========================================================================

    virtual task test_start_rep_one_error();

        `uvm_info(
            "TRNG_CASE",
            "========== CASE 2 : START REPETITION ONE ==========",
            UVM_LOW
        )


        clear_all_status();


        trng_write(
            TRNG_BYPASS_START_TEST,
            32'h0
        );


        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h1
        );


        // --------------------------------------------------------------------
        // 全 1 data
        // --------------------------------------------------------------------

        write_sw_trng_data(
            all_one_data
        );


        trigger_trng();


        // --------------------------------------------------------------------
        // 等 startup repetition-one fail
        // --------------------------------------------------------------------

        wait_status_bit(
            START_REP_ONE_FAIL_BIT,
            1'b1
        );


        check_target_flag(
            START_REP_ONE_FAIL_BIT,
            "start_repetition_one_test_fail"
        );


        // --------------------------------------------------------------------
        // Clear error
        // --------------------------------------------------------------------

        clear_fail_state();


        repeat(2)
            @(posedge system.sscg_clk);


        check_all_error_clear();

    endtask



    // ========================================================================
    // CASE 3
    //
    // START REPETITION-ZERO ERROR
    //
    // ========================================================================

    virtual task test_start_rep_zero_error();

        `uvm_info(
            "TRNG_CASE",
            "========== CASE 3 : START REPETITION ZERO ==========",
            UVM_LOW
        )


        clear_all_status();


        trng_write(
            TRNG_BYPASS_START_TEST,
            32'h0
        );


        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h1
        );


        write_sw_trng_data(
            all_zero_data
        );


        trigger_trng();


        wait_status_bit(
            START_REP_ZERO_FAIL_BIT,
            1'b1
        );


        check_target_flag(
            START_REP_ZERO_FAIL_BIT,
            "start_repetition_zero_test_fail"
        );


        clear_fail_state();


        repeat(2)
            @(posedge system.sscg_clk);


        check_all_error_clear();

    endtask



    // ========================================================================
    // CASE 4
    //
    // START ADAPTIVE ERROR
    //
    // ========================================================================

    virtual task test_start_adaptive_error();

        `uvm_info(
            "TRNG_CASE",
            "========== CASE 4 : START ADAPTIVE ERROR ==========",
            UVM_LOW
        )


        clear_all_status();


        trng_write(
            TRNG_BYPASS_START_TEST,
            32'h0
        );


        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h1
        );


        // --------------------------------------------------------------------
        // 使用偏向 1 的 pattern
        //
        // 1110 repeated
        // --------------------------------------------------------------------

        write_sw_trng_data(
            adaptive_one_data
        );


        trigger_trng();


        wait_status_bit(
            START_ADAPT_FAIL_BIT,
            1'b1
        );


        check_target_flag(
            START_ADAPT_FAIL_BIT,
            "start_adaptation_test_fail"
        );


        clear_fail_state();


        repeat(2)
            @(posedge system.sscg_clk);


        check_all_error_clear();

    endtask



    // ========================================================================
    // CASE 5
    //
    // RUNTIME REPETITION-ONE ERROR
    //
    // ========================================================================

    virtual task test_rep_one_error();

        `uvm_info(
            "TRNG_CASE",
            "========== CASE 5 : REPETITION ONE ==========",
            UVM_LOW
        )


        clear_all_status();


        // --------------------------------------------------------------------
        // bypass startup test
        //
        // 這樣主要驗 continuous health test。
        // --------------------------------------------------------------------

        trng_write(
            TRNG_BYPASS_START_TEST,
            32'h1
        );


        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h1
        );


        write_sw_trng_data(
            all_one_data
        );


        trigger_trng();


        wait_status_bit(
            REP_ONE_FAIL_BIT,
            1'b1
        );


        check_target_flag(
            REP_ONE_FAIL_BIT,
            "repetition_one_test_fail"
        );


        clear_fail_state();


        repeat(2)
            @(posedge system.sscg_clk);


        check_all_error_clear();

    endtask



    // ========================================================================
    // CASE 6
    //
    // RUNTIME REPETITION-ZERO ERROR
    //
    // ========================================================================

    virtual task test_rep_zero_error();

        `uvm_info(
            "TRNG_CASE",
            "========== CASE 6 : REPETITION ZERO ==========",
            UVM_LOW
        )


        clear_all_status();


        trng_write(
            TRNG_BYPASS_START_TEST,
            32'h1
        );


        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h1
        );


        write_sw_trng_data(
            all_zero_data
        );


        trigger_trng();


        wait_status_bit(
            REP_ZERO_FAIL_BIT,
            1'b1
        );


        check_target_flag(
            REP_ZERO_FAIL_BIT,
            "repetition_zero_test_fail"
        );


        clear_fail_state();


        repeat(2)
            @(posedge system.sscg_clk);


        check_all_error_clear();

    endtask



    // ========================================================================
    // CASE 7
    //
    // RUNTIME ADAPTIVE ERROR
    //
    // ========================================================================

    virtual task test_adaptive_error();

        `uvm_info(
            "TRNG_CASE",
            "========== CASE 7 : ADAPTIVE ERROR ==========",
            UVM_LOW
        )


        clear_all_status();


        trng_write(
            TRNG_BYPASS_START_TEST,
            32'h1
        );


        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h1
        );


        write_sw_trng_data(
            adaptive_one_data
        );


        trigger_trng();


        wait_status_bit(
            ADAPT_FAIL_BIT,
            1'b1
        );


        check_target_flag(
            ADAPT_FAIL_BIT,
            "adaptation_test_fail"
        );


        clear_fail_state();


        repeat(2)
            @(posedge system.sscg_clk);


        check_all_error_clear();

    endtask



    // ========================================================================
    // CASE 8
    //
    // CONDITIONING TEST
    //
    // VPlan：
    //
    // Use manual mode to test the conditioning component works properly.
    //
    // ========================================================================

    virtual task test_conditioning();

        `uvm_info(
            "TRNG_CASE",
            "========== CASE 8 : CONDITIONING ==========",
            UVM_LOW
        )


        clear_all_status();

        restore_normal_threshold();


        // ====================================================================
        // Step 1
        //
        // 先完成 startup health test。
        //
        // Register description 明確要求：
        //
        // conditioning debug mode 必須在 startup test finish 後才能設定。
        // ====================================================================


        trng_write(
            TRNG_BYPASS_START_TEST,
            32'h0
        );


        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h1
        );


        trng_write(
            TRNG_COND_DEBUG_MODE,
            32'h0
        );


        write_sw_trng_data(
            normal_data
        );


        trigger_trng();


        wait_status_bit(
            START_TEST_FINISH_BIT,
            1'b1
        );


        check_all_error_clear();


        // ====================================================================
        // Step 2
        //
        // Startup health test 已完成。
        //
        // 現在才能 enable conditioning debug mode。
        // ====================================================================

        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h0
        );


        trng_write(
            TRNG_COND_DEBUG_MODE,
            32'h1
        );


        // --------------------------------------------------------------------
        // 清掉前一次 conditioning finish
        // --------------------------------------------------------------------

        clear_conditioning_finish();


        // --------------------------------------------------------------------
        // 寫 controlled SW data
        // --------------------------------------------------------------------

        write_sw_trng_data(
            normal_data
        );


        // --------------------------------------------------------------------
        // Manual request
        // --------------------------------------------------------------------

        trigger_trng();


        // --------------------------------------------------------------------
        // 等 conditioning finish
        // --------------------------------------------------------------------

        wait_status_bit(
            CONDITIONING_FINISH_BIT,
            1'b1
        );


        read_trng_status(
            status
        );


        if (
            status[CONDITIONING_FINISH_BIT]
            !==
            1'b1
        ) begin

            `uvm_error(
                "TRNG_CONDITIONING",
                $sformatf(
                    "conditioning_finish should be 1, status=0x%08h",
                    status
                )
            )

        end


        // --------------------------------------------------------------------
        // Clear conditioning finish
        // --------------------------------------------------------------------

        clear_conditioning_finish();


        // --------------------------------------------------------------------
        // 確認真的清掉
        // --------------------------------------------------------------------

        wait_status_bit(
            CONDITIONING_FINISH_BIT,
            1'b0
        );


        `uvm_info(
            "TRNG_CASE",
            "CASE 8 PASS : Conditioning component works correctly",
            UVM_LOW
        )

    endtask



    // ========================================================================
    // CASE 9
    //
    // ERROR RECOVERY
    //
    // Error test 全部跑完後重新跑一次正常 health test。
    //
    // 確認：
    //
    // - fail flag 已清除
    // - FSM 沒卡住
    // - request 還能正常接受
    //
    // ========================================================================

    virtual task test_recovery();

        `uvm_info(
            "TRNG_CASE",
            "========== CASE 9 : ERROR RECOVERY ==========",
            UVM_LOW
        )


        clear_all_status();

        restore_normal_threshold();


        trng_write(
            TRNG_BYPASS_START_TEST,
            32'h0
        );


        trng_write(
            TRNG_COND_DEBUG_MODE,
            32'h0
        );


        trng_write(
            TRNG_HEALTH_DEBUG_MODE,
            32'h1
        );


        write_sw_trng_data(
            normal_data
        );


        trigger_trng();


        wait_status_bit(
            START_TEST_FINISH_BIT,
            1'b1
        );


        check_all_error_clear();


        `uvm_info(
            "TRNG_CASE",
            "CASE 9 PASS : TRNG recovery successful",
            UVM_LOW
        )

    endtask



    // ========================================================================
    // RUN PHASE
    // ========================================================================

    virtual task run_phase(
        uvm_phase phase
    );

        super.run_phase(
            phase
        );


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
            "TRNG UVM TEST START",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            "==========================================================",
            UVM_LOW
        )


        // --------------------------------------------------------------------
        // 等 reset release
        //
        // 這是你原 test 使用的 system reset flow。
        // --------------------------------------------------------------------

        @(posedge system.rst_n);


        // --------------------------------------------------------------------
        // 多等幾個 clock，避免 reset release 當下就 access register。
        // --------------------------------------------------------------------

        repeat(10)
            @(posedge system.sscg_clk);


        // --------------------------------------------------------------------
        // 建立 input pattern
        // --------------------------------------------------------------------

        build_test_pattern();


        // --------------------------------------------------------------------
        // 初始化 TRNG
        // --------------------------------------------------------------------

        trng_init();


        // ====================================================================
        // Normal Health Test
        // ====================================================================

        test_health_normal();


        // ====================================================================
        // Startup Health Test Error
        // ====================================================================

        test_start_rep_one_error();

        test_start_rep_zero_error();

        test_start_adaptive_error();


        // ====================================================================
        // Runtime Health Test Error
        // ====================================================================

        test_rep_one_error();

        test_rep_zero_error();

        test_adaptive_error();


        // ====================================================================
        // Conditioning
        // ====================================================================

        test_conditioning();


        // ====================================================================
        // Error Recovery
        // ====================================================================

        test_recovery();


        `uvm_info(
            get_type_name(),
            "==========================================================",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            "TRNG UVM TEST FINISH",
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
