//////////////////////////////////////////////////////////////////////////////
//  Copyright 2014 Dov Stamler (dov.stamler@gmail.com)
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//////////////////////////////////////////////////////////////////////////////
 
`ifndef I2C_SLAVE_DRIVER__SV
`define I2C_SLAVE_DRIVER__SV

// MODIFY: functional byte-memory responder, with one sampled FSM instead of
// forked START/STOP workers. No accumulated process handles or objections.
// Each instance owns its memory and pointer. No slave sequence is required.
// MODIFY_INTEGRATION: self-contained slave driver; intentionally does NOT use
// the master-oriented i2c_base_component or its forked START/STOP workers.
// Uses the user's existing i2c_if without adding/changing clocking block ports.
// Interface clock must oversample SCL/SDA (e.g. 100 MHz for <= 1 MHz SCL).
// MODIFY32: cfg.addr_32bit_mode is INHERITED from the user's i2c_cfg.
// 0: Dev+W, Addr[15:8], Addr[7:0], payload...
// 1: Dev+W, Addr[31:24], Addr[23:16], Addr[15:8], Addr[7:0], payload...
// Address bytes are MSB first, and every accepted address byte is ACKed.
// Set cfg mode while the bus is idle and keep it stable for a combined read.
// STOP and repeated START preserve the pointer; read ACK/NACK belongs to master.
class i2c_slave_driver extends uvm_driver #(i2c_sequence_item);
  `uvm_component_utils(i2c_slave_driver)
  virtual i2c_if vif;
  i2c_slave_cfg cfg;
  // Compatibility alias for the slave_cfg name in the uploaded slave driver.
  // Agent supplies both handles to the SAME object.
  i2c_slave_cfg slave_cfg;

  // Retain the public 'data' name for existing preload code.
  // MODIFY32: full-width unsigned keys prevent truncation above 0xFFFF.
  // Sparse associative storage allocates only addresses actually written.
  typedef bit [31:0] mem_addr_t;
  logic [7:0] data[mem_addr_t];
  mem_addr_t mem_addr;
  mem_addr_t addr_shift;
  bit mode_32bit; // Latched per addressed segment; no mid-byte cfg changes.
  int unsigned addr_bytes_received, addr_bytes_required;

  typedef enum {
    IDLE, RX_DEVICE, RX_MEM_ADDR, RX_WRITE,
    ACK_SETUP, ACK_HIGH, ACK_END, TX_READ, RX_MASTER_ACK,
    NEXT_READ, WAIT_BOUNDARY
  } slave_state_t;
  slave_state_t state = IDLE;
  slave_state_t after_ack;
  logic prev_scl = 1'b1, prev_sda = 1'b1;
  logic [7:0] rx_byte, tx_byte;
  logic sda_drive = 1'b1; // 1 releases the open-drain pin; NEVER drives high.
  bit ack_this_byte;
  bit in_reset = 0;
  int unsigned bit_count, tx_bit, write_count;

  function new(string name = "i2c_slave_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null) cfg = slave_cfg;
    if (cfg == null)
      void'(uvm_config_db#(i2c_slave_cfg)::get(this, "", "cfg", cfg));
    if (vif == null)
      void'(uvm_config_db#(virtual i2c_if)::get(this, "", "vif", vif));
    if (cfg != null && slave_cfg != null && cfg != slave_cfg)
      `uvm_fatal("I2C_CFG", "cfg and slave_cfg refer to different objects")
    slave_cfg = cfg;
    if (cfg == null || vif == null)
      `uvm_fatal("I2C_CFG", "Slave cfg and vif must be assigned before build")
    if (cfg.address_num_of_bits != 7 || cfg.slave_address > 127)
      `uvm_fatal("I2C_CFG", "This memory slave requires a 7-bit device address")
    if (cfg.max_write_word_access_before_nack < 0)
      `uvm_fatal("I2C_CFG", "Write ACK limit must be >= 0; zero means unlimited")
    if (cfg.max_read_word_access_before_nack != 0)
      `uvm_warning("I2C_CFG", "Read NACK limit is ignored: the master owns read ACK/NACK")
    if ($isunknown(cfg.addr_32bit_mode))
      `uvm_fatal("I2C_CFG", "addr_32bit_mode must be 0 or 1")
    mode_32bit = cfg.addr_32bit_mode;
    mem_addr = normalize_addr(cfg.reset_pointer);
  endfunction

  // MODIFY: deterministic unwritten data, with explicit preload/peek helpers.
  function void poke(mem_addr_t addr, logic [7:0] value);
    data[addr] = value;
  endfunction

  function logic [7:0] peek(mem_addr_t addr);
    if (data.exists(addr)) return data[addr];
    return cfg.default_read_data;
  endfunction

  // MODIFY32: bus accesses wrap at the configured width.
  // Backdoor poke/peek always take the FULL address without implicit masking.
  function mem_addr_t normalize_addr(mem_addr_t addr);
    return mode_32bit ? addr : {16'h0000, addr[15:0]};
  endfunction

  function void advance_pointer();
    mem_addr = normalize_addr(mem_addr + 32'd1);
  endfunction

  function void prepare_ack(bit do_ack, slave_state_t next_state);
    ack_this_byte = do_ack;
    after_ack = next_state;
    state = ACK_SETUP;
    bit_count = 0;
  endfunction

  function void begin_read_byte();
    tx_byte = peek(mem_addr);
    tx_bit = 7;
    sda_drive = tx_byte[7];
    state = TX_READ;
  endfunction

  // MODIFY: single owner of protocol state and SDA output.
  // Reset/START/STOP preempt every state, including incomplete write bytes.
  function void sample_bus(logic scl, logic sda, logic resetn);
    bit scl_rise, scl_fall, start_seen, stop_seen;
    scl_rise = (prev_scl === 1'b0 && scl === 1'b1);
    scl_fall = (prev_scl === 1'b1 && scl === 1'b0);
    start_seen = (prev_scl === 1'b1 && scl === 1'b1 &&
                  prev_sda === 1'b1 && sda === 1'b0);
    stop_seen = (prev_scl === 1'b1 && scl === 1'b1 &&
                 prev_sda === 1'b0 && sda === 1'b1);
    prev_scl = scl;
    prev_sda = sda;

    if (resetn !== 1'b1) begin
      if (!in_reset) begin
        mode_32bit = (cfg.addr_32bit_mode === 1'b1);
        mem_addr = normalize_addr(cfg.reset_pointer);
        if (cfg.clear_memory_on_reset) data.delete();
      end
      in_reset = 1;
      state = IDLE;
      sda_drive = 1;
      bit_count = 0;
      write_count = 0;
      addr_shift = 0;
      addr_bytes_received = 0;
      return;
    end
    if (in_reset) begin
      in_reset = 0;
      return; // establish a new baseline after reset; wait for a fresh START
    end

    if (start_seen) begin
      state = RX_DEVICE;
      rx_byte = 0;
      bit_count = 0;
      write_count = 0;
      sda_drive = 1;
      addr_shift = 0;
      addr_bytes_received = 0;
      // MODIFY: keep mem_addr across START and repeated START.
      return;
    end
    if (stop_seen) begin
      state = IDLE;
      sda_drive = 1;
      // MODIFY: keep mem_addr across STOP for the separate START+READ form.
      return;
    end

    case (state)
      RX_DEVICE, RX_MEM_ADDR, RX_WRITE: begin
        if (scl_rise) begin
          rx_byte = {rx_byte[6:0], sda};
          bit_count++;
          if (bit_count == 8) begin
            if ($isunknown(rx_byte)) begin
              `uvm_error("I2C_X", "Unknown bit in received byte; NACK and wait for START/STOP")
              prepare_ack(0, WAIT_BOUNDARY);
            end
            else case (state)
              RX_DEVICE: begin
                if (rx_byte[7:1] !== cfg.slave_address[6:0])
                  prepare_ack(0, WAIT_BOUNDARY);
                else if ($isunknown(cfg.addr_32bit_mode)) begin
                  `uvm_error("I2C_CFG", "Unknown addr_32bit_mode; address NACKed")
                  prepare_ack(0, WAIT_BOUNDARY);
                end
                else begin
                  mode_32bit = cfg.addr_32bit_mode;
                  addr_bytes_required = mode_32bit ? 4 : 2;
                  addr_bytes_received = 0;
                  addr_shift = 0;
                  // If mode changed between transfers, a 16-bit read uses
                  // only the low 16 bits of the retained current pointer.
                  if (rx_byte[0]) mem_addr = normalize_addr(mem_addr);
                  prepare_ack(1, rx_byte[0] ? TX_READ : RX_MEM_ADDR);
                end
              end
              RX_MEM_ADDR: begin
                // MODIFY32: shift in two or four address bytes, MSB first.
                // Commit only when all bytes arrive; partial addresses never
                // corrupt the retained pointer, including across STOP/restart.
                addr_shift = {addr_shift[23:0], rx_byte};
                addr_bytes_received++;
                if (addr_bytes_received == addr_bytes_required) begin
                  mem_addr = normalize_addr(addr_shift);
                  prepare_ack(1, RX_WRITE);
                end
                else prepare_ack(1, RX_MEM_ADDR);
              end
              RX_WRITE: begin
                if (cfg.max_write_word_access_before_nack == 0 ||
                    write_count < cfg.max_write_word_access_before_nack) begin
                  poke(mem_addr, rx_byte);
                  advance_pointer(); // 16-bit or 32-bit wrap, according to mode
                  write_count++;
                  prepare_ack(1, RX_WRITE);
                end
                else prepare_ack(0, WAIT_BOUNDARY); // do not store NACKed data
              end
              default: ;
            endcase
          end
        end
      end
      ACK_SETUP: if (scl_fall) begin
        sda_drive = ack_this_byte ? 1'b0 : 1'b1;
        state = ACK_HIGH;
      end
      ACK_HIGH: if (scl_rise) state = ACK_END;
      ACK_END: if (scl_fall) begin
        // ACK is held throughout clock 9, then released on the falling edge.
        sda_drive = 1;
        rx_byte = 0;
        state = after_ack;
        if (after_ack == TX_READ) begin_read_byte();
      end
      TX_READ: if (scl_fall) begin
        if (tx_bit == 0) begin
          sda_drive = 1; // MODIFY: release for MASTER's ninth ACK/NACK bit.
          state = RX_MASTER_ACK;
        end
        else begin
          tx_bit--;
          sda_drive = tx_byte[tx_bit];
        end
      end
      RX_MASTER_ACK: if (scl_rise) begin
        // A complete read consumes one byte, including the final NACKed byte.
        advance_pointer();
        if (sda === 1'b0) state = NEXT_READ;
        else begin
          if (sda !== 1'b1) `uvm_error("I2C_X", "Unknown master ACK/NACK")
          state = WAIT_BOUNDARY;
          sda_drive = 1;
        end
      end
      NEXT_READ: if (scl_fall) begin_read_byte();
      default: sda_drive = 1;
    endcase
  endfunction

  task run_phase(uvm_phase phase);
    logic last_target, applied_sda, pending_sda;
    bit pending;
    realtime apply_at;
    last_target = 1;
    applied_sda = 1;
    pending_sda = 1;
    pending = 0;
    apply_at = 0;
    // MODIFY_INTEGRATION: initialize only this agent's output controls.
    vif.drv_cb.scl_out <= 1'b1;
    vif.drv_cb.sda_out <= 1'b1;
    // No objections or slave sequences: test owns the simulation lifetime.
    forever begin
      @(vif.drv_cb);
      sample_bus(vif.drv_cb.scl_in, vif.drv_cb.sda_in,
                 cfg.use_reset ? vif.resetn : 1'b1);
      vif.drv_cb.scl_out <= 1'b1; // no clock stretching in this model

      if ((cfg.use_reset && vif.resetn !== 1'b1) ||
          state == IDLE || state == RX_DEVICE) begin
        // Reset and bus boundaries cancel any stale delayed data/ACK update.
        pending = 0;
        applied_sda = 1;
        last_target = 1;
      end
      else begin
        if (sda_drive !== last_target) begin
          pending_sda = sda_drive;
          last_target = sda_drive;
          pending = 1;
          // MODIFY: uploaded cfg uses integer t_hd_dat, in nanoseconds.
          apply_at = $realtime +
                     (cfg.use_cfg_t_hd_dat ? cfg.t_hd_dat * 1ns : 0ns);
        end
        if (pending && $realtime >= apply_at) begin
          // SDA must remain stable during SCL high. An impossible timing
          // setting is an error, not an excuse to create a false START/STOP.
          if (vif.drv_cb.scl_in === 1'b0) begin
            applied_sda = pending_sda;
            pending = 0;
          end
          else begin
            `uvm_error("I2C_TIMING", "t_hd_dat + sampling/output delay exceeds SCL low time")
            pending = 0;
          end
        end
      end
      vif.drv_cb.sda_out <= applied_sda;
    end
  endtask
endclass
`endif
