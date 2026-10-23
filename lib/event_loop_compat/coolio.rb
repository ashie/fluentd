#
# Coolio compatibility namespace on top of EventLoopCompat.
#
# This file intentionally defines the public Coolio constants used by
# external plugins. It is loaded when the io_event_compat backend is
# selected (lib/fluent/plugin_helper/event_loop.rb) and by
# lib/cool.io.rb, so that a process using the compat backend has the same
# Coolio namespace as one using the cool.io gem. It is not loaded by the
# EventLoopCompat entry point, because tests compare the two
# implementations in one process. Loading both the real cool.io extension
# and this namespace in the same process is otherwise not supported.
#
# The watcher classes reproduce the cool.io hierarchy: Coolio::Watcher is
# the base class of Coolio::IOWatcher, Coolio::TimerWatcher and
# Coolio::StatWatcher, and those classes get their implementation by
# mixing in the EventLoopCompat*Behavior modules. Inheriting the
# EventLoopCompat watcher classes instead would make is_a?, kind_of?,
# Case-when and `Coolio::TimerWatcher < Coolio::Watcher` disagree with
# cool.io, which plugins do rely on. Coolio::IO is not a watcher in
# cool.io, so it stays based on EventLoopCompat::BufferedIO.
#

require 'socket'
require 'resolv'

require 'event_loop_compat'

if defined?(::Coolio::Loop)
  loc = begin
    ::Coolio::Loop.instance_method(:run).source_location
  rescue NameError
    nil
  end

  if loc && loc.first.include?('event_loop_compat')
    return
  else
    raise LoadError, "cool.io is already loaded; cannot load EventLoopCompat Coolio compatibility"
  end
end

# The watcher interface of the Coolio namespace. It is not a Coolio
# constant on purpose: cool.io has no module in the ancestor chain of
# Coolio::Watcher, and Coolio::Watcher.ancestors is observable.
module EventLoopCompat
  module CoolioWatcherBehavior
    # cool.io only accepts a Coolio::Loop. Fluentd's event loop helper
    # creates an EventLoopCompat::Loop (Coolio::Loop is a subclass of it,
    # so accepting the base class covers both), and watchers of this
    # namespace must be attachable to it: that is the whole point of the
    # compatibility layer.
    def attach(loop)
      unless loop.is_a?(EventLoopCompat::Loop)
        raise ArgumentError, "expected loop to be an instance of Coolio::Loop, not #{loop.inspect}"
      end

      detach if attached?
      loop.__attach_watcher__(self)
      self
    end

    def detach
      raise RuntimeError, "not attached to a loop" unless attached?
      @loop.detach(self)
      self
    end

    def enable
      raise RuntimeError, "not attached to a loop" unless attached?
      raise RuntimeError, "already enabled" if enabled?
      @loop.enable(self)
      self
    end

    def disable
      raise RuntimeError, "not attached to a loop" unless attached?
      raise RuntimeError, "already disabled" unless enabled?
      @loop.disable(self)
      self
    end
  end
end

module Coolio
  VERSION = '1.9.0'
  DEFAULT_BACKLOG = 1024
  WINDOWS = RUBY_PLATFORM.match?(/mingw|mswin/)

  def self.inspect
    "Cool.io"
  end

  module Meta
    def watcher_delegate(proxy_var)
      %w[attach attached? detach enable disable].each do |method|
        module_eval <<-EOD, __FILE__, __LINE__ + 1
          def #{method}(*args)
            if defined?(#{proxy_var}) && #{proxy_var}
              #{proxy_var}.#{method}(*args)
              return self
            end

            super
          end
        EOD
      end
    end

    def event_callback(*methods)
      methods.each do |method|
        method = method.to_s
        remove_method(method.to_sym) if instance_methods(false).include?(method.to_sym)

        module_eval <<-EOD, __FILE__, __LINE__ + 1
          def #{method}(*args, &block)
            if block
              @#{method}_callback = block
              return
            end

            if defined?(@#{method}_callback) && @#{method}_callback
              @#{method}_callback.call(*args)
            end
          end
        EOD
      end
    end
  end

  class Loop < EventLoopCompat::Loop
    def self.default
      Thread.current._coolio_loop
    end

    def initialize(options = {})
      validate_options(options)
      super()
    end

    def attach(watcher)
      if watcher.is_a?(Coolio::Watcher) || composite_watcher?(watcher)
        watcher.attach(self)
      else
        __attach_watcher__(watcher)
      end
      watcher
    end

    # cool.io's Loop#run returns false (the C extension returns Qfalse).
    def run(timeout = nil)
      super
      false
    end

    def run_once(timeout = nil)
      raise ArgumentError, "time interval must be positive" if timeout && timeout < 0
      super
    end

    def run_nonblock
      run_once(0)
    end

    def stop
      raise RuntimeError, "loop not running" unless running?
      super
      nil
    end

    def has_active_watchers?
      active_count > 0
    end

    private

    def validate_options(options)
      options.each do |option, value|
        case option
        when :skip_environment, :fork_check
          # Accepted for API compatibility. The io-event backend has no
          # libev environment flags or fork-check mode to configure.
        when :backend
          value = [value] unless value.is_a?(Array)
          value.each do |backend|
            unless [:select, :poll, :epoll, :kqueue, :port].include?(backend)
              raise ArgumentError, "no such backend: #{backend}"
            end
          end
        else
          raise ArgumentError, "no such option: #{option}"
        end
      end
    end
  end

  class Thread
    unless method_defined?(:_coolio_loop)
      def _coolio_loop
        @_coolio_loop ||= Coolio::Loop.new
      end
    end
  end

  class Watcher < EventLoopCompat::Watcher
    include EventLoopCompat::CoolioWatcherBehavior

    def initialize
      raise "watcher base class should not be initialized directly" if self.class == Coolio::Watcher
      super
    end
  end

  class IOWatcher < Watcher
    include EventLoopCompat::IOWatcherBehavior
    extend Meta

    def initialize(io, flags = 'r', &block)
      flags = 'r' if flags.nil?
      flags = flags.to_s
      unless %w[r w rw].include?(flags)
        raise ArgumentError, "invalid event type: '#{flags}' (must be 'r', 'w', or 'rw')"
      end

      super(io, flags.to_sym, &block)
    end

    def on_readable; end
    def on_writable; end
    event_callback :on_readable, :on_writable
  end

  class TimerWatcher < Watcher
    include EventLoopCompat::TimerWatcherBehavior
    extend Meta

    def on_timer; end
    event_callback :on_timer

    def reset
      raise RuntimeError, "not attached to a loop" unless attached?
      return self unless enabled?

      cancel_handle
      if @repeats
        @deadline = @loop.timers.now + @interval
        schedule_next(@loop)
      else
        __disable_flag__
      end
      self
    end
  end

  class StatWatcher < Watcher
    include EventLoopCompat::StatWatcherBehavior

    def initialize(path, interval = 0, &block)
      super(path, interval, &block)
    end
  end

  class AsyncWatcher < IOWatcher
    extend Meta

    def initialize
      @reader, @writer = ::IO.pipe
      super(@reader, 'r')
    end

    def signal
      @writer.write "\0"
    end

    def on_signal; end
    event_callback :on_signal

    protected

    def on_readable
      begin
        @reader.read_nonblock 1
      rescue Errno::EAGAIN
        return
      end
      on_signal
    end
  end

  class Buffer
    MAX_SIZE = 0x40000000

    @default_node_size = 16384

    class << self
      attr_reader :default_node_size

      def default_node_size=(size)
        unless size.is_a?(Integer) && size >= 1 && size <= MAX_SIZE
          raise ArgumentError, "invalid node size: #{size.inspect}"
        end
        @default_node_size = size
      end
    end

    def initialize(size = self.class.default_node_size)
      unless size.is_a?(Integer) && size >= 1 && size <= MAX_SIZE
        raise ArgumentError, "invalid buffer size: #{size.inspect}"
      end
      @node_size = size
      @data = String.new(encoding: Encoding::BINARY)
    end

    def clear
      @data.clear
      self
    end

    def size
      @data.bytesize
    end

    def empty?
      @data.empty?
    end

    def <<(data)
      @data << data.to_s
      self
    end
    alias append <<
    alias write <<

    def prepend(data)
      @data.prepend(data.to_s)
      self
    end

    def read(length = nil)
      length = @data.bytesize if length.nil?
      @data.slice!(0, length)
    end

    def read_frame(data, mark)
      index = @data.index(mark)
      return false unless index

      frame_end = index + mark.bytesize
      data << @data.slice!(0, frame_end)
      true
    end

    def to_str
      @data.dup
    end

    def read_from(io)
      begin
        chunk = io.read_nonblock(@node_size)
      rescue EOFError
        return 0
      end

      @data << chunk
      chunk.bytesize
    end

    def write_to(io)
      return 0 if @data.empty?

      written = io.write_nonblock(@data)
      @data.slice!(0, written)
      written
    end
  end

  class IO < EventLoopCompat::BufferedIO
    # Internal class implementing the watchers used by Coolio::IO, the
    # counterpart of cool.io's Coolio::IO::Watcher.
    class Watcher < Coolio::IOWatcher
      def initialize(ruby_io, coolio_io, flags)
        @coolio_io = coolio_io
        super(ruby_io, flags)
      end

      def on_readable
        @coolio_io.__send__(:on_readable)
      end

      def on_writable
        @coolio_io.__send__(:on_writable)
      end
    end

    def initialize(io, &block)
      super(io, &block)
      @read_watcher = Watcher.new(@_io, self, 'r')
      @write_watcher = Watcher.new(@_io, self, 'w')
    end

    def attach(loop)
      @read_watcher.attach(loop)
      @loop = loop
      schedule_write unless @write_buffer.empty?
      self
    end
  end

  class Socket < IO
    extend Meta

    def self.connect(socket, *args)
      new(socket, *args).instance_eval do
        @_connector = Connector.new(self, socket)
        self
      end
    end

    def initialize(*args)
      @_failed = nil
      @_connector = nil
      super
    end

    watcher_delegate :@_connector

    remove_method :attach
    def attach(loop)
      raise RuntimeError, "connection failed" if @_failed

      if @_connector
        @_connector.attach(loop)
        return self
      end

      super
    end

    def on_connect; end
    event_callback :on_connect

    def on_connect_failed; end
    event_callback :on_connect_failed

    alias_method :on_resolve_failed, :on_connect_failed

    class Connector < IOWatcher
      def initialize(coolio_socket, ruby_socket)
        @coolio_socket, @ruby_socket = coolio_socket, ruby_socket
        super(ruby_socket, 'w')
        @events_mask |= ::IO::PRIORITY if EventLoopCompat::WINDOWS
      end

      def on_writable
        evl = evloop
        detach

        if connect_successful?
          @coolio_socket.instance_eval { @_connector = nil }
          @coolio_socket.attach(evl)

          begin
            @ruby_socket.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_NODELAY, [1].pack("l"))
            @ruby_socket.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_KEEPALIVE, true)
          rescue SystemCallError, IOError
            # Non-TCP sockets (e.g. AF_UNIX) do not support these options.
          end

          @coolio_socket.__send__(:on_connect)
        else
          @coolio_socket.instance_eval { @_failed = true }
          @coolio_socket.__send__(:on_connect_failed)
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
      @resolve_failed = nil

      unless socket.is_a?(::TCPSocket) || socket.is_a?(TCPConnectSocket)
        raise TypeError, "socket must be a TCPSocket"
      end

      super

      @address_family, @remote_port, @remote_host, @remote_addr = (socket.peeraddr rescue PEERADDR_FAILED)
    end

    def peeraddr
      [@address_family, @remote_port, @remote_host, @remote_addr]
    end

    def attach(loop)
      if @resolve_failed
        @resolve_failed = nil
        @_failed = true
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

  class Listener < IOWatcher
    def initialize(listen_socket)
      @listen_socket = listen_socket
      super(@listen_socket, 'r')
    end

    def fileno
      @listen_socket.fileno
    end

    def listen(backlog)
      @listen_socket.listen(backlog)
    end

    def close
      detach if attached?
      super
    end

    def on_connection(socket); end
    event_callback :on_connection

    protected

    def on_readable
      begin
        if WINDOWS
          on_connection @listen_socket.accept
        else
          on_connection @listen_socket.accept_nonblock
        end
      rescue Errno::EAGAIN, Errno::ECONNABORTED
      end
    end
  end

  class TCPListener < Listener
    def initialize(addr, port = nil, options = {})
      BasicSocket.do_not_reverse_lookup = true unless options[:reverse_lookup]
      options[:backlog] ||= DEFAULT_BACKLOG

      listen_socket = if ::TCPServer === addr
                        addr
                      else
                        raise ArgumentError, "port must be an integer" if nil == port
                        ::TCPServer.new(addr, port)
                      end
      listen_socket.instance_eval { listen(options[:backlog]) }
      super(listen_socket)
    end
  end

  class UNIXListener < Listener
    def initialize(*args)
      s = ::UNIXServer === args.first ? args.first : ::UNIXServer.new(*args)
      s.instance_eval { listen(DEFAULT_BACKLOG) }
      super(s)
    end
  end

  class Server < Listener
    def initialize(listen_socket, klass = Socket, *args, &block)
      unless klass.allocate.is_a? Coolio::IO
        raise ArgumentError, "can't convert #{klass} to Coolio::IO"
      end

      arity = klass.instance_method(:initialize).arity
      expected = arity >= 0 ? arity : -(arity + 1)
      if (arity >= 0 && args.size + 1 != expected) || (arity < 0 && args.size + 1 < expected)
        raise ArgumentError, "wrong number of arguments for #{klass}#initialize (#{args.size + 1} for #{expected})"
      end

      @klass, @args, @block = klass, args, block
      super(listen_socket)
    end

    def fileno
      @listen_socket.fileno
    end

    protected

    def on_connection(socket)
      connection = @klass.new(socket, *@args).attach(evloop)
      connection.__send__(:on_connect)
      @block.call(connection) if @block
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
      listen_socket.instance_eval { listen(DEFAULT_BACKLOG) }
      super(listen_socket, klass, *args, &block)
    end
  end

  class UNIXServer < Server
    def initialize(path, klass = UNIXSocket, *args, &block)
      s = ::UNIXServer === path ? path : ::UNIXServer.new(path)
      s.instance_eval { listen(DEFAULT_BACKLOG) }
      super(s, klass, *args, &block)
    end
  end

  class DNSResolver < IOWatcher
    DNS_PORT = 53
    DATAGRAM_SIZE = 512
    TIMEOUT = 3
    RETRIES = 4

    def self.hosts(host, hostfile = Resolv::Hosts::DefaultFileName)
      hosts = {}
      File.open(hostfile) do |f|
        f.each_line do |host_entry|
          entries = host_entry.gsub(/#.*$/, '').gsub(/\s+/, ' ').split(' ')
          addr = entries.shift
          entries.each { |e| hosts[e] ||= addr }
        end
      end

      unless hosts.key?("localhost")
        hosts["localhost"] = ::Socket.getaddrinfo("localhost", nil).first[3]
      end

      hosts[host]
    end

    def initialize(hostname, *nameservers)
      if nameservers.empty?
        nameservers = Resolv::DNS::Config.default_config_hash[:nameserver]
        raise RuntimeError, "no nameservers found" if nameservers.empty?
      end

      @nameservers = nameservers
      @question = request_question hostname

      @socket = UDPSocket.new
      @timer = Timeout.new(self)

      super(@socket)
    end

    def attach(evloop)
      send_request
      @timer.attach(evloop)
      super
    end

    def detach
      @timer.detach if @timer.attached?
      super
    end

    def on_success(address); end
    event_callback :on_success

    def on_failure; end
    event_callback :on_failure

    def on_timeout
      on_failure
    end

    protected

    def send_request
      nameserver = @nameservers.shift
      @nameservers << nameserver
      begin
        @socket.send request_message, 0, @nameservers.first, DNS_PORT
      rescue Errno::EHOSTUNREACH
      end
    end

    def on_readable
      datagram = nil
      begin
        datagram = @socket.recvfrom_nonblock(DATAGRAM_SIZE).first
      rescue Errno::ECONNREFUSED
      end

      address = response_address(datagram) rescue nil
      address ? on_success(address) : on_failure
      detach
    end

    def request_question(hostname)
      raise ArgumentError, "hostname cannot be nil" if hostname.nil?

      message = hostname.split('.').map { |s| [s.size].pack('C') << s }.join + "\0"
      qtype = 1
      qclass = 1
      message << [qtype, qclass].pack('nn')
    end

    def request_message
      message = [2, 1, 0].pack('nCC')
      qdcount = 1
      ancount = nscount = arcount = 0
      message << [qdcount, ancount, nscount, arcount].pack('nnnn')
      message << @question
    end

    def response_address(message)
      return unless message

      id = message[0..1].unpack('n').first.to_i
      return unless id == 2

      qr = message[2..2].unpack('B1').first.to_i
      return unless qr == 1

      rcode = message[3..3].unpack('B8').first[4..7].to_i(2)
      return unless rcode == 0

      qdcount, _ancount = message[4..7].unpack('nn').map { |n| n.to_i }
      return unless qdcount == 1
      message.slice!(0, 12)

      return unless message[0..(@question.size - 1)] == @question
      message.slice!(0, @question.size)

      while !message.empty?
        type = message[2..3].unpack('n').first.to_i
        rdlength = message[10..11].unpack('n').first.to_i
        rdata = message[12..(12 + rdlength - 1)]
        message.slice!(0, 12 + rdlength)

        next unless rdlength == 4
        return rdata.unpack('CCCC').join('.') if type == 1
      end

      nil
    end

    class Timeout < TimerWatcher
      def initialize(resolver)
        @resolver = resolver
        @attempts = 0
        super(TIMEOUT, true)
      end

      def on_timer
        @attempts += 1
        if @attempts <= RETRIES
          begin
            return @resolver.__send__(:send_request)
          rescue Errno::EHOSTUNREACH
            return nil
          end
        end
        @resolver.__send__(:on_timeout)
        @resolver.detach
      end
    end
  end
end

module Cool
  def self.io
    Coolio
  end
end
