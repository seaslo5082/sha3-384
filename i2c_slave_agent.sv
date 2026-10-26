`ifndef I2C_SLAVE_AGENT__SV
`define I2C_SLAVE_AGENT__SV
// MODIFY_INTEGRATION: keeps the uploaded agent's vif/cfg/mon/drv names.
// Accept either direct handle assignment OR type-correct config_db entries.
class i2c_slave_agent extends uvm_agent;
  `uvm_component_utils(i2c_slave_agent)
  virtual i2c_if vif;
  i2c_slave_cfg cfg;
  i2c_slave_monitor mon;
  i2c_slave_driver drv;
  uvm_analysis_port#(i2c_sequence_item) analysis_port;

  function new(string name="i2c_slave_agent", uvm_component parent=null);
    super.new(name,parent);
    analysis_port = new("analysis_port",this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null)
      void'(uvm_config_db#(i2c_slave_cfg)::get(this,"","cfg",cfg));
    if (cfg == null) begin
      // No surprise randomization of inherited addr_32bit_mode or timing.
      cfg = i2c_slave_cfg::type_id::create("cfg",this);
      `uvm_info("I2C_CFG", "Using default slave cfg: device 0x52, 16-bit memory address", UVM_LOW)
    end
    if (vif == null)
      void'(uvm_config_db#(virtual i2c_if)::get(this,"","vif",vif));
    if (vif == null) `uvm_fatal("I2C_VIF", "Slave interface not set")

    // Explicit types: a set#(i2c_master_cfg) does NOT satisfy get#(i2c_slave_cfg).
    uvm_config_db#(i2c_slave_cfg)::set(this,"mon","cfg",cfg);
    uvm_config_db#(virtual i2c_if)::set(this,"mon","vif",vif);
    mon = i2c_slave_monitor::type_id::create("mon",this);
    mon.cfg = cfg;
    mon.vif = vif;
    if (cfg.is_active == UVM_ACTIVE) begin
      uvm_config_db#(i2c_slave_cfg)::set(this,"drv","cfg",cfg);
      uvm_config_db#(virtual i2c_if)::set(this,"drv","vif",vif);
      drv = i2c_slave_driver::type_id::create("drv",this);
      drv.cfg = cfg;
      drv.slave_cfg = cfg;
      drv.vif = vif;
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    mon.analysis_port.connect(analysis_port);
  endfunction
endclass
`endif
