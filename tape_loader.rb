require 'wavefile'
require 'optparse'

# class Bitstream
class Bitstream
  SYNC_BYTE = 0xe6

  def initialize
    clear
  end

  def add_bit(bit)
    @raw_data += bit ? '1' : '0'
  end

  def trim
    @raw_data = @raw_data[@offset..-1]
    @raw_data ||= []
    reset
  end

  def empty?
    length.zero?
  end

  def reset
    @offset = -1
    @inv = false
  end

  def clear
    @raw_data = ''
    @inv = false
    reset
  end

  def next_bit
    @offset += 1
    @offset <= @raw_data.length
  end

  def offset(ofs)
    @offset += ofs
    @offset <= @raw_data.length
  end

  def next_byte
    offset 8
  end

  def next_word
    offset 16
  end

  def hex(len)
    data = @raw_data[@offset, len]
    data += '0' * (len - data.length) if data.length < len
    mask = (@inv ? ((1 << len) - 1) : 0)
    result = data.to_i(2) ^ mask
    result
  end

  def bit
    hex 1
  end

  def byte
    hex 8
  end

  def word
    hex 16
  end

  def find(syn, msk, len)
    while next_bit
      @inv = false
      # puts "+ #{format('%02x', byte)} #{format('%04x', @offset>>3)}+#{@offset&7}"
      return true if hex(len) & msk == syn

      @inv = true
      # puts "- #{format('%02x', byte)} #{format('%04x', @offset>>3)}+#{@offset&7}"
      return true if hex(len) & msk == syn

    end
    false
  end

  def find_sync
    len = 8
    return false unless find(SYNC_BYTE, 0xff, len)

    offset len
  end

  def find_sync_bit
    len = 16
    find(0x0080, 0xff80, len)
  end

  def length
    @raw_data.length
  end

  def position
    @offset
  end

  def ary
    reset
    data = []
    return data unless find_sync_bit

    data += [byte]
    while next_byte
      data += [byte]
    end
    data
  end

  def inspect
    "length: #{length}, position: #{position}\n#{@raw_data}"
  end

end

# class DataFile
class DataFile
  def initialize
    @base = 0
    @end = 0
    @length = 0
    @data = []
    @crc_rd = 0
    @crc_ld = 0
    @state = :unknown
  end

  def print_line(addr, data, length)
    hex_line = data.collect { |b| format('%<byte>02x', byte: b) }.join(' ')
    ascii_line = data.collect { |b| b >= 32 && b < 128 ? format('%<byte>c', byte: b) : '.' }.join
    format("%<addr>04x: %<hex>-#{3 * length}s %<ascii>-#{length}s", addr: addr, hex: hex_line, ascii: ascii_line)
  end

  def print_raw(data)
    line_length = 16
    length = data.length
    n = ((length + line_length - 1) / line_length).to_i
    n.times do |i|
      ofs = line_length * i
      puts print_line(ofs, data[ofs, line_length], line_length)
    end
  end

  def print_data
    print_raw @data
  end

  def crc(data)
    suml = 0
    sumh = 0
    data.each_index do |i|
      suml += data[i]
      c = suml >> 8
      suml &= 0xff
      break if i == data.length-1
      sumh += data[i] + c
      sumh &= 0xff
    end
    (sumh << 8) | suml
  end

  def analyze_raw(stream)
    stream.reset
    @data = stream.ary
    @length = @data.length
    @base = 0
    @end = @length - 1
    @file_name = 'raw data'
    :raw
  end

  def analyze_type(stream)
    stream.reset
    return :no_sync unless stream.find_sync

    8.times do
      c = stream.byte
      return :no_header unless stream.next_byte

      return :radio if c < 0x20 || c > 0x7f

    end
    8.times do
      return :radio unless stream.byte.zero?

      return :no_header unless stream.next_byte

    end
    :orion
  end

  def analyze_rk86(stream)
    stream.reset
    @data = []
    return :no_sync unless stream.find_sync

    # return :no_sync unless stream.next_byte
    @base = stream.word
    return :no_base unless stream.next_word

    @end = stream.word
    @length = @end - @base + 1
    return :negative_length if @length.negative?

    return :no_length unless stream.next_word

    @length.times do
      @data += [stream.byte]
      return :wrong_length unless stream.next_byte
    end
    return :no_sync_crc unless stream.find_sync

    # return :no_sync_crc unless stream.next_byte

    @crc_rd = stream.word
    return :no_crc unless stream.next_word

    @file_name = "#{format('%<hex>04x', hex: @crc_rd)}.rk"
    @crc_ld = crc(@data)
    return :bad_crc unless @crc_ld == @crc_rd

    :ok
  end

  def analyze_orion(stream)
    stream.reset
    @data = []
    return :no_sync unless stream.find_sync

    @file_name ||= ''
    8.times do
      c = stream.byte
      return :no_header unless stream.next_byte

      c = 0x3f if c < 0x20 || c > 0x7f || c == 0x2f || c == 0x5c
      @file_name += format('%<char>c', char: c)
    end
    8.times do
      return :no_header unless stream.next_byte

      return :not_orion unless stream.byte.zero?
    end

    return :no_header unless stream.next_byte

    return :no_sync unless stream.find_sync

    #return :no_sync unless stream.next_byte

    @base = stream.word
    return :no_base unless stream.next_word

    @end = stream.word
    @length = @end - @base + 1
    return :negative_length if @length.negative?

    return :no_length unless stream.next_word

    @length.times do
      @data += [stream.byte]
      return :wrong_length unless stream.next_byte
    end
    return :no_sync_crc unless stream.find_sync

    #return :no_sync_crc unless stream.next_byte

    @crc_rd = stream.word
    return :no_crc unless stream.next_word

    @crc_ld = crc(@data)
    return :bad_crc unless @crc_ld == @crc_rd
    :ok
  end

  def analyze(stream)
    @state = analyze_type(stream)
    case @state
    when :orion
      @state = analyze_orion(stream)
    when :radio
      @state = analyze_rk86(stream)
    end
    print_info
    @state = analyze_raw(stream) unless @state == :ok
    print_info if @state == :raw
    @state
  end

  def print_info
    puts 'File info:'
    puts "\tresult: #{@state}"
    return unless @state == :ok || @state == :bad_crc || @state == :wrong_length || @state == :raw

    puts "\tname:   #{@file_name}" unless @file_name.nil?
    puts "\tbase:   #{format('%<hex>04x', hex: @base)}-#{format('%<hex>04x', hex: @end)}"
    puts "\tlength: #{format('%<hex>04x', hex: @length)}"
    puts "\tCRC   : #{format('%<hex>04x', hex: @crc_rd)} -> #{format('%<hex>04x', hex: @crc_ld)}" unless @state == :raw
    print_data
  end

  def save
    return unless @file_name

    return unless @state == :ok

    File.open(@file_name, 'w') do |r|
      r.write @data.pack('C*')
    end
  end
end

# calss Demodulator
class Demodulator
  attr_reader :bitstream

  def initialize(delta, length)
    @bitstream = Bitstream.new
    @delta = delta
    @length = length
    @bit = false
    @suml2 = 0
    @sums2 = 0
    @suml = 0
    @sums = 0
    @numl = 0
    @nums = 0
    @minl = 0
    @maxl = 0
    @mins = 0
    @maxs = 0
    @freqs = {}
    @freql = {}
    @sum = 0
    @num = 0
    @state = :unknown
  end

  def avg
    return 0 if @num.zero?

    @sum.to_f / @num
  end

  def avgs
    return 0 if @nums.zero?

    @sums.to_f / @nums
  end

  def avgl
    return 0 if @numl.zero?

    @suml.to_f / @numl
  end

  def disps
    return 0 if @nums.zero?

    (@sums2.to_f / @nums) - (avgs**2)
  end

  def displ
    return 0 if @numl.zero?

    (@suml2.to_f / @numl) - (avgl**2)
  end

  def set(cur)
    @bitstream.clear
    @suml2 = 0
    @sums2 = cur * cur
    @suml = 0
    @sums = cur
    @numl = 0
    @nums = 1

    @minl = -1
    @maxl = -1
    @mins = -1
    @maxs = -1

    @freqs = {}
    @freql = {}

    @state = :unknown

    @sum = cur
    @num = 1
    @num
  end

  def add(cur, num = 1)
    if num == 1
      @sums2 += cur * cur
      @sums += cur
      @mins = cur if @mins == -1
      @maxs = cur if @maxs == -1
      @mins = cur if cur < @mins
      @maxs = cur if cur > @maxs
      @freqs[cur] = 0 if @freqs[cur].nil?
      @freqs[cur] += 1
      @nums += 1
    else
      @suml2 += cur * cur
      @suml += cur
      @minl = cur if @minl == -1
      @maxl = cur if @maxl == -1
      @minl = cur if cur < @minl
      @maxl = cur if cur > @maxl
      @freql[cur] = 0 if @freql[cur].nil?
      @freql[cur] += 1
      @numl += 1
    end
    @sum += cur
    @num += num
    @num
  end

  def check(cur, width = 1)
    width * (1 - @delta / width) * avg < cur && cur < width * (1 + @delta / width) * avg
  end

  def add_tone(cur)
    if check(cur)
      add(cur) > @length
    else
      set(cur) > @length
    end
  end

  def half_bit
    case @state
    when :half
      @bitstream.add_bit @bit
      @state = :full
    when :full
      @state = :half
    end
  end

  def full_bit
    case @state
    when :half
      @bitstream.add_bit @bit
      @state = :modul_error
    when :full
      @bit = !@bit
      @bitstream.add_bit @bit
    when :unknown
      @bit = false
      32.times { @bitstream.add_bit @bit }
      @bit = !@bit
      @bitstream.add_bit @bit
      @state = :full
    end
  end

  def add_duration(cur)
    @state = :full if @state == :modul_error
    if check(cur)
      half_bit
      add(cur)
    elsif check(cur, 2)
      full_bit
      add(cur, 2)
    else
      @state = :lost_tone
    end
    @state
  end

  def empty?
    @bitstream.length.zero?
  end

  def print_distrib(hash)
    keys = hash.keys.sort
    keys.collect { |key| "#{key}:#{hash[key]}" }.join(' ')
  end

  def print_info
    puts 'Statistics:'
    puts "\tstream length:        #{@bitstream.length} (#{format('%<val>04x', val: (@bitstream.length >> 3))}+#{@bitstream.length & 7})"
    puts "\taverage period:       #{format('%<val>3.1f', val: avg)} (#{@num})"
    puts "\tshort average period: [#{format('%<val>3.1f', val: (avg * (1 - @delta)))}] #{@mins} < #{format('%<val>3.1f', val: avgs)} < #{@maxs} [#{format('%<val>3.1f', val: (avg * (1 + @delta)))}] (#{@nums})"
    puts "\tshort distributions:  #{print_distrib(@freqs)}"
    puts "\tshort dispersion:     #{format('%<val>3.1f', val: disps)}"
    puts "\tlong average period:  [#{format('%<val>3.1f', val: (2 * avg * (1 - @delta / 2)))}] #{@minl} < #{format('%<val>3.1f', val: avgl)} < #{@maxl} [#{format('%<val>3.1f', val: (2 * avg * (1 + @delta / 2)))}] (#{@numl})"
    puts "\tlong distributions:   #{print_distrib(@freql)}"
    puts "\tlong dispersion:      #{format('%<val>3.1f', val: displ)}"
  end
end

# class Buffer
class Buffer
  BLOCK_SIZE = 4096

  def initialize
    @buffer = []
    @block = []
  end

  def add(val)
    @block += [val]
    if @block.length >= BLOCK_SIZE
      @buffer += [@block]
      @block = []
    end
  end

  def length
    @buffer.collect { |b| b.length }.sum
  end

  def sum
    @buffer.collect { |b| b.sum }.sum
  end

  def last
    unless @block.empty?
      @buffer += [@block]
      @block = []
    end
  end

  def subary(ofs, len)
    buf_idx = ofs / BLOCK_SIZE
    buf_ofs = ofs % BLOCK_SIZE

    tmp = @buffer[buf_idx] # TODO Check buffer reference
    tmp ||= []
    tmp += @buffer[buf_idx+1] if buf_ofs+len > tmp.length and buf_idx+1 < @buffer.length  # TODO Check buffer end
    tmp[buf_ofs, len]
  end

  def step
    @buffer.each do |buf|
      buf.each { |d| yield d }
    end
  end
end


# class Loader
class Loader
  DELTA = 0.4
  MIN_TONE_LENGTH = 32

  def initialize(options)
    @options = options
    @options ||= {}

    @delta = @options[:delta]
    @delta ||= DELTA

    @tone_length = @options[:tone_length]
    @tone_length ||= MIN_TONE_LENGTH

    @channel = @options[:channel]
    @channel ||= :left
  end

  def inspect
    reader = WaveFile::Reader.new(@options[:file_name])
    result = reader.format.inspect
    reader.close
    result
  end

  def sample(ary)
    case @channel
    when :left
      ary[0]
    when :right
      ary[1]
    else
      (ary[0] + ary[1]) / 2
    end
  end

  def average
    avg = 0
    num = 0
    reader = WaveFile::Reader.new(@options[:file_name])
    if reader.format.mono?
      reader.each_buffer do |buffer|
        avg += buffer.samples.sum
        num += buffer.samples.count
      end
    else
      reader.each_buffer do |buffer|
        avg += buffer.samples.collect { |s| sample(s) }.sum
        num += buffer.samples.count
      end
    end
    reader.close
    num.positive? ? avg / num : 0
  end


  def parse
    prv = nil
    dur = 0
    cur = 0
    @durations = Buffer.new
    avg = average
    reader = WaveFile::Reader.new(@options[:file_name])
    if reader.format.mono?
      reader.each_buffer do |buffer|
        buffer.samples.each do |c|
          cur = (0.4 * cur + 0.6 * c).to_i
          if prv
            if (cur >= avg && prv < avg) || (cur < avg && prv >= avg)
              @durations.add(dur)
              dur = 0
            end
          end
          dur += 1
          prv = cur
        end
      end
    else
      reader.each_buffer do |buffer|
        # puts @durations.length
        buffer.samples.each do |ary|
          cur = (0.4 * cur + 0.6 * sample(ary)).to_i
          if prv
            if (cur >= avg && prv < avg) || (cur < avg && prv >= avg)
              @durations.add(dur)
              dur = 0
            end
          end
          dur += 1
          prv = cur
        end
      end
    end
    reader.close
    @durations.last
    @durations
  end

  def as_hex(val)
    "#{format('%<hex>04x', hex: (val >> 3))}+#{val & 7}"
  end

  def as_line(ofs, len)
    base = ofs - len / 2
    base = 0 if base.negative?
    "#{base}: #{@durations.subary(base, len).collect { |b| format('%<byte>2d', byte: b) }.join(' ')}"
  end

  def print_dur
    puts "durations length: #{@durations.length}"
    puts "durations samples: #{@durations.sum}"
  end

  def print_lost_tone
    puts "Lost tone at sample: #{@sample}, duration index: #{@index} (#{as_hex(@index)})"
    puts "durations: #{as_line(@index, 16)}"
  end

  def print_modul_error
    puts "Modulation error at sample: #{@sample}, duration index: #{@index} (#{as_hex(@index)})"
    puts "durations: #{as_line(@index, 16)}"
  end

  def print_found_tone
    puts '*' * 80
    puts "Found tone at sample: #{@sample}, duration index: #{@index} (#{as_hex(@index)})"
    puts "durations: #{as_line(@index, 16)}"
  end

  def step_init(cur)
    @demodulator.set cur
    :wait_tone
  end

  def step_tone(cur)
    if @demodulator.add_tone(cur)
      print_found_tone
      return :process
    end
    :wait_tone
  end

  def step_process(cur)
    case @demodulator.add_duration(cur)
    when :lost_tone
      print_lost_tone
      return :lost_tone
    when :modul_error
      print_modul_error
    end
    :process
  end

  def step_lost
    unless @demodulator.empty?
      @demodulator.print_info
      bitstream = @demodulator.bitstream
      until bitstream.empty?
        # puts "bitstream: #{bitstream.inspect}"
        file = DataFile.new
        file.analyze bitstream
        # puts "bitstream: #{bitstream.inspect}"
        # file.print_info
        file.save
        bitstream.trim
        # puts "bitstream: #{bitstream.inspect}"
      end
    end
    :init
  end

  def step(cur)
    case @state
    when :init
      @state = step_init(cur)
    when :wait_tone
      @state = step_tone(cur)
    when :process
      @state = step_process(cur)
    when :lost_tone
      @state = step_lost
    end
    @index += 1
    @sample += cur
  end

  def analyze
    @state = :init
    @demodulator = Demodulator.new(@delta, @tone_length)
    @sample = 0
    @index = 0
    @durations.step { |cur| step(cur) }
    if @state == :process
      step_process 0
      step_lost
    end
  end
end

# class Rogram
class Program
  def initialize
    options = {}
    OptionParser.new do |opts|
      opts.banner = 'Usage: tape_loader.rb [options]'

      opts.on('-c CHANNEL', '--channel=CHANNEL', %i[left right both], 'Type of used channel (left, right, both)') do |v|
        options[:channel] = v
      end

      opts.on('-dN', '--delta=N', Integer, 'Permissible deviation interval in percent (default 40%)') do |v|
        options[:delta] = v.to_f/100
      end

      opts.on('-tN', '--tone=N', Integer, 'Minimal initial tone length in periods (default 16, 1 byte)') do |v|
        options[:tone_length] = v
      end

      opts.on('-f FILE', '--file=FILE', 'Input WAV file') do |v|
        options[:file_name] = v
      end

      opts.on('-h', '--help', 'Print this help') do
        puts opts
        exit
      end

      opts.on_tail() do
        if options[:file_name].nil?
          puts opts
          exit
        end
      end
    end.parse!

    # puts options.inspect

    @loader = Loader.new(options)
  end

  def done
    puts 'End'
  end

  def run
    @loader.parse
    @loader.print_dur
    @loader.analyze
  end
end

program = Program.new
program.run
program.done
