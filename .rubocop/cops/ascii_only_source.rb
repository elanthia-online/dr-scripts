# frozen_string_literal: true

module RuboCop
  module Cop
    module Custom
      # Checks source files for non-ASCII characters and escape sequences that
      # produce non-ASCII output at runtime.
      class AsciiOnlySource < Base
        extend AutoCorrector
        include RangeHelp

        MSG = 'Use only ASCII characters and ASCII-producing escapes in source files.'

        UNICODE_BRACE_ESCAPE = /\\u\{[0-9a-fA-F\s]+\}/
        UNICODE_SHORT_ESCAPE = /\\u[0-9a-fA-F]{4}/
        HEX_ESCAPE = /\\x[0-9a-fA-F]{2}/

        REPLACEMENTS = {
          "\u2713" => 'ok',
          "\u2717" => 'x',
          "\u2605" => '*',
          "\u2606" => '-',
          "\u26A0" => 'warning',
          "\uFE0F" => '',
          "\u00A0" => ' ',
          "\u00AD" => '',
          "\u00A9" => '(c)',
          "\u00AE" => '(r)',
          "\u200B" => '',
          "\u2013" => '-',
          "\u2014" => '-',
          "\u2022" => '*',
          "\u2026" => '...',
          "\u2122" => 'TM',
          "\u2190" => '<-',
          "\u2192" => '->',
          "\u2500" => '-',
          "\u00D7" => 'x',
          "\uFEFF" => ''
        }.freeze

        ESCAPE_REPLACEMENTS = {
          '\u2713' => 'ok',
          '\u2717' => 'x',
          '\u2605' => '*',
          '\u2606' => '-',
          '\u26A0' => 'warning',
          '\uFE0F' => ''
        }.freeze

        UTF8_ESCAPE_REPLACEMENTS = {
          '\xC2\xA0' => ' ',
          '\xC2\xA9' => '(c)',
          '\xC2\xAD' => '',
          '\xC2\xAE' => '(r)',
          '\xC3\x97' => 'x',
          '\xE2\x80\x8B' => '',
          '\xE2\x80\x93' => '-',
          '\xE2\x80\x94' => '-',
          '\xE2\x80\x98' => nil,
          '\xE2\x80\x99' => nil,
          '\xE2\x80\x9C' => nil,
          '\xE2\x80\x9D' => nil,
          '\xE2\x80\xA2' => '*',
          '\xE2\x80\xA6' => '...',
          '\xE2\x84\xA2' => 'TM',
          '\xE2\x86\x90' => '<-',
          '\xE2\x86\x92' => '->',
          '\xE2\x94\x80' => '-',
          '\xEF\xBB\xBF' => ''
        }.freeze

        def on_new_investigation
          processed_source.lines.each_with_index do |line, index|
            inspect_line(line, index + 1)
          end
        end

        private

        def inspect_line(line, line_number)
          add_raw_non_ascii_offenses(line, line_number)
          return if line.lstrip.start_with?('#')

          ignored_ranges = add_utf8_escape_sequence_offenses(line, line_number)
          add_escape_offenses(line, line_number, UNICODE_SHORT_ESCAPE) { |token| unicode_short_non_ascii?(token) }
          add_escape_offenses(line, line_number, UNICODE_BRACE_ESCAPE) { |token| unicode_brace_non_ascii?(token) }
          add_escape_offenses(line, line_number, HEX_ESCAPE, ignored_ranges) { |token| hex_non_ascii?(token) }
        end

        def add_raw_non_ascii_offenses(line, line_number)
          scan_ranges(line) { |char| !char.ascii_only? }.each do |start_column, length|
            token = line.chars.slice(start_column, length).join
            add_ascii_offense(line_number, start_column, length, correction_for_raw(token))
          end
        end

        def add_utf8_escape_sequence_offenses(line, line_number)
          ignored_ranges = []

          UTF8_ESCAPE_REPLACEMENTS.each_key do |sequence|
            pattern = /#{Regexp.escape(sequence)}/i
            line.to_enum(:scan, pattern).each do
              token = Regexp.last_match(0)
              start_column = Regexp.last_match.begin(0)
              next unless active_escape?(line, start_column)

              ignored_ranges << (start_column...(start_column + token.length))
              add_ascii_offense(
                line_number,
                start_column,
                token.length,
                correction_for_utf8_escape(token)
              )
            end
          end

          ignored_ranges
        end

        def add_escape_offenses(line, line_number, pattern, ignored_ranges = [])
          line.to_enum(:scan, pattern).each do
            token = Regexp.last_match(0)
            start_column = Regexp.last_match.begin(0)
            next if range_covered?(start_column, ignored_ranges)
            next unless active_escape?(line, start_column)
            next unless yield(token)

            add_ascii_offense(
              line_number,
              start_column,
              token.length,
              correction_for_escape(token)
            )
          end
        end

        def add_ascii_offense(line_number, column, length, correction)
          range = source_range(processed_source.buffer, line_number, column, length)

          add_offense(range, message: MSG) do |corrector|
            corrector.replace(range, correction) unless correction.nil?
          end
        end

        def scan_ranges(line)
          ranges = []
          current_start = nil
          current_length = 0

          line.each_char.with_index do |char, column|
            if yield(char)
              current_start ||= column
              current_length += 1
            elsif current_start
              ranges << [current_start, current_length]
              current_start = nil
              current_length = 0
            end
          end

          ranges << [current_start, current_length] if current_start
          ranges
        end

        def unicode_short_non_ascii?(token)
          token.delete_prefix('\u').to_i(16) > 0x7F
        end

        def unicode_brace_non_ascii?(token)
          token.delete_prefix('\u{').delete_suffix('}').split.any? do |codepoint|
            codepoint.to_i(16) > 0x7F
          end
        end

        def hex_non_ascii?(token)
          token.delete_prefix('\x').to_i(16) > 0x7F
        end

        def active_escape?(line, start_column)
          backslashes = 0
          column = start_column

          while column >= 0 && line[column] == '\\'
            backslashes += 1
            column -= 1
          end

          backslashes.odd?
        end

        def range_covered?(column, ranges)
          ranges.any? { |range| range.cover?(column) }
        end

        def correction_for_raw(token)
          corrections = token.each_char.map { |char| REPLACEMENTS[char] }
          return nil if corrections.any?(&:nil?)

          corrections.join
        end

        def correction_for_escape(token)
          return ESCAPE_REPLACEMENTS[token] if ESCAPE_REPLACEMENTS.key?(token)

          correction_for_brace_escape(token) if token.start_with?('\u{')
        end

        def correction_for_utf8_escape(token)
          UTF8_ESCAPE_REPLACEMENTS[normalized_hex_sequence(token)]
        end

        def normalized_hex_sequence(token)
          token.scan(/[0-9a-fA-F]{2}/).map { |byte| "\\x#{byte.upcase}" }.join
        end

        def correction_for_brace_escape(token)
          chars = token.delete_prefix('\u{').delete_suffix('}').split.map do |codepoint|
            codepoint.to_i(16).chr(Encoding::UTF_8)
          end

          correction_for_raw(chars.join)
        rescue RangeError
          nil
        end
      end
    end
  end
end
