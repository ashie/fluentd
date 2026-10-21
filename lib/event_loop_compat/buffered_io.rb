#
# BufferedIO, compatible with the semantics of Coolio::IO (the base of
# Coolio::Socket used by Fluentd's server plugin helper):
#
#   - on_read(data) is called as data arrives
#   - write(data) buffers and writes out non-blockingly, and
#     on_write_complete is called when the buffer becomes empty
#   - EOF or an IO error closes the stream and calls on_close
#
# Subclasses override on_read / on_write_complete / on_close, or register
# callbacks by calling those methods with a block (Coolio's event_callback
# form: the block receives the same arguments as the method).
#
# Like Coolio, this class is not thread-safe: write() and close() must
# be called from the event loop thread (typically from a callback), or
# externally synchronized by the user.
#
# The on_read / on_write_complete / on_close methods follow Coolio's
# event_callback semantics: calling them with a block registers the
# callback, calling them without a block invokes the registered callback
# (subclasses may also override the methods directly, which takes
# precedence exactly as with Coolio).
#

require 'socket'

require 'event_loop_compat/io_watcher'

module EventLoopCompat
  class BufferedIO
    # Maximum number of bytes to consume at once, same as Coolio::IO.
    INPUT_SIZE = 16384

    attr_reader :io

    def initialize(io, &on_read_block)
      @_io = io
      @on_read_block = on_read_block
      @loop = nil
      @write_buffer = []
      @write_buffer_size = 0
      @closed = false
      @read_watcher = IOWatcher.new(@_io, :r) { on_readable }
      @write_watcher = IOWatcher.new(@_io, :w) { on_writable }
    end

    def to_io
      @_io
    end

    #
    # Watcher interface, delegated to the read watcher (like Coolio::IO)
    #

    def attach(loop)
      raise ArgumentError, "already attached" if attached?
      @loop = loop
      loop.attach(@read_watcher)
      # Same guard as Coolio::IO#attach: never enable write interest
      # without buffered data, or the level-triggered loop fires
      # on_write_complete spuriously.
      schedule_write unless @write_buffer.empty?
      self
    end

    def detach
      if @loop
        @loop.detach(@read_watcher)
        @loop.detach(@write_watcher)
        @loop = nil
      end
      self
    end

    def enable
      @read_watcher.enable if @loop
      self
    end

    def disable
      if @loop
        @read_watcher.disable
        disable_write_watcher
      end
      self
    end

    def attached?
      !@loop.nil?
    end

    def enabled?
      @read_watcher.enabled?
    end

    #
    # Callbacks (event_callback semantics, see the header comment)
    #

    def on_read(*args, &block)
      if block
        @on_read_block = block
        return
      end
      if @on_read_block
        @on_read_block.call(*args)
      end
    end

    def on_write_complete(*args, &block)
      if block
        @on_write_complete_callback = block
        return
      end
      if @on_write_complete_callback
        @on_write_complete_callback.call(*args)
      end
    end

    def on_close(*args, &block)
      if block
        @on_close_callback = block
        return
      end
      if @on_close_callback
        @on_close_callback.call(*args)
      end
    end

    #
    # Write interface
    #

    # Like Coolio, writing to an unattached or closed stream is silently
    # dropped (schedule_write does nothing unless the read watcher is
    # attached). Raising here would diverge from the cool.io backend.
    def write(data)
      data = data.to_s
      unless data.empty?
        @write_buffer << data
        @write_buffer_size += data.bytesize
        schedule_write
      end
      data.bytesize
    end

    def close
      loop = @loop
      detach if attached?
      unless @closed
        @closed = true
        if loop && loop.running? && (@read_watcher.fiber_alive? || @write_watcher.fiber_alive?)
          # A fiber may still be registered on the shared io in the
          # selector; closing the fd now would race with the selector.
          # The watchers' fibers close it once they have exited.
          @read_watcher.request_close
          @write_watcher.request_close
        else
          begin
            @_io.close unless @_io.closed?
          rescue IOError
          end
        end
      end
      on_close
      nil
    end

    def closed?
      @closed || @_io.nil? || @_io.closed?
    end

    protected

    # Read from the input and dispatch to on_read, same hook names as
    # Coolio::IO so that subclasses (TLS handlers) can override and call
    # super exactly like on the cool.io backend.
    def on_readable
      begin
        data = @_io.read_nonblock(INPUT_SIZE)
      rescue Errno::EAGAIN, Errno::EINTR
        return
      end
      on_read(data)
    rescue EOFError, SystemCallError, IOError, SocketError
      close
    end

    def on_writable
      begin
        flush_write_buffer
      rescue Errno::EAGAIN, Errno::EINTR
        # socket buffer is full, wait for the next writable event
        return
      rescue SystemCallError, IOError, SocketError
        return close
      end

      if @write_buffer.empty?
        # Coolio detaches the write watcher when the buffer drains, so
        # that a level-triggered loop cannot deliver a spurious writable
        # event and fire on_write_complete twice.
        @loop.detach(@write_watcher) if @loop && @write_watcher.attached?
        on_write_complete
      end
    end

    def flush_write_buffer
      while (chunk = @write_buffer.first)
        written = @_io.write_nonblock(chunk)
        if written >= chunk.bytesize
          @write_buffer.shift
        else
          @write_buffer[0] = chunk.byteslice(written, chunk.bytesize - written)
        end
        @write_buffer_size -= written
      end
    end

    # Same as Coolio::IO#schedule_write: no check for an empty buffer,
    # because subclasses (TLS handlers) keep their own write buffer and
    # call schedule_write directly.
    def schedule_write
      return if closed?
      return unless attached?
      if @write_watcher.attached?
        @write_watcher.enable unless @write_watcher.enabled?
      else
        @loop.attach(@write_watcher)
      end
    end

    def disable_write_watcher
      @write_watcher.disable if @write_watcher && @write_watcher.enabled?
    end
  end
end
