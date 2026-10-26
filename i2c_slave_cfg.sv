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

`ifndef I2C_SLAVE_CFG__SV
`define I2C_SLAVE_CFG__SV

// MODIFY: 7-bit I2C device address and a separate 16/32-bit byte memory pointer.
class i2c_slave_cfg extends i2c_cfg;
  rand logic [9:0] slave_address;
  // MODIFY: 0 = unlimited ACKs; N > 0 = ACK exactly N PAYLOAD bytes.
  // The two or four register-address bytes are not included in this limit.
  rand int max_write_word_access_before_nack;
  // Compatibility field only: a slave TRANSMITTER cannot NACK a read byte.
  rand int max_read_word_access_before_nack;
  logic [7:0] default_read_data = 8'hFF;
  // MODIFY32: addr_32bit_mode already exists in base i2c_cfg.
  // Do NOT redeclare it here: cfg and driver must read the SAME field.
  bit [31:0] reset_pointer = 32'h0000_0000;
  bit clear_memory_on_reset = 0;
  // MODIFY_INTEGRATION: read resetn directly; user's clocking blocks omit it.
  // If the existing interface resetn is unused, explicitly set use_reset = 0.
  bit use_reset = 1;
  // cfg.t_hd_dat (in ns) is inherited from the user's existing i2c_cfg.
  // Honor this delay after a sampled SCL falling edge when updating SDA.
  bit use_cfg_t_hd_dat = 1;

  `uvm_object_utils_begin(i2c_slave_cfg)
    `uvm_field_int(slave_address, UVM_ALL_ON)
    `uvm_field_int(max_write_word_access_before_nack, UVM_ALL_ON)
    `uvm_field_int(max_read_word_access_before_nack, UVM_ALL_ON)
    `uvm_field_int(default_read_data, UVM_ALL_ON)
    `uvm_field_int(reset_pointer, UVM_ALL_ON)
    `uvm_field_int(clear_memory_on_reset, UVM_ALL_ON)
    `uvm_field_int(use_reset, UVM_ALL_ON)
    `uvm_field_int(use_cfg_t_hd_dat, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "i2c_slave_cfg");
    super.new(name);
    // MODIFY: usable defaults even when the caller does not randomize cfg.
    is_active = UVM_ACTIVE;
    address_num_of_bits = 7;
    slave_address = `I2C_DEFAULT_SLAVE_ADDRESS;
    addr_32bit_mode = 0; // inherited field; caller may set 1 before traffic
    max_write_word_access_before_nack = 0;
    max_read_word_access_before_nack = 0;
  endfunction

  constraint agent_is_active_c { soft is_active == UVM_ACTIVE; }
  constraint address_bits_c { address_num_of_bits == 7; }
  constraint slave_address_c {
    slave_address inside {[0:127]};
    soft slave_address == `I2C_DEFAULT_SLAVE_ADDRESS;
  }
  constraint max_word_access_c {
    max_write_word_access_before_nack >= 0;
    soft max_write_word_access_before_nack == 0;
    max_read_word_access_before_nack == 0;
  }
endclass
`endif
