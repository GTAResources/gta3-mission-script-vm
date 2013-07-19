
class Gta3Vm::Execution

  include Gta3Vm::Logger

  attr_accessor :vm

  attr_accessor :allocations

  attr_accessor :threads

  attr_accessor :tick_count
  attr_accessor :thread_id
  attr_accessor :pc
  attr_accessor :realtime

  attr_accessor :switch_on_new_thread

  attr_accessor :current_instruction
  attr_accessor :dispatched_method
  attr_accessor :dispatched_args

  def initialize(vm)
    self.vm = vm
    reset
    extend vm.opcodes.opcode_module
  end

  def reset
    log "reset"
    self.allocations = {}
    self.tick_count = 0

    self.threads = []
    thread_create(0)
    self.thread_id = 0

    self.realtime = 0

    self.switch_on_new_thread = true
  end

  def irb
    
  end

  def tick
    instruction_pos = self.pc
    instruction_thread = self.thread_id
    self.current_instruction = vm.instruction_at(instruction_pos)
    result = dispatch_instruction(current_instruction)

    # advance past instruction if we haven't manually jumped
    if self.threads[instruction_thread].pc == instruction_pos
      self.threads[instruction_thread].pc = instruction_pos + current_instruction.size
    end

    self.realtime += 1
    self.tick_count += 1
    result
  end

  def current_thread
    self.threads[self.thread_id]
  end

  def thread_create(pc,is_mission = false)
    self.threads << VmThread.new(vm,self,pc,is_mission)
    # self.thread_id = self.threads.size - 1 if self.switch_on_new_thread
    self.thread_pass if self.switch_on_new_thread
  end

  def thread_pass
    # sort threads by realtime past desired wakeup time
    e_threads = self.threads.each_with_index.
      map{|thread,id| [id, thread.idle_until ? self.realtime - thread.idle_until : -999_999_999] }.
      sort_by(&:last).
      reverse

    log("e_threads: #{e_threads.inspect}")
    raise "No valid threads to pass to" if e_threads.empty?

    # if passed thread didn't say how long, leave it at current priority
    self.current_thread.idle_until ||= self.realtime if self.current_thread

    self.thread_id = e_threads[0][0] # most overdue thread

    self.current_thread.idle_until = nil
  end

  def thread_idle(until_realtime = nil)
    self.current_thread.idle_until = until_realtime
    self.thread_pass
  end

  def pc
    self.current_thread.pc
  end

  def pc=(value)
    self.current_thread.pc = value
  end

  def jump(pc)
    self.pc = pc
  end

  def load_state_from_save(save)
    # buffer = save.read
    scr_marker_at = 236
    # scm_block_size, memory_size = buffer[scr_marker_at+4...scr_marker_at+4+8].unpack("ll")
    save.seek(scr_marker_at)
    scr_marker = save.read(4)
    scm_block_size, memory_size = save.read(8).unpack("L<*")
    puts "scr_marker_at: #{scr_marker.inspect}"
    puts "scm_block_size: #{scm_block_size}, memory_size: #{memory_size}"
    memory = save.read(memory_size)

    # errything_else = save.read(scm_block_size - memory_size)
    # puts "errything_else:"
    # puts errything_else.bytes.to_a.inspect
    # puts errything_else.unpack("L*").inspect

    # return


    vm_block_size = save.read(4).unpack("L<")[0]
    puts "vm_block_size: #{vm_block_size}"
    vm_block = save.read(vm_block_size)
    puts "vm_block:"
    puts vm_block.unpack("L<*").inspect
    # puts vm_block.unpack("SL<*").inspect
    puts vm_block.bytes.to_a.inspect

    block_c_size = save.read(4).unpack("L<")[0]
    puts "block_c_size: #{block_c_size}"
    block_c = save.read(block_c_size)
    puts "block_c:"
    puts block_c.unpack("L<*").inspect
    # puts block_c.unpack("SL<*").inspect
    puts block_c.bytes.to_a.inspect

    block_d_size = save.read(4).unpack("L<")[0]
    puts "block_d_size: #{block_d_size}"
    block_d = save.read(block_d_size)
    puts "block_d:"
    puts block_d.unpack("L<*").inspect

    maybe_thread_pcs = []

    post_block = save.read(1024)
    puts "postblock: #{post_block.inspect}"

    self.reset
    self.threads = []
    maybe_thread_pcs.each do |thread_pc|
      thread_create(thread_pc)
    end
  end

  def dispatch_instruction(instruction)
    definition = vm.opcodes.definition_for(instruction.opcode)
    method_name = definition.nice
    log "dispatch_instruction - thread #{self.thread_id} @ #{pc} - #{definition.nice} - #{instruction.to_ruby(self.vm).inspect}"
    send("opcode_#{method_name}",ArgWrapper.new(self.vm,definition,instruction.args))
  end

  def set_pg(address,data_type,value = nil)
    allocate(address,data_type)
  end

  def allocate(address,data_type,value = nil)
    log "allocate(address: #{address.inspect}, data_type: #{data_type.inspect}, value: #{value.inspect})"
    raise ArgumentError, "address is nil" unless address
    raise ArgumentError, "data_type is nil" unless data_type
    size = 4

    store_as = { 0x01=>0x01, 0x04=>0x01, 0x05=>0x01,  0x06=>0x06 }[data_type]
    raise ArgumentError, "no store_as entry for data_type #{data_type.inspect}" unless store_as

    to_write = vm.native_to_arg_value(store_as,value)
    raise ArgumentError, "incorrect size #{to_write.inspect}" unless to_write.size == size

    self.allocations[address] = data_type
    write(address,size,to_write)
  end

  def assert(check,message,klass = ExecutionAssertionError)
    raise klass, message unless check
  end

  def read_as_arg(*args)
    vm.read_as_arg(*args)
  end

  def write(address,size,to_write)
    vm.memory.write(address,size,to_write)
  end

  def variables
    @variables ||= VariablesProxy.new(self)
  end

  def locals
    current_thread.locals
  end

  def read_variable(pg_id)
    vm.memory.read( vm.memory.structure[:memory].begin + pg_id, 4 )
  end

  # def write_variable(pg_id,bytes)
  #   write( vm.memory.structure[:memory].begin + pg_id, 4, bytes )
  # end


  # #####################

  class VariablesProxy
    attr_accessor :exe

    def initialize(exe)
      self.exe = exe
    end

    def [](pg_id,type)
      exe.arg_to_native(type,exe.read_variable(pg_id))
    end

    def []=(pg_id,(type,value))
      exe.allocate( exe.vm.memory.structure[:memory].begin + pg_id, type, value)
    end
  end

  class ArgWrapper
    attr_accessor :vm
    attr_accessor :definition
    attr_accessor :args

    def initialize(vm,definition,args)
      self.vm = vm
      self.definition = definition
      self.args = args
    end

    def method_missing(symbol,*arguments)
      type = nil
      if symbol.to_s.match(/(.+?)(_(type))?$/)
        type = $3
        symbol = $1.to_sym
      end
      puts "ArgWrapper: #{args.inspect}"
      if symbol == :var_args
        # exclude last arg, it's just the end-of-list marker
        self.args[0...-1].map{|arg|
          arg = Gta3Vm::Instruction::Arg.new(arg)
          vm.arg_to_native(arg)
        }
      elsif index = definition.args_names.index(symbol)
        if type == "type"
          args[index].type
        else
          vm.arg_to_native(args[index])
        end
      end
    end
  end

  # #####################

  class VmThread
    attr_accessor :vm
    attr_accessor :execution

    attr_accessor :pc
    attr_accessor :name

    # used for relative jumps
    attr_accessor :base_offset

    attr_accessor :idle_until

    attr_accessor :is_mission

    def initialize(vm,execution,pc = 0,is_mission = false)
      self.vm = vm
      self.execution = execution
      self.pc = pc
      self.is_mission = is_mission
      if is_mission
        self.base_offset = pc
      end
      self.idle_until = 0
    end
  end

  # Extra features #######

  require "gta3vm/execution/dirty.rb"
  include Gta3Vm::Execution::Dirty

  class ExecutionAssertionError < ::StandardError; end
  
end
