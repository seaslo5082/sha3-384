class mcu_i2c0_slv_256byte_rw_test extends host_mcu_i2c_base_test;
    `uvm_component_utils(mcu_i2c0_slv_256byte_rw_test)

    localparam int BURST_LEN = 256;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        logic [31:0] start_addr;
        byte write_data[$];

        super.run_phase(phase);
        phase.raise_objection(this);

        if (!$value$plusargs("MCU_I2C_BURST_ADDR=%h", start_addr) ||
            $isunknown(start_addr) || start_addr > 32'h0000_FF00) begin
            `uvm_fatal("MCU_I2C_BURST",
                       "Set +MCU_I2C_BURST_ADDR=<hex base of a 256-byte RW TCON window within 16-bit addressing>")
        end

        mcu_test_preset();
        mcu_sel = 0;
        mcu_i2c_test_preset(mcu_sel, "SLAVE");
        if (m_host_top_cfg.i2c_32bit_addr_mode !== 1'b0) begin
            `uvm_fatal("MCU_I2C_BURST", "Use the passing single test's 16-bit internal address mode")
        end
        #50us;

        repeat (BURST_LEN)
            write_data.push_back(byte'($urandom()));

        `uvm_info("MCU_I2C_BURST",
                  $sformatf("WRITE start: addr=0x%04h len=%0d",
                            start_addr[15:0], BURST_LEN), UVM_LOW)
        fork
            m_i2c_seq.i2c_sequential_byte_write(
                slv_dev_addr, start_addr, BURST_LEN, write_data[0:BURST_LEN-1]);
            mcu_i2c_slave_burst_write_and_compare(
                mcu_sel, slv_dev_addr, start_addr,
                m_host_top_cfg.i2c_32bit_addr_mode, write_data, scl_spd);
        join
        polling_mcu_i2c_status_reg(mcu_sel, 0, 1'b1);

        #($urandom_range(100, 40) * 1us);

        `uvm_info("MCU_I2C_BURST",
                  $sformatf("READ start: addr=0x%04h len=%0d",
                            start_addr[15:0], BURST_LEN), UVM_LOW)
        fork
            m_i2c_seq.i2c_sequential_byte_read(slv_dev_addr, start_addr, BURST_LEN);
            mcu_i2c_slave_burst_read_and_compare(
                mcu_sel, slv_dev_addr, start_addr,
                m_host_top_cfg.i2c_32bit_addr_mode, BURST_LEN, scl_spd);
        join

        `uvm_info("MCU_I2C_BURST", "256-byte write/read stimulus completed", UVM_LOW)
        phase.drop_objection(this);
    endtask

    local task mcu_i2c_slave_burst_write_and_compare(
        bit [2:0] mcu_sel,
        logic [6:0] slv_dev_addr,
        logic [31:0] addr,
        logic i2c_32bit_addr,
        byte data[],
        bit [2:0] scl_spd
    );
        logic [31:0] rx_reg_addr;
        logic [7:0] rx_byte;
        logic [7:0] rx_data[$];
        logic [31:0] byte_addr;

        if (data.size() == 0) begin
            `uvm_fatal("MCU_I2C_SLV", "Empty write payload")
            return;
        end

        `uvm_info("MCU_I2C_SLV",
                  $sformatf("WRITE: mcu=%0d dev=0x%02h addr=0x%08h len=%0d addr32=%0b",
                            mcu_sel, slv_dev_addr, addr, data.size(), i2c_32bit_addr), UVM_LOW)

        case (mcu_sel)
            0: rx_reg_addr = {m_host_top_cfg.mcu_reg_page_addr_1, 8'h16};
            1: rx_reg_addr = {m_host_top_cfg.mcu_reg_page_addr_1, 8'h26};
            2: rx_reg_addr = {m_host_top_cfg.mcu_reg_page_addr_2, 8'h11};
            3: rx_reg_addr = {m_host_top_cfg.mcu_reg_page_addr_2, 8'h8D};
            4: rx_reg_addr = {m_host_top_cfg.mcu_reg_page_addr_2, 8'h2F};
            default: begin
                `uvm_fatal("MCU_I2C_SLV", $sformatf("Invalid mcu_sel=%0d", mcu_sel))
                return;
            end
        endcase

        mcu_set_i2c_scl_spd(mcu_sel, scl_spd);

        polling_mcu_i2c_int_flag(mcu_sel, 7, 1'b1);
        #5us;
        write_mcu_i2c_config_reg(mcu_sel, 8'h40);
        #5us;
        mcu_i2c_int_clear(mcu_sel, 8'h80);

        // The passing source uses the 16-bit internal address path.
        for (int byte_index = 1; byte_index >= 0; byte_index--) begin
            polling_mcu_i2c_int_flag(mcu_sel, 5, 1'b1);
            #1us;
            read_mcu_i2c_rx_data_compare(mcu_sel, addr[8*byte_index +: 8]);
            #2us;
            mcu_i2c_int_clear(mcu_sel, 8'h20);
        end

        foreach (data[i]) begin
            polling_mcu_i2c_int_flag(mcu_sel, 5, 1'b1);  // RX IRQ
            if (data.size() > 1)
                polling_mcu_i2c_status_reg(mcu_sel, 3, 1'b1);  // RX Q2 full

            #1us;
            set_mcu_scb_model_golden_data(rx_reg_addr, data[i]);
            read_mcu_i2c_rx_data(mcu_sel, rx_byte);
            rx_data.push_back(rx_byte);

            #2us;
            mcu_i2c_int_clear(mcu_sel, 8'h20);

            if (data.size() == 1)
                #($urandom_range(10, 5) * 1us);
        end

        // Drain the RX queue before using MBUS for the TCON backing writes.
        foreach (rx_data[i]) begin
            byte_addr = addr + i;
            mcu_reg_wr(byte_addr[31:8], byte_addr[7:0], rx_data[i]);
        end
    endtask

    local task mcu_i2c_slave_burst_read_and_compare(
        bit [2:0] mcu_sel,
        logic [6:0] slv_dev_addr,
        logic [31:0] addr,
        logic i2c_32bit_addr,
        int data_length,
        bit [2:0] scl_spd
    );
        logic [31:0] byte_addr;
        logic [7:0] rdata;

        if (data_length <= 0) begin
            `uvm_fatal("MCU_I2C_SLV", $sformatf("Invalid read length %0d", data_length))
            return;
        end

        `uvm_info("MCU_I2C_SLV",
                  $sformatf("READ: mcu=%0d dev=0x%02h addr=0x%08h len=%0d addr32=%0b",
                            mcu_sel, slv_dev_addr, addr, data_length, i2c_32bit_addr), UVM_LOW)

        mcu_set_i2c_scl_spd(mcu_sel, scl_spd);

        polling_mcu_i2c_int_flag(mcu_sel, 7, 1'b1);
        #5us;
        write_mcu_i2c_config_reg(mcu_sel, 8'h40);
        #5us;
        mcu_i2c_int_clear(mcu_sel, 8'h80);

        for (int byte_index = 1; byte_index >= 0; byte_index--) begin
            polling_mcu_i2c_int_flag(mcu_sel, 5, 1'b1);
            #1us;
            read_mcu_i2c_rx_data_compare(mcu_sel, addr[8*byte_index +: 8]);
            #2us;
            mcu_i2c_int_clear(mcu_sel, 8'h20);
        end

        // Dev+R and the first TX request follow the passing single-read flow.
        polling_mcu_i2c_int_flag(mcu_sel, 7, 1'b1);
        polling_mcu_i2c_int_flag(mcu_sel, 6, 1'b1);
        #10us;
        mcu_i2c_int_clear(mcu_sel, 8'hC0);
        #5us;

        for (int i = 0; i < data_length; i++) begin
            if (i > 0)
                polling_mcu_i2c_int_flag(mcu_sel, 6, 1'b1);  // TX IRQ

            if (data_length > 1)
                polling_mcu_i2c_status_reg(mcu_sel, 5, 1'b1);  // TX Q1 empty

            byte_addr = addr + i;
            mcu_reg_rd(byte_addr[31:8], byte_addr[7:0], rdata);

            if (data_length == 1)
                #20us;

            write_mcu_i2c_tx_data(mcu_sel, rdata);

            if (data_length > 1)
                mcu_i2c_int_clear(mcu_sel, 8'h40);
            else
                #5us;
        end

        // The external master supplies the final NACK and STOP.
        if (data_length > 1)
            polling_mcu_i2c_status_reg(mcu_sel, 0, 1'b1);  // Bus idle

        write_mcu_i2c_config_reg(mcu_sel, 8'h00);
        #30us;
    endtask
endclass
