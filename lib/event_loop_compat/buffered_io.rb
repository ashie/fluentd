#
# BufferedIO, compatible with the semantics of Coolio::IO (the base of
# Coolio::Socket used by Fluentd's server plugin helper):
#
#   - on_read(data) is called as data arrives
#   - write(data) buffers and writes out non-blockingly, and
#     on_write_complete is called when the buffer becomes empty
#   - EOF or an IO error closes the stream and calls on_close
#
# Subclasses override on_read / on_write_complete / on_close. A block
# given to the constructor is used as on_read (block.call(self, data)).
#
# Like Coolio, this class is not thread-safe: write() and close() must
# be called from the event loop thread (typically from a callback), or
# externally synchronized by the user.
#

require 'socket'

require 'event_loop_compat/io_watcher'

module EventLoopCompat
  class BufferedIO
    # Maximum number of bytes to consume at once, same as Coolio::IO.
    INPUT_SIZE = 16384

    attr_reader :io

    def initialize(io, &on_read_block)
      @io = io
      @on_read_block = on_read_block
      @loop = nil
      @write_buffer = []
      @write_buffer_size = 0
      @closed = false
      @read_watcher = IOWatcher.new(@io, :r) { on_readable_internal }
      @write_watcher = IOWatcher.new(@io, :w) { on_writable_internal }
    end

    #
    # Watcher interface, delegated to the read watcher (like Coolio::IO)
    #

    def attach(loop)
      raise ArgumentError, "already attached" if attached?
      @loop = loop
      loop.attach(@read_watcher)
      schedule_write
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
    # Callbacks
    #

    def on_read(data)
      @on_read_block.call(self, data) if @on_read_block
    end

    def on_write_complete
    end

    def on_close
    end

    #
    # Write interface
    #

    def write(data)
      raise IOError, "closed stream" if closed?
      data = data.to_s
      unless data.empty?
        @write_buffer << data
        @write_buffer_size += data.bytesize
        schedule_write
      end
      data.bytesize
    end

    def close
      detach if attached?
      unless @closed
        @closed = true
        begin
          @io.close unless @io.closed?
        rescue IOError
        end
      end
      on_close
      nil
    end

    def closed?
      @closed || @io.nil? || @io.closed?
    end

    protected

    def on_readable_internal
      begin
        data = @io.read_nonblock(INPUT_SIZE)
      rescue Errno::EAGAIN, Errno::EINTR
        return
      end
      on_read(data)
    rescue EOFError, SystemCallError, IOError, SocketError
      close
    end

    def on_writable_internal
      begin
        flush_write_buffer
      rescue Errno::EAGAIN, Errno::EINTR
        # socket buffer is full, wait for the next writable event
        return
      rescue SystemCallError, IOError, SocketError
        return close
      end

      if @write_buffer.empty?
        disable_write_watcher
        on_write_complete
      end
    end

    def flush_write_buffer
      while (chunk = @write_buffer.first)
        written = @io.write_nonblock(chunk)
        if written >= chunk.bytesize
          @write_buffer.shift
        else
          @write_buffer[0] = chunk.byteslice(written, chunk.bytesize - written)
        end
        @write_buffer_size -= written
      end
    end

    def schedule_write
      return if closed?
      return unless attached?
      return if @write_buffer.empty?
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
