`ifndef HOST_CRC_IP_TEST
`define HOST_CRC_IP_TEST


class host_crc_ip_test extends host_base_test;

    `uvm_component_utils(host_crc_ip_test)


    //============================================================
    // CRC REGISTER OFFSET
    //============================================================

    // 0x00
    // [1] chksum_mismatch : R
    // [0] check_start     : W1S
    localparam logic [7:0] CRC_REG_CTRL               = 8'h00;

    // SEED
    localparam logic [7:0] CRC_REG_SEED_LO            = 8'h02;
    localparam logic [7:0] CRC_REG_SEED_HI            = 8'h03;

    // START ADDRESS
    localparam logic [7:0] CRC_REG_START_ADDR_0       = 8'h04;
    localparam logic [7:0] CRC_REG_START_ADDR_1       = 8'h05;
    localparam logic [7:0] CRC_REG_START_ADDR_2       = 8'h06;
    localparam logic [7:0] CRC_REG_START_ADDR_3       = 8'h07;

    // END ADDRESS
    localparam logic [7:0] CRC_REG_END_ADDR_0         = 8'h08;
    localparam logic [7:0] CRC_REG_END_ADDR_1         = 8'h09;
    localparam logic [7:0] CRC_REG_END_ADDR_2         = 8'h0A;
    localparam logic [7:0] CRC_REG_END_ADDR_3         = 8'h0B;

    // EXPECTED CHECKSUM
    localparam logic [7:0] CRC_REG_EXP_CHECKSUM_LO    = 8'h0C;
    localparam logic [7:0] CRC_REG_EXP_CHECKSUM_HI    = 8'h0D;

    // ACTUAL CHECKSUM
    localparam logic [7:0] CRC_REG_ACT_CHECKSUM_LO    = 8'h10;
    localparam logic [7:0] CRC_REG_ACT_CHECKSUM_HI    = 8'h11;

    // COMPLETE STATUS
    // [0] W1C
    localparam logic [7:0] CRC_REG_CHKSUM_COMPLETE    = 8'h14;

    // COMPLETE ENABLE
    localparam logic [7:0] CRC_REG_CHKSUM_COMPLETE_EN = 8'h18;


    //============================================================
    // Variables
    //============================================================

    logic [23:0] crc_page_addr;

    logic [31:0] crc_mem_expected[];
    logic [31:0] crc_mem_readback[];


    //============================================================
    // Constructor
    //============================================================

    function new(
        string name = "host_crc_ip_test",
        uvm_component parent = null
    );

        super.new(name, parent);

    endfunction


    //============================================================
    // Build Phase
    //============================================================

    virtual function void build_phase(uvm_phase phase);

        super.build_phase(phase);

    endfunction


    //============================================================
    // RUN PHASE
    //============================================================

    virtual task run_phase(uvm_phase phase);

        logic [31:0] start_addr;
        logic [31:0] end_addr;

        logic [15:0] seed;
        logic [15:0] golden_crc;

        int unsigned word_num;


        super.run_phase(phase);

        phase.raise_objection(this);


        //--------------------------------------------------------
        // CRC register page
        //--------------------------------------------------------

        crc_page_addr =
            h_host_top_cfg.crc_page_addr;


        //--------------------------------------------------------
        // Reset
        //--------------------------------------------------------

        mcu_test_reset();


        //========================================================
        //
        // STEP 0
        //
        // SELF TEST
        //
        // Before touching DUT CRC hardware,
        // first prove our own golden CRC model is correct.
        //
        //========================================================

        crc16_self_test();


        //========================================================
        //
        // STEP 1
        //
        // Generate valid CRC memory range.
        //
        //========================================================

        gen_crc_range(
            start_addr,
            end_addr,
            word_num
        );


        `uvm_info(
            get_type_name(),
            $sformatf(
                "CRC RANGE : START=0x%08h END=0x%08h WORD_NUM=%0d",
                start_addr,
                end_addr,
                word_num
            ),
            UVM_LOW
        )


        //========================================================
        //
        // STEP 2
        //
        // Prepare memory.
        //
        // Write known random data into exactly the same addresses
        // that DUT CRC will later read.
        //
        //========================================================

        prepare_crc_memory(
            start_addr,
            word_num
        );


        //========================================================
        //
        // STEP 3
        //
        // Generate random CRC seed.
        //
        //========================================================

        seed =
            $urandom;


        //========================================================
        //
        // STEP 4
        //
        // Read same memory addresses back.
        //
        // 1. Verify memory content
        // 2. Calculate golden CRC
        //
        //========================================================

        readback_crc_memory_and_calc_golden(
            start_addr,
            word_num,
            seed,
            golden_crc
        );


        `uvm_info(
            get_type_name(),
            $sformatf(
                "CRC GOLDEN READY : SEED=0x%04h GOLDEN=0x%04h",
                seed,
                golden_crc
            ),
            UVM_LOW
        )


        //========================================================
        //
        // CASE 1
        //
        // NORMAL CRC MATCH
        //
        // EXP == GOLDEN
        //
        // Expected:
        //
        // ACT == GOLDEN
        // mismatch == 0
        //
        //========================================================

        run_crc_check_case(
            .case_name         ("CRC_MATCH"),
            .start_addr        (start_addr),
            .end_addr          (end_addr),
            .seed              (seed),
            .exp_checksum      (golden_crc),
            .golden_crc        (golden_crc),
            .expected_mismatch (1'b0)
        );


        //========================================================
        //
        // CASE 2
        //
        // CRC WRITE MISMATCH
        //
        // Deliberately write wrong expected CRC.
        //
        // XOR 1 guarantees different checksum.
        //
        // Expected:
        //
        // ACT == GOLDEN
        // EXP != ACT
        // mismatch == 1
        //
        //========================================================

        run_crc_check_case(
            .case_name         ("CRC_WRITE_MISMATCH"),
            .start_addr        (start_addr),
            .end_addr          (end_addr),
            .seed              (seed),
            .exp_checksum      (golden_crc ^ 16'h0001),
            .golden_crc        (golden_crc),
            .expected_mismatch (1'b1)
        );


        //========================================================
        //
        // CASE 3
        //
        // MATCH AGAIN
        //
        // Verify mismatch can clear after being asserted.
        //
        // Expected:
        //
        // ACT == GOLDEN
        // mismatch == 0
        //
        //========================================================

        run_crc_check_case(
            .case_name         ("CRC_MATCH_AFTER_MISMATCH"),
            .start_addr        (start_addr),
            .end_addr          (end_addr),
            .seed              (seed),
            .exp_checksum      (golden_crc),
            .golden_crc        (golden_crc),
            .expected_mismatch (1'b0)
        );


        `uvm_info(
            get_type_name(),
            "\n================================================\nCRC TEST PASS FLOW FINISHED\n================================================",
            UVM_LOW
        )


        phase.drop_objection(this);

    endtask



    //======================================================================
    //
    // CRC SELF TEST
    //
    // Important:
    //
    // Do NOT trust golden model before checking it against known vectors.
    //
    // Tests:
    //
    // 1. "abc"
    // 2. "123456789"
    // 3. 32-bit endian test = 32'h12345678
    //
    //======================================================================

    virtual task crc16_self_test();

        logic [15:0] crc;
        logic [15:0] expected_crc;


        `uvm_info(
            get_type_name(),
            "\n================================================\nCRC16 SELF TEST START\n================================================",
            UVM_LOW
        )


        //========================================================
        //
        // SELF TEST #1
        //
        // "abc"
        //
        // ASCII:
        //
        // a = 0x61
        // b = 0x62
        // c = 0x63
        //
        // Configuration:
        //
        // poly   = 0x8005
        // init   = 0x0000
        // refin  = false
        // refout = false
        // xorout = 0x0000
        //
        // Expected = 16'hCADB
        //
        //========================================================

        crc =
            16'h0000;


        crc =
            crc16_update_byte_msb(
                crc,
                8'h61
            );


        crc =
            crc16_update_byte_msb(
                crc,
                8'h62
            );


        crc =
            crc16_update_byte_msb(
                crc,
                8'h63
            );


        expected_crc =
            16'hCADB;


        if (
            crc !== expected_crc
        ) begin

            `uvm_fatal(
                get_type_name(),
                $sformatf(
                    {
                        "\nCRC SELF TEST FAIL : abc",
                        "\nExpected = 0x%04h",
                        "\nActual   = 0x%04h"
                    },
                    expected_crc,
                    crc
                )
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                $sformatf(
                    "CRC SELF TEST PASS : \"abc\" -> 0x%04h",
                    crc
                ),
                UVM_LOW
            )

        end


        //========================================================
        //
        // SELF TEST #2
        //
        // Standard check string:
        //
        // "123456789"
        //
        // Expected CRC = 16'hFEE8
        //
        //========================================================

        crc =
            16'h0000;


        crc = crc16_update_byte_msb(crc, 8'h31);
        crc = crc16_update_byte_msb(crc, 8'h32);
        crc = crc16_update_byte_msb(crc, 8'h33);
        crc = crc16_update_byte_msb(crc, 8'h34);
        crc = crc16_update_byte_msb(crc, 8'h35);
        crc = crc16_update_byte_msb(crc, 8'h36);
        crc = crc16_update_byte_msb(crc, 8'h37);
        crc = crc16_update_byte_msb(crc, 8'h38);
        crc = crc16_update_byte_msb(crc, 8'h39);


        expected_crc =
            16'hFEE8;


        if (
            crc !== expected_crc
        ) begin

            `uvm_fatal(
                get_type_name(),
                $sformatf(
                    {
                        "\nCRC SELF TEST FAIL : 123456789",
                        "\nExpected = 0x%04h",
                        "\nActual   = 0x%04h"
                    },
                    expected_crc,
                    crc
                )
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                $sformatf(
                    "CRC SELF TEST PASS : \"123456789\" -> 0x%04h",
                    crc
                ),
                UVM_LOW
            )

        end


        //========================================================
        //
        // SELF TEST #3
        //
        // Verify the 32-bit WORD function byte ordering.
        //
        // data = 32'h12345678
        //
        // RTL processing order:
        //
        // 78
        // 56
        // 34
        // 12
        //
        // Expected = 16'h5C43
        //
        //========================================================

        crc =
            crc16_update_word(
                16'h0000,
                32'h1234_5678
            );


        expected_crc =
            16'h5C43;


        if (
            crc !== expected_crc
        ) begin

            `uvm_fatal(
                get_type_name(),
                $sformatf(
                    {
                        "\nCRC WORD SELF TEST FAIL",
                        "\nDATA     = 0x12345678",
                        "\nExpected = 0x%04h",
                        "\nActual   = 0x%04h",
                        "\nExpected byte order = 78 -> 56 -> 34 -> 12"
                    },
                    expected_crc,
                    crc
                )
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                $sformatf(
                    {
                        "CRC WORD SELF TEST PASS : ",
                        "0x12345678 -> 0x%04h ",
                        "(byte order 78->56->34->12)"
                    },
                    crc
                ),
                UVM_LOW
            )

        end


        `uvm_info(
            get_type_name(),
            "\n================================================\nCRC16 SELF TEST ALL PASS\n================================================",
            UVM_LOW
        )

    endtask



    //======================================================================
    //
    // Generate valid CRC range
    //
    // DUT address:
    //
    // START
    // START + 4
    // START + 8
    // ...
    // END
    //
    //======================================================================

    virtual task gen_crc_range(
        output logic [31:0] start_addr,
        output logic [31:0] end_addr,
        output int unsigned word_num
    );

        logic [31:0] region_start;
        logic [31:0] region_end;

        logic [31:0] aligned_start;
        logic [31:0] aligned_end;

        int unsigned available_words;
        int unsigned start_word_offset;


        case (
            $urandom_range(0, 2)
        )


            0: begin

                region_start =
                    h_host_top_cfg.tcon_reg_addr_str;

                region_end =
                    h_host_top_cfg.tcon_reg_addr_ed;

            end


            1: begin

                region_start =
                    h_host_top_cfg.dram_addr_str;

                region_end =
                    h_host_top_cfg.dram_addr_ed;

            end


            default: begin

                region_start =
                    h_host_top_cfg.mcu_iram_addr_str;

                region_end =
                    h_host_top_cfg.mcu_iram_addr_ed;

            end

        endcase


        //--------------------------------------------------------
        // Align upward.
        //--------------------------------------------------------

        aligned_start =
            (region_start + 32'd3)
            & 32'hFFFF_FFFC;


        //--------------------------------------------------------
        // Align downward.
        //--------------------------------------------------------

        aligned_end =
            region_end
            & 32'hFFFF_FFFC;


        if (
            aligned_end < aligned_start
        ) begin

            `uvm_fatal(
                get_type_name(),
                $sformatf(
                    "Invalid CRC address region START=%08h END=%08h",
                    region_start,
                    region_end
                )
            )

        end


        available_words =
            ((aligned_end - aligned_start) >> 2)
            + 1;


        if (
            available_words > 64
        ) begin

            word_num =
                $urandom_range(
                    1,
                    64
                );

        end
        else begin

            word_num =
                $urandom_range(
                    1,
                    available_words
                );

        end


        start_word_offset =
            $urandom_range(
                0,
                available_words - word_num
            );


        start_addr =
            aligned_start
            + (start_word_offset * 4);


        end_addr =
            start_addr
            + ((word_num - 1) * 4);


        //--------------------------------------------------------
        // Sanity check.
        //--------------------------------------------------------

        if (
            start_addr[1:0] !== 2'b00
        ) begin

            `uvm_fatal(
                get_type_name(),
                "START_ADDR is not 4-byte aligned"
            )

        end


        if (
            end_addr[1:0] !== 2'b00
        ) begin

            `uvm_fatal(
                get_type_name(),
                "END_ADDR is not 4-byte aligned"
            )

        end

    endtask



    //======================================================================
    //
    // Memory WRITE wrapper
    //
    // Change this task only if your mcu_wr() prototype differs.
    //
    //======================================================================

    virtual task crc_mem_wr_byte(
        input logic [31:0] addr,
        input logic [7:0] data
    );

        mcu_wr(
            {addr[23:0], 8'h00},
            data
        );

    endtask



    //======================================================================
    //
    // Memory READ wrapper
    //
    //======================================================================

    virtual task crc_mem_rd_byte(
        input  logic [31:0] addr,
        output logic [7:0] data
    );

        mcu_rd(
            {addr[23:0], 8'h00},
            data
        );

    endtask



    //======================================================================
    //
    // Prepare Memory
    //
    // Each CRC word:
    //
    // addr+0 : word[7:0]
    // addr+1 : word[15:8]
    // addr+2 : word[23:16]
    // addr+3 : word[31:24]
    //
    //======================================================================

    virtual task prepare_crc_memory(
        input logic [31:0] start_addr,
        input int unsigned word_num
    );

        logic [31:0] addr;
        logic [31:0] word_data;


        crc_mem_expected =
            new[word_num];


        for (
            int unsigned i = 0;
            i < word_num;
            i++
        ) begin


            addr =
                start_addr
                + (i * 4);


            //----------------------------------------------------
            // Generate known data.
            //----------------------------------------------------

            word_data =
                $urandom;


            crc_mem_expected[i] =
                word_data;


            //----------------------------------------------------
            // WRITE SAME ADDRESS RANGE
            //----------------------------------------------------

            crc_mem_wr_byte(
                addr + 0,
                word_data[7:0]
            );


            crc_mem_wr_byte(
                addr + 1,
                word_data[15:8]
            );


            crc_mem_wr_byte(
                addr + 2,
                word_data[23:16]
            );


            crc_mem_wr_byte(
                addr + 3,
                word_data[31:24]
            );


            `uvm_info(
                get_type_name(),
                $sformatf(
                    "CRC MEM WRITE : ADDR=%08h DATA=%08h",
                    addr,
                    word_data
                ),
                UVM_HIGH
            )

        end

    endtask



    //======================================================================
    //
    // READBACK SAME ADDRESS AND CALCULATE GOLDEN
    //
    //======================================================================

    virtual task readback_crc_memory_and_calc_golden(
        input logic [31:0] start_addr,
        input int unsigned word_num,
        input logic [15:0] seed,
        output logic [15:0] golden_crc
    );

        logic [31:0] addr;
        logic [31:0] word_data;

        logic [7:0] byte0;
        logic [7:0] byte1;
        logic [7:0] byte2;
        logic [7:0] byte3;

        logic [15:0] crc;


        crc_mem_readback =
            new[word_num];


        crc =
            seed;


        for (
            int unsigned i = 0;
            i < word_num;
            i++
        ) begin


            addr =
                start_addr
                + (i * 4);


            //----------------------------------------------------
            // READ SAME ADDRESS
            //----------------------------------------------------

            crc_mem_rd_byte(
                addr + 0,
                byte0
            );


            crc_mem_rd_byte(
                addr + 1,
                byte1
            );


            crc_mem_rd_byte(
                addr + 2,
                byte2
            );


            crc_mem_rd_byte(
                addr + 3,
                byte3
            );


            //----------------------------------------------------
            // Rebuild 32-bit word.
            //----------------------------------------------------

            word_data = {
                byte3,
                byte2,
                byte1,
                byte0
            };


            crc_mem_readback[i] =
                word_data;


            //----------------------------------------------------
            // First verify memory itself.
            //----------------------------------------------------

            if (
                word_data !== crc_mem_expected[i]
            ) begin

                `uvm_fatal(
                    get_type_name(),
                    $sformatf(
                        {
                            "CRC MEMORY ERROR : ",
                            "ADDR=%08h ",
                            "WRITE=%08h ",
                            "READ=%08h"
                        },
                        addr,
                        crc_mem_expected[i],
                        word_data
                    )
                )

            end


            //----------------------------------------------------
            // Then calculate golden CRC.
            //----------------------------------------------------

            `uvm_info(
                get_type_name(),
                $sformatf(
                    {
                        "CRC GOLDEN : ",
                        "ADDR=%08h ",
                        "DATA=%08h ",
                        "CRC_BEFORE=%04h"
                    },
                    addr,
                    word_data,
                    crc
                ),
                UVM_HIGH
            )


            crc =
                crc16_update_word(
                    crc,
                    word_data
                );


            `uvm_info(
                get_type_name(),
                $sformatf(
                    "CRC_AFTER=%04h",
                    crc
                ),
                UVM_HIGH
            )

        end


        golden_crc =
            crc;


        `uvm_info(
            get_type_name(),
            $sformatf(
                "FINAL GOLDEN CRC = 0x%04h",
                golden_crc
            ),
            UVM_LOW
        )

    endtask



    //======================================================================
    //
    // CRC16 BYTE
    //
    // Polynomial = 16'h8005
    //
    // MSB FIRST
    //
    // bit7 -> bit0
    //
    //======================================================================

    virtual function automatic logic [15:0]
    crc16_update_byte_msb(
        input logic [15:0] crc_i,
        input logic [7:0]  data_i
    );

        logic [15:0] crc;
        logic feedback;


        crc =
            crc_i;


        for (
            int i = 7;
            i >= 0;
            i--
        ) begin


            feedback =
                crc[15]
                ^ data_i[i];


            crc =
                {crc[14:0], 1'b0};


            if (
                feedback
            ) begin

                crc ^=
                    16'h8005;

            end

        end


        return crc;

    endfunction



    //======================================================================
    //
    // CRC16 32-BIT WORD
    //
    // RTL order:
    //
    // [7:0]
    // [15:8]
    // [23:16]
    // [31:24]
    //
    //======================================================================

    virtual function automatic logic [15:0]
    crc16_update_word(
        input logic [15:0] crc_i,
        input logic [31:0] data_i
    );

        logic [15:0] crc;


        crc =
            crc_i;


        crc =
            crc16_update_byte_msb(
                crc,
                data_i[7:0]
            );


        crc =
            crc16_update_byte_msb(
                crc,
                data_i[15:8]
            );


        crc =
            crc16_update_byte_msb(
                crc,
                data_i[23:16]
            );


        crc =
            crc16_update_byte_msb(
                crc,
                data_i[31:24]
            );


        return crc;

    endfunction



    //======================================================================
    //
    // CRC register configuration
    //
    //======================================================================

    virtual task set_crc_config(
        input logic [31:0] start_addr,
        input logic [31:0] end_addr,
        input logic [15:0] exp_checksum,
        input logic [15:0] seed
    );


        //--------------------------------------------------------
        // SEED
        //--------------------------------------------------------

        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_SEED_LO,
            seed[7:0]
        );


        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_SEED_HI,
            seed[15:8]
        );


        //--------------------------------------------------------
        // START ADDRESS
        //--------------------------------------------------------

        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_START_ADDR_0,
            start_addr[7:0]
        );


        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_START_ADDR_1,
            start_addr[15:8]
        );


        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_START_ADDR_2,
            start_addr[23:16]
        );


        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_START_ADDR_3,
            start_addr[31:24]
        );


        //--------------------------------------------------------
        // END ADDRESS
        //--------------------------------------------------------

        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_END_ADDR_0,
            end_addr[7:0]
        );


        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_END_ADDR_1,
            end_addr[15:8]
        );


        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_END_ADDR_2,
            end_addr[23:16]
        );


        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_END_ADDR_3,
            end_addr[31:24]
        );


        //--------------------------------------------------------
        // EXPECTED CHECKSUM
        //--------------------------------------------------------

        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_EXP_CHECKSUM_LO,
            exp_checksum[7:0]
        );


        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_EXP_CHECKSUM_HI,
            exp_checksum[15:8]
        );


        `uvm_info(
            get_type_name(),
            $sformatf(
                {
                    "CRC CONFIG : ",
                    "START=%08h ",
                    "END=%08h ",
                    "SEED=%04h ",
                    "EXP=%04h"
                },
                start_addr,
                end_addr,
                seed,
                exp_checksum
            ),
            UVM_LOW
        )

    endtask



    //======================================================================
    //
    // Enable COMPLETE
    //
    //======================================================================

    virtual task enable_chksum_complete_en();

        logic [7:0] rdata;


        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_CHKSUM_COMPLETE_EN,
            8'h01
        );


        mcu_reg_rd(
            crc_page_addr,
            CRC_REG_CHKSUM_COMPLETE_EN,
            rdata
        );


        if (
            rdata[0] !== 1'b1
        ) begin

            `uvm_error(
                get_type_name(),
                $sformatf(
                    "CHKSUM_COMPLETE_EN FAIL READ=%02h",
                    rdata
                )
            )

        end

    endtask



    //======================================================================
    //
    // CHECK START
    //
    //======================================================================

    virtual task set_check_start();

        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_CTRL,
            8'h01
        );

    endtask



    //======================================================================
    //
    // Poll COMPLETE
    //
    //======================================================================

    virtual task poll_chksum_complete(
        input int unsigned max_retry = 10000
    );

        logic [7:0] rdata;

        bit detected;


        detected =
            0;


        for (
            int unsigned i = 0;
            i < max_retry;
            i++
        ) begin


            mcu_reg_rd(
                crc_page_addr,
                CRC_REG_CHKSUM_COMPLETE,
                rdata
            );


            if (
                rdata[0] === 1'b1
            ) begin

                detected =
                    1;


                `uvm_info(
                    get_type_name(),
                    $sformatf(
                        "CHKSUM_COMPLETE after %0d polls",
                        i + 1
                    ),
                    UVM_LOW
                )


                break;

            end

        end


        if (
            !detected
        ) begin

            `uvm_fatal(
                get_type_name(),
                "CRC COMPLETE TIMEOUT"
            )

        end


        //--------------------------------------------------------
        // CHECK_START should self clear.
        //--------------------------------------------------------

        mcu_reg_rd(
            crc_page_addr,
            CRC_REG_CTRL,
            rdata
        );


        if (
            rdata[0] !== 1'b0
        ) begin

            `uvm_error(
                get_type_name(),
                "CHECK_START DID NOT SELF CLEAR"
            )

        end

    endtask



    //======================================================================
    //
    // Get ACT checksum
    //
    //======================================================================

    virtual task get_act_checksum(
        output logic [15:0] act_checksum
    );

        logic [7:0] lo;
        logic [7:0] hi;


        mcu_reg_rd(
            crc_page_addr,
            CRC_REG_ACT_CHECKSUM_LO,
            lo
        );


        mcu_reg_rd(
            crc_page_addr,
            CRC_REG_ACT_CHECKSUM_HI,
            hi
        );


        act_checksum = {
            hi,
            lo
        };

    endtask



    //======================================================================
    //
    // Get mismatch flag
    //
    //======================================================================

    virtual task get_chksum_mismatch(
        output logic mismatch
    );

        logic [7:0] rdata;


        mcu_reg_rd(
            crc_page_addr,
            CRC_REG_CTRL,
            rdata
        );


        mismatch =
            rdata[1];

    endtask



    //======================================================================
    //
    // Clear COMPLETE
    //
    //======================================================================

    virtual task clear_chksum_complete();

        logic [7:0] rdata;


        //--------------------------------------------------------
        // W1C
        //--------------------------------------------------------

        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_CHKSUM_COMPLETE,
            8'h01
        );


        //--------------------------------------------------------
        // Verify clear
        //--------------------------------------------------------

        mcu_reg_rd(
            crc_page_addr,
            CRC_REG_CHKSUM_COMPLETE,
            rdata
        );


        if (
            rdata[0] !== 1'b0
        ) begin

            `uvm_error(
                get_type_name(),
                "CHKSUM_COMPLETE W1C FAIL"
            )

        end

    endtask



    //======================================================================
    //
    // RUN ONE CRC CASE
    //
    //======================================================================

    virtual task run_crc_check_case(

        input string       case_name,

        input logic [31:0] start_addr,
        input logic [31:0] end_addr,

        input logic [15:0] seed,

        input logic [15:0] exp_checksum,
        input logic [15:0] golden_crc,

        input logic expected_mismatch
    );

        logic [15:0] act_checksum;

        logic actual_mismatch;
        logic derived_mismatch;

        logic [7:0] complete_status;


        `uvm_info(
            get_type_name(),
            $sformatf(
                {
                    "\n================================================",
                    "\nCRC CASE : %s",
                    "\nSTART            = %08h",
                    "\nEND              = %08h",
                    "\nSEED             = %04h",
                    "\nGOLDEN           = %04h",
                    "\nEXP              = %04h",
                    "\nEXPECTED MISMATCH= %0b",
                    "\n================================================"
                },
                case_name,
                start_addr,
                end_addr,
                seed,
                golden_crc,
                exp_checksum,
                expected_mismatch
            ),
            UVM_LOW
        )


        //========================================================
        // Clear stale COMPLETE
        //========================================================

        mcu_reg_rd(
            crc_page_addr,
            CRC_REG_CHKSUM_COMPLETE,
            complete_status
        );


        if (
            complete_status[0] === 1'b1
        ) begin

            clear_chksum_complete();

        end


        //========================================================
        // Program registers
        //========================================================

        set_crc_config(
            start_addr,
            end_addr,
            exp_checksum,
            seed
        );


        //========================================================
        // Enable complete
        //========================================================

        enable_chksum_complete_en();


        //========================================================
        // Start
        //========================================================

        set_check_start();


        //========================================================
        // Wait complete
        //========================================================

        poll_chksum_complete();


        //========================================================
        // Read ACT
        //========================================================

        get_act_checksum(
            act_checksum
        );


        //========================================================
        //
        // CHECK 1
        //
        // Golden CRC vs ACT checksum
        //
        //========================================================

        if (
            act_checksum !== golden_crc
        ) begin

            `uvm_error(
                get_type_name(),
                $sformatf(
                    {
                        "[%s] CRC CALC FAIL : ",
                        "GOLDEN=%04h ACT=%04h"
                    },
                    case_name,
                    golden_crc,
                    act_checksum
                )
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                $sformatf(
                    "[%s] CRC CALC PASS : GOLDEN=%04h ACT=%04h",
                    case_name,
                    golden_crc,
                    act_checksum
                ),
                UVM_LOW
            )

        end


        //========================================================
        //
        // CHECK 2
        //
        // Read DUT mismatch.
        //
        //========================================================

        get_chksum_mismatch(
            actual_mismatch
        );


        //========================================================
        //
        // Derive independently.
        //
        //========================================================

        derived_mismatch =
            (act_checksum != exp_checksum);


        //========================================================
        //
        // Verify flag against testcase expectation.
        //
        //========================================================

        if (
            actual_mismatch !== expected_mismatch
        ) begin

            `uvm_error(
                get_type_name(),
                $sformatf(
                    {
                        "[%s] MISMATCH FLAG FAIL : ",
                        "EXP=%04h ACT=%04h ",
                        "EXPECT_FLAG=%0b ACTUAL_FLAG=%0b"
                    },
                    case_name,
                    exp_checksum,
                    act_checksum,
                    expected_mismatch,
                    actual_mismatch
                )
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                $sformatf(
                    "[%s] MISMATCH FLAG PASS : FLAG=%0b",
                    case_name,
                    actual_mismatch
                ),
                UVM_LOW
            )

        end


        //========================================================
        //
        // Verify flag against actual EXP != ACT.
        //
        //========================================================

        if (
            actual_mismatch !== derived_mismatch
        ) begin

            `uvm_error(
                get_type_name(),
                $sformatf(
                    {
                        "[%s] MISMATCH COMPARE LOGIC FAIL : ",
                        "ACT=%04h EXP=%04h DERIVED=%0b FLAG=%0b"
                    },
                    case_name,
                    act_checksum,
                    exp_checksum,
                    derived_mismatch,
                    actual_mismatch
                )
            )

        end


        //========================================================
        //
        // Explicit mismatch assertion check
        //
        //========================================================

        if (
            expected_mismatch
        ) begin


            if (
                exp_checksum === golden_crc
            ) begin

                `uvm_fatal(
                    get_type_name(),
                    "TESTBENCH ERROR : mismatch case EXP equals GOLDEN"
                )

            end


            if (
                actual_mismatch !== 1'b1
            ) begin

                `uvm_error(
                    get_type_name(),
                    "CRC WRITE MISMATCH FLAG DID NOT ASSERT"
                )

            end
            else begin

                `uvm_info(
                    get_type_name(),
                    "CRC WRITE MISMATCH FLAG ASSERT PASS",
                    UVM_LOW
                )

            end

        end


        //========================================================
        // Clear COMPLETE
        //========================================================

        clear_chksum_complete();


        `uvm_info(
            get_type_name(),
            $sformatf(
                "CRC CASE DONE : %s",
                case_name
            ),
            UVM_LOW
        )

    endtask


endclass


`endif
