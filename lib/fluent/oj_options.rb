require 'fluent/config/types'

module Fluent
  class OjOptions
    AVAILABLE_OPTIONS = {
      'bigdecimal_load': :symbol,
      'max_nesting': :integer,
      'mode': :symbol,
      'use_to_json': :bool
    }

    ALLOWED_VALUES = {
      'bigdecimal_load': %i[bigdecimal float auto],
      'mode': %i[strict null compat json rails object custom]
    }

    @@available = false

    def self.init
      begin
        require 'oj'
        Oj.default_options = self.get
        @@available = true
      rescue LoadError
        @@available = false
      end
    end

    def self.available?
      @@available
    end

    private

    def self.get
      options = Fluent::DEFAULT_OJ_OPTIONS.dup
      AVAILABLE_OPTIONS.each do |key, type|
        env_value = ENV["FLUENT_OJ_OPTION_#{key.upcase}"]
        next if env_value.nil?

        cast_value = Fluent::Config.reformatted_value(AVAILABLE_OPTIONS[key], env_value, { strict: true })
        next if cast_value.nil?

        next if ALLOWED_VALUES[key] && !ALLOWED_VALUES[key].include?(cast_value)

        options[key.to_sym] = cast_value
      end

      options
    end
  end
end

Fluent::OjOptions.init
