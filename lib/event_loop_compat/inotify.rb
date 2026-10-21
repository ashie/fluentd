#
# Inotify, the per-loop shared inotify instance of the EventLoopCompat
# PoC layer (the equivalent of the single inotify fd that libev keeps
# for each loop).
#
# One instance owns one inotify fd and one IOWatcher on the loop, and
# multiplexes the watches of every StatWatcher attached to that loop.
# Watch descriptors are reference counted (the kernel returns the same
# wd for the same path, so several watchers on one path share it), and
# the instance closes itself when the last watch is removed so that no
# fd and no loop watcher is left behind.
#
# libc bindings go through Fiddle (stdlib): Kernel#syscall is deprecated
# and unsafe, and Ruby has no inotify bindings otherwise. On platforms
# without inotify (macOS, Windows) supported? is false and callers use
# polling only.
#

require 'fiddle'

require 'event_loop_compat/io_watcher'

module EventLoopCompat
  class Inotify
    # inotify event masks (uapi linux/inotify.h)
    IN_MODIFY = 0x00000002
    IN_ATTRIB = 0x00000004
    IN_MOVED_FROM = 0x00000040
    IN_MOVED_TO = 0x00000080
    IN_CREATE = 0x00000100
    IN_DELETE = 0x00000200
    IN_DELETE_SELF = 0x00000400
    IN_MOVE_SELF = 0x00000800
    IN_Q_OVERFLOW = 0x00004000
    IN_IGNORED = 0x00008000
    IN_ONLYDIR = 0x00100000
    # inotify_init1 flags (O_NONBLOCK / O_CLOEXEC)
    IN_NONBLOCK = 0x00000800
    IN_CLOEXEC = 0x00080000

    FILE_WATCH_MASK = IN_ATTRIB | IN_MODIFY | IN_DELETE_SELF | IN_MOVE_SELF
    DIR_WATCH_MASK = IN_CREATE | IN_MOVED_TO | IN_MOVED_FROM | IN_DELETE | IN_ONLYDIR

    def self.functions
      return @functions if defined?(@functions)
      @functions = begin
        libc = Fiddle.dlopen(nil)
        {
          init1: Fiddle::Function.new(libc['inotify_init1'],
                                      [Fiddle::TYPE_INT], Fiddle::TYPE_INT),
          add_watch: Fiddle::Function.new(libc['inotify_add_watch'],
                                          [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_UINT],
                                          Fiddle::TYPE_INT),
          rm_watch: Fiddle::Function.new(libc['inotify_rm_watch'],
                                         [Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT),
        }
      rescue LoadError, RuntimeError
        nil
      end
    end

    def self.supported?
      !functions.nil?
    end

    def initialize(loop)
      @loop = loop
      @mutex = Mutex.new
      # wd => watchers, reference count and effective mask; path => wd.
      @handlers = {}
      @refs = {}
      @masks = {}
      @paths = {}
      fd = self.class.functions[:init1].call(IN_NONBLOCK | IN_CLOEXEC)
      raise SystemCallError.new("inotify_init1", -fd) if fd < 0
      @io = IO.for_fd(fd)
      @watcher = IOWatcher.new(@io, :r) { drain }
      @watcher.attach(loop)
    end

    def closed?
      @io.nil? || @io.closed?
    end

    # Registers path for watcher and returns the watch descriptor, or
    # nil when the kernel refused the path (missing file and so on).
    # Several watchers on the same path share one wd; the effective
    # mask is the union of what they asked for.
    def add_watch(watcher, path, mask)
      return nil if closed?
      functions = self.class.functions
      @mutex.synchronize do
        wd = @paths[path]
        if wd
          merged = @masks[wd] | mask
          if merged != @masks[wd]
            return nil if functions[:add_watch].call(fileno, path, merged) < 0
            @masks[wd] = merged
          end
        else
          wd = functions[:add_watch].call(fileno, path, mask)
          return nil if wd < 0
          @paths[path] = wd
          @masks[wd] = mask
        end
        @refs[wd] = @refs[wd].to_i + 1
        (@handlers[wd] ||= []) << watcher
        wd
      end
    end

    def remove_watch(watcher, wd)
      return if wd.nil? || closed?
      @mutex.synchronize do
        return self if @refs[wd].nil?
        list = @handlers[wd]
        list.delete(watcher) if list
        count = @refs[wd] - 1
        if count <= 0
          self.class.functions[:rm_watch].call(fileno, wd)
          drop_wd(wd)
          close if @refs.empty?
        else
          @refs[wd] = count
        end
      end
      self
    end

    def close
      return if closed?
      @watcher.close
      @watcher = nil
      @io.close
      @io = nil
      @handlers.clear
      @refs.clear
      @masks.clear
      @paths.clear
      @loop.__inotify_stopped__(self) if @loop
      @loop = nil
    end

    private

    def fileno
      @io.fileno
    end

    def drop_wd(wd)
      @refs.delete(wd)
      @masks.delete(wd)
      @handlers.delete(wd)
      @paths.delete_if { |_path, w| w == wd }
    end

    def drain
      return if @io.nil?
      begin
        data = @io.read_nonblock(4096)
      rescue EOFError, IO::WaitReadable, Errno::EAGAIN
        return
      end
      return if data.nil? || data.empty?
      dispatch(data)
    end

    # struct inotify_event { int wd; uint32 mask, cookie, len; char name[]; }
    def dispatch(data)
      pos = 0
      while pos + 16 <= data.bytesize
        wd, mask, _cookie, len = data[pos, 16].unpack('l L l L')
        pos += 16
        name = nil
        if len > 0
          name = data[pos, len].to_s.split("\x00", 2).first
          pos += len
        end
        handlers = @mutex.synchronize { @handlers[wd] }
        if (mask & IN_IGNORED) != 0
          # The kernel dropped the watch (file removed, moved away or
          # rm_watch'ed); watchers clear their reference and re-add it
          # when their path exists again.
          @mutex.synchronize { drop_wd(wd) }
        end
        next if handlers.nil? || handlers.empty?
        handlers.dup.each do |watcher|
          begin
            watcher.__inotify_event__(wd, mask, name)
          rescue => e
            @loop.__error__(watcher, e) if @loop
          end
        end
      end
    end
  end
end
