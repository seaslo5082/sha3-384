`ifndef I2C_SLAVE_TRANSACTION__SV
`define I2C_SLAVE_TRANSACTION__SV
// MODIFY_INTEGRATION: extend, do not replace, the user's shared sequence item.
// Inherited address/direction_e/data/read_delay_num_cycle remain unchanged.
// data[] is the RAW bus byte stream after Dev+R/W: write address bytes included.
class i2c_slave_transaction extends i2c_sequence_item;
  logic data_ack[$]; // raw ninth bit: 0 ACK, 1 NACK; master owns read ACKs
  bit addr_32bit_mode;
  bit ended_by_stop, ended_by_restart, aborted_by_reset;
  `uvm_object_utils_begin(i2c_slave_transaction)
    `uvm_field_queue_int(data_ack, UVM_ALL_ON)
    `uvm_field_int(addr_32bit_mode, UVM_ALL_ON)
    `uvm_field_int(ended_by_stop, UVM_ALL_ON)
    `uvm_field_int(ended_by_restart, UVM_ALL_ON)
    `uvm_field_int(aborted_by_reset, UVM_ALL_ON)
  `uvm_object_utils_end
  function new(string name="i2c_slave_transaction");
    super.new(name);
  endfunction
endclass
`endif
