class Gta3Vm::Opcodes

  include Gta3Vm::Logger

  attr_accessor :vm
  attr_accessor :opcode_data
  attr_accessor :opcode_module

  attr_accessor :symbol_names

  def initialize(vm)
    self.vm = vm
    self.opcode_data = {}
    self.opcode_module = Module.new
    load_symbol_names
    parse_from_scm_ini(self.vm.class.opcodes_definition_path)
    load_opcode_definitions
  end

  def load_opcode_definitions
    Dir.glob("lib/gta3vm/opcodes/*.rb").each do |path|
      int, float, bool, string = :int, :float, :bool, :string
      pg, lg = :pg, :lg
      int_or_float, int_or_var, float_or_var = :int_or_float, :int_or_var, :float_or_var
      var = :pg
      local, lvar = :lg
      log "load_opcode_definitions: loading #{path}"
      eval(File.read(path),nil,File.join(Dir.pwd,path))
    end
  end

  def valid?(opcode)
    !!self.opcode_data[opcode]
  end

  def definition_for(opcode)
    opcode = undo_negated_opcode(opcode)
    self.opcode_data[opcode]
  end

  def definition_for_name(opcode_name)
    @_definition_for_name ||= {}
    if @_definition_for_name.key?(opcode_name)
      @_definition_for_name[opcode_name]
    else
      value = self.opcode_data.values.detect do |opcode_def|
        opcode_name =~ /^#{opcode_def.symbol_name}$/i
      end
      @_definition_for_name[opcode_name] = value
      value
    end
  end

  # Conditional opcodes can have the highest bit of the opcode set to 1
  # So they look like 8038 instead of 0038
  # This is basically a NOT version of the normal opcode
  # We should detect this here, set a flag to say the next write_branch_condition call
  # should be negated, and remove the high bit on the opcode so it calls the "plain" opcode
  NEGATED_OPCODE_MASK = 0x80
  def undo_negated_opcode(opcode)
    good_opcode = opcode
    good_opcode[1] -= NEGATED_OPCODE_MASK if good_opcode[1] >= NEGATED_OPCODE_MASK
    good_opcode
  end

  def load_symbol_names
    self.symbol_names = {}
    File.open("data/vc/opcodes_defines.h","r").read.each_line do |line|
      matches = line.match(%r[\/\* ([0-9A-F]+) .*? "(\w+)"])
        puts "matches: #{matches.inspect}"
      if matches
        opcode, name = $1, $2
        symbol_names[opcode] = name
      end
    end
    puts "symbol_names: #{symbol_names.inspect}"
  end

  def parse_from_scm_ini(path_to_ini)
    File.open(path_to_ini,"r").read.each_line do |line|
      next unless line =~ /\A([0-9a-f]{4})\=(-?\d+),(.*)?/i
      opcode, arg_count, o_notes = $1.upcase, $2.to_i, $3
      # puts o_notes
      opcode.upcase!

      # try to hack something nice out of the notes
      notes = o_notes.gsub(/(%.*?%)/im,'').strip.gsub(/;/,'').gsub(/\s+/,'_')

      opcode_name = if name = symbol_names[opcode]
        name
      else
        "#{opcode}_#{notes}"
      end
      # puts opcode_name

      # arg_names = {}

      # matches = o_notes.scan(/(\w+)\s+\%(\d+)([a-z]+)\%/)
      # if matches.size > 0
      #   matches.each do |row|
      #     index = row[1].to_i
      #     arg_names[index] = row[0]
      #   end
      #   puts "arg_names: #{arg_names.inspect}"
      # end
      
      args_def = {}
      if arg_count == -1
        args_def[:var_args] = -1
      else
        arg_count.times{ |i|
          # arg_name = arg_names[i] || "arg_#{i}"
          # args_def[arg_name.to_sym] = -1
          args_def[:"arg_#{i}"] = -1
        }
      end


      opcode(opcode,"auto_#{opcode_name}",args_def) {
        puts "  !!! WARNING: opcode #{opcode} is auto-generated and NOOP"
      }
    end
  end

  # dsl method
  def opcode(opcode_name_string,sym_name,arguments_definition = {},&block)
    opcode_bytes = opcode_name_string.scan(/(..)/).map{|hex| hex[0].to_i(16) }.reverse
    self.opcode_data[opcode_bytes] = Gta3Vm::OpcodeDefinition.new({
      :bytes      => opcode_bytes,
      :sym_name   => sym_name.to_s,
      :nice       => opcode_name_string,
      :symbol_name=> self.symbol_names[opcode_name_string] || sym_name,
      :args_count => arguments_definition.size,
      :args_names => arguments_definition.keys,
      :args_types => arguments_definition.values.map { |type| type }
    })
    self.opcode_module.class_eval do
      define_method("opcode_#{opcode_name_string}",&block)
    end
  end

end
