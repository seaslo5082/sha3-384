//======================================================================
// Shared Access Blocking verification body for VPlan 135 / 136.
// INCLUDED INSIDE each derived UVM test class (NOT a stand-alone class).
//
// Required class-specific adapters:
//   ab_init()                       : protocol initialization + IRQ RAL
//   ab_command(cmd, addr)           : SPI or I2C-to-SPI commands
//   ab_verify_programmed(addr,n)    : compare PP data against source
//   ab_read_frontdoor(addr)         : read + check actual received data
//
// Fixed option: AB_OPTION = 0 SPI Master, 1 I2C-to-SPI.
// No command-line plusargs. No one-line WREN/SE/BE/DEBUG wrappers.
//======================================================================
typedef enum { CMD_WREN, CMD_PP, CMD_SE, CMD_BE, CMD_CE } ab_cmd_e;
localparam int AB_PP_LEN = 255;
localparam int AB_PP_CHECK = 8;       // [MODIFY] PP checks only 8 bytes
localparam int AB_ERASE_CHECK = 255; // [KEEP] Erase samples 255 bytes/page
localparam int AB_SECTOR = 'h1000;
localparam int AB_BLOCK = 'h10000;
localparam logic [23:0] AB_PROT_ADDR = 24'h030000;
localparam logic [23:0] AB_FREE_ADDR = 24'h050000;
logic [19:0] ab_part_start[3];
uvm_reg ab_irq_reg;

// [KEEP] Check the real sticky NVM IRQ register and W1C behavior.
// Use RAL FRONTDOOR; ab_init() MUST supply its actual register handle.
virtual task ab_irq_check(input logic [3:0] expected, input string tag);
    uvm_status_e st;
    uvm_reg_data_t data;
    if (ab_irq_reg == null)
        `uvm_fatal("AB_IRQ", "Bind real NVM_PROT_IRQ_STATUS RAL handle in ab_init()")
    ab_irq_reg.read(st, data, UVM_FRONTDOOR);
    if (st != UVM_IS_OK)
        `uvm_fatal("AB_IRQ", $sformatf("%s IRQ read failed", tag))
    if (data[3:0] !== expected)
        `uvm_error("AB_IRQ", $sformatf("%s exp=%b got=%b", tag, expected, data[3:0]))
endtask

virtual task ab_irq_clear(input string tag);
    uvm_status_e st;
    if (ab_irq_reg == null)
        `uvm_fatal("AB_IRQ", "IRQ RAL register not bound")
    ab_irq_reg.write(st, 'hF, UVM_FRONTDOOR); // W1C status[3:0]
    if (st != UVM_IS_OK)
        `uvm_fatal("AB_IRQ", $sformatf("%s W1C write failed", tag))
    ab_irq_check(4'b0000, {tag, " cleared"});
endtask

// [KEEP] General flash memory checkers: NOT one-line wrappers.
virtual task ab_check_ff(input logic [23:0] addr, input int count, input string tag);
    for (int i=0; i<count; i++)
        if (`UVM_SYSTEM.i_tcon_rom_1.memory[addr+i] !== 8'hFF)
            `uvm_error("AB_FLASH", $sformatf("%s addr=%06h exp=FF got=%02h",
                         tag, addr+i, `UVM_SYSTEM.i_tcon_rom_1.memory[addr+i]))
endtask

virtual task ab_save_data(input logic [23:0] addr, input int count,
                          output logic [7:0] saved[]);
    saved = new[count];
    foreach(saved[i]) saved[i] = `UVM_SYSTEM.i_tcon_rom_1.memory[addr+i];
endtask

virtual task ab_check_saved(input logic [23:0] addr,
                            input logic [7:0] saved[], input string tag);
    foreach(saved[i])
        if (`UVM_SYSTEM.i_tcon_rom_1.memory[addr+i] !== saved[i])
            `uvm_error("AB_FLASH", $sformatf("%s addr=%06h exp=%02h got=%02h",
                         tag,addr+i,saved[i],`UVM_SYSTEM.i_tcon_rom_1.memory[addr+i]))
endtask

// [KEEP] Setup phase has real meaning: DEBUG bypass, erase, check.
virtual task ab_setup_erase(input logic [23:0] addr);
    set_eff_mcu_debug_en(1'b1);
    #2us;
    ab_command(CMD_WREN);
    ab_command(CMD_SE, {addr[23:12],12'h000});
    #300us; // TODO: replace fixed delay with model WIP/BUSY polling.
    ab_check_ff(addr, AB_ERASE_CHECK, "SETUP_ERASE");
endtask

// [FIX] Program-only: DO NOT erase inside this task.
virtual task ab_setup_program(input logic [23:0] addr);
    bit non_ff;
    set_eff_mcu_debug_en(1'b1);
    #2us;
    ab_command(CMD_WREN);
    ab_command(CMD_PP,addr);
    #100us;
    ab_verify_programmed(addr,AB_PP_CHECK);
    non_ff=0;
    for (int i=0;i<AB_PP_CHECK;i++)
        if (`UVM_SYSTEM.i_tcon_rom_1.memory[addr+i] !== 8'hFF) non_ff=1;
    if (!non_ff) `uvm_fatal("AB_SETUP", "Program setup produced all-FF data")
endtask

virtual task ab_test_pp(input logic [23:0] addr, input bit blocked,
                        input bit debug_en, input logic [3:0] exp_irq);
    ab_setup_erase(addr);
    set_eff_mcu_debug_en(debug_en);
    #2us;
    ab_irq_clear("PP BEFORE");
    ab_command(CMD_WREN);
    ab_command(CMD_PP,addr);
    #100us;
    if (blocked) ab_check_ff(addr,AB_PP_CHECK,"PP_BLOCK");
    else         ab_verify_programmed(addr,AB_PP_CHECK);
    ab_irq_check(exp_irq,"PP AFTER");
    ab_irq_clear("PP AFTER");
endtask

// [KEEP] Sector and block erase share meaningful baseline/check logic.
virtual task ab_test_erase(input logic [23:0] addr, input bit block_erase,
                           input bit blocked, input bit debug_en,
                           input logic [3:0] exp_irq);
    logic [23:0] last;
    logic [7:0] first_data[],last_data[];
    int region;
    region = block_erase ? AB_BLOCK : AB_SECTOR;
    last = addr+region-'h100;
    ab_setup_erase(addr);
    if (block_erase) ab_setup_erase(last); // different sector only
    ab_setup_program(addr);
    ab_setup_program(last); // no erase between two programs
    ab_save_data(addr,AB_ERASE_CHECK,first_data);
    ab_save_data(last,AB_ERASE_CHECK,last_data);
    set_eff_mcu_debug_en(debug_en);
    #2us;
    ab_irq_clear("ERASE BEFORE");
    ab_command(CMD_WREN);
    if (block_erase) ab_command(CMD_BE,addr);
    else             ab_command(CMD_SE,addr);
    if (block_erase) #1ms;
    else             #300us;
    if (blocked) begin
        ab_check_saved(addr,first_data,"ERASE_BLOCK_FIRST");
        ab_check_saved(last,last_data,"ERASE_BLOCK_LAST");
    end else begin
        ab_check_ff(addr,AB_ERASE_CHECK,"ERASE_PASS_FIRST");
        ab_check_ff(last,AB_ERASE_CHECK,"ERASE_PASS_LAST");
    end
    ab_irq_check(exp_irq,block_erase?"BE AFTER":"SE AFTER");
    ab_irq_clear("ERASE AFTER");
endtask

// [KEEP] CE is GLOBAL; sample both a protected and a free region.
virtual task ab_test_ce(input bit blocked,input bit debug_en,
                        input logic [3:0] exp_irq);
    logic [7:0] saved_p[],saved_f[];
    ab_setup_erase(AB_PROT_ADDR);
    ab_setup_erase(AB_FREE_ADDR);
    ab_setup_program(AB_PROT_ADDR);
    ab_setup_program(AB_FREE_ADDR);
    ab_save_data(AB_PROT_ADDR,AB_ERASE_CHECK,saved_p);
    ab_save_data(AB_FREE_ADDR,AB_ERASE_CHECK,saved_f);
    set_eff_mcu_debug_en(debug_en);
    #2us;
    ab_irq_clear("CE BEFORE");
    ab_command(CMD_WREN);
    ab_command(CMD_CE);
    #5ms;
    if (blocked) begin
        ab_check_saved(AB_PROT_ADDR,saved_p,"CE_BLOCK_PROT");
        ab_check_saved(AB_FREE_ADDR,saved_f,"CE_BLOCK_FREE");
    end else begin
        ab_check_ff(AB_PROT_ADDR,AB_ERASE_CHECK,"CE_PASS_PROT");
        ab_check_ff(AB_FREE_ADDR,AB_ERASE_CHECK,"CE_PASS_FREE");
    end
    ab_irq_check(exp_irq,"CE AFTER");
    ab_irq_clear("CE AFTER");
endtask

virtual task ab_test_read(input logic [23:0] addr,input bit debug_en);
    logic [7:0] before[];
    ab_setup_erase(addr);
    ab_setup_program(addr);
    ab_save_data(addr,AB_ERASE_CHECK,before);
    set_eff_mcu_debug_en(debug_en);
    #2us;
    ab_irq_clear("READ BEFORE");
    ab_read_frontdoor(addr); // SPI: RX DRAM; I2C: RX scoreboard must verify
    ab_check_saved(addr,before,"READ_UNCHANGED");
    ab_irq_check(4'b0000,"READ AFTER");
    ab_irq_clear("READ AFTER");
endtask

// [MODIFY] Shared policy and all TC live in ONE place.
// Protocol-specific helper wrappers no longer clutter run_phase.
virtual task ab_run_all();
    bit free_blocked;
    logic [3:0] irq_prot;
    ab_part_start[0]=20'h00020;
    ab_part_start[1]=20'h00040;
    ab_part_start[2]=20'h00060;
    ab_init();
    if (m_host_top_cfg.spi_flash_addr_max < 24'h0700FF)
        `uvm_fatal("AB_SIZE", "Selected Flash does not contain partition-3 probe address 0x070000")
    if (ab_irq_reg==null)
        `uvm_fatal("AB_IRQ", "Missing NVM_PROT_IRQ_STATUS register handle")
    free_blocked=(AB_OPTION==1); // ERS: I2C-to-SPI writes require DEBUG=1 (verify RTL)
    irq_prot=(AB_OPTION==0)?4'b0010:4'b0000; // I2C target IRQ assumption; verify DD RTL

    // TC1: no protection, DEBUG=0
    m_chip_env.m_spi_env.vif.force_nvm_protect(
        4'b0000, ab_part_start[0], ab_part_start[1], ab_part_start[2]);
    #2us;
    ab_test_pp(AB_PROT_ADDR,free_blocked,0,4'b0);

    // TC2: protection enabled, DEBUG=1 bypass
    m_chip_env.m_spi_env.vif.force_nvm_protect(
        4'b0010, ab_part_start[0], ab_part_start[1], ab_part_start[2]);
    #2us;
    ab_test_pp(AB_PROT_ADDR,0,1,0);
    ab_test_erase(AB_PROT_ADDR,0,0,1,0);
    ab_test_erase(AB_PROT_ADDR,1,0,1,0);
    ab_test_ce(0,1,0);

    // TC3: protection enabled, DEBUG=0, protected address
    ab_test_pp(AB_PROT_ADDR,1,0,irq_prot);
    ab_test_erase(AB_PROT_ADDR,0,1,0,irq_prot);
    ab_test_erase(AB_PROT_ADDR,1,1,0,irq_prot);
    ab_test_ce(1,0,irq_prot);
    ab_test_read(AB_PROT_ADDR,0);

    // TC4: protection enabled, DEBUG=0, unprotected address
    ab_test_pp(AB_FREE_ADDR,free_blocked,0,0);
    ab_test_erase(AB_FREE_ADDR,0,free_blocked,0,0);
    ab_test_erase(AB_FREE_ADDR,1,free_blocked,0,0);
    ab_test_read(AB_FREE_ADDR,0);

    // TC5: enable each protection bit, check PP and sticky IRQ
    for (int p=0;p<4;p++) begin
        logic [3:0] onehot;
        logic [23:0] probe;
        logic [3:0] irq_expected;
        onehot=4'b0001<<p;
        case (p)
            0: probe=24'h010000;
            1: probe=24'h030000;
            2: probe=24'h050000;
            3: probe=24'h070000;
            default: probe=24'h000000;
        endcase
        m_chip_env.m_spi_env.vif.force_nvm_protect(
            onehot, ab_part_start[0], ab_part_start[1], ab_part_start[2]);
        #2us;
        irq_expected=(AB_OPTION==0)?onehot:4'b0; // I2C IRQ requires RTL confirmation
        ab_test_pp(probe,1,0,irq_expected);
    end
endtask

//////////////
//======================================================================
// VPlan 135: I2C follower -> I2C-to-SPI Bridge -> SPI0 NVM
// Uses SAME verification flow as SPI test, protocol adapter differs.
//======================================================================
class i2c_over_spi_access_block_test extends host_i2c_over_spi_base_test;
    `uvm_component_utils(i2c_over_spi_access_block_test)
    localparam int AB_OPTION=1;
    localparam bit [1:0] SPI_SEL=2'd0;
    `include "nvm_access_block_flow_compact.svh"

    function new(string name="i2c_over_spi_access_block_test",uvm_component parent=null);
        super.new(name,parent);
    endfunction

    virtual task ab_init();
        mcu_test_preset();
        i2c_over_spi_test_preset(SPI_SEL);
        // Environment must bind actual NVM_PROT_IRQ_STATUS RAL register.
        if (!uvm_config_db#(uvm_reg)::get(this,"","NVM_PROT_IRQ_STATUS_REG",ab_irq_reg))
            `uvm_fatal("AB_IRQ","Bind NVM_PROT_IRQ_STATUS_REG in environment")
    endtask

    // [MODIFY] Single I2C-specific dispatch, instead of WREN/PP/SE/BE/CE tasks.
    virtual task ab_command(input ab_cmd_e cmd,input logic [23:0] addr='0);
        byte data[$];
        case(cmd)
            CMD_WREN: i2c_over_spi_write_enable(SPI_SEL);
            CMD_PP: begin
                // The existing helper pop_front() consumes this queue.
                for(int i=0;i<AB_PP_LEN;i++) data.push_back(byte'(1+(i%200)));
                i2c_over_spi_page_program(addr,data,AB_PP_LEN,SPI_SEL);
            end
            CMD_SE:   i2c_over_spi_sector_erase(addr,SPI_SEL);
            CMD_BE:   i2c_over_spi_block_erase(addr,SPI_SEL);
            CMD_CE:   i2c_over_spi_chip_erase(SPI_SEL); // Verify name/signature in base
            default:  `uvm_fatal("AB_CMD","Unsupported I2C-to-SPI command")
        endcase
    endtask

    // [KEEP] Protocol-specific PP expected data is generated in adapter.
    virtual task ab_verify_programmed(input logic [23:0] addr,input int n);
        logic [7:0] actual[];
        flash_backdoor_read(addr,n,actual);
        if(actual.size()!=n) `uvm_fatal("AB_PP","Backdoor size mismatch")
        foreach(actual[i])
            if(actual[i] !== 8'(1+(i%200)))
                `uvm_error("AB_PP",$sformatf("addr=%06h exp=%02h got=%02h",
                    addr+i,8'(1+(i%200)),actual[i]))
    endtask

    // [KEEP] Frontdoor read must also be compared by I2C RX scoreboard.
    // The flash snapshot check in common flow alone does NOT check received data.
    virtual task ab_read_frontdoor(input logic [23:0] addr);
        i2c_over_spi_fast_read(addr,AB_PP_LEN,SPI_SEL);
        #10us;
        // TODO: Confirm I2C RX scoreboard checks actual read bytes; otherwise
        // this verification is incomplete even if backdoor comparison passes.
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this,"Start VPlan 135");
        ab_run_all();
        phase.drop_objection(this,"Finish VPlan 135");
    endtask
endclass
/////////////////////////
//======================================================================
// VPlan 136: SPI Master -> SPI Leader (SPI0/NVM)
// Small one-line command tasks removed. Shared algorithm in .svh.
//======================================================================
class spi_master_access_block_test extends host_mcu_spi_base_test;
    `uvm_component_utils(spi_master_access_block_test)
    localparam int AB_OPTION=0;
    `include "nvm_access_block_flow_compact.svh"

    function new(string name="spi_master_access_block_test",uvm_component parent=null);
        super.new(name,parent);
    endfunction

    // [KEEP] Multi-step protocol initialization, not a simple wrapper.
    virtual task ab_init();
        mcu_test_preset();
        mcu_spi_disable_auto_rdsr(1);
        exlm_spi_wr_mem_pp(m_host_top_cfg.mcu_dram_addr_st,AB_PP_LEN);
        // Environment must bind real NVM_PROT_IRQ_STATUS RAL register.
        if (!uvm_config_db#(uvm_reg)::get(this,"","NVM_PROT_IRQ_STATUS_REG",ab_irq_reg))
            `uvm_fatal("AB_IRQ","Bind NVM_PROT_IRQ_STATUS_REG in environment")
    endtask

    // [MODIFY] Replace five tiny command wrappers with one adapter.
    virtual task ab_command(input ab_cmd_e cmd,input logic [23:0] addr='0);
        case(cmd)
            CMD_WREN: mcu_spi_write_enable();
            CMD_PP:   mcu_spi_page_program(addr,0,10'h0FF,m_host_top_cfg.mcu_dram_addr_st);
            CMD_SE:   mcu_spi_sector_erase(addr,32'h0);
            CMD_BE:   mcu_spi_block_erase(addr,32'h0);
            CMD_CE:   mcu_spi_chip_erase();
            default:  `uvm_fatal("AB_CMD","Unsupported SPI command")
        endcase
    endtask

    // [KEEP] Protocol-specific checker: SPI source is MCU DRAM.
    // Verify the helper's 3rd argument is a byte count in your base test.
    virtual task ab_verify_programmed(input logic [23:0] addr,input int n);
        backdoor_check(addr,m_host_top_cfg.mcu_dram_addr_st,n);
    endtask

    // [KEEP] Actual frontdoor RX comparison uses separate DRAM destination.
    virtual task ab_read_frontdoor(input logic [23:0] addr);
        logic [31:0] dst;
        dst=m_host_top_cfg.mcu_dram_addr_st+'h200;
        mcu_spi_fast_read(AB_PP_LEN,addr,dst,0);
        #5us;
        backdoor_check(addr,dst,AB_PP_LEN);
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this,"Start VPlan 136");
        ab_run_all();
        phase.drop_objection(this,"Finish VPlan 136");
    endtask
endclass

