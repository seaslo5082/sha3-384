`ifndef I2C_SLAVE_ENV__SV
`define I2C_SLAVE_ENV__SV
// MODIFY_INTEGRATION: add alongside existing master i2c_env, do not replace it.
// Deliberately does not instantiate the DUT-register-specific master i2c_scb.
class i2c_slave_env extends uvm_env;
  `uvm_component_utils(i2c_slave_env)
  virtual i2c_if vif;
  i2c_slave_cfg cfg;
  i2c_slave_agent agent;
  uvm_analysis_port#(i2c_sequence_item) analysis_port;
  function new(string name="i2c_slave_env", uvm_component parent=null);
    super.new(name,parent);
    analysis_port = new("analysis_port",this);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null)
      void'(uvm_config_db#(i2c_slave_cfg)::get(this,"","cfg",cfg));
    if (cfg == null) cfg = i2c_slave_cfg::type_id::create("cfg",this);
    if (vif == null)
      void'(uvm_config_db#(virtual i2c_if)::get(this,"","vif",vif));
    if (vif == null) `uvm_fatal("I2C_VIF", "Slave env interface not set")
    uvm_config_db#(i2c_slave_cfg)::set(this,"agent","cfg",cfg);
    uvm_config_db#(virtual i2c_if)::set(this,"agent","vif",vif);
    agent = i2c_slave_agent::type_id::create("agent",this);
  endfunction
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agent.analysis_port.connect(analysis_port);
  endfunction
endclass
`endif
