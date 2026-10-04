// Replace the original i2c_over_spi_tmcu_crc_cmp class; do not compile both.
// 保留原 class 名稱與 inherited transport tasks。 / Preserve the original class name and inherited transport tasks.
// 此版依提供的照片與 RTL 錄影重建，尚未在完整 DUT/UVM 環境編譯或模擬。
// Reconstructed from the supplied photos/RTL recordings; not compiled or simulated in the complete DUT/UVM environment.
// Dependencies: host_i2c_over_spi_base_test, `TM_SPI_SLV, tmcu_reg_read/write,
// mcu_test_preset, i2c_over_spi_test_preset, i2c_over_spi_adr_write,
// i2c_over_spi_crc_write, and the original spi_slv_crc(data, crc) reference function.
// 輸入封包 task 必須使用本案 CA/CC/CD，並在結束時完成 CS deassert。
// Existing transport tasks must use this project's CA/CC/CD commands and complete CS deassertion.
// 此版驗 CRC/狀態/內部地址；沒有宣稱完成 ILM/DLM/REG 全區域資料讀回驗證。
// This test checks CRC/status/internal address; it does not claim full ILM/DLM/REG memory readback coverage.

class i2c_over_spi_tmcu_crc_cmp extends host_i2c_over_spi_base_test;
  `uvm_component_utils(i2c_over_spi_tmcu_crc_cmp)

  // NEW: 沿用目前 reg map，若與實例參數不同則明確停止。 / Use the supplied register map and fail clearly on a parameter mismatch.
  localparam logic [23:0] START_ADDR_REG = 24'h1F_B2A8;
  localparam logic [15:0] CRC_SEED = 16'hFFFF;
  typedef byte crc81_payload_t[$];
  int unsigned crc81_cases;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // NEW: 與照片的 SPI 展開方程式相同：左移、8005、data[0] 先處理。
  // Matches the SPI equations: left shift, polynomial 8005, data[0] processed first.
  // SPI 實體傳輸順序與 CRC 平行 byte 的運算順序是不同概念。
  // SPI wire bit order and the CRC update's parallel-byte bit order are separate concepts.
  function automatic logic [15:0] crc81_update_byte(
      input logic [15:0] crc_i, input logic [7:0] data_i);
    logic [15:0] crc;
    logic feedback;
    crc = crc_i;
    for (int i = 0; i < 8; i++) begin
      feedback = crc[15] ^ data_i[i];
      crc = {crc[14:0], 1'b0};
      if (feedback) crc ^= 16'h8005;
    end
    return crc;
  endfunction

  function automatic logic [15:0] crc81_calc(
      input crc81_payload_t payload, input logic [15:0] seed);
    logic [15:0] crc;
    crc = seed;
    foreach (payload[i]) crc = crc81_update_byte(crc, payload[i]);
    return crc;
  endfunction

  // NEW: 波形範例 + 線性基底，確認 bit order 及原展開式相容。
  // Waveform vector plus linear-basis checks validate bit order and compatibility with the original equations.
  function void crc81_self_test();
    logic [15:0] c, old_crc, new_crc;
    logic [7:0] d;
    c = crc81_update_byte(16'hFFFF, 8'h3E);
    if (c !== 16'h7C09) `uvm_fatal("CRC81_SELF", "FFFF + 3E must produce 7C09")
    c = crc81_update_byte(c, 8'h34);
    if (c !== 16'h08E0) `uvm_fatal("CRC81_SELF", "FFFF + 3E,34 must produce 08E0")
    for (int k = -1; k < 24; k++) begin
      c = '0;
      d = '0;
      if (k >= 0 && k < 16) c[k] = 1'b1;
      if (k >= 16) d[k-16] = 1'b1;
      old_crc = spi_slv_crc(d, c);
      new_crc = crc81_update_byte(c, d);
      if (new_crc !== old_crc)
        `uvm_fatal("CRC81_SELF", $sformatf("Basis %0d: loop=%04h original=%04h", k, new_crc, old_crc))
    end
    `uvm_info("CRC81_SELF", "CRC loop self-test PASS", UVM_LOW)
  endfunction

  // NEW: 有限等待，避免 clock 停止造成永久卡住。 / Bound clock settling to avoid hanging on a stopped clock.
  task crc81_settle();
    fork
      begin
        fork
          begin repeat (16) @(negedge `TM_SPI_SLV.clk); end
          begin #100us; `uvm_fatal("CRC81_CLOCK", "TMCU SPI slave clock did not advance") end
        join_any
        disable fork;
      end
    join
  endtask

  // MODIFY: 先設定 seed，再清 CRC；只寫 seed 不會立即更新 accumulator。
  // Program the seed, then clear CRC; programming the seed alone does not reload the accumulator.
  task crc81_initialize();
    logic [7:0] ctrl;
    tmcu_reg_write(8'hB2, 8'h9E, CRC_SEED[7:0]);
    tmcu_reg_write(8'hB2, 8'h9F, CRC_SEED[15:8]);
    tmcu_reg_read(8'hB2, 8'h9D, ctrl);
    if ($isunknown(ctrl)) `uvm_fatal("CRC81_CFG", "B2:9D contains X/Z")
    ctrl[6:5] = 2'b11;
    ctrl[4] = 1'b0;
    // W/C 欄位只在需要 clear 時置 1，保留 RX 與 length 欄位。
    // Assert the W/C field only for clearing; preserve RX and length fields.
    tmcu_reg_write(8'hB2, 8'h9D, ctrl | 8'h10);
    tmcu_reg_write(8'hB2, 8'h9D, ctrl);
    crc81_settle();
    if (`TM_SPI_SLV.crc_data_o !== CRC_SEED)
      `uvm_fatal("CRC81_INIT", $sformatf("CRC clear failed: actual=%04h expected=%04h", `TM_SPI_SLV.crc_data_o, CRC_SEED))
    if (`TM_SPI_SLV.crc_err_level !== 1'b0)
      `uvm_fatal("CRC81_INIT", "CRC error level did not clear")
  endtask

  // MODIFY: length 依實際 payload.size() 設定，不做 11-bit 靜默截斷。
  // Set length from the actual payload size; reject values that would truncate to 11 bits.
  task crc81_set_length(input int n);
    logic [7:0] ctrl;
    logic [7:0] len_lo, len_hi;
    if (n < 1 || n > 2047) `uvm_fatal("CRC81_LEN", $sformatf("Invalid payload size %0d", n))
    tmcu_reg_read(8'hB2, 8'h9D, ctrl);
    if ($isunknown(ctrl)) `uvm_fatal("CRC81_CFG", "B2:9D contains X/Z")
    ctrl[4] = 1'b0;
    ctrl[2:0] = n[10:8];
    tmcu_reg_write(8'hB2, 8'h9C, n[7:0]);
    tmcu_reg_write(8'hB2, 8'h9D, ctrl);
    tmcu_reg_read(8'hB2, 8'h9C, len_lo);
    tmcu_reg_read(8'hB2, 8'h9D, len_hi);
    if ({len_hi[2:0],len_lo} !== n[10:0])
      `uvm_fatal("CRC81_LEN", "CRC length register readback mismatch")
  endtask

  // NEW: 同時觀察真正的 CS low->high 與 task 返回，不以固定 #1000 判斷完成。
  // Observe a real CS low-to-high transfer and task return instead of relying on a fixed #1000.
  // 此 helper 只在 SPI idle 時呼叫；外層 500ms watchdog 也涵蓋 setup/register access。
  // Call only while SPI is idle; the outer 500ms watchdog also covers setup/register accesses.
  task crc81_send(input bit adr_mode, input logic [23:0] arg,
                  input crc81_payload_t payload, input bit compare_en);
    if (`TM_SPI_SLV.spi_csn !== 1'b1)
      `uvm_fatal("CRC81_BUSY", "SPI CS must be high before starting a test transaction")
    fork
      begin
        fork
          begin
            fork
              begin
                wait (`TM_SPI_SLV.spi_csn === 1'b0);
                wait (`TM_SPI_SLV.spi_csn === 1'b1);
              end
              begin
                if (adr_mode)
                  i2c_over_spi_adr_write(arg, payload, payload.size(), m_host_top_cfg.use_i2c_over_spi_tmcu);
                else
                  i2c_over_spi_crc_write(arg, payload, payload.size(), compare_en, m_host_top_cfg.use_i2c_over_spi_tmcu);
              end
            join
            crc81_settle();
          end
          begin
            #50ms;
            `uvm_fatal("CRC81_TIMEOUT", "SPI transaction/transport task did not complete within 50ms")
          end
        join_any
        disable fork;
      end
    join
  endtask

  task crc81_set_address(input logic [23:0] addr);
    crc81_payload_t addr_bytes;
    // MODIFY: 原本 [0]/[1]/[2] 是 bit；連續 register bytes 必須使用 byte slices。
    // Original [0]/[1]/[2] selected bits; consecutive register bytes require byte slices.
    addr_bytes = '{addr[7:0], addr[15:8], addr[23:16]};
    if (`TM_SPI_SLV.START_ADDR_POS !== START_ADDR_REG)
      `uvm_fatal("CRC81_ADDRMAP", $sformatf("RTL START_ADDR_POS=%06h, supplied map=%06h; check instance parameter/reg map", `TM_SPI_SLV.START_ADDR_POS, START_ADDR_REG))
    crc81_send(1'b1, START_ADDR_REG, addr_bytes, 1'b0);
    // NEW: 確認 SPI ADR write 確實更新 CRC write 使用的內部地址。
    // Confirm SPI ADR write updated the internal address actually used by CRC writes.
    if (`TM_SPI_SLV.addr_reg !== addr)
      `uvm_fatal("CRC81_ADDR", $sformatf("ADR write: addr_reg=%06h expected=%06h", `TM_SPI_SLV.addr_reg, addr))
  endtask

  // NEW: 由暫存器驗 status 與 CRC；地址檢查用 RTL latch，避免假設 A8-AA 會反映自動增量。
  // Check status/CRC through registers; use the RTL address latch because A8-AA may not mirror automatic increments.
  task crc81_check(input string label_s, input logic [2:0] exp_status,
                    input logic [15:0] exp_crc, input logic [23:0] exp_addr);
    logic [7:0] status, lo, hi;
    tmcu_reg_read(8'hB2, 8'hA6, status);
    tmcu_reg_read(8'hB2, 8'hA4, lo);
    tmcu_reg_read(8'hB2, 8'hA5, hi);
    if (status[2:0] !== exp_status)
      `uvm_fatal("CRC81_STATUS", $sformatf("%s: {err,pass,done}=%03b expected=%03b", label_s, status[2:0], exp_status))
    if ({hi,lo} !== exp_crc)
      `uvm_fatal("CRC81_DATA", $sformatf("%s: CRC=%04h expected=%04h", label_s, {hi,lo}, exp_crc))
    if (`TM_SPI_SLV.addr_reg !== exp_addr)
      `uvm_fatal("CRC81_ADDR", $sformatf("%s: addr_reg=%06h expected=%06h", label_s, `TM_SPI_SLV.addr_reg, exp_addr))
    crc81_cases++;
    `uvm_info("CRC81_CASE", $sformatf("%s PASS: CRC=%04h status=%03b addr=%06h", label_s, {hi,lo}, status[2:0], exp_addr), UVM_LOW)
  endtask

  task crc81_body();
    crc81_payload_t payload;
    logic [15:0] golden, accumulated, bad_golden;
    logic [23:0] addr;
    int n;

    crc81_cases = 0;
    crc81_self_test();
    mcu_test_preset();
    if (m_host_top_cfg.use_i2c_over_spi_tmcu !== 1)
      `uvm_fatal("CRC81_ROUTE", "This test requires the TMCU SPI route (spi_select=1)")
    // MODIFY: preset 可能影響 clocks/reset，必須在 CRC register 設定之前完成。
    // Complete presets that may affect clocks/reset before programming CRC registers.
    i2c_over_spi_test_preset(m_host_top_cfg.use_i2c_over_spi_tmcu);
    crc81_settle();

    // NEW: 限制一次 smoke payload 為 1..64 bytes，沿用原 reg_set 資料來源。
    // Bound each smoke payload to 1..64 bytes while retaining the original reg_set data source.
    if (!reg_set.randomize() with { data_word inside {[1:64]}; })
      `uvm_fatal("CRC81_RAND", "reg_set randomization failed; inspect its constraints")
    reg_set.print();
    n = reg_set.data_word;
    if (reg_set.data.size() < n)
      `uvm_fatal("CRC81_PAYLOAD", "reg_set.data is smaller than data_word")
    // MODIFY: 計算與傳送使用同一份 payload，不再誤傳 start_addr bits。
    // Compute and transmit the same payload instead of accidentally sending start_addr bits.
    payload.delete();
    for (int i = 0; i < n; i++) payload.push_back(reg_set.data[i]);

    // NEW: 使用 ILM 內小段測試空間，避免把 Flash 的隨機地址當成 TMCU 合法地址。
    // Use a small ILM scratch region instead of treating a randomized Flash address as a valid TMCU address.
    // 若環境保留此空間，可用 +CRC81_START_ADDR=<hex> 指定另一段 ILM 空間。
    // If this space is reserved by the environment, select another ILM region with +CRC81_START_ADDR=<hex>.
    addr = 24'h001000;
    if ($value$plusargs("CRC81_START_ADDR=%h", addr)) begin end
    if (addr < `TM_SPI_SLV.ILM_BASE ||
        (longint'(addr) + 6*n) > (longint'(`TM_SPI_SLV.ILM_BASE) + (longint'(`TM_SPI_SLV.ILM_SIZE)<<10)))
      `uvm_fatal("CRC81_RANGE", "Selected CRC test region is outside ILM")

    crc81_initialize();
    crc81_set_length(n);
    crc81_set_address(addr);

    // TC1 MODIFY: compare pass 後 CRC 已回到 seed，不能再比 golden。
    // After compare passes, CRC has returned to the seed and must not be compared with golden.
    golden = crc81_calc(payload, CRC_SEED);
    crc81_send(0, {8'h00,golden}, payload, 1);
    addr += n;
    crc81_check("TC1_COMPARE_PASS", 3'b011, CRC_SEED, addr);

    // TC2 NEW: 故意給錯 golden，但 no compare 仍保留計算結果且不產生 error。
    // Deliberately send an incorrect golden value; no-compare must retain CRC without an error.
    accumulated = crc81_calc(payload, CRC_SEED);
    bad_golden = accumulated ^ 16'h0001;
    crc81_send(0, {8'h00,bad_golden}, payload, 0);
    addr += n;
    crc81_check("TC2_NO_COMPARE", 3'b000, accumulated, addr);

    // TC3 NEW: 第二筆 no compare 必須從上一筆 CRC 接續計算。
    // A second no-compare transaction must continue from the preceding CRC.
    accumulated = crc81_calc(payload, accumulated);
    bad_golden = accumulated ^ 16'h0001;
    crc81_send(0, {8'h00,bad_golden}, payload, 0);
    addr += n;
    crc81_check("TC3_NO_COMPARE_ACCUMULATE", 3'b000, accumulated, addr);

    // TC4 NEW: compare fail 回復到 TC3 CRC，地址不前進；不代表記憶體寫入回滾。
    // Compare failure restores the TC3 CRC and retains the address; it does not imply rollback of memory writes.
    golden = crc81_calc(payload, accumulated);
    bad_golden = golden ^ 16'h0001;
    crc81_send(0, {8'h00,bad_golden}, payload, 1);
    crc81_check("TC4_COMPARE_FAIL_ROLLBACK", 3'b101, accumulated, addr);

    // TC5 NEW: 不清 error 直接重試，同一 seed/地址必須可成功，sticky error 仍為 1。
    // Retry without clearing the error: the same seed/address must pass while the sticky error remains set.
    crc81_send(0, {8'h00,golden}, payload, 1);
    addr += n;
    crc81_check("TC5_RETRY_PASS_STICKY_ERROR", 3'b111, CRC_SEED, addr);

    // TC6 NEW: 清 error 後再做 compare，確認 error=0 且 pass/done 正常。
    // Clear the error and compare again to confirm error=0 and normal pass/done status.
    crc81_initialize();
    golden = crc81_calc(payload, CRC_SEED);
    crc81_send(0, {8'h00,golden}, payload, 1);
    addr += n;
    crc81_check("TC6_CLEAR_ERROR_AND_PASS", 3'b011, CRC_SEED, addr);
    `uvm_info("CRC81_SUMMARY", $sformatf("All %0d CRC cases completed", crc81_cases), UVM_LOW)
  endtask

  virtual task run_phase(uvm_phase phase);
    // MODIFY: objection 涵蓋 parent setup，外層 timeout 涵蓋所有 blocking tasks。
    // Cover parent setup with the objection and all blocking tasks with an outer timeout.
    phase.raise_objection(this);
    fork
      begin
        fork
          begin
            super.run_phase(phase);
            crc81_body();
          end
          begin
            #500ms;
            `uvm_fatal("CRC81_TEST_TIMEOUT", "CRC test exceeded 500ms; inspect clocks, register access, and I2C/SPI transport")
          end
        join_any
        disable fork;
      end
    join
    phase.drop_objection(this);
  endtask
endclass
