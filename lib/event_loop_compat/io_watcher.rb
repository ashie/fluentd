#
# IOWatcher, compatible with the readable side of Coolio::IOWatcher:
# IOWatcher.new(io, :r) and the on_readable callback. A block can be
# given as a shortcut (block.call(self)), or subclasses can override
# #on_readable. Only :r (readable) is implemented in this PoC.
#
# Each attached watcher owns a Fiber which repeatedly calls
# Selector#io_wait. The fiber is driven by the event loop; state changes
# (detach / disable / enable) are applied on the event loop thread and
# make the fiber re-evaluate its state by pushing it into the selector's
# ready list or by writing a byte to its private park pipe.
#

require 'event_loop_compat/watcher'

module EventLoopCompat
  class IOWatcher < Watcher
    attr_reader :io

    def initialize(io, flags = :r, &callback)
      raise ArgumentError, "only :r (readable) is supported" unless flags == :r
      @io = io
      @callback = callback
      @fiber = nil
      @park_reader = nil
      @park_writer = nil
      super()
    end

    def on_readable
      @callback.call(self) if @callback
    end

    def __start_runtime__(loop)
      if @fiber
        # The fiber exists but is parked because it was disabled.
        unpark
        return
      end
      selector = loop.selector
      raise "loop is not running" if selector.nil?

      @fiber = Fiber.new do
        begin
          while attached?
            if enabled?
              events = selector.io_wait(Fiber.current, @io, IO::READABLE)
              next unless events
              next unless attached? && enabled?
              begin
                on_readable
              rescue => e
                @loop.__error__(self, e) if @loop
              end
            else
              park(selector)
            end
          end
        rescue => e
          # The IO was closed while waiting, or the callback broke the
          # underlying selector registration. Report and stop the fiber.
          @loop.__error__(self, e) if attached? && @loop
        ensure
          @fiber = nil
          close_park
        end
      end
      @fiber.transfer
    end

    def __stop_runtime__(loop)
      fiber = @fiber
      if fiber && fiber.alive? && loop.running? && loop.selector
        # Wake the fiber up so that it re-evaluates attached?/enabled?
        # and exits (or parks) on the event loop thread.
        loop.selector.push(fiber)
      end
    end

    def __run_finished__
      # The selector is closed: every fiber of this run is dead.
      @fiber = nil
      close_park
    end

    private

    def park(selector)
      ensure_park
      selector.io_wait(Fiber.current, @park_reader, IO::READABLE)
      begin
        @park_reader.read_nonblock(64)
      rescue IO::WaitReadable, EOFError
      end
    end

    def unpark
      @park_writer.write(".") if @park_writer
      @park_writer.flush if @park_writer
    rescue IOError
    end

    def ensure_park
      return if @park_reader
      @park_reader, @park_writer = ::IO.pipe
    end

    def close_park
      @park_reader.close if @park_reader && !@park_reader.closed?
      @park_writer.close if @park_writer && !@park_writer.closed?
    rescue
    ensure
      @park_reader = nil
      @park_writer = nil
    end
  end
end
