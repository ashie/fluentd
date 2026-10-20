#
# Runnable example of the EventLoopCompat PoC.
#
#   bundle exec ruby -Ilib test/event_loop_compat/example.rb
#
# It shows: a repeating timer, a readable socket watcher, attaching a
# watcher from another thread, and stopping the loop from another thread.
#

require 'socket'
require 'event_loop_compat'

errors = []
loop = EventLoopCompat::Loop.new(error_handler: ->(w, e) { errors << e })

tick = EventLoopCompat::TimerWatcher.new(0.1, true) { puts "timer tick" }
tick.attach(loop)

sock1, sock2 = UNIXSocket.pair
reader = EventLoopCompat::IOWatcher.new(sock1) do |watcher|
  puts "read: #{watcher.io.read_nonblock(100).inspect}"
end
reader.attach(loop)

# attach a new watcher from another thread
attacher = Thread.new do
  sleep 0.35
  puts "-- attaching watcher from another thread"
  late = EventLoopCompat::TimerWatcher.new(0.1, true) { puts "late timer tick" }
  late.attach(loop)
end

# write data from another thread
writer = Thread.new do
  sleep 0.2
  sock2.write("hello from another thread")
end

# stop the loop from another thread
stopper = Thread.new do
  sleep 0.8
  puts "-- stopping loop from another thread"
  loop.stop
end

# the threads above act while loop.run is blocking
loop.run
attacher.join
writer.join
stopper.join

puts "errors: #{errors.inspect}"
sock1.close
sock2.close
