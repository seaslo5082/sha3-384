// Paste INSIDE host_arbiter_base_test; replace the old reload-buffer task.
// Depends on arb_iterations() from arbiter_tasks_update.svh.
// Reference: supplied spi_fstr_single_reload_buf_test video.
// Not compiled/simulated against your environment.
//
// Before the parallel fork in host_arbiter_reload_test:
//   force `APR_TOP.gate_lut_clk_enable = 1'b1;
// After all parallel workers finish:
//   release `APR_TOP.gate_lut_clk_enable;
// The force is copied from the reference; keep it outside the worker so
// one stress iteration cannot release a clock needed by another worker.
//
// Reference uses buf_end_addr = 0 + 256 for a 256-byte load.
// Here -1 selects 0 + byte_count. This is NOT assumed to be destination+len.
// Confirm end-field semantics / supported length granularity in RTL.

virtual task run_spi_flash_fast_read_reload_buf_test(
    input bit stress_en = 0,
    input int unsigned repeat_count = 100,
    input logic [2:0] spi_spd = 3,
    input time transfer_timeout = 1ms,
    input int unsigned byte_count = 15,
    input int reload_end_value = -1
);
    logic [31:0] target_addr, addr;
    logic [15:0] buf_start_addr, buf_end_addr;
    logic [7:0] expected[], ignore_mask[];
    logic [7:0] actual, status;
    int unsigned loops, errors;
    bit checked, completed;
    string stage;

    target_addr = m_host_top_cfg.tcon_reg_addr_st + 32'h21;
    buf_start_addr = target_addr[15:0];
    loops = arb_iterations(stress_en, repeat_count);
    // Reserve only the original SPI window: offsets 0x21..0x2F.
    if (byte_count < 1 || byte_count > 15)
        `uvm_fatal("RELOAD_CFG", "byte_count must be 1..15 for this arbiter map")
    if (reload_end_value < -1 || reload_end_value > 65535)
        `uvm_fatal("RELOAD_CFG", "reload_end_value must be -1 or 0..65535")
    if (transfer_timeout == 0 || $isunknown(spi_spd))
        `uvm_fatal("RELOAD_CFG", "Invalid timeout or SPI speed")
    buf_end_addr = (reload_end_value == -1) ? 16'(byte_count)
                                           : 16'(reload_end_value);
    expected = new[byte_count];
    ignore_mask = new[byte_count];

    for (int unsigned iter = 0; iter < loops; iter++) begin
        completed = 0;
        errors = 0;
        status = 'x;
        stage = "setup";
        // Isolate disable fork from the other arbiter workers.
        fork
            begin
                fork
                    begin
                        mcu_set_spi_spd(spi_spd);
                        force_flash_data_with_mcu(24'h0, target_addr, byte_count);
                        checked = 0;
                        for (int unsigned i = 0; i < byte_count; i++) begin
                            addr = target_addr + i;
                            expected[i] = m_reg_model.rom[addr];
                            ignore_mask[i] = m_reg_model.full_mask[addr];
                            if ($isunknown(ignore_mask[i]))
                                `uvm_fatal("RELOAD_MASK", "Unknown destination mask")
                            if (ignore_mask[i] != 8'hFF) checked = 1;
                        end
                        if (!checked)
                            `uvm_fatal("RELOAD_MASK", "All destination bits are masked")

                        stage = "flash_to_reload_buffer";
                        // MODIFY: load_target=3 instead of normal TCON load_target=0.
                        // Reference buffer load address is zero; the TCON target
                        // is programmed separately below.
                        mcu_spi_fast_read(16'(byte_count), 24'h0, 32'h0, 3'b011);
                        // Existing helper already waits for SPI command completion.

                        stage = "program_reload_ranges";
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'hF4, buf_start_addr[15:8]);
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'hF5, buf_start_addr[7:0]);
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'hF6, buf_end_addr[15:8]);
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'hF7, buf_end_addr[7:0]);
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_2, 8'hE2, buf_start_addr[15:8]);
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_2, 8'hE3, buf_start_addr[7:0]);
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_2, 8'hE6, buf_end_addr[15:8]);
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_2, 8'hE7, buf_end_addr[7:0]);
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_2, 8'hE4, buf_start_addr[15:8]);
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_2, 8'hE5, buf_start_addr[7:0]);
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_2, 8'hE8, buf_end_addr[15:8]);
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_2, 8'hE9, buf_end_addr[7:0]);

                        stage = "arm_reload";
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'hF8, 8'h20);
                        mcu_reg_rd(m_host_top_cfg.mcu_reg_page_addr_1, 8'hF8, status);
                        // Do not allow a previous iteration's DONE to fake completion.
                        // If DONE is sticky and requires another clear operation,
                        // replace this arm sequence using its documented clear rule.
                        if (status[6] !== 1'b0)
                            `uvm_fatal("RELOAD_STALE_DONE", $sformatf(
                                "F8=%02h after arm; confirm DONE clear/read semantics", status))
                        mcu_reg_wr(m_host_top_cfg.mcu_reg_page_addr_1, 8'hF8, 8'hA0);

                        stage = "wait_reload_done";
                        do begin
                            mcu_reg_rd(m_host_top_cfg.mcu_reg_page_addr_1, 8'hF8, status);
                            if (status[6] !== 1'b1) #1us;
                        end while (status[6] !== 1'b1);

                        stage = "compare_tcon";
                        // Keep expected data from BEFORE transfer, not DUT readback.
                        for (int unsigned i = 0; i < byte_count; i++) begin
                            addr = target_addr + i;
                            mcu_reg_rd(addr[31:8], addr[7:0], actual);
                            if ((actual | ignore_mask[i]) !==
                                (expected[i] | ignore_mask[i])) begin
                                errors++;
                                `uvm_error("RELOAD_CHECK", $sformatf(
                                    "iter=%0d addr=%08h exp=%02h got=%02h ignore=%02h",
                                    iter + 1, addr, expected[i], actual, ignore_mask[i]))
                            end
                        end
                        completed = 1;
                    end
                    begin
                        #(transfer_timeout);
                        if (!completed)
                            `uvm_fatal("RELOAD_TIMEOUT", $sformatf(
                                "iter=%0d stage=%s F8=%02h target=%08h start=%04h end=%04h",
                                iter + 1, stage, status, target_addr,
                                buf_start_addr, buf_end_addr))
                    end
                join_any
                disable fork;
            end
        join
        if (!completed)
            `uvm_fatal("RELOAD_INCOMPLETE", "Reload worker did not finish")
        `uvm_info("RELOAD", $sformatf(
            "iteration=%0d/%0d target=%08h bytes=%0d errors=%0d",
            iter + 1, loops, target_addr, byte_count, errors), UVM_LOW)
    end
endtask

// Minimal change in host_arbiter_reload_test.run_phase, after existing presets:
//
// force `APR_TOP.gate_lut_clk_enable = 1'b1;
// fork
//     run_i2c_rw_test();
//     run_ahb_rw_test();
//     run_spi_flash_fast_read_reload_buf_test(.stress_en(1), .repeat_count(100));
//     run_ahb_dma_test();
//     run_crc_test();
// join
// release `APR_TOP.gate_lut_clk_enable;
//
// AUX is disabled, so update the old "6-way" log messages to "5-way".
// To sustain competing traffic, enable stress on the other four workers too.
//
// Hardware-dependent points not established by the reference alone:
// 1. The reference loads 256 bytes; 15-byte reload support needs confirmation.
// 2. F8[6] must be software-readable and remain asserted until observed.
//    The reference's active wait is an internal RTL signal; its software poll
//    is commented out. This task uses software polling, not an unverified path.
// 3. F8=20 must clear stale DONE before retrigger, or add the correct clear rule.
// 4. A/B/C destination mapping and end-field meaning need RTL confirmation;
//    the programmed values follow the reference, not an inferred new map.
