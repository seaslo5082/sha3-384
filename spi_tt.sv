//======================================================================
// TMCU SPI access blocking / TMCU SPI 存取阻擋測試。
//
// DEBUG=1: write A -> Fast Read A.
// DEBUG=0: attempt to write B -> Fast Read must still return A.
// A[i] != B[i] for every tested byte.
//
// Reuse the set_eff_mcu_debug_en(bit) interface used by test #135.
// 此 task 必須存在於本類別或共同父類別，不能只存在另一支 sibling test。
// The task must exist here or in an ancestor, not only in a sibling test.
//
// Reuse the absolute-index MBUS arrays and rdata usage in the screenshots.
// mbus_read() 必須在 m_scb_x.rdata 已更新後才返回。
// mbus_read() must return after m_scb_x.rdata has been updated.
//
// [INTEGRATION] SPI task 必須等待命令完成或被拒絕後才返回。
// SPI tasks must return only after command completion or rejection.
// timeout 一律視為錯誤，不能把卡住當作 block 成功。
// A timeout is an error, never proof of a successful access block.
//
// Address 0 comes from the screenshots and does not cover all REG/ILM/DLM.
// Optional: +TMCU_SPI_TEST_ADDR=<hex>, +TMCU_SPI_TEST_BYTES=<decimal>
// A REG case requires a writable scratch-register range without side effects.
//
// This file has not been compiled or simulated in the user's DUT/UVM environment.
//======================================================================

`ifndef SPI_TOUCH_MASTER_ACCESS_BLOCK_TEST_SV
`define SPI_TOUCH_MASTER_ACCESS_BLOCK_TEST_SV

class spi_touch_master_access_block_test extends host_mcu_spi_base_test;
    `uvm_component_utils(spi_touch_master_access_block_test)

    localparam int MAX_BYTES = 16;
    localparam time CASE_TIMEOUT = 100ms;

    int unsigned test_bytes = MAX_BYTES;
    logic [23:0] tmcu_addr = 24'h000000;
    logic [31:0] mcu_buf_addr;
    logic [15:0] mbus_buf_addr;

    logic [7:0] pattern_a[MAX_BYTES];
    logic [7:0] pattern_b[MAX_BYTES];
    logic [7:0] poison[MAX_BYTES];

    // Match the size and absolute-address indexing of rom_try in the photos.
    byte mbus_wr_payload[17'h10000];
    byte mbus_rd_payload[17'h10000];
    string current_step;

    function new(string name = "spi_touch_master_access_block_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // Update only the software golden model, not DUT or TMCU memory.
    task set_buffer_golden(input logic [7:0] data[MAX_BYTES]);
        for (int i = 0; i < test_bytes; i++)
            m_test_cfg.rom[int'(mbus_buf_addr) + i] = data[i];
    endtask

    // Prepare the TX/RX buffer through real MCU bus writes.
    task write_mcu_buffer(input logic [7:0] data[MAX_BYTES]);
        set_buffer_golden(data);
        for (int i = 0; i < test_bytes; i++)
            mbus_wr_payload[int'(mbus_buf_addr) + i] = byte'(data[i]);
        mbus_seq_x.mbus_write(mbus_buf_addr, test_bytes, mbus_wr_payload);
    endtask

    // [NEW] 使用獨立 pattern 比對實際 read data，避免 golden 被覆寫。
    // Compare actual read data against an independent pattern.
    task check_mcu_buffer(input logic [7:0] expected[MAX_BYTES],
                          input string tag);
        logic saved_compare;
        logic [7:0] got;
        int unsigned mismatch_count;

        mismatch_count = 0;
        saved_compare = m_scb_x.scb_compare;

        // [NEW] 只在這段 MBUS read 使用下面的逐 byte checker。
        // Use the byte-by-byte checker below for these MBUS reads.
        m_scb_x.scb_compare = 0;
        for (int i = 0; i < test_bytes; i++) begin
            mbus_seq_x.mbus_read(16'(int'(mbus_buf_addr) + i),
                                1, mbus_rd_payload);
            got = m_scb_x.rdata;
            if (got !== expected[i]) begin
                mismatch_count++;
                `uvm_error("TMCU_ACCESS_BLOCK",
                    $sformatf("[%s] MCU=%04h byte=%0d expected=%02h actual=%02h",
                              tag, int'(mbus_buf_addr) + i, i,
                              expected[i], got))
            end
        end
        m_scb_x.scb_compare = saved_compare;

        // [NEW] baseline 失敗就停止，不能繼續宣稱阻擋檢查有效。
        // Stop on a bad baseline rather than trusting later block checks.
        if (mismatch_count != 0)
            `uvm_fatal("TMCU_ACCESS_BLOCK",
                $sformatf("[%s] %0d byte mismatch(es)", tag, mismatch_count))
    endtask

    // [NEW] 先污染 RX buffer，再由真正 Fast Read 填回資料。
    // Poison the RX buffer, then refill it through a real Fast Read.
    task fast_read_check_a(input string tag);
        write_mcu_buffer(poison);
        check_mcu_buffer(poison, {tag, "_RX_PRELOAD"});

        // [NEW] 只設定預期值，MCU buffer 的實體內容仍然是 poison。
        // Set the expected model only; the physical buffer still holds poison.
        set_buffer_golden(pattern_a);
        mcu_touch_spi_fast_read(reg_set.spi_pp_end_num,
                                tmcu_addr, mcu_buf_addr, 0);
        check_mcu_buffer(pattern_a, tag);
    endtask

    task run_access_checks();
        // [NEW] TC1：debug 開啟，真實寫入 A 並確認 Fast Read 得到 A。
        // TC1: enable debug, write A, and verify A through Fast Read.
        current_step = "TC1_DEBUG1_WRITE_A";
        set_eff_mcu_debug_en(1'b1);
        #2us;
        write_mcu_buffer(pattern_a);
        check_mcu_buffer(pattern_a, "TX_A_PRELOAD");
        mcu_touch_spi_write_enable();
        mcu_touch_spi_page_program(tmcu_addr, 16'h0,
                                   reg_set.spi_pp_end_num, mcu_buf_addr, 0);

        current_step = "TC1_DEBUG1_FAST_READ_A";
        fast_read_check_a(current_step);

        // [NEW] TC2：debug 關閉後再送 WREN 與 B，保持正常 command 流程。
        // TC2: disable debug, then issue WREN and B using the normal command flow.
        current_step = "TC2_DEBUG0_WRITE_B";
        set_eff_mcu_debug_en(1'b0);
        #2us;
        write_mcu_buffer(pattern_b);
        check_mcu_buffer(pattern_b, "TX_B_PRELOAD");
        mcu_touch_spi_write_enable();
        mcu_touch_spi_page_program(tmcu_addr, 16'h0,
                                   reg_set.spi_pp_end_num, mcu_buf_addr, 0);

        // [NEW] 維持 debug=0 讀回 A，同時驗證寫入阻擋及讀取仍允許。
        // Keep debug=0 and read A to check blocked writes and permitted reads.
        current_step = "TC2_DEBUG0_FAST_READ_UNCHANGED_A";
        fast_read_check_a(current_step);

        // [NEW] 收尾恢復 debug 設定，不再發出 TMCU write。
        // Restore debug during cleanup without issuing another TMCU write.
        current_step = "RESTORE_DEBUG";
        set_eff_mcu_debug_en(1'b1);
        #2us;
    endtask

    virtual task run_phase(uvm_phase phase);
        bit completed;
        int unsigned addr_arg;
        int unsigned bytes_arg;

        phase.raise_objection(this, "Starting TMCU SPI access block test");
        mcu_test_preset();

        if (!reg_set.randomize())
            `uvm_fatal("TMCU_ACCESS_BLOCK", "reg_set.randomize() failed")

        // Use a short fixed transfer, following the length convention in the photos.
        if ($value$plusargs("TMCU_SPI_TEST_BYTES=%d", bytes_arg)) begin
            if ((bytes_arg < 1) || (bytes_arg > MAX_BYTES))
                `uvm_fatal("TMCU_ACCESS_BLOCK", "TMCU_SPI_TEST_BYTES must be 1..16")
            test_bytes = bytes_arg;
        end
        if ($value$plusargs("TMCU_SPI_TEST_ADDR=%h", addr_arg)) begin
            if (addr_arg > 'hFFFFFF)
                `uvm_fatal("TMCU_ACCESS_BLOCK", "TMCU_SPI_TEST_ADDR exceeds 24 bits")
            tmcu_addr = addr_arg[23:0];
        end
        if ((int'(tmcu_addr[7:0]) + test_bytes) > 256)
            `uvm_fatal("TMCU_ACCESS_BLOCK", "Test transfer must stay within one page")

        reg_set.spi_pp_end_num = test_bytes;
        mcu_buf_addr = m_host_top_cfg.mcu_dram_addr_st;
        mbus_buf_addr = mcu_buf_addr[15:0];
        if ((int'(mbus_buf_addr) + test_bytes) > 'h10000)
            `uvm_fatal("TMCU_ACCESS_BLOCK", "MCU buffer crosses the MBUS array boundary")

        for (int i = 0; i < MAX_BYTES; i++) begin
            pattern_a[i] = 8'h35 ^ 8'(i);
            pattern_b[i] = ~pattern_a[i];
            poison[i] = pattern_a[i] ^ 8'h5A;
        end

        // Reuse the SPI polarity settings from the photos.
        force system.i_NT71801.i01_grp_tcon.i1_apr_top.i00_host_top.i01_mcu_top.i_mcu_jc_apr.i_mcu_spi_touch.i_mcu_spi.rx_polarity = 1'b0;
        force system.i_NT71801.i01_grp_tcon.i1_apr_top.i00_host_top.i01_mcu_top.i_mcu_jc_apr.i_mcu_spi_touch.i_mcu_spi.tx_polarity = 1'b0;

        `uvm_info("TMCU_ACCESS_BLOCK",
            $sformatf("START: TMCU=%06h MCU buffer=%08h bytes=%0d",
                      tmcu_addr, mcu_buf_addr, test_bytes), UVM_LOW)

        completed = 0;
        // Isolate the watchdog in its own process to preserve unrelated forks.
        fork
            begin
                fork
                    begin
                        run_access_checks();
                        completed = 1;
                    end
                    begin
                        #CASE_TIMEOUT;
                    end
                join_any
                disable fork;
            end
        join

        release system.i_NT71801.i01_grp_tcon.i1_apr_top.i00_host_top.i01_mcu_top.i_mcu_jc_apr.i_mcu_spi_touch.i_mcu_spi.rx_polarity;
        release system.i_NT71801.i01_grp_tcon.i1_apr_top.i00_host_top.i01_mcu_top.i_mcu_jc_apr.i_mcu_spi_touch.i_mcu_spi.tx_polarity;

        if (!completed)
            `uvm_fatal("TMCU_ACCESS_BLOCK",
                $sformatf("TIMEOUT at %s; a stalled task is not proof of blocking",
                          current_step))

        `uvm_info("TMCU_ACCESS_BLOCK",
            "Checks completed: DEBUG1 write/read A; DEBUG0 blocked B/read A", UVM_LOW)
        phase.drop_objection(this, "Finished TMCU SPI access block test");
    endtask
endclass

`endif
