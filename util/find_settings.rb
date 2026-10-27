#!/usr/bin/env ruby

class Message
  @@ERROR_MESSAGES = {
    "TEST_OUTPUT_ERROR_MESSAGE" => "Test Error Message",
    "USAGE"                     => "Please rephrase that command. ;)\n" +
                                   "Correct Usage: ./find_settings.rb /path/to/lich/scripts/scriptName.lic",
    "REQUIRE_NOT_ALLOWED"       => "This script is intended to only be called directly.",
    "INVALID_MESSAGE_TYPE"      => "Internal Error: Invalid Message Type Specified",
    "INPUT_FILE_IS_NOT_A_FILE"  => "Input filepath is not a file we can find."
  }

  @@OUTPUT_MESSAGES = {
    "TEST_OUTPUT_MESSAGE" => "Test Output Message"
  }

  @@ALL_MESSAGES = @@ERROR_MESSAGES.merge(@@OUTPUT_MESSAGES)

  def self.send_output_message(message)
    puts(message)
  end

  def self.send_error_message(message)
    STDERR.puts("Error: #{message}")
  end

  def self.is_message_type_valid?(type)
    return @@ALL_MESSAGES.key?(type)
  end

  def self.compute_message(type, extra)
    message = nil
    message = @@ERROR_MESSAGES[type] if @@ERROR_MESSAGES.key?(type)
    message = @@OUTPUT_MESSAGES[type] if @@OUTPUT_MESSAGES.key?(type)
    message = @@ERROR_MESSAGES["INVALID_MESSAGE_TYPE"] if not is_message_type_valid?(type)
    message = message + " (#{extra})" if extra != nil
    return message
  end

  def self.send(type:, exit_after: false, extra: nil)
    type = type.upcase().strip()
    message = compute_message(type, extra)
    send_error_message(message) if @@ERROR_MESSAGES.key?(type)
    send_output_message(message) if @@OUTPUT_MESSAGES.key?(type)
    exit 1 if exit_after
  end
end

def usage()
  Message::send(type: "USAGE", exit_after: true)
end

def does_line_contain_settings_variables?(line)
  return line.match?(/ ?= ?get_settings\(?/)
end

def does_line_contain_settings?(line, var)
  return nil if line.strip().match?(/^#/)
  return line.match?(/#{Regexp.escape(var)}\./)
end

def get_settings_in_line(line, var)
  return line.match(/#{Regexp.escape(var)}\.(\w+(\[['"]?\w+['"]?\]){0,})/).captures
end

def does_line_contain_setting?(line, setting)
  return nil if line.strip().match?(/^#/)
  return line.strip().match?(/^.*\.#{Regexp.escape(setting)}.*$/)
end

def main()
  usage() if ARGV.length != 1
  Message::send(type: "INPUT_FILE_IS_NOT_A_FILE", exit_after: true, extra: ARGV[0]) \
      if not File.file?(ARGV[0])

  filepath = ARGV[0].strip()
  filepath = File.absolute_path(filepath)

  settings_vars_used = []
  settings_used = {}

  File.open(filepath, 'r') do |fd|
    fd.each_line.with_index(1) do |line, _number|
      line = line.strip()
      var = line.split('=')[0].strip() if does_line_contain_settings_variables?(line)
      settings_vars_used.push(var) if var != nil
    end

    fd.seek(0)

    fd.each_line.with_index(1) do |line, _number|
      settings_vars_used.each do |var|
        line = line.strip()
        if does_line_contain_settings?(line, var)
          settings_list = get_settings_in_line(line, var)
          next if settings_list == nil
          settings_list.each do |setting|
            next if setting == nil or setting == "" or setting.match?(/^\[/) or \
                    setting == "each" or settings_used.include?(setting)
            settings_used[setting] = nil
          end
        end
      end
    end

    fd.seek(0)

    fd.each_line.with_index(1) do |line, number|
      number = number.to_s.rjust(5)
      settings_used_copy = Marshal.load(Marshal.dump(settings_used))
      settings_used_copy.each_key do |setting|
        if settings_used[setting] == nil
          settings_used[setting] = "#{number}: #{line.strip()}" \
                if does_line_contain_setting?(line, setting)
        else
          settings_used[setting] += "\n#{number}: #{line.strip()}" \
                if does_line_contain_setting?(line, setting)
        end
      end
    end
  end

  settings_used.sort.each do |setting, lines|
    puts("===== #{setting} =====\n\n")
    puts(lines)
    puts("\n")
  end
end

if __FILE__ == $0
  main()
else
  Message::send(type: "REQUIRE_NOT_ALLOWED", exit_after: true)
end
