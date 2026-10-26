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
 
`ifndef I2C_SLAVE_MONITOR__SV
`define I2C_SLAVE_MONITOR__SV

// MODIFY: one sampled parser, one fresh item per START-addressed segment.
// Write data[] INCLUDES all register-address bytes (2 or 4), then payload.
// cfg.addr_32bit_mode == 0: [A15:8, A7:0, payload...].
// cfg.addr_32bit_mode == 1: [A31:24, A23:16, A15:8, A7:0, payload...].
// Repeated START publishes the write segment, then starts a new read segment.
class i2c_slave_monitor extends uvm_monitor;
  `uvm_component_utils(i2c_slave_monitor)
  i2c_slave_cfg cfg;
  virtual i2c_if vif;
  uvm_analysis_port #(i2c_sequence_item) analysis_port;
  typedef enum {M_IDLE, M_ADDRESS, M_ADDR_ACK, M_DATA, M_DATA_ACK, M_WAIT} mon_state_t;
  mon_state_t state = M_IDLE;
  logic prev_scl = 1, prev_sda = 1;
  logic [7:0] shift_byte;
  int unsigned bit_count;
  bit header_complete;
  i2c_slave_transaction item;

  function new(string name = "i2c_slave_monitor", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null)
      void'(uvm_config_db#(i2c_slave_cfg)::get(this, "", "cfg", cfg));
    if (vif == null)
      void'(uvm_config_db#(virtual i2c_if)::get(this, "", "vif", vif));
    if (cfg == null || vif == null) `uvm_fatal("I2C_CFG", "Monitor cfg/vif missing")
    if (cfg.address_num_of_bits != 7) `uvm_fatal("I2C_CFG", "Only 7-bit device addresses supported")
    analysis_port = new("analysis_port", this);
  endfunction
  function void finish_item(bit stop_seen, bit restart_seen, bit reset_seen);
    if (item != null && header_complete) begin
      item.ended_by_stop = stop_seen;
      item.ended_by_restart = restart_seen;
      item.aborted_by_reset = reset_seen;
      analysis_port.write(item);
    end
    item = null; // never reuse/mutate a previously published handle
    header_complete = 0;
    state = M_IDLE;
  endfunction
  function void sample_bus(logic scl, logic sda, logic resetn);
    bit rising, start_seen, stop_seen;
    rising = (prev_scl === 0 && scl === 1);
    start_seen = (prev_scl === 1 && scl === 1 && prev_sda === 1 && sda === 0);
    stop_seen = (prev_scl === 1 && scl === 1 && prev_sda === 0 && sda === 1);
    prev_scl = scl;
    prev_sda = sda;
    if (resetn !== 1'b1) begin
      finish_item(0, 0, 1);
      return;
    end
    if (start_seen) begin
      finish_item(0, 1, 0);
      item = i2c_slave_transaction::type_id::create("item", this);
      item.addr_32bit_mode = cfg.addr_32bit_mode;
      if (cfg.start_e != null) begin cfg.start_e.trigger(); cfg.start_e.reset(); end
      shift_byte = 0;
      bit_count = 0;
      state = M_ADDRESS;
      return;
    end
    if (stop_seen) begin
      if (cfg.stop_e != null) begin cfg.stop_e.trigger(); cfg.stop_e.reset(); end
      finish_item(1, 0, 0);
      return;
    end
    if (!rising) return;
    case (state)
      M_ADDRESS, M_DATA: begin
        shift_byte = {shift_byte[6:0], sda};
        bit_count++;
        if (bit_count == 8) begin
          bit_count = 0;
          if (state == M_ADDRESS) begin
            item.address = {3'b0, shift_byte[7:1]};
            item.direction_e = e_i2c_direction'(shift_byte[0]);
            state = M_ADDR_ACK;
          end
          else state = M_DATA_ACK;
        end
      end
      M_ADDR_ACK: begin
        item.address_ack = sda;
        item.addr_32bit_mode = cfg.addr_32bit_mode;
        if (sda === 1 && cfg.dev_addr_nack_e != null) begin
          cfg.dev_addr_nack_e.trigger(); cfg.dev_addr_nack_e.reset();
        end
        header_complete = 1;
        state = (sda === 0) ? M_DATA : M_WAIT;
      end
      M_DATA_ACK: begin
        // MODIFY: publish only complete 8+1-bit bytes, never a STOP setup bit.
        item.data.push_back(shift_byte);
        item.data_ack.push_back(sda);
        // Normal final read NACK is NOT a slave write-error event.
        if (sda === 1 && item.direction_e == I2C_DIR_WRITE && cfg.data_nack_e != null) begin
          cfg.data_nack_e.trigger(); cfg.data_nack_e.reset();
        end
        state = (sda === 0) ? M_DATA : M_WAIT;
      end
      default: ;
    endcase
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);
      sample_bus(vif.mon_cb.scl_in, vif.mon_cb.sda_in,
                 cfg.use_reset ? vif.resetn : 1'b1);
    end
  endtask
endclass
`endif
