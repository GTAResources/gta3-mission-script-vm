class Gta3Vm::VmViceCity < Gta3Vm::Vm
  def self.scm_markers
    [ [0x6d,:memory], [0x00,:models], [0x00,:missions] ]
  end
  
  def self.max_data_type
    0x06
  end

  def self.data_types
    {
      0x01 => :int32,
      0x02 => :pg,
      0x03 => :pl,
      0x04 => :int8,
      0x05 => :int16,
      0x06 => :float32
    }
  end

  def self.opcodes_definition_path
    "data/vc/VICESCM.ini"
  end
end
