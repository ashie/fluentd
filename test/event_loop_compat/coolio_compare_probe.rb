#
# Comparison probe for the Coolio namespace: the same checks are run
# against the real cool.io gem and against the EventLoopCompat Coolio
# compatibility namespace, each in its own process, and the transcripts
# are compared by test/event_loop_compat/test_coolio_compatibility.rb.
#
# Usage:
#   ruby coolio_compare_probe.rb real     # real cool.io (no -Ilib)
#   ruby -Ilib coolio_compare_probe.rb compat
#
# The probe prints one "KEY\tVALUE.inspect" line per observation, sorted,
# so the two transcripts can be diffed directly. Values that are not
# expected to match (event counts, timings) are reported as booleans.
#

backend = ARGV[0]

require 'fileutils'
require 'socket'
require 'tmpdir'

case backend
when 'real'
  require 'cool.io'
when 'compat'
  require 'event_loop_compat/coolio'
else
  abort "usage: #{$PROGRAM_NAME} real|compat"
end

$out = {}

def report(key, value)
  $out[key] = value
end

def normalize_class(klass)
  return "nil" if klass.nil?
  name = klass.name
  name.nil? || !name.start_with?("Coolio::") ? "Object" : name
end

def coolio_ancestors(klass)
  klass.ancestors.filter_map do |mod|
    name = mod.name
    name if name&.start_with?("Coolio::")
  end
end

def error_of
  yield
  "no error"
rescue Exception => e
  "#{e.class}: #{e.message}"
end

CLASSES = %w[
  Watcher IOWatcher TimerWatcher StatWatcher AsyncWatcher
  IO Socket TCPSocket UNIXSocket
  Listener TCPListener UNIXListener Server TCPServer UNIXServer
  Buffer Loop DNSResolver
].freeze

CLASSES.each do |name|
  key = "class #{name}"
  unless Coolio.const_defined?(name, false)
    report(key, "missing")
    next
  end
  klass = Coolio.const_get(name)
  report(key, "superclass=#{normalize_class(klass.superclass)} " \
              "ancestors=#{coolio_ancestors(klass).join(',')} " \
              "constants=#{klass.constants.sort.map(&:to_s).join(',')}")
end

CLASSES.each do |a|
  next unless Coolio.const_defined?(a, false)
  CLASSES.each do |b|
    next unless Coolio.const_defined?(b, false)
    next if a == b
    left = Coolio.const_get(a)
    right = Coolio.const_get(b)
    report("subclass #{a} < #{b}", left < right)
  end
end

#
# Instances: type predicates must agree with the real implementation.
#

def build_instances
  instances = {}

  dir = Dir.mktmpdir("coolio-compare")
  stat_path = File.join(dir, "stat.txt")
  File.write(stat_path, "x")

  listen = ::TCPServer.new('127.0.0.1', 0)
  port = listen.addr[1]
  unix_path = File.join(dir, "unix.sock")
  unix_listen = ::UNIXServer.new(unix_path)
  client = ::TCPSocket.new('127.0.0.1', port)
  peer = listen.accept
  reader, writer = ::IO.pipe

  instances['Watcher'] = -> { Coolio::Watcher.new }
  instances['IOWatcher'] = -> { Coolio::IOWatcher.new(reader, 'r') }
  instances['TimerWatcher'] = -> { Coolio::TimerWatcher.new(1, false) }
  instances['StatWatcher'] = -> { Coolio::StatWatcher.new(stat_path) }
  instances['AsyncWatcher'] = -> { Coolio::AsyncWatcher.new }
  instances['IO'] = -> { Coolio::IO.new(reader) }
  instances['Socket'] = -> { Coolio::Socket.new(client) }
  instances['TCPSocket'] = -> { Coolio::TCPSocket.new(client) }
  instances['UNIXSocket'] = -> { Coolio::UNIXSocket.new(::UNIXSocket.new(unix_path)) }
  instances['Listener'] = -> { Coolio::Listener.new(listen) }
  instances['TCPListener'] = -> { Coolio::TCPListener.new('127.0.0.1', 0) }
  instances['UNIXListener'] = -> { Coolio::UNIXListener.new("#{unix_path}.l") }
  instances['Server'] = -> { Coolio::Server.new(listen) }
  instances['TCPServer'] = -> { Coolio::TCPServer.new('127.0.0.1', 0) }
  instances['UNIXServer'] = -> { Coolio::UNIXServer.new("#{unix_path}.srv") }
  instances['Buffer'] = -> { Coolio::Buffer.new }
  instances['Loop'] = -> { Coolio::Loop.new }

  built = {}
  instances.each do |name, constructor|
    built[name] = begin
      [constructor.call, nil]
    rescue Exception => e
      [nil, "#{e.class}: #{e.message}"]
    end
  end

  cleanup = lambda do
    [client, peer, reader, writer, listen, unix_listen].each do |io|
      begin
        io.close unless io.closed?
      rescue StandardError
      end
    end
    FileUtils.remove_entry(dir) if dir
  end

  [built, cleanup]
end

instances, cleanup = build_instances

begin
  CLASSES.each do |name|
    instance, err = instances[name]
    if instance.nil?
      report("construct #{name}", err)
      next
    end
    report("construct #{name}", "ok")
    satisfied = []
    mismatched = []
    CLASSES.each do |other|
      next unless Coolio.const_defined?(other, false)
      klass = Coolio.const_get(other)
      is_a = instance.is_a?(klass)
      kind_of = instance.kind_of?(klass)
      triple_eq = klass === instance
      satisfied << other if is_a
      mismatched << other unless is_a == kind_of && is_a == triple_eq
    end
    report("is_a #{name}", satisfied.join(","))
    report("predicate-mismatch #{name}", mismatched.empty? ? "none" : mismatched.join(","))
  end
ensure
  cleanup.call
end

#
# Error semantics of the watcher and loop API.
#

report("Watcher.new", error_of { Coolio::Watcher.new })
report("TimerWatcher#attach String", error_of { Coolio::TimerWatcher.new(1).attach("x") })
report("TimerWatcher#detach unattached", error_of { Coolio::TimerWatcher.new(1).detach })
report("TimerWatcher#enable unattached", error_of { Coolio::TimerWatcher.new(1).enable })
report("TimerWatcher#disable unattached", error_of { Coolio::TimerWatcher.new(1).disable })
report("TimerWatcher#reset unattached", error_of { Coolio::TimerWatcher.new(1).reset })
report("IOWatcher invalid flag", error_of { Coolio::IOWatcher.new($stdin, 'x') })
report("IO#attach String", error_of { r, w = IO.pipe; begin; Coolio::IO.new(r).attach("x"); ensure; r.close; w.close; end })
report("Loop.new unknown option", error_of { Coolio::Loop.new(foo: 1) })
report("Loop.new unknown backend", error_of { Coolio::Loop.new(backend: :foo) })
report("Loop#stop not running", error_of { Coolio::Loop.new.stop })
report("Loop#run no watchers", error_of { Coolio::Loop.new.run })
report("Loop#run_once negative", error_of { Coolio::Loop.new.run_once(-1) })
report("Loop#run_nonblock no watchers", error_of { Coolio::Loop.new.run_nonblock })

# enable / disable twice, on an attached watcher
begin
  loop = Coolio::Loop.new
  timer = Coolio::TimerWatcher.new(1, false)
  timer.attach(loop)
  report("Watcher#enable twice", error_of { timer.enable; timer.enable })
  report("Watcher#disable twice", error_of { timer.disable; timer.disable })
  report("Watcher#attach running loop", error_of { timer.attach(loop) })
ensure
  timer.detach if timer.attached?
end

# Server connection class validation
begin
  listen = ::TCPServer.new('127.0.0.1', 0)
  report("Server invalid class", error_of { Coolio::Server.new(listen, String) })
  report("Server wrong arity", error_of { Coolio::Server.new(listen, Coolio::TCPSocket, :extra) })
  listen.close
rescue StandardError
end

#
# Behavior: callbacks, close, re-running the loop.
#

# one-shot timer
loop = Coolio::Loop.new
fires = 0
timer = Coolio::TimerWatcher.new(0, false)
timer.on_timer { fires += 1 }
timer.attach(loop)
loop.run_once(0.5)
loop.run_once(0.5)
report("timer one-shot fires", fires)
report("timer one-shot disabled after firing", !timer.enabled?)
report("timer one-shot still attached", timer.attached?)
# cool.io counts attached watchers in @active_watchers and never lowers
# that count for a one-shot timer, so its Loop#run keeps blocking after
# the timer has fired.
report("loop has active watchers after one-shot", loop.has_active_watchers?)

# repeating timer stopped from the callback
loop = Coolio::Loop.new
repeat_fires = 0
repeater = Coolio::TimerWatcher.new(0.01, true)
repeater.on_timer { repeat_fires += 1; loop.stop }
repeater.attach(loop)
run_result = loop.run(0.5)
report("timer repeating fires", repeat_fires >= 1)
report("loop#run returns false", run_result.equal?(false))

# TimerWatcher#reset re-arms a repeating timer
loop = Coolio::Loop.new
reset_fires = 0
repeater = Coolio::TimerWatcher.new(0.05, true)
repeater.on_timer { reset_fires += 1; repeater.reset; loop.stop }
repeater.attach(loop)
loop.run(0.5)
report("timer reset fires", reset_fires)

# IO watcher read callback
loop = Coolio::Loop.new
reader, writer = IO.pipe
received = nil
iow = Coolio::IOWatcher.new(reader, 'r')
iow.on_readable { received = reader.read_nonblock(16) }
iow.attach(loop)
writer.write "hello"
loop.run_once(1)
report("iowatcher on_readable", received)
iow.detach
reader.close
writer.close

# Coolio::IO read / write / close callbacks
loop = Coolio::Loop.new
client, server = Socket.pair(:UNIX, :STREAM)
read_data = nil
write_complete = false
closed = false
io = Coolio::IO.new(server)
io.on_read { |data| read_data = data }
io.on_write_complete { write_complete = true }
io.on_close { closed = true }
io.attach(loop)
client.write "ping"
loop.run_once(1)
io.write "pong"
2.times { loop.run_once(1) }
report("io on_read", read_data)
report("io on_write_complete", write_complete)
io.close
report("io on_close", closed)
client.close

# AsyncWatcher
loop = Coolio::Loop.new
signals = 0
async = Coolio::AsyncWatcher.new
async.on_signal { signals += 1 }
async.attach(loop)
async.signal
loop.run_once(1)
report("async on_signal", signals)

# StatWatcher: on_change through a subclass override (the only form
# cool.io supports) and the class of the structs passed to it.
class StatProbe < Coolio::StatWatcher
  attr_reader :changes

  def initialize(path)
    @changes = []
    super(path, 0.05)
  end

  def on_change(prev, cur)
    @changes << [prev.class.name, cur.class.name, prev.size, cur.size]
    evloop.stop
  end
end

class CountingStatProbe < StatProbe
  def on_change(prev, cur)
    @changes << [prev.class.name, cur.class.name, prev.size, cur.size]
  end
end

Dir.mktmpdir("coolio-stat") do |dir|
  path = File.join(dir, "f")
  File.write(path, "a")
  loop = Coolio::Loop.new
  stat = StatProbe.new(path)
  stat.attach(loop)
  # The modification has to happen while the loop is running: cool.io
  # seeds the baseline when the watcher is attached, EventLoopCompat when
  # the loop starts, and a change made before both is invisible to both.
  # The callback is registered with on_timer because cool.io ignores
  # blocks given to watcher constructors.
  writer = Coolio::TimerWatcher.new(0.2, false)
  writer.on_timer { File.write(path, "bb") }
  writer.attach(loop)
  loop.run(3)
  report("stat on_change", stat.changes.first.inspect)
end

# Baseline seeding: both implementations stat the path when the watcher
# is attached, so a change made before the loop runs is reported.
Dir.mktmpdir("coolio-stat-baseline") do |dir|
  path = File.join(dir, "f")
  File.write(path, "a")
  loop = Coolio::Loop.new
  stat = CountingStatProbe.new(path)
  stat.attach(loop)
  File.write(path, "bb")
  stopper = Coolio::TimerWatcher.new(0.3, false)
  stopper.on_timer { loop.stop }
  stopper.attach(loop)
  loop.run(1)
  report("stat baseline at attach", stat.changes.size > 0)
end

# The attributes of a path that does not exist are uninitialized memory
# in the C extension, so only the attributes of the current file are
# reported for the missing path and removal scenarios.
class AttrStatProbe < Coolio::StatWatcher
  attr_reader :changes

  def initialize(path)
    @changes = []
    super(path, 0.05)
  end

  def on_change(prev, cur)
    @changes << [cur.size, cur.mode.zero?]
  end
end

def stop_after(loop, interval)
  stopper = Coolio::TimerWatcher.new(interval, false)
  stopper.on_timer { loop.stop }
  stopper.attach(loop)
  stopper
end

# Detaching and attaching again re-seeds the baseline, so the change made
# in between is not reported.
Dir.mktmpdir("coolio-stat-reattach") do |dir|
  path = File.join(dir, "f")
  File.write(path, "a")
  loop = Coolio::Loop.new
  stat = CountingStatProbe.new(path)
  stat.attach(loop)
  stop_after(loop, 0.2)
  loop.run(1)
  stat.detach
  File.write(path, "ccc")
  stat.attach(loop)
  stop_after(loop, 0.3)
  loop.run(1)
  report("stat reattach re-seeds baseline", stat.changes.size)
end

# A watcher that stays attached keeps its baseline while the loop is
# stopped, so the change made in between is reported by the next run.
Dir.mktmpdir("coolio-stat-rerun") do |dir|
  path = File.join(dir, "f")
  File.write(path, "a")
  loop = Coolio::Loop.new
  stat = CountingStatProbe.new(path)
  stat.attach(loop)
  stop_after(loop, 0.2)
  loop.run(1)
  after_first_run = stat.changes.size
  File.write(path, "dddd")
  stop_after(loop, 0.3)
  loop.run(1)
  report("stat baseline across loop runs", [after_first_run, stat.changes.size].inspect)
end

# A path that does not exist yet: the first stat only seeds a baseline,
# the file being created is reported as a change.
Dir.mktmpdir("coolio-stat-missing") do |dir|
  path = File.join(dir, "missing")
  loop = Coolio::Loop.new
  stat = AttrStatProbe.new(path)
  stat.attach(loop)
  writer = Coolio::TimerWatcher.new(0.2, false)
  writer.on_timer { File.write(path, "hello") }
  writer.attach(loop)
  stop_after(loop, 0.5)
  loop.run(2)
  report("stat missing path", stat.changes.inspect)
end

# Removing the watched file reports one change in both implementations,
# but the attributes of the removed file are not the same.
Dir.mktmpdir("coolio-stat-removed") do |dir|
  path = File.join(dir, "f")
  File.write(path, "aaaa")
  loop = Coolio::Loop.new
  stat = AttrStatProbe.new(path)
  stat.attach(loop)
  remover = Coolio::TimerWatcher.new(0.2, false)
  remover.on_timer { File.unlink(path) }
  remover.attach(loop)
  stop_after(loop, 0.5)
  loop.run(2)
  report("stat removed file", stat.changes.inspect)
end

# TCPServer echo through the connection class
loop = Coolio::Loop.new
echoed = nil
server = Coolio::TCPServer.new('127.0.0.1', 0, Coolio::TCPSocket) do |conn|
  conn.on_read { |data| conn.write(data) }
  conn.on_write_complete { conn.close }
end
port = server.instance_variable_get(:@listen_socket).addr[1]
server.attach(loop)
client = TCPSocket.new('127.0.0.1', port)
loop.run_once(1)
client.write "x"
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
  loop.run_once(0.1)
  begin
    echoed = client.read_nonblock(1)
    break
  rescue IO::WaitReadable, Errno::EAGAIN
  end
end
report("tcpserver echo", echoed)
begin
  client.close
rescue StandardError
end
begin
  server.close
rescue StandardError
end

# re-running a loop after it finished
loop = Coolio::Loop.new
rerun = 0
timer = Coolio::TimerWatcher.new(0, false)
timer.on_timer { rerun += 1 }
timer.attach(loop)
loop.run_once(0.5)
timer.reset if timer.respond_to?(:reset)
timer.enable if !timer.enabled? && timer.attached?
loop.run_once(0.5)
report("timer re-run fires", rerun)

puts $out.sort_by { |k, _| k }.map { |k, v| "#{k}\t#{v.inspect}" }
