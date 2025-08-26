# frozen_string_literal: true

require "active_support/core_ext/object/duplicable"
require "active_support/core_ext/array/extract"

module ActiveSupport
  # Simple LRU cache implementation for caching regexp matches
  class LRUCache # :nodoc:
    def initialize(max_size)
      @max_size = max_size
      @cache = {}
      @order = []
    end

    def get(key)
      if @cache.key?(key)
        refresh(key)
        @cache[key]
      end
    end

    def set(key, value)
      if @cache.key?(key)
        @cache[key] = value
        refresh(key)
      else
        if @order.size >= @max_size
          oldest = @order.shift
          @cache.delete(oldest)
        end
        @cache[key] = value
        @order << key
      end
    end

    private

    def refresh(key)
      @order.delete(key)
      @order << key
    end
  end

  # = Active Support Parameter Filter
  #
  # +ParameterFilter+ replaces values in a <tt>Hash</tt>-like object if their
  # keys match one of the specified filters.
  #
  # Matching based on nested keys is possible by using dot notation, e.g.
  # <tt>"credit_card.number"</tt>.
  #
  # If a proc is given as a filter, each key and value of the <tt>Hash</tt>-like
  # and of any nested <tt>Hash</tt>es will be passed to it. The value or key can
  # then be mutated as desired using methods such as <tt>String#replace</tt>.
  #
  #   # Replaces values with "[FILTERED]" for keys that match /password/i.
  #   ActiveSupport::ParameterFilter.new([:password])
  #
  #   # Replaces values with "[FILTERED]" for keys that match /foo|bar/i.
  #   ActiveSupport::ParameterFilter.new([:foo, "bar"])
  #
  #   # Replaces values for the exact key "pin" and for keys that begin with
  #   # "pin_". Does not match keys that otherwise include "pin" as a
  #   # substring, such as "shipping_id".
  #   ActiveSupport::ParameterFilter.new([/\Apin\z/, /\Apin_/])
  #
  #   # Replaces the value for :code in `{ credit_card: { code: "xxxx" } }`.
  #   # Does not change `{ file: { code: "xxxx" } }`.
  #   ActiveSupport::ParameterFilter.new(["credit_card.code"])
  #
  #   # Reverses values for keys that match /secret/i.
  #   ActiveSupport::ParameterFilter.new([-> (k, v) do
  #     v.reverse! if /secret/i.match?(k)
  #   end])
  #
  class ParameterFilter
    FILTERED = "[FILTERED]" # :nodoc:
    DEFAULT_CACHE_SIZE = 100 # :nodoc:

    # Precompiles an array of filters that otherwise would be passed directly to
    # #initialize. Depending on the quantity and types of filters,
    # precompilation can improve filtering performance, especially in the case
    # where the ParameterFilter instance itself cannot be retained (but the
    # precompiled filters can be retained).
    #
    #   filters = [/foo/, :bar, "nested.baz", /nested\.qux/]
    #
    #   precompiled = ActiveSupport::ParameterFilter.precompile_filters(filters)
    #   # => [/(?-mix:foo)|(?i:bar)/, /(?i:nested\.baz)|(?-mix:nested\.qux)/]
    #
    #   ActiveSupport::ParameterFilter.new(precompiled)
    #
    def self.precompile_filters(filters)
      filters, patterns = filters.partition { |filter| filter.is_a?(Proc) }

      patterns.map! do |pattern|
        pattern.is_a?(Regexp) ? pattern : "(?i:#{Regexp.escape pattern.to_s})"
      end

      deep_patterns = patterns.extract! { |pattern| pattern.to_s.include?("\\.") }

      filters << Regexp.new(patterns.join("|")) if patterns.any?
      filters << Regexp.new(deep_patterns.join("|")) if deep_patterns.any?

      filters
    end

    # Create instance with given filters. Supported type of filters are +String+, +Regexp+, and +Proc+.
    # Other types of filters are treated as +String+ using +to_s+.
    # For +Proc+ filters, key, value, and optional original hash is passed to block arguments.
    #
    # ==== Options
    #
    # * <tt>:mask</tt> - A replaced object when filtered. Defaults to <tt>"[FILTERED]"</tt>.
    # * <tt>:cache_size</tt> - Size of the regexp matching cache. Defaults to 100. Set to 0 to disable caching.
    def initialize(filters = [], mask: FILTERED, cache_size: DEFAULT_CACHE_SIZE)
      @mask = mask
      @regexp_cache = cache_size > 0 ? LRUCache.new(cache_size) : nil
      compile_filters!(filters)
    end

    # Mask value of +params+ if key matches one of filters.
    def filter(params)
      @no_filters ? params.dup : call(params)
    end

    # Returns filtered value for given key. For +Proc+ filters, third block argument is not populated.
    def filter_param(key, value)
      @no_filters ? value : value_for_key(key, value)
    end

  private
    def compile_filters!(filters)
      @no_filters = filters.empty?
      return if @no_filters

      @regexps, strings = [], []
      @deep_regexps, deep_strings = nil, nil
      @blocks = nil

      filters.each do |item|
        case item
        when Proc
          (@blocks ||= []) << item
        when Regexp
          if item.to_s.include?("\\.")
            (@deep_regexps ||= []) << item
          else
            @regexps << item
          end
        else
          s = Regexp.escape(item.to_s)
          if s.include?("\\.")
            (deep_strings ||= []) << s
          else
            strings << s
          end
        end
      end

      @regexps << Regexp.new(strings.join("|"), true) unless strings.empty?
      (@deep_regexps ||= []) << Regexp.new(deep_strings.join("|"), true) if deep_strings

      # Combine all regexps into a single regexp for faster matching
      @combined_regexp = @regexps.size == 1 ? @regexps.first :
                        @regexps.empty? ? nil : Regexp.union(@regexps)
    end

    def call(params, full_parent_key = nil, original_params = params)
      filtered_params = params.class.new

      params.each do |key, value|
        filtered_params[key] = value_for_key(key, value, full_parent_key, original_params)
      end

      filtered_params
    end

    def value_for_key(key, value, full_parent_key = nil, original_params = nil)
      if @deep_regexps
        full_key = full_parent_key ? "#{full_parent_key}.#{key}" : key.to_s
      end

      if regexp_matches_key?(key.to_s)
        value = @mask
      elsif @deep_regexps&.any? { |r| r.match?(full_key) }
        value = @mask
      elsif value.is_a?(Hash)
        value = call(value, full_key, original_params)
      elsif value.is_a?(Array)
        value = value.map { |v| value_for_key(key, v, full_parent_key, original_params) }
      elsif @blocks
        key = key.dup if key.duplicable?
        value = value.dup if value.duplicable?
        @blocks.each { |b| b.arity == 2 ? b.call(key, value) : b.call(key, value, original_params) }
      end

      value
    end

    def regexp_matches_key?(key_str)
      return false unless @combined_regexp

      if @regexp_cache
        cached_result = @regexp_cache.get(key_str)
        return cached_result unless cached_result.nil?
      end

      result = @combined_regexp.match?(key_str)
      @regexp_cache&.set(key_str, result)
      result
    end
  end
end
