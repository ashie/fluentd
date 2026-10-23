#
# IOWatcher, compatible with Coolio::IOWatcher: IOWatcher.new(io, flags)
# where flags is :r, :w or :rw, and the on_readable / on_writable
# callbacks. A block can be given as a shortcut for the single-event
# form (block.call(self) with :r or :w), or subclasses can override the
# callbacks.
#
# Note: the io-event selectors are level-triggered. A watcher waiting on
# :w keeps firing while the socket is writable, so write interest should
# be enabled only when there is data to write (see BufferedIO).
#
# Each attached watcher owns a Fiber which repeatedly calls
# Selector#io_wait. The fiber is driven by the event loop; state changes
# (detach / disable / enable) are applied on the event loop thread and
# make the fiber re-evaluate its state by pushing it into the selector's
# ready list or by writing a byte to its private park pipe.
#

require 'event_loop_compat/watcher'

module EventLoopCompat
  # The behavior of an IO watcher, kept in a module so that the Coolio
  # compatibility namespace (event_loop_compat/coolio.rb) can reuse it on
  # top of Coolio::Watcher, which is required for the Coolio class
  # hierarchy (Coolio::IOWatcher < Coolio::Watcher) to match cool.io.
  module IOWatcherBehavior
    attr_reader :io

    def initialize(io, flags = :r, &callback)
      unless EventLoopCompat::IOWatcher::FLAGS.key?(flags)
        raise ArgumentError, "unsupported flags: #{flags.inspect} (use :r, :w or :rw)"
      end
      if callback && flags == :rw
        raise ArgumentError, "the block form supports :r or :w only"
      end
      @io = io
      @events_mask = EventLoopCompat::IOWatcher::FLAGS[flags]
      @callback = callback
      @fiber = nil
      @park_reader = nil
      @park_writer = nil
      @close_requested = false
      super()
    end

    def on_readable
      @callback.call(self) if @callback
    end

    def on_writable
      @callback.call(self) if @callback
    end

    # Detach and close the underlying io. Coolio::IOWatcher has no such
    # method, but Coolio::IO#close and Coolio::Listener#close provide the
    # equivalent behavior for the classes used by Fluentd; this is the
    # shared implementation for direct IOWatcher users (UDPServer).
    #
    # If the fiber is still registered in the selector and the detach is
    # deferred to the event loop thread, closing the fd here would race
    # with the selector processing events for it (io-event crashes on
    # that). In that case the close is requested and performed by the
    # fiber's ensure block, after its registration is gone.
    def close
      loop = @loop
      detach if attached?
      if @close_requested
        nil
      elsif loop && loop.running? && @fiber && @fiber.alive? && !Fiber.current.equal?(@fiber)
        # The fiber is suspended in io_wait (or parked) and will be
        # stopped on the event loop thread; close the io from there.
        @close_requested = true
      else
        close_io
      end
      nil
    end

    # Used by BufferedIO#close: the shared io is closed once all fibers
    # that could be registered on it have exited.
    def request_close
      @close_requested = true
    end

    def fiber_alive?
      !@fiber.nil? && @fiber.alive?
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
              events = selector.io_wait(Fiber.current, @io, @events_mask)
              next unless events
              next unless attached? && enabled?
              if (events & IO::READABLE) != 0
                begin
                  on_readable
                rescue => e
                  @loop.__error__(self, e) if @loop
                end
              end
              # Winsock reports a failed nonblocking connect in the
              # exception set. Let connectors distinguish that event from
              # success, even if SO_ERROR was already consumed.
              if (events & (IO::WRITABLE | IO::PRIORITY)) != 0
                begin
                  if (events & IO::PRIORITY) != 0 && respond_to?(:on_priority)
                    on_priority
                  else
                    on_writable
                  end
                rescue => e
                  @loop.__error__(self, e) if @loop
                end
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
          close_io if @close_requested
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

    # The selector that drove this fiber is being discarded (run_once
    # is called from another thread, or run() follows run_once mode).
    # A fiber suspended in io_wait cannot be resumed or closed from
    # another thread, so it is abandoned here: the watcher drops its
    # reference, and the fiber together with the old selector becomes
    # garbage. The watcher is started again on the new driving thread.
    def __discard_runtime__
      @fiber = nil
      close_park
      close_io if @close_requested
    end

    def __run_finished__
      # The selector is closed: every fiber of this run is dead.
      @fiber = nil
      close_park
      close_io if @close_requested
    end

    private

    def close_io
      @io.close unless @io.closed?
    rescue IOError, Errno::EBADF
    end

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

  class IOWatcher < Watcher
    FLAGS = {
      r: IO::READABLE,
      w: IO::WRITABLE,
      rw: IO::READABLE | IO::WRITABLE,
    }

    include IOWatcherBehavior
  end
end
