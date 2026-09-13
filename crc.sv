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
    // VARIABLES
    //============================================================

    logic [23:0] crc_page_addr;

    logic [31:0] crc_mem_expected[];
    logic [31:0] crc_mem_readback[];


    //============================================================
    // NEW
    //============================================================

    function new(
        string name = "host_crc_ip_test",
        uvm_component parent = null
    );

        super.new(name, parent);

    endfunction


    //============================================================
    // BUILD PHASE
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

        crc_page_addr = h_host_top_cfg.crc_page_addr;


        //--------------------------------------------------------
        // Reset
        //--------------------------------------------------------

        mcu_test_reset();


        //========================================================
        // STEP 1
        //
        // Generate valid CRC address range.
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
        // STEP 2
        //
        // Write known random data into exactly the same
        // address range that DUT CRC will later read.
        //========================================================

        prepare_crc_memory(
            start_addr,
            word_num
        );


        //========================================================
        // STEP 3
        //
        // Generate initial CRC seed.
        //========================================================

        seed = $urandom;


        //========================================================
        // STEP 4
        //
        // Read SAME memory range back.
        //
        // 1. Check readback data
        // 2. Calculate golden CRC
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
        // CASE 1 : CRC MATCH
        //
        // EXP == GOLDEN
        //
        // Expected:
        //
        // ACT_CHECKSUM    == GOLDEN
        // CHKSUM_MISMATCH == 0
        //
        //========================================================

        run_crc_check_case(
            .case_name          ("CRC_MATCH"),
            .start_addr         (start_addr),
            .end_addr           (end_addr),
            .seed               (seed),
            .exp_checksum       (golden_crc),
            .golden_crc         (golden_crc),
            .expected_mismatch  (1'b0)
        );


        //========================================================
        //
        // CASE 2 : CRC WRITE MISMATCH
        //
        // Deliberately write WRONG EXP_CHECKSUM.
        //
        // XOR bit0 guarantees:
        //
        // EXP != GOLDEN
        //
        // Expected:
        //
        // ACT_CHECKSUM    == GOLDEN
        // CHKSUM_MISMATCH == 1
        //
        //========================================================

        run_crc_check_case(
            .case_name          ("CRC_WRITE_MISMATCH"),
            .start_addr         (start_addr),
            .end_addr           (end_addr),
            .seed               (seed),
            .exp_checksum       (golden_crc ^ 16'h0001),
            .golden_crc         (golden_crc),
            .expected_mismatch  (1'b1)
        );


        //========================================================
        //
        // CASE 3 : MATCH AGAIN
        //
        // Verify previous mismatch flag does not stick.
        //
        // Expected:
        //
        // ACT_CHECKSUM    == GOLDEN
        // CHKSUM_MISMATCH == 0
        //
        //========================================================

        run_crc_check_case(
            .case_name          ("CRC_MATCH_AFTER_MISMATCH"),
            .start_addr         (start_addr),
            .end_addr           (end_addr),
            .seed               (seed),
            .exp_checksum       (golden_crc),
            .golden_crc         (golden_crc),
            .expected_mismatch  (1'b0)
        );


        `uvm_info(
            get_type_name(),
            "==============================================",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            "CRC TEST FINISHED",
            UVM_LOW
        )

        `uvm_info(
            get_type_name(),
            "==============================================",
            UVM_LOW
        )


        phase.drop_objection(this);

    endtask



    //============================================================
    // Generate valid CRC range
    //
    // DUT address sequence:
    //
    // START
    // START + 4
    // START + 8
    // ...
    // END
    //
    // START and END must therefore be 4-byte aligned.
    //============================================================

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


        //--------------------------------------------------------
        // Select valid region.
        //
        // You can adjust the list according to which regions
        // CRC hardware is actually allowed to access.
        //========================================================

        case ($urandom_range(0, 2))

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
        // Align start upward.
        //--------------------------------------------------------

        aligned_start =
            (region_start + 32'd3)
            & 32'hFFFF_FFFC;


        //--------------------------------------------------------
        // Align end downward.
        //--------------------------------------------------------

        aligned_end =
            region_end
            & 32'hFFFF_FFFC;


        if (aligned_end < aligned_start) begin

            `uvm_fatal(
                get_type_name(),
                $sformatf(
                    "Invalid CRC region : START=0x%08h END=0x%08h",
                    region_start,
                    region_end
                )
            )

        end


        //--------------------------------------------------------
        // Number of available 32-bit words.
        //--------------------------------------------------------

        available_words =
            ((aligned_end - aligned_start) >> 2) + 1;


        //--------------------------------------------------------
        // Avoid an excessively long testcase.
        //--------------------------------------------------------

        if (available_words > 64) begin

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


        //--------------------------------------------------------
        // Choose start offset.
        //--------------------------------------------------------

        start_word_offset =
            $urandom_range(
                0,
                available_words - word_num
            );


        //--------------------------------------------------------
        // START address.
        //--------------------------------------------------------

        start_addr =
            aligned_start
            + (start_word_offset * 4);


        //--------------------------------------------------------
        // END means address of LAST word.
        //--------------------------------------------------------

        end_addr =
            start_addr
            + ((word_num - 1) * 4);


        //--------------------------------------------------------
        // Sanity check.
        //--------------------------------------------------------

        if (
            start_addr[1:0] != 2'b00
        ) begin

            `uvm_fatal(
                get_type_name(),
                $sformatf(
                    "START_ADDR is not aligned : 0x%08h",
                    start_addr
                )
            )

        end


        if (
            end_addr[1:0] != 2'b00
        ) begin

            `uvm_fatal(
                get_type_name(),
                $sformatf(
                    "END_ADDR is not aligned : 0x%08h",
                    end_addr
                )
            )

        end


        if (
            end_addr > aligned_end
        ) begin

            `uvm_fatal(
                get_type_name(),
                $sformatf(
                    "END_ADDR exceeds valid region : 0x%08h > 0x%08h",
                    end_addr,
                    aligned_end
                )
            )

        end

    endtask



    //============================================================
    // Memory byte write wrapper
    //
    // IMPORTANT:
    //
    // If your mcu_wr() prototype is different,
    // modify ONLY this task.
    //============================================================

    virtual task crc_mem_wr_byte(
        input logic [31:0] addr,
        input logic [7:0] data
    );

        //--------------------------------------------------------
        // Based on the address format visible in your original
        // testcase:
        //
        // {addr[23:0], 8'h00}
        //
        //========================================================

        mcu_wr(
            {addr[23:0], 8'h00},
            data
        );

    endtask



    //============================================================
    // Memory byte read wrapper
    //
    // If your mcu_rd() prototype is different,
    // modify ONLY this task.
    //============================================================

    virtual task crc_mem_rd_byte(
        input  logic [31:0] addr,
        output logic [7:0]  data
    );

        mcu_rd(
            {addr[23:0], 8'h00},
            data
        );

    endtask



    //============================================================
    // Prepare CRC memory
    //
    // One CRC word:
    //
    // addr+0 = word[7:0]
    // addr+1 = word[15:8]
    // addr+2 = word[23:16]
    // addr+3 = word[31:24]
    //============================================================

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

            //----------------------------------------------------
            // Current 32-bit word address.
            //----------------------------------------------------

            addr =
                start_addr
                + (i * 4);


            //----------------------------------------------------
            // Generate random known value.
            //----------------------------------------------------

            word_data =
                $urandom;


            crc_mem_expected[i] =
                word_data;


            //----------------------------------------------------
            // Write data byte-by-byte.
            //----------------------------------------------------

            crc_mem_wr_byte(
                addr + 32'd0,
                word_data[7:0]
            );


            crc_mem_wr_byte(
                addr + 32'd1,
                word_data[15:8]
            );


            crc_mem_wr_byte(
                addr + 32'd2,
                word_data[23:16]
            );


            crc_mem_wr_byte(
                addr + 32'd3,
                word_data[31:24]
            );


            `uvm_info(
                get_type_name(),
                $sformatf(
                    "CRC MEM WRITE : ADDR=0x%08h DATA=0x%08h",
                    addr,
                    word_data
                ),
                UVM_HIGH
            )

        end

    endtask



    //============================================================
    // Read SAME addresses and calculate golden CRC
    //
    // Flow:
    //
    // WRITE
    //   ↓
    // READBACK
    //   ↓
    // compare expected memory
    //   ↓
    // calculate golden CRC
    //============================================================

    virtual task readback_crc_memory_and_calc_golden(
        input  logic [31:0] start_addr,
        input  int unsigned word_num,
        input  logic [15:0] seed,
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


        //--------------------------------------------------------
        // CRC initial value = SEED
        //--------------------------------------------------------

        crc =
            seed;


        `uvm_info(
            get_type_name(),
            $sformatf(
                "CRC GOLDEN START : SEED=0x%04h",
                seed
            ),
            UVM_LOW
        )


        for (
            int unsigned i = 0;
            i < word_num;
            i++
        ) begin

            addr =
                start_addr
                + (i * 4);


            //----------------------------------------------------
            // Read exactly the same four byte addresses.
            //----------------------------------------------------

            crc_mem_rd_byte(
                addr + 32'd0,
                byte0
            );


            crc_mem_rd_byte(
                addr + 32'd1,
                byte1
            );


            crc_mem_rd_byte(
                addr + 32'd2,
                byte2
            );


            crc_mem_rd_byte(
                addr + 32'd3,
                byte3
            );


            //----------------------------------------------------
            // Rebuild 32-bit word.
            //
            // addr+0 -> [7:0]
            // addr+1 -> [15:8]
            // addr+2 -> [23:16]
            // addr+3 -> [31:24]
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
            // Memory check.
            //----------------------------------------------------

            if (
                word_data !== crc_mem_expected[i]
            ) begin

                `uvm_fatal(
                    get_type_name(),
                    $sformatf(
                        {
                            "CRC MEMORY READBACK FAIL : ",
                            "ADDR=0x%08h ",
                            "EXPECTED=0x%08h ",
                            "READ=0x%08h"
                        },
                        addr,
                        crc_mem_expected[i],
                        word_data
                    )
                )

            end


            //----------------------------------------------------
            // Calculate golden CRC.
            //----------------------------------------------------

            `uvm_info(
                get_type_name(),
                $sformatf(
                    {
                        "CRC GOLDEN WORD : ",
                        "ADDR=0x%08h ",
                        "DATA=0x%08h ",
                        "CRC_BEFORE=0x%04h"
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
                    "CRC_AFTER = 0x%04h",
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
                "CRC GOLDEN FINAL = 0x%04h",
                golden_crc
            ),
            UVM_LOW
        )

    endtask



    //============================================================
    // CRC16 BYTE UPDATE
    //
    // Polynomial:
    //
    // x^16 + x^15 + x^2 + 1
    //
    // POLY = 16'h8005
    //
    // RTL processing order:
    //
    // data[7]
    // data[6]
    // ...
    // data[0]
    //============================================================

    virtual function automatic logic [15:0]
    crc16_update_byte_msb(
        input logic [15:0] crc_i,
        input logic [7:0]  data_i
    );

        logic [15:0] crc;
        logic        feedback;


        crc =
            crc_i;


        for (
            int i = 7;
            i >= 0;
            i--
        ) begin

            //----------------------------------------------------
            // feedback = CRC MSB XOR input bit.
            //----------------------------------------------------

            feedback =
                crc[15]
                ^ data_i[i];


            //----------------------------------------------------
            // Shift left.
            //----------------------------------------------------

            crc =
                {crc[14:0], 1'b0};


            //----------------------------------------------------
            // Apply polynomial.
            //----------------------------------------------------

            if (
                feedback
            ) begin

                crc =
                    crc
                    ^ 16'h8005;

            end

        end


        return crc;

    endfunction



    //============================================================
    // CRC16 WORD UPDATE
    //
    // RTL byte order:
    //
    // FIRST  : data[7:0]
    // SECOND : data[15:8]
    // THIRD  : data[23:16]
    // FOURTH : data[31:24]
    //============================================================

    virtual function automatic logic [15:0]
    crc16_update_word(
        input logic [15:0] crc_i,
        input logic [31:0] data_i
    );

        logic [15:0] crc;


        crc =
            crc_i;


        //--------------------------------------------------------
        // BYTE 0
        //--------------------------------------------------------

        crc =
            crc16_update_byte_msb(
                crc,
                data_i[7:0]
            );


        //--------------------------------------------------------
        // BYTE 1
        //--------------------------------------------------------

        crc =
            crc16_update_byte_msb(
                crc,
                data_i[15:8]
            );


        //--------------------------------------------------------
        // BYTE 2
        //--------------------------------------------------------

        crc =
            crc16_update_byte_msb(
                crc,
                data_i[23:16]
            );


        //--------------------------------------------------------
        // BYTE 3
        //--------------------------------------------------------

        crc =
            crc16_update_byte_msb(
                crc,
                data_i[31:24]
            );


        return crc;

    endfunction



    //============================================================
    // Program CRC registers
    //============================================================

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
                    "START=0x%08h ",
                    "END=0x%08h ",
                    "SEED=0x%04h ",
                    "EXP=0x%04h"
                },
                start_addr,
                end_addr,
                seed,
                exp_checksum
            ),
            UVM_LOW
        )

    endtask



    //============================================================
    // Enable checksum complete
    //============================================================

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
                    "CHKSUM_COMPLETE_EN write fail : READ=0x%02h",
                    rdata
                )
            )

        end

    endtask



    //============================================================
    // CHECK_START
    //
    // 0x00[0] W1S
    //============================================================

    virtual task set_check_start();

        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_CTRL,
            8'h01
        );

    endtask



    //============================================================
    // Poll checksum complete
    //
    // 0x14[0]
    //============================================================

    virtual task poll_chksum_complete(
        input int unsigned max_retry = 10000
    );

        logic [7:0] rdata;
        bit         detected;


        detected =
            1'b0;


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
                    1'b1;


                `uvm_info(
                    get_type_name(),
                    $sformatf(
                        "CHKSUM_COMPLETE detected after %0d polls",
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
                $sformatf(
                    "CRC timeout : CHKSUM_COMPLETE never asserted, max_retry=%0d",
                    max_retry
                )
            )

        end


        //--------------------------------------------------------
        // Verify CHECK_START has self-cleared.
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
                $sformatf(
                    "CHECK_START did not self-clear : CTRL=0x%02h",
                    rdata
                )
            )

        end

    endtask



    //============================================================
    // Read actual checksum
    //============================================================

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


        `uvm_info(
            get_type_name(),
            $sformatf(
                "ACT_CHECKSUM = 0x%04h",
                act_checksum
            ),
            UVM_LOW
        )

    endtask



    //============================================================
    // Read checksum mismatch
    //
    // 0x00[1]
    //============================================================

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


        `uvm_info(
            get_type_name(),
            $sformatf(
                "CHKSUM_MISMATCH = %0b",
                mismatch
            ),
            UVM_LOW
        )

    endtask



    //============================================================
    // Clear checksum complete
    //
    // 0x14[0] W1C
    //============================================================

    virtual task clear_chksum_complete();

        logic [7:0] rdata;


        //--------------------------------------------------------
        // Write 1 to clear.
        //--------------------------------------------------------

        mcu_reg_wr(
            crc_page_addr,
            CRC_REG_CHKSUM_COMPLETE,
            8'h01
        );


        //--------------------------------------------------------
        // Read back and verify clear.
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
                $sformatf(
                    "CHKSUM_COMPLETE clear fail : READ=0x%02h",
                    rdata
                )
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                "CHKSUM_COMPLETE clear PASS",
                UVM_LOW
            )

        end

    endtask



    //============================================================
    // Run one CRC verification case
    //
    // This task verifies TWO independent things:
    //
    // 1. GOLDEN vs ACT
    //    -> CRC calculation
    //
    // 2. EXP vs ACT and mismatch flag
    //    -> checksum comparison logic
    //============================================================

    virtual task run_crc_check_case(
        input string       case_name,
        input logic [31:0] start_addr,
        input logic [31:0] end_addr,
        input logic [15:0] seed,
        input logic [15:0] exp_checksum,
        input logic [15:0] golden_crc,
        input logic        expected_mismatch
    );

        logic [15:0] act_checksum;

        logic actual_mismatch;
        logic derived_mismatch;


        `uvm_info(
            get_type_name(),
            $sformatf(
                {
                    "\n==============================================",
                    "\nCRC CASE : %s",
                    "\n----------------------------------------------",
                    "\nSTART              = 0x%08h",
                    "\nEND                = 0x%08h",
                    "\nSEED               = 0x%04h",
                    "\nGOLDEN             = 0x%04h",
                    "\nEXP_CHECKSUM       = 0x%04h",
                    "\nEXPECTED_MISMATCH  = %0b",
                    "\n=============================================="
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


        //--------------------------------------------------------
        // Clear stale COMPLETE before starting new case.
        //--------------------------------------------------------

        begin

            logic [7:0] complete_data;

            mcu_reg_rd(
                crc_page_addr,
                CRC_REG_CHKSUM_COMPLETE,
                complete_data
            );


            if (
                complete_data[0] === 1'b1
            ) begin

                clear_chksum_complete();

            end

        end


        //========================================================
        // Program config
        //========================================================

        set_crc_config(
            start_addr,
            end_addr,
            exp_checksum,
            seed
        );


        //========================================================
        // Enable completion
        //========================================================

        enable_chksum_complete_en();


        //========================================================
        // Start CRC
        //
        // RTL/spec should clear old mismatch condition when
        // CHECK_START is accepted.
        //========================================================

        set_check_start();


        //========================================================
        // Wait complete
        //========================================================

        poll_chksum_complete(
            10000
        );


        //========================================================
        // Read ACT checksum
        //========================================================

        get_act_checksum(
            act_checksum
        );


        //========================================================
        // CHECK #1
        //
        // Golden vs ACT
        //
        // This MUST pass in both MATCH and MISMATCH cases.
        //========================================================

        if (
            act_checksum !== golden_crc
        ) begin

            `uvm_error(
                get_type_name(),
                $sformatf(
                    {
                        "\n==============================================",
                        "\n[%s] CRC CALCULATION FAIL",
                        "\n----------------------------------------------",
                        "\nGOLDEN CRC    = 0x%04h",
                        "\nACT CHECKSUM  = 0x%04h",
                        "\nEXP CHECKSUM  = 0x%04h",
                        "\n=============================================="
                    },
                    case_name,
                    golden_crc,
                    act_checksum,
                    exp_checksum
                )
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                $sformatf(
                    "[%s] CRC CALC PASS : GOLDEN=0x%04h ACT=0x%04h",
                    case_name,
                    golden_crc,
                    act_checksum
                ),
                UVM_LOW
            )

        end


        //========================================================
        // Read mismatch flag
        //========================================================

        get_chksum_mismatch(
            actual_mismatch
        );


        //========================================================
        // Independently derive mismatch from actual HW values.
        //========================================================

        derived_mismatch =
            (act_checksum != exp_checksum);


        //========================================================
        // CHECK #2
        //
        // Expected testcase behavior.
        //========================================================

        if (
            actual_mismatch !== expected_mismatch
        ) begin

            `uvm_error(
                get_type_name(),
                $sformatf(
                    {
                        "\n==============================================",
                        "\n[%s] CHKSUM_MISMATCH FAIL",
                        "\n----------------------------------------------",
                        "\nGOLDEN             = 0x%04h",
                        "\nACT_CHECKSUM       = 0x%04h",
                        "\nEXP_CHECKSUM       = 0x%04h",
                        "\nEXPECTED_MISMATCH  = %0b",
                        "\nACTUAL_MISMATCH    = %0b",
                        "\n=============================================="
                    },
                    case_name,
                    golden_crc,
                    act_checksum,
                    exp_checksum,
                    expected_mismatch,
                    actual_mismatch
                )
            )

        end
        else begin

            `uvm_info(
                get_type_name(),
                $sformatf(
                    "[%s] CHKSUM_MISMATCH PASS : FLAG=%0b",
                    case_name,
                    actual_mismatch
                ),
                UVM_LOW
            )

        end


        //========================================================
        // CHECK #3
        //
        // Verify RTL mismatch flag really matches ACT != EXP.
        //
        // This avoids the testcase passing just because
        // expected_mismatch was manually specified incorrectly.
        //========================================================

        if (
            actual_mismatch !== derived_mismatch
        ) begin

            `uvm_error(
                get_type_name(),
                $sformatf(
                    {
                        "[%s] MISMATCH LOGIC FAIL : ",
                        "ACT=0x%04h ",
                        "EXP=0x%04h ",
                        "DERIVED=%0b ",
                        "FLAG=%0b"
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
        // Explicit mismatch case check.
        //
        // For CRC_WRITE_MISMATCH:
        //
        // ACT must still equal GOLDEN,
        // while EXP must differ.
        //========================================================

        if (
            expected_mismatch == 1'b1
        ) begin

            if (
                exp_checksum === golden_crc
            ) begin

                `uvm_fatal(
                    get_type_name(),
                    $sformatf(
                        "[%s] Testbench bug : EXP_CHECKSUM accidentally equals GOLDEN",
                        case_name
                    )
                )

            end


            if (
                actual_mismatch !== 1'b1
            ) begin

                `uvm_error(
                    get_type_name(),
                    $sformatf(
                        "[%s] CRC mismatch flag was NOT asserted",
                        case_name
                    )
                )

            end
            else begin

                `uvm_info(
                    get_type_name(),
                    $sformatf(
                        "[%s] CRC mismatch flag successfully asserted",
                        case_name
                    ),
                    UVM_LOW
                )

            end

        end


        //========================================================
        // Clear COMPLETE for next case.
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
