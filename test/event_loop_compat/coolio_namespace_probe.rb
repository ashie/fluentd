#
# Standalone probe for the Coolio compatibility namespace.
#
# It is intentionally run in a separate process (see
# test_coolio_namespace.rb) because defining the Coolio namespace and
# loading the real cool.io extension in the same process is not
# supported.
#

require 'event_loop_compat/coolio'

def check(condition, message)
  raise message unless condition
end

def expect_error(error_class, message)
  yield
  raise "expected #{error_class}: #{message}"
rescue error_class => e
  check(e.message == message, "expected #{error_class} #{message.inspect}, got #{e.message.inspect}")
end

check(Coolio::VERSION == '1.9.0', "unexpected Coolio::VERSION: #{Coolio::VERSION.inspect}")
check(Cool.io.equal?(Coolio), "Cool.io must reference Coolio")

expect_error(ArgumentError, "no such option: foo") do
  Coolio::Loop.new(foo: 1)
end

expect_error(ArgumentError, "no such backend: foo") do
  Coolio::Loop.new(backend: :foo)
end

expect_error(RuntimeError, "watcher base class should not be initialized directly") do
  Coolio::Watcher.new
end

expect_error(ArgumentError, "expected loop to be an instance of Coolio::Loop, not \"x\"") do
  Coolio::TimerWatcher.new(1).attach("x")
end

expect_error(ArgumentError, "invalid event type: 'x' (must be 'r', 'w', or 'rw')") do
  Coolio::IOWatcher.new($stdin, 'x')
end

expect_error(RuntimeError, "not attached to a loop") do
  Coolio::TimerWatcher.new(1).reset
end

expect_error(RuntimeError, "not attached to a loop") do
  Coolio::TimerWatcher.new(1).detach
end

expect_error(RuntimeError, "loop not running") do
  Coolio::Loop.new.stop
end

expect_error(RuntimeError, "no watchers for this loop") do
  Coolio::Loop.new.run
end

expect_error(ArgumentError, "time interval must be positive") do
  Coolio::Loop.new.run_once(-1)
end

loop = Coolio::Loop.new
timer = Coolio::TimerWatcher.new(0)
timer_events = 0
timer.on_timer { timer_events += 1 }
timer.attach(loop)

expect_error(RuntimeError, "already enabled") do
  timer.enable
end

nevents = loop.run_once
check(nevents >= 1, "run_once must return the number of dispatched events, got #{nevents.inspect}")
check(timer_events == 1, "one-shot timer callback must fire once, got #{timer_events}")
check(!timer.enabled?, "one-shot timer must disable itself after firing")

expect_error(RuntimeError, "already disabled") do
  timer.disable
end

loop = Coolio::Loop.new
signals = 0
async = Coolio::AsyncWatcher.new
async.on_signal { signals += 1 }
async.attach(loop)
async.signal
nevents = loop.run_once(1)
check(nevents >= 1, "run_once must count async signals, got #{nevents.inspect}")
check(signals == 1, "async signal callback must fire once, got #{signals}")

loop = Coolio::Loop.new
reader, writer = ::IO.pipe
data = nil
io_watcher = Coolio::IOWatcher.new(reader, 'r')
check(!io_watcher.respond_to?(:loop), "Coolio::IOWatcher must not expose a public loop accessor")
io_watcher.on_readable { data = reader.read_nonblock(1) }
io_watcher.attach(loop)
writer.write "x"
nevents = loop.run_once(1)
check(nevents >= 1, "run_once must count IO events, got #{nevents.inspect}")
check(data == "x", "IO watcher must receive data, got #{data.inspect}")

check(Coolio::Socket <= Coolio::IO, "Coolio::Socket must be a Coolio::IO")
check(Coolio::TCPSocket <= Coolio::Socket, "Coolio::TCPSocket must be a Coolio::Socket")
check(Coolio::UNIXSocket <= Coolio::Socket, "Coolio::UNIXSocket must be a Coolio::Socket")
check(Coolio::TCPServer <= Coolio::Server, "Coolio::TCPServer must be a Coolio::Server")
check(Coolio::UNIXServer <= Coolio::Server, "Coolio::UNIXServer must be a Coolio::Server")

server = Coolio::TCPServer.new('127.0.0.1', 0, Coolio::TCPSocket) do |conn|
  conn.on_read do |data|
    conn.write(data)
  end
  conn.on_write_complete do
    conn.close
  end
end
port = server.instance_variable_get(:@listen_socket).addr[1]
loop = Coolio::Loop.new
server.attach(loop)

client = TCPSocket.new('127.0.0.1', port)
loop.run_once(1)
client.write "x"

data = nil
10.times do
  loop.run_once(0.1)
  begin
    data = client.read_nonblock(1)
    break
  rescue IO::WaitReadable, Errno::EAGAIN
  end
end

check(data == "x", "Coolio::TCPServer must echo data, got #{data.inspect}")
client.close
server.close

buffer = Coolio::Buffer.new
buffer << "abc"
check(buffer.size == 3, "Buffer#size must report buffered bytes")
check(buffer.read(2) == "ab", "Buffer#read must consume bytes")
check(buffer.to_str == "c", "Buffer#to_str must return remaining bytes")

puts "OK"
