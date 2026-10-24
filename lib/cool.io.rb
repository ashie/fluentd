#
# Load-path shim for external plugins that do `require 'cool.io'`.
#
# With FLUENTD_EVENT_LOOP_BACKEND=io_event_compat it loads the
# EventLoopCompat Coolio namespace. Otherwise it loads the real cool.io
# gem by absolute path so this file can shadow the gem without hiding it
# from the default backend.
#

if defined?(::Coolio::Loop)
  # Something already defined the Coolio namespace. Loading it twice is
  # fine only when it is the compatibility namespace; the real cool.io
  # extension cannot be mixed with the io_event_compat backend, because
  # its watchers cannot be attached to an EventLoopCompat::Loop.
  if ENV['FLUENTD_EVENT_LOOP_BACKEND'] == 'io_event_compat'
    require 'event_loop_compat'
    unless ::Coolio::Loop < EventLoopCompat::Loop
      raise LoadError, "cool.io is already loaded; the io_event_compat backend needs the EventLoopCompat Coolio namespace instead of the cool.io gem"
    end
  end
elsif ENV['FLUENTD_EVENT_LOOP_BACKEND'] == 'io_event_compat'
  require 'event_loop_compat'
  require 'event_loop_compat/coolio'
else
  begin
    spec = Gem::Specification.find_by_name('cool.io')
  rescue Gem::MissingSpecError
    raise LoadError, "cannot load such file -- cool.io"
  end

  path = spec.full_require_paths.map { |dir| File.join(dir, 'cool.io.rb') }.find { |file| File.exist?(file) }
  raise LoadError, "cannot load such file -- cool.io" unless path

  require path
end
