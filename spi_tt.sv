
class spi_touch_master_access_block_test extends host_mcu_spi_base_test;
    `uvm_component_utils(spi_touch_master_access_block_test)

    logic [7:0] original_data[16];
    byte write_data[17'h10000];

    function new(string name = "spi_touch_master_access_block_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        logic [15:0] dram_addr;
        super.run_phase(phase);
        phase.raise_objection(this);
        mcu_test_preset();
        if (!reg_set.randomize())
            `uvm_fatal("TMCU_BLOCK", "reg_set randomization failed")
        reg_set.spi_pp_end_num = 16;
        dram_addr = m_host_top_cfg.mcu_dram_addr_st[15:0];
        if (int'(dram_addr) + 16 > 'h10000)
            `uvm_fatal("TMCU_BLOCK", "DRAM buffer crosses MBUS address boundary")

        force system.i_NT71801.i01_grp_tcon.i1_apr_top.i00_host_top.i01_mcu_top.i_mcu_jc_apr.i_mcu_spi_touch.i_mcu_spi.rx_polarity = 1'b0;
        force system.i_NT71801.i01_grp_tcon.i1_apr_top.i00_host_top.i01_mcu_top.i_mcu_jc_apr.i_mcu_spi_touch.i_mcu_spi.tx_polarity = 1'b0;

        for (int i = 0; i < 16; i++) begin
            original_data[i] = `UVM_SYSTEM.i_tmcu_rom_1.memory[i];
            if ($isunknown(original_data[i]))
                `uvm_fatal("TMCU_BLOCK", "Initial TMCU data contains X/Z")
        end

        // Replace random DRAM preparation with B=~A.
        // Every byte differs, preventing an unchanged-data false pass.
        for (int i = 0; i < 16; i++) begin
            write_data[int'(dram_addr)+i] = ~original_data[i];
            m_test_cfg.rom[int'(dram_addr)+i] = write_data[int'(dram_addr)+i];
        end
        mbus_seq_x.mbus_write(dram_addr, 16, write_data);

        // [NEW] 關閉 debug，才發出本次要驗證的 SPI write。
        // Disable debug before issuing the SPI write under test.
        set_eff_mcu_debug_en(1'b0);
        #2us;
        mcu_touch_spi_write_enable();
        mcu_touch_spi_page_program(24'h0, 16'h0,
                                  reg_set.spi_pp_end_num,
                                  m_host_top_cfg.mcu_dram_addr_st, 0);

        // [MODIFY] 預期讀回的是原值 A，而不是此次嘗試寫入的 B。
        // Expect original A, not the attempted write data B.
        // 這裡只改軟體 golden；實體 DRAM 仍是 B，不要再寫入 A。
        // Update only the software golden; physical DRAM remains B, never preload A.
        for (int i = 0; i < 16; i++)
            m_test_cfg.rom[int'(dram_addr)+i] = original_data[i];

        // [REUSE] debug 維持 0，Fast Read 將 TMCU 資料搬回 DRAM。
        // Keep debug at 0; Fast Read transfers TMCU data back into DRAM.
        mcu_touch_spi_fast_read(reg_set.spi_pp_end_num, 24'h0,
                               m_host_top_cfg.mcu_dram_addr_st, 0);

        // [REUSE] 沿用原 checker，比對實際 DRAM 與 golden A。
        // Reuse the original checker to compare actual DRAM against golden A.
        exlm_spi_rd_mem_pp_compare(m_host_top_cfg.mcu_dram_addr_st,
                                  reg_set.spi_pp_end_num);
        #5us;

        release system.i_NT71801.i01_grp_tcon.i1_apr_top.i00_host_top.i01_mcu_top.i_mcu_jc_apr.i_mcu_spi_touch.i_mcu_spi.rx_polarity;
        release system.i_NT71801.i01_grp_tcon.i1_apr_top.i00_host_top.i01_mcu_top.i_mcu_jc_apr.i_mcu_spi_touch.i_mcu_spi.tx_polarity;
        phase.drop_objection(this);
    endtask
endclass
