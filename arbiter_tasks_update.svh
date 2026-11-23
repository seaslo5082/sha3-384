// Paste INSIDE host_arbiter_base_test; replace the old five run_* tasks.
// Keep existing presets and inherited transport / CRC configuration helpers.
// Reviewed against screenshots only: not compiled against your UVM/DUT.
// CRC timeout is diagnostic, not a verified fix for the hardware hang.

typedef enum int {
    ARB_I2C_TCON = 0,
    ARB_I2C_DLM_ILM = 1, // Preserve old run_i2c_rw_test(1) intent.
    ARB_I2C_DLM = 2,
    ARB_I2C_ILM = 3,
    ARB_I2C_N9 = 4
} arb_i2c_target_e;

typedef enum int {
    ARB_SPI_SINGLE = 0,
    ARB_SPI_DUAL = 1,
    ARB_SPI_QUAD = 2
} arb_spi_mode_e;

localparam int unsigned ARB_STRESS_LIMIT = 1000;

function automatic int unsigned arb_iterations(
    input bit stress_en, input int unsigned repeat_count
);
    if (!stress_en) return 1;
    if (repeat_count < 1 || repeat_count > ARB_STRESS_LIMIT) begin
        `uvm_fatal("ARB_CFG", $sformatf(
            "repeat_count=%0d; allowed range=1..%0d",
            repeat_count, ARB_STRESS_LIMIT))
        return 0;
    end
    return repeat_count;
endfunction

// MODIFY: Local loop variables, explicit limits, original addresses.
// DLM/ILM/N9 use the same scalar-address AMBA helper call as your example.
virtual task run_i2c_rw_test(
    input arb_i2c_target_e target = ARB_I2C_TCON,
    input bit stress_en = 0,
    input int unsigned repeat_count = 100
);
    logic [31:0] addr_q[$];
    logic [31:0] addr;
    int unsigned loops, count;
    loops = arb_iterations(stress_en, repeat_count);

    if (target == ARB_I2C_TCON) begin
        for (int i = 'h00; i <= 'h17; i++)
            addr_q.push_back({24'h10001C, 8'(i)});
        for (int i = 'h6C; i <= 'hFB; i++)
            addr_q.push_back({24'h10001C, 8'(i)});
        if (!amba_to_reg_set.randomize())
            `uvm_fatal("ARB_I2C", "amba_to_reg_set randomize failed")
    end

    for (int unsigned iter = 0; iter < loops; iter++) begin
        case (target)
            ARB_I2C_TCON: begin
                addr_q.shuffle();
                count = 5; // Preserve original helper's default count.
                if (count > addr_q.size()) count = addr_q.size();
                // MODIFY: Bypass the uninitialized loop / <= count in
                // i2c_random_data_rw; write and read the exact same entries.
                for (int i = 0; i < count; i++) begin
                    m_i2c_seq.i2c_byte_write(
                        slv_dev_addr, addr_q[i], $urandom);
                    #($urandom_range(15, 5) * 1us);
                end
                for (int i = 0; i < count; i++) begin
                    // Existing I2C scoreboard performs comparison.
                    m_i2c_seq.i2c_byte_read(slv_dev_addr, addr_q[i]);
                    #($urandom_range(15, 5) * 1us);
                end
            end
            ARB_I2C_DLM, ARB_I2C_ILM, ARB_I2C_DLM_ILM: begin
                if (target inside {ARB_I2C_DLM, ARB_I2C_DLM_ILM}) begin
                    if (!mcu_dmem.randomize())
                        `uvm_fatal("ARB_I2C", "mcu_dmem randomize failed")
                    i2c_random_data_rw_amba(slv_dev_addr, mcu_dmem.addr);
                end
                if (target inside {ARB_I2C_ILM, ARB_I2C_DLM_ILM}) begin
                    if (!mcu_imem.randomize())
                        `uvm_fatal("ARB_I2C", "mcu_imem randomize failed")
                    i2c_random_data_rw_amba(slv_dev_addr, mcu_imem.addr);
                end
            end
            ARB_I2C_N9: begin
                // MODIFY: User-requested inclusive range: 65 addresses.
                for (int i = 0; i <= 64; i++) begin
                    addr = m_host_top_cfg.andes_reg_addr_st + i;
                    i2c_random_data_rw_amba(slv_dev_addr, addr);
                end
            end
            default: `uvm_fatal("ARB_I2C", "Invalid I2C target")
        endcase
        `uvm_info("ARB_I2C", $sformatf(
            "%s iteration %0d/%0d completed",
            target.name(), iter + 1, loops), UVM_LOW)
    end
endtask

virtual task run_ahb_rw_test(
    input bit stress_en = 0,
    input int unsigned repeat_count = 100
);
    logic [31:0] first_addr, last_addr;
    int unsigned loops;
    first_addr = m_host_top_cfg.tcon_reg_addr_st + 'h58;
    last_addr  = m_host_top_cfg.tcon_reg_addr_st + 'h67;
    loops = arb_iterations(stress_en, repeat_count);
    for (int unsigned iter = 0; iter < loops; iter++) begin
        // 32 random accesses, not a 32-byte contiguous transfer.
        mcu_read_after_write_data_random_addr(first_addr, last_addr, 32);
        `uvm_info("ARB_AHB", $sformatf(
            "iteration %0d/%0d completed", iter + 1, loops), UVM_LOW)
    end
endtask

virtual task run_spi_flash_fast_read_test(
    input arb_spi_mode_e mode = ARB_SPI_SINGLE,
    input bit stress_en = 0,
    input int unsigned repeat_count = 100,
    input logic [2:0] spi_spd = 3
);
    logic [31:0] target_addr, addr;
    logic [7:0] expected[15], ignore_mask[15], actual;
    int unsigned loops, errors;
    bit checked;
    target_addr = m_host_top_cfg.tcon_reg_addr_st + 'h21;
    loops = arb_iterations(stress_en, repeat_count);
    if (!(mode inside {ARB_SPI_SINGLE, ARB_SPI_DUAL, ARB_SPI_QUAD}))
        `uvm_fatal("ARB_SPI", "Invalid SPI mode")
    if ($isunknown(spi_spd))
        `uvm_fatal("ARB_SPI", "SPI speed contains X/Z")

    // MODIFY: No shared reg_set.randomize during concurrent execution.
    mcu_set_spi_spd(spi_spd);
    if (mode == ARB_SPI_DUAL)
        mcu_reg_wr(m_host_top_cfg.host_reg_page_addr + 'h45,
                   8'h31, 8'hF2);

    for (int unsigned iter = 0; iter < loops; iter++) begin
        errors = 0;
        checked = 0;
        // MODIFY: Follow the supplied working single/dual/quad examples.
        // Flash start=0; target offset=0x21; length=15, unchanged.
        force_flash_data_with_mcu(24'h0, target_addr, 15);
        for (int i = 0; i < 15; i++) begin
            addr = target_addr + i;
            expected[i] = m_reg_model.rom[addr];
            // Same convention as compare_reg(): 1 means ignore.
            ignore_mask[i] = m_reg_model.full_mask[addr];
            if (ignore_mask[i] !== 8'hFF) checked = 1;
        end
        if (!checked)
            `uvm_fatal("ARB_SPI", "All SPI destination bits are masked")

        case (mode)
            ARB_SPI_SINGLE: mcu_spi_fast_read(15, 24'h0, target_addr, 0);
            ARB_SPI_DUAL: mcu_spi_fast_read_dual(15, 24'h0, target_addr, 0);
            ARB_SPI_QUAD: mcu_spi_fast_read_quad(15, 24'h0, target_addr, 0);
        endcase
        // These helpers already call wait_spi_cmd_done().
        // No additional fixed #1ms delay; no post-transfer golden rewrite.
        for (int i = 0; i < 15; i++) begin
            addr = target_addr + i;
            mcu_reg_rd(addr[31:8], addr[7:0], actual);
            if ((actual | ignore_mask[i]) !==
                (expected[i] | ignore_mask[i])) begin
                errors++;
                `uvm_error("ARB_SPI", $sformatf(
                    "mode=%s iter=%0d addr=%08h exp=%02h got=%02h ignore=%02h",
                    mode.name(), iter + 1, addr,
                    expected[i], actual, ignore_mask[i]))
            end
        end
        `uvm_info("ARB_SPI", $sformatf(
            "%s iteration %0d/%0d completed; errors=%0d",
            mode.name(), iter + 1, loops, errors), UVM_LOW)
    end
endtask

// NEW: Override this macro if the DUT hierarchy changes.
`ifndef ARB_DMA_DONE
`define ARB_DMA_DONE system.i_NT71801.i01_grp_tcon.i1_apr_top.i00_host_top.u_ldc_dma.u_slave.dma_finish_rp
`endif

virtual task run_ahb_dma_test(
    input bit stress_en = 0,
    input int unsigned repeat_count = 100,
    input bit burst_mode = 0,
    input time transfer_timeout = 1ms
);
    logic [31:0] src, dst, addr, wdata, rdata;
    logic [7:0] expected[8], ignore_mask[8], actual;
    int unsigned loops, errors;
    src = 32'h0020_0000;
    dst = m_host_top_cfg.tcon_reg_addr_st + 'h68;
    loops = arb_iterations(stress_en, repeat_count);
    if (transfer_timeout == 0)
        `uvm_fatal("ARB_DMA", "transfer_timeout must be positive")

    for (int unsigned iter = 0; iter < loops; iter++) begin
        errors = 0;
        for (int i = 0; i < 8; i++) begin
            // First iteration retains original 00..07 pattern.
            expected[i] = 8'(i + iter * 8);
            ignore_mask[i] = m_reg_model.full_mask[dst + i];
        end
        for (int i = 0; i < 2; i++) begin
            addr = src + i * 4;
            wdata = {expected[i*4+3], expected[i*4+2],
                     expected[i*4+1], expected[i*4]};
            ahb_word_write(addr[31:8], addr[7:0], wdata);
            ahb_word_read(addr[31:8], addr[7:0], rdata);
            if (rdata !== wdata)
                `uvm_fatal("ARB_DMA_SRC", $sformatf(
                    "Source addr=%08h exp=%08h got=%08h", addr, wdata, rdata))
        end

        // MODIFY: Arm completion monitor BEFORE triggering DMA.
        // Isolate disable fork so it cannot kill the other masters.
        fork
            begin
                fork
                    begin
                        fork
                            begin
                                wait (`ARB_DMA_DONE === 1'b0);
                                wait (`ARB_DMA_DONE === 1'b1);
                            end
                            begin
                                // MODIFY: byte_mode=0 means 4-byte mode.
                                // Keep incrementing addresses and an 8-byte length.
                                ahb_dma_trigger(
                                    .read_addr(src), .write_addr(dst),
                                    .length(8), .burst_mode(burst_mode),
                                    .byte_mode(0), .fix_read_address(0),
                                    .fix_write_address(0),
                                    .dma_crc_refin_en(0), .dma_crc_refout_en(0));
                            end
                        join
                    end
                    begin
                        #(transfer_timeout);
                        `uvm_fatal("ARB_DMA_TIMEOUT", $sformatf(
                            "DMA did not finish: src=%08h dst=%08h", src, dst))
                    end
                join_any
                disable fork;
            end
        join

        // MODIFY: Read each destination byte explicitly.
        for (int i = 0; i < 8; i++) begin
            addr = dst + i;
            mcu_reg_rd(addr[31:8], addr[7:0], actual);
            if ((actual | ignore_mask[i]) !==
                (expected[i] | ignore_mask[i])) begin
                errors++;
                `uvm_error("ARB_DMA", $sformatf(
                    "iter=%0d addr=%08h exp=%02h got=%02h ignore=%02h",
                    iter + 1, addr, expected[i], actual, ignore_mask[i]))
            end
        end
        `uvm_info("ARB_DMA", $sformatf(
            "iteration %0d/%0d completed; errors=%0d",
            iter + 1, loops, errors), UVM_LOW)
    end
endtask

virtual task run_crc_test(
    input bit stress_en = 0,
    input int unsigned repeat_count = 100,
    input time transfer_timeout = 1ms
);
    logic [31:0] first_addr, last_addr, addr, wdata, rdata;
    logic [15:0] seed, golden, actual_crc;
    logic [7:0] status, ctrl, mask_byte;
    logic mismatch;
    int unsigned loops, errors;
    first_addr = m_host_top_cfg.tcon_reg_addr_st + 'h78;
    last_addr = first_addr + 7; // Preserve supplied 0x78..0x7F range.
    loops = arb_iterations(stress_en, repeat_count);
    if (transfer_timeout == 0)
        `uvm_fatal("ARB_CRC", "transfer_timeout must be positive")

    for (int unsigned iter = 0; iter < loops; iter++) begin
        errors = 0;
        seed = 16'($urandom);
        golden = seed;
        for (int i = 0; i < 2; i++) begin
            addr = first_addr + i * 4;
            wdata = $urandom;
            mcu_word_wr(addr[31:8], addr[7:0], wdata);
            mcu_word_rd(addr[31:8], addr[7:0], rdata);
            // NEW: Validate prepared data on meaningful register bits.
            for (int b = 0; b < 4; b++) begin
                mask_byte = m_reg_model.full_mask[addr + b];
                if ((rdata[b*8 +: 8] | mask_byte) !==
                    (wdata[b*8 +: 8] | mask_byte))
                    `uvm_fatal("ARB_CRC_SRC", $sformatf(
                        "CRC source preparation failed at %08h", addr + b))
            end
            if ($isunknown(rdata))
                `uvm_fatal("ARB_CRC_SRC", "CRC source contains X/Z")
            // Keep the supplied CRC master's existing algorithm/byte order.
            // Do NOT switch to SPI-slave CRC81 sb=1 without RTL evidence.
            golden = crc16_update_word(golden, rdata);
        end

        // MODIFY: Bounded version of the existing MATCH case.
        fork
            begin
                fork
                    begin
                        mcu_reg_w1_and_w1c_check(
                            m_host_top_cfg.crc_page_addr, 8'h14, 1);
                        set_crc_config(first_addr, last_addr, golden, seed);
                        mcu_reg_wr_bits_and_rd_check(
                            m_host_top_cfg.crc_page_addr,
                            8'h18, 8'h01, 8'h01);
                        // Verify stale completion was cleared before start.
                        mcu_reg_rd(m_host_top_cfg.crc_page_addr, 8'h14, status);
                        if (status[0] !== 1'b0)
                            `uvm_fatal("ARB_CRC", "COMPLETE did not clear")
                        mcu_reg_wr(m_host_top_cfg.crc_page_addr, 8'h00, 8'h01);
                        do begin
                            mcu_reg_rd(m_host_top_cfg.crc_page_addr,
                                       8'h14, status);
                            if (status[0] !== 1'b1) #1us;
                        end while (status[0] !== 1'b1);
                        mcu_reg_rd(m_host_top_cfg.crc_page_addr, 8'h00, ctrl);
                        if (ctrl[0] !== 1'b0) begin
                            errors++;
                            `uvm_error("ARB_CRC", "CHECK_START did not self-clear")
                        end
                        crc_get_act_checksum(actual_crc);
                        crc_get_chksum_mismatch(mismatch);
                        if (actual_crc !== golden) begin
                            errors++;
                            `uvm_error("ARB_CRC", $sformatf(
                                "iter=%0d seed=%04h exp=%04h got=%04h",
                                iter + 1, seed, golden, actual_crc))
                        end
                        if (mismatch !== 1'b0) begin
                            errors++;
                            `uvm_error("ARB_CRC", "MATCH case mismatch flag is not zero")
                        end
                        mcu_reg_w1_and_w1c_check(
                            m_host_top_cfg.crc_page_addr, 8'h14, 1);
                        trigger_cov_crc();
                    end
                    begin
                        #(transfer_timeout);
                        `uvm_fatal("ARB_CRC_TIMEOUT", $sformatf(
                            "CRC timeout: start=%08h end=%08h last_status=%02h; inspect CRC request/response and end-address RTL",
                            first_addr, last_addr, status))
                    end
                join_any
                disable fork;
            end
        join
        `uvm_info("ARB_CRC", $sformatf(
            "iteration %0d/%0d completed; errors=%0d",
            iter + 1, loops, errors), UVM_LOW)
    end
endtask

// NEW: One owner of completion tokens; no put() inside individual tasks.
// Whole-run watchdog also covers a blocked setup or inherited bus helper.
task run_arbiter_tasks(
    input arb_i2c_target_e i2c_target = ARB_I2C_TCON,
    input arb_spi_mode_e spi_mode = ARB_SPI_SINGLE,
    input bit stress_en = 0,
    input int unsigned repeat_count = 100,
    input time overall_timeout = 1s
);
    semaphore done_sem;
    bit [4:0] done;
    done_sem = new(0);
    done = '0;
    if (overall_timeout == 0)
        `uvm_fatal("ARB_CFG", "overall_timeout must be positive")
    fork
        begin
            fork
                begin
                    fork
                        begin
                            run_i2c_rw_test(i2c_target, stress_en, repeat_count);
                            done[0] = 1;
                            `uvm_info("TASK_DONE", "I2C completed", UVM_LOW)
                            done_sem.put(1);
                        end
                        begin
                            run_ahb_rw_test(stress_en, repeat_count);
                            done[1] = 1;
                            `uvm_info("TASK_DONE", "AHB completed", UVM_LOW)
                            done_sem.put(1);
                        end
                        begin
                            run_spi_flash_fast_read_test(spi_mode, stress_en, repeat_count);
                            done[2] = 1;
                            `uvm_info("TASK_DONE", "SPI completed", UVM_LOW)
                            done_sem.put(1);
                        end
                        begin
                            run_ahb_dma_test(stress_en, repeat_count);
                            done[3] = 1;
                            `uvm_info("TASK_DONE", "DMA completed", UVM_LOW)
                            done_sem.put(1);
                        end
                        begin
                            run_crc_test(stress_en, repeat_count);
                            done[4] = 1;
                            `uvm_info("TASK_DONE", "CRC completed", UVM_LOW)
                            done_sem.put(1);
                        end
                    join_none
                    done_sem.get(5);
                    wait fork;
                end
                begin
                    #(overall_timeout);
                    `uvm_fatal("ARB_TIMEOUT", $sformatf(
                        "done {CRC,DMA,SPI,AHB,I2C}=%05b", done))
                end
            join_any
            disable fork;
        end
    join
    if (done !== 5'b11111)
        `uvm_fatal("ARB_DONE", "Not all five tasks completed")
    `uvm_info("ALL_DONE", "5/5 tasks completed; consult UVM errors for PASS/FAIL", UVM_LOW)
endtask

/* Replace run_phase in amba_arbiter_test with:

virtual task run_phase(uvm_phase phase);
    super.run_phase(phase);
    phase.raise_objection(this);
    mcu_test_preset();
    i2c_test_preset();
    mcu_set_host_arbiter(1);
    run_arbiter_tasks(
        .i2c_target(ARB_I2C_TCON),
        .spi_mode(ARB_SPI_SINGLE),
        .stress_en(0),
        .repeat_count(100),
        .overall_timeout(1s)
    );
    phase.drop_objection(this);
endtask

For the N9 arbiter test, use its OWN arbiter preset, then select ARB_I2C_N9,
ARB_I2C_DLM, ARB_I2C_ILM, or ARB_I2C_DLM_ILM as needed. Changing the I2C
target alone does not prove the other four masters traverse the N9 arbiter.

Integration limits:
- Inherited AHB/MCU helpers must be reentrant or use a sequencer correctly.
- I2C compare remains in the existing scoreboard/helper; keep it enabled.
- N9 range is inclusive base..base+64 (65 addresses). Read-only/W1C/trigger
  semantics must be handled by the existing AMBA helper/register model.
- All source/destination addresses are preserved; CRC end remains 0x7F.
- DMA word mode is a directed alternative, NOT a fix to byte-mode RTL.
- No complete DUT simulation or SystemVerilog compilation was available.
*/
