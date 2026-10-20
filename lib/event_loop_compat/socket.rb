#
# Socket / TCPSocket / TCPServer / UNIXServer, compatible with the
# Coolio classes of the same names as used by Fluentd:
#
#   * Socket.connect(socket, *args) returns a half-open object that
#     starts the (non-blocking) connect when it is attached to a loop,
#     then fires on_connect / on_connect_failed.
#   * TCPServer.new(host, port, klass, *args, &block) accepts
#     connections and creates handler objects, calling
#     klass.new(socket, *args).attach(loop), then on_connect, then the
#     block, in that order (same as Coolio::Server#on_connection).
#
# Known intentional difference from cool.io: TCPSocket.connect resolves
# hostnames synchronously with Addrinfo.getaddrinfo on the calling
# thread instead of asynchronously through the event loop. The failure
# path is kept equivalent: a resolution failure fires on_resolve_failed
# (which defaults to on_connect_failed) when the object is attached,
# and later attach calls raise "connection failed".
#

require 'socket'
require 'resolv'

require 'event_loop_compat/buffered_io'

module EventLoopCompat
  WINDOWS = RUBY_PLATFORM =~ /mingw|mswin/ ? true : false

  DEFAULT_BACKLOG = 1024

  class Socket < BufferedIO
    # Returns a half-open socket object. The connect completes when the
    # object is attached to a running loop.
    def self.connect(socket, *args)
      new(socket, *args).instance_eval do
        @connector = Connector.new(self, socket)
        self
      end
    end

    def initialize(*args)
      @failed = nil
      @connector = nil
      super
    end

    # Delegation to the connector, equivalent to Coolio's watcher_delegate.
    def attach(loop)
      raise "connection failed" if @failed

      if @connector
        @connector.attach(loop)
        return self
      end

      super
    end

    def detach
      if @connector
        @connector.detach
        return self
      end
      super
    end

    def enable
      if @connector
        @connector.enable
        return self
      end
      super
    end

    def disable
      if @connector
        @connector.disable
        return self
      end
      super
    end

    def attached?
      return @connector.attached? if @connector
      super
    end

    def enabled?
      return @connector.enabled? if @connector
      super
    end

    def evloop
      return @connector.evloop if @connector
      super
    end

    def on_connect(*args, &block)
      if block
        @on_connect_callback = block
        return
      end
      if @on_connect_callback
        @on_connect_callback.call(*args)
      end
    end

    def on_connect_failed(*args, &block)
      if block
        @on_connect_failed_callback = block
        return
      end
      if @on_connect_failed_callback
        @on_connect_failed_callback.call(*args)
      end
    end

    alias on_resolve_failed on_connect_failed

    class Connector < IOWatcher
      def initialize(socket, ruby_socket)
        @socket, @ruby_socket = socket, ruby_socket
        super(ruby_socket, :w)
      end

      def on_writable
        evl = evloop
        detach

        if connect_successful?
          @socket.instance_eval { @connector = nil }
          @socket.attach(evl)
          begin
            @ruby_socket.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_NODELAY, [1].pack("l"))
            @ruby_socket.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_KEEPALIVE, true)
          rescue SystemCallError, IOError
            # Non-TCP sockets (e.g. AF_UNIX) do not support these options.
          end
          @socket.__send__(:on_connect)
        else
          @socket.instance_eval { @failed = true }
          @socket.__send__(:on_connect_failed)
        end
      end

      private

      def connect_successful?
        @ruby_socket.getsockopt(::Socket::SOL_SOCKET, ::Socket::SO_ERROR).unpack('i').first == 0
      rescue IOError
        false
      end
    end
  end

  class TCPSocket < Socket
    PEERADDR_FAILED = ["?", 0, "name resolusion failed", "?"]

    attr_reader :remote_host, :remote_addr, :remote_port, :address_family

    # addr is a string, can be an IP address or a hostname.
    def self.connect(addr, port, *args)
      if (family = ip_family(addr))
        return super(TCPConnectSocket.new(family, addr, port), *args)
      end

      begin
        infos = ::Addrinfo.getaddrinfo(addr, port, nil, :stream)
        raise ::SocketError, "getaddrinfo: nodename nor servname provided, or not known" if infos.empty?
      rescue ::SocketError, ::SystemCallError
        obj = allocate
        obj.send(:preinitialize_failed, addr, port)
        return obj
      end

      connect(infos.first.ip_address, port, *args)
    end

    def self.ip_family(addr)
      if (Resolv::IPv4.create(addr) rescue nil)
        ::Socket::AF_INET
      elsif (Resolv::IPv6.create(addr) rescue nil)
        ::Socket::AF_INET6
      end
    end
    private_class_method :ip_family

    def initialize(socket)
      unless socket.is_a?(::TCPSocket) || socket.is_a?(TCPConnectSocket)
        raise TypeError, "socket must be a TCPSocket"
      end

      super

      @address_family, @remote_port, @remote_host, @remote_addr = (socket.peeraddr rescue PEERADDR_FAILED)
    end

    def peeraddr
      [@address_family, @remote_port, @remote_host, @remote_addr]
    end

    # Half-open object for a hostname that could not be resolved.
    # on_resolve_failed fires on the first attach, same as cool.io.
    def attach(loop)
      if @resolve_failed
        @resolve_failed = nil
        @failed = true
        __send__(:on_resolve_failed)
        return self
      end
      super
    end

    protected

    def preinitialize_failed(addr, port)
      @remote_host, @remote_addr, @remote_port = addr, addr, port
      @resolve_failed = true
    end

    class TCPConnectSocket < ::Socket
      def initialize(family, addr, port, host = addr)
        @host, @addr, @port = host, addr, port
        @address_family = nil

        super(family, ::Socket::SOCK_STREAM, 0)
        begin
          connect_nonblock(::Socket.sockaddr_in(port, addr))
        rescue Errno::EINPROGRESS
        end
      end

      def peeraddr
        [
          @address_family == ::Socket::AF_INET ? 'AF_INET' : 'AF_INET6',
          @port,
          @host,
          @addr,
        ]
      end
    end
  end

  class UNIXSocket < Socket
    attr_reader :path, :address_family

    def self.connect(path, *args)
      new(::UNIXSocket.new(path), *args)
    end

    def initialize(socket)
      raise ArgumentError, "socket must be a UNIXSocket" unless socket.is_a? ::UNIXSocket

      super
      @address_family, @path = socket.peeraddr
    end
  end

  # Equivalent of Coolio::Listener + Coolio::Server + Coolio::TCPServer /
  # Coolio::UNIXServer, in one class pair.
  class Server < IOWatcher
    def initialize(listen_socket, klass = Socket, *args, &block)
      unless klass.allocate.is_a? BufferedIO
        raise ArgumentError, "can't convert #{klass} to EventLoopCompat::BufferedIO"
      end

      arity = klass.instance_method(:initialize).arity
      expected = arity >= 0 ? arity : -(arity + 1)
      if (arity >= 0 && args.size + 1 != expected) || (arity < 0 && args.size + 1 < expected)
        raise ArgumentError, "wrong number of arguments for #{klass}#initialize (#{args.size + 1} for #{expected})"
      end

      @klass, @args, @block = klass, args, block
      super(listen_socket, :r)
    end

    def fileno
      @io.fileno
    end

    def listen(backlog)
      @io.listen(backlog)
    end

    def on_connection(socket)
      connection = @klass.new(socket, *@args).attach(loop)
      connection.__send__(:on_connect)
      @block.call(connection) if @block
    end

    # Same as Coolio::Listener#on_readable: one accept per readiness
    # event. On Windows, blocking accept is used to avoid the
    # thundering herd problem, same as cool.io.
    def on_readable
      begin
        if WINDOWS
          on_connection @io.accept
        else
          on_connection @io.accept_nonblock
        end
      rescue Errno::EAGAIN, Errno::ECONNABORTED
      end
    end
  end

  class TCPServer < Server
    def initialize(host, port = nil, klass = TCPSocket, *args, &block)
      listen_socket = if ::TCPServer === host
                        host
                      else
                        raise ArgumentError, "port must be an integer" if nil == port
                        ::TCPServer.new(host, port)
                      end
      listen_socket.listen(DEFAULT_BACKLOG) # Change listen backlog to 1024
      super(listen_socket, klass, *args, &block)
    end
  end

  class UNIXServer < Server
    def initialize(path, klass = UNIXSocket, *args, &block)
      s = ::UNIXServer === path ? path : ::UNIXServer.new(path)
      s.listen(DEFAULT_BACKLOG)
      super(s, klass, *args, &block)
    end
  end
end
