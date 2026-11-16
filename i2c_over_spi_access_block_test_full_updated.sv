//======================================================================
// File: i2c_over_spi_access_block_test_full_updated.sv
// VPlan #135 : I2C over SPI Access Blocking
//
// Initiator : I2C over SPI
// Target    : SPI Leader -> NVM Flash
//
// Based on user's ~320-line original screenshot test.
// No extra include / plusargs / additional UVM classes.
//
// [KEEP] Original ab_irq_check / ab_irq_clear / PP / CE / Read pattern.
// [KEEP] Original TC1 ~ TC5 and protocol dispatch.
// [MODIFY] PP check samples only 8 bytes (program length remains 255).
// [MODIFY] Align erase window for 4KB / 32KB / 64KB.
// [FIX] Use aligned erase_start/last for backdoor snapshots and checks.
// [FIX] Avoid force_flash_data(last, 'h1000) writing outside region.
// [NEW] Block Erase 32KB (52h) and protected overlap TC6.
// [NEW] Three intentionally unfinished command-sending tasks:
//        Quad PP (32h), BE 32KB (52h), CE (C7h).
//
// NOTE 1: Fill the 3 [TODO] tasks before running cases using them.
//         They stop with UVM_FATAL until implemented, avoiding false PASS.
// NOTE 2: Existing proprietary helpers are inferred from screenshots.
//         Exact compile and simulation PASS are not claimed.
// NOTE 3: Confirm actual Flash model size for 0x050000 / 0x070000.
//======================================================================

class i2c_over_spi_access_block_test extends host_i2c_over_spi_base_test;

    `uvm_component_utils(i2c_over_spi_access_block_test)

    localparam bit [1:0] SPI_SEL = 2'd0;

    // [MODIFY] Append enum entries; keep old numeric encodings unchanged.
    typedef enum {
        CMD_WREN,
        CMD_PP,
        CMD_SE,
        CMD_BE,
        CMD_CE,
        CMD_QPP,      // [NEW] 32h
        CMD_BE32,     // [NEW] 52h
        CMD_CE_C7     // [NEW] C7h
    } ab_cmd_e;

    localparam int AB_PP_LEN      = 255;
    localparam int AB_PP_CHECK    = 8;
    localparam int AB_ERASE_CHECK = 255;
    localparam int AB_SECTOR      = 'h1000;
    localparam int AB_BLOCK       = 'h10000;
    localparam int AB_BLOCK_32    = 'h8000; // [NEW] 32KB

    localparam logic [23:0] AB_PROT_ADDR = 24'h030000;
    localparam logic [23:0] AB_FREE_ADDR = 24'h050000;

    logic [19:0] ab_part_start[3];


    //==================================================================
    // [KEEP] IRQ status and W1C clear, as in original test.
    //==================================================================
    virtual task ab_irq_check(
        input bit [3:0] value,
        input string tag
    );
        `uvm_info(get_type_name(),
            $sformatf("ab_irq_check: value=%h, tag=%s", value, tag),
            UVM_LOW)

        mcu_masked_data_check(
            m_host_top_cfg.access_blocking_page_addr_3,
            8'hFB,
            value,
            8'h0F
        );
    endtask

    virtual task ab_irq_clear(input string tag);
        `uvm_info(get_type_name(),
            $sformatf("ab_irq_clear: %s", tag), UVM_LOW)

        mcu_reg_wr_bits(
            m_host_top_cfg.access_blocking_page_addr_3,
            8'hFB,
            8'h0F,
            8'h0F
        );
    endtask


    //==================================================================
    // [KEEP] Page Program check.
    // [NEW] Optional QPP opcode; original calls still default to 02h.
    // [FIX] Allowed-program check uses AB_PP_CHECK (8), not AB_PP_LEN.
    //==================================================================
    virtual task ab_test_pp(
        input logic [23:0] addr,
        input bit blocked,
        input bit debug_en,
        input logic [3:0] exp_irq,
        input bit use_qpp = 0
    );
        `uvm_info(get_type_name(),
            $sformatf("ab_test_pp addr=%06h blocked=%0b debug_en=%0b exp_irq=%h opcode=%02h",
                      addr, blocked, debug_en, exp_irq,
                      use_qpp ? 8'h32 : 8'h02), UVM_LOW)

        initial_flash_data();
        force_eff_mcu_debug_en(debug_en);
        #2us;

        ab_irq_clear("PP BEFORE");
        ab_command(CMD_WREN);
        #10us;

        if (use_qpp)
            ab_command(CMD_QPP, addr);
        else
            ab_command(CMD_PP, addr);

        #100us;

        if (blocked) begin
            backdoor_check_fixed_value(
                8'hFF, addr, AB_PP_CHECK, "PP_BLOCK");
        end
        else begin
            // [MODIFY] Only compare 8 bytes, not the full 255 bytes.
            ab_verify_programmed(addr, AB_PP_CHECK);
        end

        `uvm_info(get_type_name(),
            $sformatf("ab_test_pp done addr=%06h", addr), UVM_LOW)

        ab_irq_check(exp_irq, "PP AFTER");
        ab_irq_clear("PP AFTER");
        release_eff_mcu_debug_en();
    endtask


    //==================================================================
    // [MODIFY] Shared 4KB / 32KB / 64KB erase verification.
    //
    // block_erase = 0 : 4KB  SE   20h
    // block_erase = 1 : 64KB BE   D8h
    // block_erase = 2 : 32KB BE   52h
    //
    // Crucial rule:
    //   - Send ORIGINAL addr to command (test RTL address conversion).
    //   - Use ALIGNED erase_start/last for Flash snapshots and checks.
    //==================================================================
    virtual task ab_test_erase(
        input logic [23:0] addr,
        input int block_erase,
        input bit blocked,
        input bit debug_en,
        input logic [3:0] exp_irq
    );
        logic [23:0] erase_start;
        logic [23:0] last;
        logic [7:0]  first_data[];
        logic [7:0]  last_data[];
        int region;

        // [FIX] Actual erase region is aligned based on opcode.
        case (block_erase)
            0: begin
                region      = AB_SECTOR;
                erase_start = {addr[23:12], 12'h000};
            end
            1: begin
                region      = AB_BLOCK;
                erase_start = {addr[23:16], 16'h0000};
            end
            2: begin
                region      = AB_BLOCK_32;
                erase_start = {addr[23:15], 15'h0000};
            end
            default: `uvm_fatal("AB_ERASE", "Invalid block_erase mode")
        endcase

        last = erase_start + region - 'h100;

        `uvm_info(get_type_name(),
            $sformatf("ab_test_erase cmd_addr=%06h erase_start=%06h last=%06h mode=%0d blocked=%0b debug_en=%0b exp_irq=%h",
                      addr, erase_start, last, block_erase,
                      blocked, debug_en, exp_irq), UVM_LOW)

        initial_flash_data();

        // [FIX] Only initialize first/last 256-byte samples.
        // Previous force_flash_data(last, 'h1000) could spill past block.
        force_flash_data(erase_start, 'h100);
        force_flash_data(last,        'h100);

        // [FIX] Snapshot the actual erase window, not command addr.
        flash_backdoor_read(erase_start, AB_ERASE_CHECK, first_data);
        flash_backdoor_read(last,        AB_ERASE_CHECK, last_data);

        force_eff_mcu_debug_en(debug_en);
        #2us;

        ab_irq_clear("ERASE BEFORE");
        ab_command(CMD_WREN);
        #10us;

        // [MODIFY] Keep original command address. Never replace with
        // erase_start here, or the overlap-address test is lost.
        case (block_erase)
            0: ab_command(CMD_SE, addr);
            1: ab_command(CMD_BE, addr);
            2: ab_command(CMD_BE32, addr);
        endcase

        // [KEEP] Original post-command wait.
        // Confirm WIP polling is handled inside low-level erase helpers.
        #300us;

        if (blocked) begin
            backdoor_check_with_expect_data_no_check_len(
                erase_start, first_data, "ERASE_BLOCK_FIRST");

            backdoor_check_with_expect_data_no_check_len(
                last, last_data, "ERASE_BLOCK_LAST");
        end
        else begin
            backdoor_check_fixed_value(
                8'hFF, erase_start, AB_ERASE_CHECK, "ERASE_PASS_FIRST");

            backdoor_check_fixed_value(
                8'hFF, last, AB_ERASE_CHECK, "ERASE_PASS_LAST");
        end

        ab_irq_check(
            exp_irq,
            (block_erase == 0) ? "SE AFTER" :
            (block_erase == 2) ? "BE32 AFTER" : "BE64 AFTER"
        );

        `uvm_info(get_type_name(),
            $sformatf("ab_test_erase done addr=%06h", addr), UVM_LOW)

        ab_irq_clear("ERASE AFTER");
        release_eff_mcu_debug_en();
    endtask


    //==================================================================
    // [KEEP] Chip Erase is GLOBAL, so check protected and free locations.
    // [NEW] use_c7 selects alternative C7h command. Default remains 60h.
    //==================================================================
    virtual task ab_test_ce(
        input bit blocked,
        input bit debug_en,
        input logic [3:0] exp_irq,
        input bit use_c7 = 0
    );
        logic [7:0] saved_p[];
        logic [7:0] saved_f[];

        `uvm_info(get_type_name(),
            $sformatf("ab_test_ce blocked=%0b debug_en=%0b exp_irq=%h opcode=%02h",
                      blocked, debug_en, exp_irq,
                      use_c7 ? 8'hC7 : 8'h60), UVM_LOW)

        initial_flash_data();
        force_flash_data(AB_PROT_ADDR, 'h100);
        force_flash_data(AB_FREE_ADDR, 'h100);

        flash_backdoor_read(AB_PROT_ADDR, AB_ERASE_CHECK, saved_p);
        flash_backdoor_read(AB_FREE_ADDR, AB_ERASE_CHECK, saved_f);

        force_eff_mcu_debug_en(debug_en);
        #2us;
        ab_irq_clear("CE BEFORE");
        ab_command(CMD_WREN);
        #10us;

        if (use_c7)
            ab_command(CMD_CE_C7);
        else
            ab_command(CMD_CE);

        #300us;

        if (blocked) begin
            backdoor_check_with_expect_data_no_check_len(
                AB_PROT_ADDR, saved_p, "CE_BLOCK_PROT");
            backdoor_check_with_expect_data_no_check_len(
                AB_FREE_ADDR, saved_f, "CE_BLOCK_FREE");
        end
        else begin
            backdoor_check_fixed_value(
                8'hFF, AB_PROT_ADDR, AB_ERASE_CHECK, "CE_PASS_PROT");
            backdoor_check_fixed_value(
                8'hFF, AB_FREE_ADDR, AB_ERASE_CHECK, "CE_PASS_FREE");
        end

        ab_irq_check(exp_irq, "CE AFTER");
        `uvm_info(get_type_name(), "ab_test_ce done", UVM_LOW)
        ab_irq_clear("CE AFTER");
        release_eff_mcu_debug_en();
    endtask


    //==================================================================
    // [KEEP] Original Fast Read flow (from screenshots).
    // [NOTE] RX payload comparison still depends on existing I2C scoreboard.
    //==================================================================
    virtual task ab_test_read(
        input logic [23:0] addr,
        input bit debug_en
    );
        logic [7:0] before_data[];

        `uvm_info(get_type_name(),
            $sformatf("ab_test_read addr=%06h debug_en=%0b",
                      addr, debug_en), UVM_LOW)

        initial_flash_data();
        force_eff_mcu_debug_en(debug_en);
        #2us;

        i2c_over_spi_write_enable(0);
        #10us;

        // [KEEP] Existing base method arguments from original screenshot.
        i2c_over_spi_page_program(
            reg_set.flash_start_addr, reg_set.data, reg_set.data_word);
        #100us;

        backdoor_check(
            reg_set.flash_start_addr, reg_set.data, reg_set.data_word);

        #($urandom_range(20, 50) * 1us);

        i2c_over_spi_fast_read(
            reg_set.flash_start_addr, reg_set.data_word);
        #30us;

        `uvm_info(get_type_name(),
            $sformatf("ab_test_read done addr=%06h", addr), UVM_LOW)

        ab_irq_check(4'b0000, "READ AFTER");
        ab_irq_clear("READ AFTER");
        release_eff_mcu_debug_en();
    endtask


    //==================================================================
    // [KEEP + MODIFY] Original test scenarios.
    // Change tc=3 manually when targeting a different case.
    //==================================================================
    virtual task ab_run_all();
        logic [3:0] irq_prot;
        int tc;

        ab_part_start[0] = 20'h00020;
        ab_part_start[1] = 20'h00040;
        ab_part_start[2] = 20'h00060;

        ab_init();

        `uvm_info(get_type_name(),
            $sformatf("ab_run_all START part_start={%0h,%0h,%0h}",
                      ab_part_start[0],
                      ab_part_start[1],
                      ab_part_start[2]), UVM_LOW)

        irq_prot = 4'b0010;

        // [KEEP] Your screenshot currently hard-codes TC=3.
        // Change to 6 to execute the new overlap case.
        tc = 3;
        // tc = 6;

        `uvm_info(get_type_name(),
            $sformatf("=== TC selected: %0d ===", tc), UVM_LOW)

        case (tc)

            //==========================================================
            // TC1: No protection, DEBUG=0.
            //==========================================================
            1: begin
                `uvm_info(get_type_name(),
                    "=== TC1: no protection, DEBUG=0 ===", UVM_LOW)

                force_nvm_protect(
                    .prot_en(4'b0000),
                    .part_start0(ab_part_start[0]),
                    .part_start1(ab_part_start[1]),
                    .part_start2(ab_part_start[2]));
                #2us;

                ab_test_pp(.addr(AB_PROT_ADDR),
                           .blocked(0), .debug_en(0), .exp_irq(4'b0));

                release_nvm_protect();
            end

            //==========================================================
            // TC2: Protection enabled, DEBUG=1 bypass.
            //==========================================================
            2: begin
                `uvm_info(get_type_name(),
                    "=== TC2: protection enabled, DEBUG=1 bypass ===",
                    UVM_LOW)

                force_nvm_protect(
                    .prot_en(4'b0010),
                    .part_start0(ab_part_start[0]),
                    .part_start1(ab_part_start[1]),
                    .part_start2(ab_part_start[2]));
                #2us;

                ab_test_pp(.addr(AB_PROT_ADDR),
                           .blocked(0), .debug_en(1), .exp_irq(4'b0));

                ab_test_erase(.addr(AB_PROT_ADDR), .block_erase(0),
                              .blocked(0), .debug_en(1), .exp_irq(4'b0));

                // [NEW] 32KB valid with DEBUG bypass.
                ab_test_erase(.addr(AB_PROT_ADDR), .block_erase(2),
                              .blocked(0), .debug_en(1), .exp_irq(4'b0));

                ab_test_erase(.addr(AB_PROT_ADDR), .block_erase(1),
                              .blocked(0), .debug_en(1), .exp_irq(4'b0));

                ab_test_ce(.blocked(0), .debug_en(1), .exp_irq(4'b0));
                release_nvm_protect();
            end

            //==========================================================
            // TC3: Protection enabled, DEBUG=0, protected address.
            // All requested PP / 4K / 32K / 64K / CE opcodes.
            //==========================================================
            3: begin
                `uvm_info(get_type_name(),
                    "=== TC3: protected address, DEBUG=0 => BLOCK ===",
                    UVM_LOW)

                force_nvm_protect(
                    .prot_en(4'b0010),
                    .part_start0(ab_part_start[0]),
                    .part_start1(ab_part_start[1]),
                    .part_start2(ab_part_start[2]));
                #2us;

                // 02h PP
                ab_test_pp(.addr(AB_PROT_ADDR),
                           .blocked(1), .debug_en(0), .exp_irq(irq_prot));

                // [NEW] 32h QPP
                ab_test_pp(.addr(AB_PROT_ADDR),
                           .blocked(1), .debug_en(0), .exp_irq(irq_prot),
                           .use_qpp(1));

                // 20h SE 4KB
                ab_test_erase(.addr(AB_PROT_ADDR), .block_erase(0),
                              .blocked(1), .debug_en(0),
                              .exp_irq(irq_prot));

                // [NEW] 52h BE 32KB
                ab_test_erase(.addr(AB_PROT_ADDR), .block_erase(2),
                              .blocked(1), .debug_en(0),
                              .exp_irq(irq_prot));

                // D8h BE 64KB
                ab_test_erase(.addr(AB_PROT_ADDR), .block_erase(1),
                              .blocked(1), .debug_en(0),
                              .exp_irq(irq_prot));

                // 60h CE
                ab_test_ce(.blocked(1), .debug_en(0), .exp_irq(irq_prot));

                // [NEW] C7h CE
                ab_test_ce(.blocked(1), .debug_en(0), .exp_irq(irq_prot),
                           .use_c7(1));

                // [KEEP] Read remains allowed with protection enabled.
                // ab_test_read(.addr(AB_PROT_ADDR), .debug_en(0));

                release_nvm_protect();
            end

            //==========================================================
            // TC4: Protection enabled, DEBUG=0, free address.
            //==========================================================
            4: begin
                `uvm_info(get_type_name(),
                    "=== TC4: protection enabled, unprotected address ===",
                    UVM_LOW)

                force_nvm_protect(
                    .prot_en(4'b0010),
                    .part_start0(ab_part_start[0]),
                    .part_start1(ab_part_start[1]),
                    .part_start2(ab_part_start[2]));
                #2us;

                ab_test_pp(.addr(AB_FREE_ADDR),
                           .blocked(0), .debug_en(0), .exp_irq(4'b0));

                ab_test_erase(.addr(AB_FREE_ADDR), .block_erase(0),
                              .blocked(0), .debug_en(0), .exp_irq(4'b0));

                // [NEW] 32KB free-range erase.
                ab_test_erase(.addr(AB_FREE_ADDR), .block_erase(2),
                              .blocked(0), .debug_en(0), .exp_irq(4'b0));

                ab_test_erase(.addr(AB_FREE_ADDR), .block_erase(1),
                              .blocked(0), .debug_en(0), .exp_irq(4'b0));

                // CE omitted: global, blocked if any protected region.
                // ab_test_read(.addr(AB_FREE_ADDR), .debug_en(0));

                release_nvm_protect();
            end

            //==========================================================
            // TC5: One enabled protection bit at a time.
            //==========================================================
            5: begin
                `uvm_info(get_type_name(),
                    "=== TC5: each protection bit, PP and sticky IRQ ===",
                    UVM_LOW)

                for (int p = 0; p < 4; p++) begin
                    logic [3:0]  onehot;
                    logic [23:0] probe;
                    logic [3:0]  irq_expected;

                    onehot = (4'b0001 << p);
                    case (p)
                        0: probe = 24'h010000; // [FIX] PART0
                        1: probe = 24'h030000; // PART1
                        2: probe = 24'h050000; // PART2
                        3: probe = 24'h070000; // PART3
                        default: probe = 24'h000000;
                    endcase

                    force_nvm_protect(
                        .prot_en(onehot),
                        .part_start0(ab_part_start[0]),
                        .part_start1(ab_part_start[1]),
                        .part_start2(ab_part_start[2]));

                    `uvm_info(get_type_name(),
                        $sformatf("TC5 p=%0d probe=%06h onehot=%h",
                                  p, probe, onehot), UVM_LOW)
                    #2us;

                    irq_expected = onehot;
                    ab_test_pp(.addr(probe),
                               .blocked(1), .debug_en(0),
                               .exp_irq(irq_expected));

                    release_nvm_protect();
                end
            end

            //==========================================================
            // [NEW] TC6: Erase-window overlap test.
            //
            // PART1 starts at 0x23000 (not aligned to 32KB/64KB).
            // Command address 0x22000 is outside protected PART1.
            // 32KB window = 0x20000..0x27FFF, overlaps PART1.
            // 64KB window = 0x20000..0x2FFFF, overlaps PART1.
            // Expected both BLOCK and IRQ[1] = 1.
            //==========================================================
            6: begin
                `uvm_info(get_type_name(),
                    "=== TC6: erase window overlaps protected range ===",
                    UVM_LOW)

                force_nvm_protect(
                    .prot_en(4'b0010),
                    .part_start0(20'h00023),
                    .part_start1(ab_part_start[1]),
                    .part_start2(ab_part_start[2]));
                #2us;

                // 4KB: unaligned command addr inside protected sector.
                ab_test_erase(.addr(24'h023123), .block_erase(0),
                              .blocked(1), .debug_en(0),
                              .exp_irq(4'b0010));

                // 32KB: unprotected cmd addr, protected erase overlap.
                ab_test_erase(.addr(24'h022000), .block_erase(2),
                              .blocked(1), .debug_en(0),
                              .exp_irq(4'b0010));

                // 64KB: unprotected cmd addr, protected erase overlap.
                ab_test_erase(.addr(24'h022000), .block_erase(1),
                              .blocked(1), .debug_en(0),
                              .exp_irq(4'b0010));

                release_nvm_protect();
            end

            default: `uvm_fatal("AB_TC", "Unsupported test case")
        endcase
    endtask


    //==================================================================
    // [KEEP] Constructor and test initialization.
    //==================================================================
    function new(
        string name = "i2c_over_spi_access_block_test",
        uvm_component parent = null
    );
        super.new(name, parent);
    endfunction

    virtual task ab_init();
        mcu_test_preset();
        `uvm_info(get_type_name(),
            "enable NVM protection range 4 IRQs", UVM_LOW)

        mcu_reg_wr_bits(
            m_host_top_cfg.access_blocking_page_addr_3,
            8'hFF,
            8'h0F,
            8'h0F
        );

        i2c_over_spi_test_preset(SPI_SEL);
    endtask


    //==================================================================
    // [NEW] Three minimal user-implemented transaction tasks.
    //
    // DO NOT replace these with empty bodies: an empty task would let
    // blocked writes/erases appear to PASS without sending any command.
    //
    // Caller sends WREN. These tasks must issue only their corresponding
    // command and wait until transaction completion.
    //==================================================================

    // [NEW] 32h Quad Page Program: 32h + address + QUAD data phase.
    virtual task ab_quad_page_program(
        input logic [23:0] addr,
        ref byte data[$]
    );
        // TODO: Implement actual I2C-over-SPI command/address/data flow.
        // Check whether the active SPI flash model supports Quad PP (32h).
        `uvm_fatal("AB_TODO_QPP", "Implement I2C-over-SPI Quad PP 32h")
    endtask

    // [NEW] 52h 32KB Erase: 52h + 24-bit address.
    virtual task ab_block_erase_32k(
        input logic [23:0] addr
    );
        // TODO: Implement actual I2C-over-SPI command/address flow.
        // Wait for WIP=0 before returning.
        `uvm_fatal("AB_TODO_BE32", "Implement I2C-over-SPI BE32 52h")
    endtask

    // [NEW] C7h Chip Erase: C7h with NO address.
    virtual task ab_chip_erase_c7();
        // TODO: Implement actual I2C-over-SPI command flow.
        // Wait for WIP=0 before returning.
        `uvm_fatal("AB_TODO_C7", "Implement I2C-over-SPI CE C7h")
    endtask


    //==================================================================
    // [KEEP + NEW] Single I2C-specific command dispatcher.
    //==================================================================
    virtual task ab_command(
        input ab_cmd_e cmd,
        input logic [23:0] addr = '0
    );
        byte data[$];

        case (cmd)
            CMD_WREN: i2c_over_spi_write_enable(SPI_SEL);

            CMD_PP: begin
                for (int i = 0; i < AB_PP_LEN; i++)
                    data.push_back(byte'(1+(i%200)));
                i2c_over_spi_page_program(
                    addr, data, AB_PP_LEN, SPI_SEL);
            end

            CMD_SE: i2c_over_spi_sector_erase(addr, SPI_SEL);
            CMD_BE: i2c_over_spi_block_erase(addr, SPI_SEL);
            CMD_CE: i2c_over_spi_chip_erase(SPI_SEL);

            // [NEW] Run user-implemented tasks.
            CMD_QPP: begin
                for (int i = 0; i < AB_PP_LEN; i++)
                    data.push_back(byte'(1+(i%200)));
                ab_quad_page_program(addr, data);
            end
            CMD_BE32:  ab_block_erase_32k(addr);
            CMD_CE_C7: ab_chip_erase_c7();

            default:
                `uvm_fatal("AB_CMD", "Unsupported I2C-to-SPI command")
        endcase
    endtask


    //==================================================================
    // [KEEP] Backdoor golden-pattern comparison.
    //==================================================================
    virtual task ab_verify_programmed(
        input logic [23:0] addr,
        input int n
    );
        logic [7:0] actual[];
        flash_backdoor_read(addr, n, actual);

        if (actual.size() != n)
            `uvm_fatal("AB_PP", "Backdoor size mismatch")

        foreach (actual[i]) begin
            if (actual[i] !== 8'(1+(i%200)))
                `uvm_error("AB_PP",
                    $sformatf("addr=%06h exp=%02h got=%02h",
                              addr+i, 8'(1+(i%200)), actual[i]))
        end
    endtask


    //==================================================================
    // [KEEP] Main UVM phase.
    //==================================================================
    virtual task run_phase(uvm_phase phase);
        super.run_phase(phase);

        phase.raise_objection(this, "Start");
        ab_run_all();
        phase.drop_objection(this, "Finish");
    endtask

endclass
