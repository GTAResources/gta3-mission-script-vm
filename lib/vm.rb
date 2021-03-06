require "ostruct"
class OpenStruct; def to_hash; @table; end; end
require "pp"

TYPE_SHORTHANDS = {
  :int32   => 0x01,
  :pg      => 0x02, # all "pointers" are to ints or floats
  :bool    => 0x04,
  :int8    => 0x04,
  :int16   => 0x05,
  :float32 => 0x06,
  :string  => 0x09,
  :vstring => 0x0e
}
TYPE_SHORTHANDS_INV = TYPE_SHORTHANDS.invert
POINTER_TYPES = {
  :pg => { :scope => :global, :size => 4 }
}
TYPE_SIZES = {
  0x01 => 4,
  0x02 => 4,
  0x04 => 1,
  0x05 => 2,
  0x06 => 4,
  0x09 => nil, # ???
  0x0e => lambda {},
}
GENERIC_TYPE_SHORTHANDS = {
  :int    => [:int8,:int16,:int32],
  :float  => [:float32],
  :string => [:string,:vstring],
  :var    => [:pg]
}
GENERIC_TYPE_SHORTHANDS[:int_or_float] = GENERIC_TYPE_SHORTHANDS[:int] + GENERIC_TYPE_SHORTHANDS[:float]
GENERIC_TYPE_SHORTHANDS[:int_or_var] = GENERIC_TYPE_SHORTHANDS[:int] + GENERIC_TYPE_SHORTHANDS[:var]
GENERIC_TYPE_SHORTHANDS[:float_or_var] = GENERIC_TYPE_SHORTHANDS[:float] + GENERIC_TYPE_SHORTHANDS[:var]
OPCODE = -0x02
TYPE   = -0x03
VALUE  = -0x04
COLORS = {
  OPCODE => "0;30;42",
  TYPE   => "0;30;45",
  VALUE  => "0;30;44",
  0x01   => "4;34", # int val = blue
  0x02   => "4;32", # pointer = green
  0x04   => "4;34",
  0x06   => "4;33", #float val = yellow
}
DEFAULT_COLOR = "7"

$: << "./lib"
load "game_objects/game_object.rb"
load "game_objects/player.rb"
load "game_objects/actor.rb"
load "game_objects/pickup.rb"
load "game_objects/cargen.rb"
load "game_objects/mapobject.rb"
load "opcode_dsl.rb"
load "opcodes.rb"
load "decompiler.rb"

# (load("lib/vm.rb") && Vm.load_scm("main-vc").run)
# (load("lib/vm.rb") && Vm.load_scm("main-vc").decompile!)
# (load("lib/vm.rb") && Vm.load_scm("main").tap{|vm| vm.import_state_from_gamesave("GTASAsf1.b") })

class Vm
  attr_accessor :memory

  attr_accessor :struct_positions
  attr_accessor :models, :missions

  attr_accessor :pc

  attr_accessor :original_opcode
  attr_accessor :opcode
  attr_accessor :args

  attr_accessor :thread_id
  attr_accessor :thread_pcs
  attr_accessor :thread_names
  attr_accessor :thread_vars
  attr_accessor :thread_timers
  attr_accessor :thread_stacks
  attr_accessor :thread_suspended
  attr_accessor :thread_switch_to_id

  attr_accessor :negated_opcode
  attr_accessor :branch_conditions

  attr_accessor :missions
  attr_accessor :missions_ranges
  attr_accessor :missions_count

  attr_accessor :engine_vars

  attr_accessor :allocations, :allocation_ids

  attr_accessor :onmission_address
  attr_accessor :game_objects

  attr_accessor :opcodes_module

  attr_accessor :scm_structures

  attr_accessor :opcode_map
  attr_accessor :opcode_addresses_to_jump_sources

  attr_accessor :tick_count
  attr_accessor :time
  attr_accessor :dirty, :dirty_memory_addresses

  attr_accessor :data_dir

  DATA_TYPE_MAX = 31
  VARIABLE_STORAGE_AT = 8
  NEGATED_OPCODE_MASK = 0x80

  DIRTY_STATES = [:threads,:memory,:game_objects,:map]

  def self.load_scm(scm = "main-vc")
    new( scm, File.read("#{`pwd`.strip}/#{scm}.scm") )
  end

  def initialize(scm_name,script_binary,options = {})
    self.memory = Memory.new(script_binary)
    self.data_dir = data_dir = { "main-vc" => "vc", "main" => "sa" }[scm_name]

    self.pc = 0

    self.thread_id = 0
    self.thread_pcs = [0]
    self.thread_names = []
    self.thread_vars = Array.new { Array.new(32,nil) } # 32 local vars
    self.thread_timers = Array.new { Array.new(2,nil) } # 2 local timers
    self.thread_stacks = Array.new { Array.new(8,nil) } # fixed 8-level stack
    self.thread_suspended = false

    self.engine_vars = OpenStruct.new

    self.allocations = {} # address => [pointer_type,id]
    self.allocation_ids = Hash.new { |h,k| h[k] = 0 }

    self.game_objects = {}

    self.tick_count = 0
    self.time = 0 #microseconds
    
    self.dirty = {}
    reset_dirty_state

    self.opcodes_module = Opcodes.module_for_game(data_dir)
    extend self.opcodes_module

    detect_scm_structures!
    build_opcode_map!
  end

  GAMESAVE_MEM_STRUCT_POS = 0x138 + 5 + 5 # 2 "BLOCK"s
  GAMESAVE_THREAD_OFFSET = 10787168
  def import_state_from_gamesave(save_path)
    puts "import_state_from_gamesave(#{save_path.inspect})"
    file = File.open(save_path)
    file.seek GAMESAVE_MEM_STRUCT_POS

    puts "  importing memory..."
    mem_size = file.read(4).unpack("L")[0]
    mem_pos = self.struct_positions[:memory][0]
    puts "    found #{mem_size} bytes, writing to #{mem_pos}"
    mem_contents = file.read(mem_size)
    self.struct_positions[:memory][0]
    write!(mem_pos,mem_size,mem_contents)

    thread_structs_pos = GAMESAVE_MEM_STRUCT_POS + 4 + mem_size + 0x0902
    puts "  importing threads..."
    file.seek thread_structs_pos
    num_threads = file.read(4).unpack("L")[0]
    puts "    found #{num_threads} threads"
    
    num_threads.times do |thread_num|
      puts
      thread_pos = thread_structs_pos + 4 + (thread_num * 262)

      file.seek(thread_pos)
      thread_id = file.read(2).unpack("S")[0]

      n_p = file.read(32).unpack("l")[0]
      p_p = file.read(32).unpack("l")[0]
      puts "  n_p: #{n_p}, p_p: #{p_p}"

      file.seek(thread_pos + 2 + 0x08)
      thread_name = file.read(8).strip

      file.seek(thread_pos + 2 + 0x10)
      base_address = file.read(4).unpack("l")[0]
      file.seek(thread_pos + 2 + 0x14)
      thread_pc = file.read(4).unpack("l")[0]

      thread_stack = file.read(4*8).unpack("l")
      thread_stack_p = file.read(4).unpack("l")[0]
      #puts "  thread_stack: #{thread_stack.inspect} - #{thread_stack_p}"

      rel_addresses_pos = thread_pos + 226
      
      36.times do |rel_addr_id|
        rel_address_pos = rel_addresses_pos + (rel_addr_id * 36)
        file.seek(rel_address_pos)
        rel_pc = file.read(4).unpack("L")[0]
        rel_stack = file.read(4*8).unpack("L*")
        if rel_addr_id == 0
          #puts "    !> #{rel_pc}"
          #puts "    !> #{hex(self.disassemble_opcode_at(rel_pc).flatten) rescue '!'}"
        end
        #puts "    #{rel_pc} - #{rel_stack.inspect}"
      end

      thread_pc -= GAMESAVE_THREAD_OFFSET

      # TODO: local thread vars
      self.thread_pcs[thread_id] = thread_pc
      self.thread_names[thread_id] = thread_name

      puts "    thread ##{thread_id} (#{thread_name}) @ #{thread_pc} #{base_address}"
      #puts "    #{self.struct_positions.inspect}"
      puts "    disassembly: #{self.disassemble_opcode_at(thread_pc).inspect}"
      puts "    disassembly: #{hex(self.disassemble_opcode_at(thread_pc).flatten)}"
    end

  end

  def run
    while tick!; end
  end

  def controlled_ticks
    while gets; tick!; end
  end

  def tick!
    traditional_tick = false

    # have to at least set up the initial tick
    if !traditional_tick && self.tick_count == 0
      manage_time!

      prepare_opcode!
      inspect_opcode
      return true
    end

    reset_dirty_state
    # reads opcode, executes opcode, returns afterwards
    if traditional_tick
      manage_time!

      prepare_opcode!
      inspect_opcode
      execute!

      inspect_memory
      manage_threads!
    # execute pending opcode, prepare next opcode, return so vm state can be
    # manipulated for next tick! where it will be executed
    else
      execute!

      inspect_memory
      manage_threads!

      manage_time!

      prepare_opcode!
      inspect_opcode
    end

    self.dirty[:threads] = true
    self.dirty[:game_objects] = self.game_objects.values.any?(&:dirty_check!)

    puts; true
  rescue => ex
    handle_vm_exception(ex)
  end

  def execute!
    definition = self.opcodes_module.definitions[self.opcode]
    translated_opcode = definition[:nice]

    # TODO: will this actually handle variable-length arg lists?
    native_args = []
    self.args.each_with_index do |(type,value),index|
      validate_arg!(definition[:args_types][index],type,translated_opcode,index)

      if type == 0x00 # end of variable-length arg list
        start_arg = definition[:args_names].index(:var_args)
        native_args[start_arg..-1] = [[:var_args,0x00,native_args[start_arg..-1]]]
      else
        native_args << [ definition[:args_names][index], type, arg_to_native(type,value) ]
      end
    end

    # TODO: check for pointer types, resolve values, provide _addr value for pointer deref
    args_helper = OpcodeArgs.new
    native_args.each do |(name,type,native_value)|
      if native_value.is_a?(Array)
        args_helper.add_arg("var_args",native_value.map{ |a| a[1] },native_value.map{ |a| a[2] })
        #args_helper.send("var_args=",native_value.map{ |a| a[2] })
        #args_helper.send("var_args_type=",native_value.map{ |a| a[1] })
      else
        args_helper.add_arg(name,type,native_value)
        #args_helper.send("#{name}=",native_value)
        #args_helper.send("#{name}_type=",type)
      end
    end

    opcode_method = "opcode_#{translated_opcode}"
    nice_args = args_helper.to_hash.reject{|k,v| k =~ /_type$/}.map{|k,v| ":#{k}=>#{v.inspect}" }
    puts "  #{opcode_method}_#{definition[:sym_name]}(#{nice_args.join(',')})"
    
    send(opcode_method,args_helper)
  end

  def manage_time!
    self.tick_count += 1
    self.time += 1000 # 1ms, 1000 microseconds
  end

  def prepare_opcode!
    self.negated_opcode = false
    self.pc = self.thread_pcs[self.thread_id]

    opcode_start_address = self.pc

    disassembly = disassemble_opcode_at(opcode_start_address)

    self.pc += disassembly.flatten.size

    self.opcode = disassembly[0]
    self.args = disassembly[1]

    original_opcode = self.opcode
    if original_opcode != undo_negated_opcode(self.opcode)
      self.opcode = undo_negated_opcode(self.opcode)
      self.negated_opcode = true
    end
  end

  def inspect_opcode
    original_opcode = self.opcode
    original_opcode[0] += NEGATED_OPCODE_MASK if self.negated_opcode
    opcode_start_address = self.thread_pcs[self.thread_id]
    mem_width = 32#40
    opcode_prelude = 4
    shim_size = (0)...([opcode,args].flatten.compact.size)
    shim = "#{ch(OPCODE,original_opcode)} #{self.args.map{|a| "#{ch(TYPE,a[0])} #{a[1] ? ch(VALUE,a[1]) : '00'}" }.join(" ")}"
    puts " thread #{self.thread_id.to_s.rjust(2," ")} @ #{opcode_start_address.to_s.rjust(8,"0")} v (threadname:#{(self.thread_names[self.thread_id] || "-")} branch_conditions:#{self.branch_conditions.inspect} negated_opcode:#{self.negated_opcode.inspect})"
    puts dump_memory_at(opcode_start_address,mem_width,opcode_prelude,shim_size,shim)
  end

  def inspect_memory
    width,rows = 32, 0
    rows.times do |index|
      puts dump_memory_at(VARIABLE_STORAGE_AT+(index*width),width)
    end
  end

  def manage_threads!
    self.thread_pcs[self.thread_id] = self.pc
    if self.thread_suspended
      puts "  suspended"
      until self.thread_switch_to_id && self.thread_pcs[self.thread_switch_to_id]
        self.thread_switch_to_id = (self.thread_id + 1) % self.thread_pcs.size
      end
      self.thread_suspended = false
    end
    if self.thread_switch_to_id
      puts " switching to thread #{self.thread_switch_to_id}"
      self.thread_id = self.thread_switch_to_id
      self.thread_switch_to_id = false
    end
  end

  def handle_vm_exception(ex)
    self.pc -= 2 if [InvalidOpcode].include?(ex.class) #rewind so we get the opcode in the dump
    puts
    puts "!!! #{ex.class.name}: #{ex.message}"
    puts "VM state:"
    puts "#{self.inspect}"
    puts
    puts "Dump at pc:"
    puts dump_memory_at(pc)
    puts
    puts "Backtrace:"
    puts ex.backtrace.reject{ |l| l =~ %r{(irb_binding)|(bin/irb:)|(ruby/1.9.1/irb)} }.join("\n")
    puts
    raise ex
  end

  # include Opcodes

  def inspect
    vars_to_inspect = [:pc,:opcode,:opcode_nice,:args,:thread_id,:thread_pcs,:branch_conditions]
    vars_to_inspect += instance_variables.map { |iv| iv.to_s.gsub(/@/,"").to_sym }
    vars_to_inspect -= [:memory]
    vars_to_inspect.uniq!
    "#<#{self.class.name} #{vars_to_inspect.map{|var| "#{var}=#{send(var).inspect}" }.join(" ") }>"
  end

  def opcode_nice(opcode = self.opcode)
    arg_to_native(-0x01,opcode).to_s(16).rjust(4,"0").upcase
  end

  def thread_name
    self.thread_names[self.thread_id]
  end

  # Conditional opcodes can have the highest bit of the opcode set to 1
  # So they look like 8038 instead of 0038
  # This is basically a NOT version of the normal opcode
  # We should detect this here, set a flag to say the next write_branch_condition call
  # should be negated, and remove the high bit on the opcode so it calls the "plain" opcode
  def undo_negated_opcode(opcode)
    good_opcode = opcode
    good_opcode[1] -= NEGATED_OPCODE_MASK if good_opcode[1] >= NEGATED_OPCODE_MASK
    good_opcode
  end

  def disassemble_opcode_at(address)
    opcode_pointer = address
    opcode, args = read(opcode_pointer,2), []
    opcode_pointer += 2

    opcode_for_lookup = undo_negated_opcode(opcode)
    raise InvalidOpcode, "#{hex(opcode_for_lookup.reverse)} not implemented" unless self.opcodes_module.definitions[opcode_for_lookup]

    arg_def = self.opcodes_module.definitions[opcode_for_lookup]
    args = []
    arg_def[:args_count].times do |index|
      # var_args is a magic arg name
      if arg_def[:args_names][index] == :var_args

        # read normal args up until an arg with the data_type 0x00
        while read(opcode_pointer,1)[0] != 0x00
          arg = disassemble_opcode_arg_at(opcode_pointer)
          opcode_pointer += arg.flatten.size
          args << arg
        end

        # read the data_type 0x00 in as an arg anyway
        args << read(opcode_pointer,1)
        opcode_pointer += 1

      else
        arg = disassemble_opcode_arg_at(opcode_pointer)
        opcode_pointer += arg.flatten.size
        args << arg
      end
    end

    [opcode,args]
  end

  def disassemble_opcode_arg_at(address)
    arg_type = read(address,1)[0]
    arg_bytes = bytes_to_read_for_arg_data_type(address)
    
    case arg_type
    when 0x0e
      [arg_type,read(address + 1,arg_bytes)] # address = data_type, +1 = var string length, +2 = var string start
    else
      [arg_type,read(address + 1,arg_bytes)]
    end
  end

  def bytes_to_read_for_arg_data_type(address)
    arg_type = read(address,1)[0]
    case arg_type
    when 0x01 # immediate 32 bit signed int
      4
    when 0x02 # 16-bit global pointer to int/float
      2
    when 0x03 # 16-bit local pointer to int/float
      2
    when 0x04 # immediate 8-bit signed int
      1
    when 0x05 # immediate 16-bit signed int 
      2
    when 0x06 # immediate 32-bit float
      4
    when 0x09 # immediate 8-byte string
      8
    when 0x0e # variable-length string
      read(address + 1,1)[0] + 1 #+1 to read the var string length prefix too
    else
      if arg_type > DATA_TYPE_MAX # immediate type-less 8-byte string
        7
      else
        raise InvalidDataType, "unknown data type #{arg_type} (#{hex(arg_type)})"
      end
    end
  end

  #protected

  def allocate_game_object!(address,game_object_class,pointer_type = :pg,&block)
    self.game_objects[address] = game_object_class.new
    allocate!(address,pointer_type,game_object_class)
    yield(self.game_objects[address]) if block_given?
  end

  # for initializing "objects" like players/actors/etc.
  # in the real game, we would normally be writing a pointer to a native game object
  # but instead, we'll just auto-increment an id and store that, referencing things by their address instead
  # for things like ints/floats/strings, we'll store the real value
  def allocate!(address,data_type,value = nil)
    data_type = TYPE_SHORTHANDS[data_type] if data_type.is_a?(Symbol)
    size = TYPE_SIZES[data_type]
    klass = nil
    raise ArgumentError, "address is nil" unless address
    raise ArgumentError, "data_type is nil" unless data_type

    to_write = if !value.is_a?(Class)
      allocation_id = nil # immediate value
      native_to_arg_value(data_type,value)
    else
      klass = value
      allocation_id = self.allocation_ids[data_type] += 1
      [allocation_id].pack("l<").bytes.to_a
    end

    self.allocations[address] = [data_type,allocation_id,klass]
    # puts "  #{address} - #{self.allocations[address].inspect}"
    # puts "  #{[address,size,to_write].inspect}"

    write!(address,size,to_write)
  end

  def write!(address,bytes,byte_array)
    memory_range = (address)...(address+bytes)
    self.memory[memory_range] = byte_array[0...bytes]
    self.dirty_memory_addresses += memory_range.to_a
  end

  def read(address,bytes = 1)
    self.memory[(address)...(address+bytes)]
  end

  def write_branch_condition!(bool)
    raise InvalidBranchConditionState, "called conditional opcode outside of if structure" if self.branch_conditions.nil?
    next_insert = self.branch_conditions.index(nil)
    raise InvalidBranchConditionState, "too many conditional opcodes (allocated: #{self.branch_conditions.size}" if next_insert >= self.branch_conditions.size
    bool = !bool if self.negated_opcode
    self.branch_conditions[next_insert] = bool
  end


  FLOAT_PRECISION = 3
  # p much everything is little-endian
  def arg_to_native(arg_type,arg_value = nil)
    return nil if arg_type == 0x00

    arg_type = TYPE_SHORTHANDS[arg_type] if arg_type.is_a?(Symbol)

    value = if pack_char = PACK_CHARS_FOR_DATA_TYPE[arg_type]
      value = arg_value.to_byte_string.unpack( PACK_CHARS_FOR_DATA_TYPE[arg_type] )[0]
      value
    else

      case arg_type
      when  0x09 # immediate 8-byte string
        arg_value.to_byte_string.strip_to_null
      when  0x0e # variable-length string
        arg_value.to_byte_string[1..-1]
      else
        if arg_type > DATA_TYPE_MAX # immediate type-less 8-byte string
          [arg_type,arg_value].flatten.to_byte_string.strip_to_null #FIXME: can have random crap after first null byte, cleanup
        else
          raise InvalidDataType, "unknown data type #{arg_type} (#{hex(arg_type)})"
        end
      end

    end

    value = value.round(FLOAT_PRECISION) if value.is_a?(Float)

    value

  end


  def native_to_arg_value(arg_type,native)
    native = [native]
    arg_type = TYPE_SHORTHANDS[arg_type] if arg_type.is_a?(Symbol)
    pack_char = PACK_CHARS_FOR_DATA_TYPE[arg_type]
    if !pack_char
      raise InvalidDataType, "native_to_arg_value: unknown data type #{arg_type} (#{hex(arg_type)})"
    end
    native.pack(pack_char).bytes.to_a
  end

  PACK_CHARS_FOR_DATA_TYPE = {
   -0x01 => "S<",
    0x01 => "l<",
    0x02 => "S<",
    0x03 => "S<",
    0x04 => "c",
    0x05 => "s<",
    0x06 => "e"
  }

  def validate_arg(expected_arg_type,arg_type)
    return true if expected_arg_type == -1 # don't care what the arg type is
    return true if expected_arg_type == true && arg_type == 0x00 # end of variable-length arg list
    return true if expected_arg_type == :string && arg_type > DATA_TYPE_MAX # immediate type-less 8-byte string
    allowable_arg_types = GENERIC_TYPE_SHORTHANDS[expected_arg_type] || [expected_arg_type]
    allowable_arg_types.map { |type| TYPE_SHORTHANDS[type] }.include?(arg_type)
  end

  def validate_arg!(expected_arg_type,arg_type,opcode,arg_index)
    if !validate_arg(expected_arg_type,arg_type)
      raise InvalidOpcodeArgumentType, "expected #{arg_type.inspect} = #{expected_arg_type.inspect} (#{opcode} @ #{arg_index})"
    end
  end

  def self.scm_markers(data_dir)
    case data_dir
    when "vc"
      [ [0x6d,:memory], [0x00,:models], [0x00,:missions] ]
    when "sa"
      [ [115,:memory], [0x00,:models], [0x01,:missions] ]
    end
  end

  def detect_scm_structures!
    #markers = [ [0x6d,:memory], [0x00,:models], [0x00,:missions] ] # vc
    # markers = [ [115,:memory], [0x00,:models], [0x01,:missions] ] # sa
    markers = self.class.scm_markers(data_dir)

    self.struct_positions = Hash.new { |h,k| h[k] = [] }
    offset = 0

    markers.each_with_index do |(marker,struct_name),index|

      jump_opcode = disassemble_opcode_at(offset)
      marker_at = offset + jump_opcode.flatten.size
      if read(marker_at,1) != [marker]
        raise InvalidScmStructure, "Didn't find '#{struct_name}' structure marker '#{marker}' at #{marker_at} (got #{read(marker_at,1)})"
      end
      self.struct_positions[struct_name][0] = marker_at + 1

      struct_end = arg_to_native(*jump_opcode[1][0])
      jump_opcode = disassemble_opcode_at(struct_end)
      if jump_opcode[0] != [0x02,0x00] && index != markers.length-1
        raise InvalidScmStructure, "Didn't find jump after '#{struct_name}' structure at #{struct_end}"
      end
      self.struct_positions[struct_name][1] = struct_end

      case struct_name
      when :models
        offset = marker_at + 1
        models_count = arg_to_native(:int32, read(offset,4) )
        offset += 4
        self.models = {}
        models_count.times do |id|
          self.models[id * -1] = read(offset,24).to_byte_string.strip_to_null
          offset += 24
        end
      when :missions
        offset = marker_at + 1

        missions_start_at = arg_to_native(:int32,read(offset,4))
        offset += 4

        # maybe? it's somewhat close to the size of the memory space
        memory_allocated = arg_to_native(:int32,read(offset,4))
        offset += 4

        missions_count = arg_to_native(:int32, read(offset,4) )
        offset += 4
        self.missions = {}
        missions_count.times do |id|
          self.missions[id * -1] = arg_to_native(:int32,read(offset,4))
          offset += 4
        end
        self.missions_ranges = []
        self.missions.each_pair do |mission_id,mission_offset|
          end_mission_offset = self.missions[mission_id - 1] ? self.missions[mission_id - 1] - 1 : self.memory.size
          self.missions_ranges << [ (mission_offset..end_mission_offset), mission_id ]
        end

        self.struct_positions[:main][0] = offset
        self.struct_positions[:main][1] = self.missions[0] - 1
        self.struct_positions[:mission_code][0] = self.missions[0]
        self.struct_positions[:mission_code][1] = self.memory.size
      end

      offset = struct_end
    end

    puts "struct_positions:"
    pp self.struct_positions
    
    true
  end

  def get_mission_from_offset(offset)
    self.missions_ranges.detect { |(range,id)| range.include?(offset) }
  end

  def build_opcode_map!
    # TODO: need to implement all datatypes and shit to get a reliable disassembly
    # return

    # For disassembly purposes, we need to know where an opcode begins
    # ignoring the special structures at the start of the SCM (memory, object table, mission table, etc.)
    # starting from the first opcode, record it's start address, fast-forward through the size of it's args to find the next opcode, repeat
    # will need to know arg counts for all opcodes, and size of all datatypes, with special handling for var_args
    puts "building disassembly map"
    self.opcode_map = []
    self.opcode_addresses_to_jump_sources = Hash.new {|h,k| h[k] = []} # key is destination address, values are array of source addresses that jump to destination
    address = self.struct_positions[:main][0]
    #address = 55976 # hack, main detection is broken for SA
    #puts "#{address} - #{hex(read(address-4,8))}"
    require 'benchmark'
    t = Benchmark.measure do
      while address < self.memory.size
        opcode_address = address
        opcode = disassemble_opcode_at(address)
        next_opcode_address = address + opcode.flatten.size
        address = next_opcode_address
        #puts "#{address.to_s.rjust(8,"0")} - #{ch(OPCODE,opcode[0].reverse)}: #{opcode[1].map{|arg| "#{ch(TYPE,arg[0])} #{arg[1] ? ch(VALUE,arg[1]) : ""}" }.join(', ')}"
        #puts dump_memory_at(address+opcode.flatten.size)
        self.opcode_map << opcode_address

        if is_unconditional_jump?(opcode)
          jump_address = self.arg_to_native(*opcode[1][0])
          self.opcode_addresses_to_jump_sources[jump_address] << opcode_address # unconditional jump goes straight to target
        elsif is_conditional_jump?(opcode)
          jump_address = self.arg_to_native(*opcode[1][0])
          # puts "conditional: #{address}, #{opcode.inspect} => #{jump_address}"
          # self.opcode_addresses_to_jump_sources[next_opcode_address] << opcode_address # previous address CAN jump to next address...
          self.opcode_addresses_to_jump_sources[jump_address] << opcode_address # ...but can also jump to provided address
        elsif is_terminator?(opcode)
          # jumps nowhere, execution ends
          # self.opcode_addresses_to_jump_sources[next_opcode_address] << nil # ack
        else
          # don't want, fucks up with labels after a terminator (OR put a nil value in to specify it comes after a terminator?)
          # self.opcode_addresses_to_jump_sources[next_opcode_address] << opcode_address # previous address jumps to next address
        end
      end
    end
    #puts self.opcode_map.inspect
    puts "Disassembled #{self.opcode_map.size} opcodes (#{self.memory.size} bytes) in #{"%.4f"%t.real} secs"
    require 'pp'
    # pp opcode_addresses_to_jump_sources
  end

  def is_unconditional_jump?(opcode)
    opcode_def = self.opcodes_module.definitions[opcode[0]]
    ["0002"].include?(opcode_def[:nice])
  end

  def is_conditional_jump?(opcode)
    opcode_def = self.opcodes_module.definitions[opcode[0]]
    ["004D","004F","00D7"].include?(opcode_def[:nice])
  end

  def is_terminator?(opcode)
    opcode_def = self.opcodes_module.definitions[opcode[0]]
    ["004E"].include?(opcode_def[:nice])
  end

  def start_of_opcode_at(address)
    return nil if address < self.struct_positions[:main][0]
    return nil if address > self.struct_positions[:main][1] # FIXME: should be last mission/end of script
    map_index = self.opcode_map.size - 1
    until address >= self.opcode_map[map_index]
      map_index -= 1
    end
    self.opcode_map[map_index]
  end


  def reset_dirty_state
    DIRTY_STATES.each { |state| self.dirty[state] = false }
    self.dirty_memory_addresses = []
  end

  def decompile!
    Decompiler.new(self).decompile!
  end

  def dump_memory_at(address,size = 16,previous_context = 0,shim_range = nil,shim = nil) #yield(buffer)
    dump = ""
    offset = address-previous_context
    same_colour_left = -1
    while offset < address+size-previous_context

      if shim_range && offset == (address+shim_range.begin)
        dump << shim
        dump << " " unless [2].include?(shim_range.end) #why? no idea
        offset = (address+shim_range.end)
        next
      end

      if self.allocations[offset]
        alloc_colour = COLORS[ self.allocations[offset][0] ] || DEFAULT_COLOR
        same_colour_left = TYPE_SIZES[ self.allocations[offset][0] ]
        dump << "\e[#{alloc_colour}m"
      end

      dump << hex(self.memory[offset])
      same_colour_left -= 1

      if same_colour_left == 0
        dump << "\e[0m"
      end

      dump << " "
      offset += 1
    end

    yield(dump) if block_given?

    "#{address.to_s.rjust(8,"o")} - #{dump}"
  end

  def hex(array_of_bytes)
    array_of_bytes = [array_of_bytes] unless array_of_bytes.is_a?(Array)
    array_of_bytes = array_of_bytes.map { |b| b.ord } if array_of_bytes.first.is_a?(String)
    array_of_bytes.map{|m| m.to_s(16).rjust(2,"0") }.join(" ")
  end

  def c(type,val)
    "\e[#{COLORS[type] || DEFAULT_COLOR}m#{val}\e[0m"
  end

  def ch(type,val)
    c(type,hex(val))
  end

  class InvalidScmStructure < StandardError; end
  class InvalidOpcode < StandardError; end
  class InvalidOpcodeArgumentType < StandardError; end
  class InvalidDataType < StandardError; end

  class InvalidBranchConditionState < StandardError; end
end

class Memory < String
  def initialize(*args)
    super(*args)
    self.force_encoding("ASCII-8BIT")
  end

  alias_method :"old_read", :"[]"
  def [](args = nil)
    super.bytes.to_a
  end

  def raw_read(*args)
    old_read(*args)
  end

  def []=(pos,args)
    args = args.to_byte_string if args.is_a?(Array) && args[0].is_a?(Numeric)
    super(pos,args)
  end
end

class OpcodeArgs < OpenStruct
  def initialize(*args)
    super
    self.arg_names = []
  end
  def add_arg(arg_name,data_type,value)
    self.arg_names << arg_name
    send("#{arg_name}=",value)
    send("#{arg_name}_type=",data_type)
  end
end

class String
  def strip_to_null
    temp = self.bytes.to_a
    null_index = temp.index(0)
    temp[0...null_index].to_byte_string
    #gsub(/#{0x00}.+$/,"")
  end
end

class Array
  def to_byte_string
    self.map { |byte| byte.chr }.join
  end
end
