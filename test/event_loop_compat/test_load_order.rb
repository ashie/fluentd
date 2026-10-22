#
# Loading the real cool.io extension and the EventLoopCompat Coolio
# namespace in the same process is not supported. These tests run the
# combinations in child processes and check that the unsupported ones
# fail with a clear error instead of leaving a mixed namespace behind.
#

require 'test/unit'
require 'rbconfig'

class EventLoopCompatCoolioLoadOrderTest < Test::Unit::TestCase
  REAL_FIRST_THEN_SHIM = <<~RUBY
    path = Gem::Specification.find_by_name("cool.io").full_require_paths.first
    require File.join(path, "cool.io.rb")
    require "cool.io"
    puts "loaded"
  RUBY

  COMPAT_FIRST_THEN_REAL = <<~RUBY
    require "event_loop_compat/coolio"
    path = Gem::Specification.find_by_name("cool.io").full_require_paths.first
    require File.join(path, "cool.io.rb")
    puts "loaded"
  RUBY

  REAL_FIRST_THEN_COMPAT = <<~RUBY
    path = Gem::Specification.find_by_name("cool.io").full_require_paths.first
    require File.join(path, "cool.io.rb")
    require "event_loop_compat/coolio"
    puts "loaded"
  RUBY

  REAL_FIRST_THEN_COOLIO_ALIAS = <<~RUBY
    path = Gem::Specification.find_by_name("cool.io").full_require_paths.first
    require File.join(path, "cool.io.rb")
    require "coolio"
    puts "loaded"
  RUBY

  COOLIO_ALIAS_WITH_COMPAT_BACKEND = <<~RUBY
    require "coolio"
    puts Coolio::Loop.ancestors.include?(EventLoopCompat::Loop)
  RUBY

  COOLIO_ALIAS_WITH_DEFAULT_BACKEND = <<~RUBY
    require "coolio"
    puts Coolio::Loop.instance_method(:run).source_location.first.include?("cool.io")
  RUBY

  SHIM_WITH_COMPAT_BACKEND = <<~RUBY
    require "cool.io"
    puts Coolio::Loop.ancestors.include?(EventLoopCompat::Loop)
  RUBY

  SHIM_WITH_DEFAULT_BACKEND = <<~RUBY
    require "cool.io"
    puts Coolio::Loop.instance_method(:run).source_location.first.include?("cool.io")
  RUBY

  def test_real_gem_loaded_before_the_shim_with_compat_backend
    status, output = run_child(REAL_FIRST_THEN_SHIM, compat_backend: true)
    assert_not_equal(0, status)
    assert_match(/cool\.io is already loaded/, output)
  end

  def test_real_gem_loaded_before_the_coolio_alias_with_compat_backend
    status, output = run_child(REAL_FIRST_THEN_COOLIO_ALIAS, compat_backend: true)
    assert_not_equal(0, status)
    assert_match(/cool\.io is already loaded/, output)
  end

  def test_coolio_alias_loads_the_compat_namespace_with_compat_backend
    status, output = run_child(COOLIO_ALIAS_WITH_COMPAT_BACKEND, compat_backend: true)
    assert_equal(0, status, output)
    assert_equal('true', output.strip)
  end

  def test_coolio_alias_loads_the_real_gem_with_default_backend
    status, output = run_child(COOLIO_ALIAS_WITH_DEFAULT_BACKEND)
    assert_equal(0, status, output)
    assert_equal('true', output.strip)
  end

  def test_real_gem_loaded_after_the_compat_namespace
    status, output = run_child(COMPAT_FIRST_THEN_REAL)
    assert_not_equal(0, status)
    assert_match(/superclass mismatch for class Coolio::Loop/, output)
  end

  def test_real_gem_loaded_before_the_compat_namespace
    status, output = run_child(REAL_FIRST_THEN_COMPAT)
    assert_not_equal(0, status)
    assert_match(/cool\.io is already loaded/, output)
  end

  def test_shim_loads_the_compat_namespace_with_compat_backend
    status, output = run_child(SHIM_WITH_COMPAT_BACKEND, compat_backend: true)
    assert_equal(0, status, output)
    assert_equal('true', output.strip)
  end

  def test_shim_loads_the_real_gem_with_default_backend
    status, output = run_child(SHIM_WITH_DEFAULT_BACKEND)
    assert_equal(0, status, output)
    assert_equal('true', output.strip)
  end

  private

  def run_child(script, compat_backend: false)
    # The parent process may already have selected a backend; the child
    # has to be told explicitly which one it is testing.
    env = { 'FLUENTD_EVENT_LOOP_BACKEND' => compat_backend ? 'io_event_compat' : nil }

    output = IO.popen([env, RbConfig.ruby, '-Ilib', '-e', script], err: [:child, :out], &:read)
    [$?.exitstatus, output]
  end
end
