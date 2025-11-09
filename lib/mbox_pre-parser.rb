#!/usr/bin/env ruby
# mbox_pre-parser.rb - Convert mbox to JSON format compatible with refactored_splitter.rb
# Usage: ruby mbox_pre-parser.rb input.mbox -o output.json
# Output: `[{"message_id": "...", "email_message": "raw RFC 822..."}]`

require 'json'
require 'digest/sha256'
require 'mail'
require 'optparse'

def parse_mbox(mbox_path)
  messages = []
  current_message = []
  in_message = false
  
  File.open(mbox_path, 'r:UTF-8') do |file|
    file.each_line do |line|
      # mbox separator: lines starting with "From " (not "From:")
      if line.start_with?('From ') && !line.start_with?('From:')
        # Save previous message if exists
        if in_message && !current_message.empty?
          messages << current_message.join
          current_message = []
        end
        in_message = true
      else
        current_message << line if in_message
      end
    end
    
    # Save last message
    if in_message && !current_message.empty?
      messages << current_message.join
    end
  end
  
  messages
end

def extract_message_id(raw_email)
  begin
    mail = Mail.new(raw_email)
    msg_id = mail.message_id
    
    # If no Message-ID header, synthesize one from content hash
    if msg_id.nil? || msg_id.empty?
      hash = Digest::SHA256.hexdigest(raw_email)[0..15]
      msg_id = "synthetic-#{hash}@generated"
    end
    
    msg_id
  rescue => e
    # Fallback if parsing fails completely
    hash = Digest::SHA256.hexdigest(raw_email)[0..15]
    "synthetic-#{hash}@generated"
  end
end

# Parse command-line arguments
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ruby Mbox_pre-parser.rb input.mbox -o output.json"
  
  opts.on("-o", "--output FILE", "Output JSON file") do |o|
    options[:output] = o
  end
  
  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end.parse!

if ARGV.empty?
  puts "Error: No input mbox file specified"
  puts "Usage: ruby Mbox_pre-parser.rb input.mbox -o output.json"
  exit 1
end

mbox_path = ARGV[0]
output_path = options[:output] || "output.json"

unless File.exist?(mbox_path)
  puts "Error: File not found: #{mbox_path}"
  exit 1
end

puts "Parsing mbox: #{mbox_path}"
raw_messages = parse_mbox(mbox_path)
puts "Found #{raw_messages.size} messages"

# Convert to required JSON format
json_output = raw_messages.map do |raw_email|
  {
    "message_id" => extract_message_id(raw_email),
    "email_message" => raw_email.strip
  }
end

# Write JSON output
File.open(output_path, 'w') do |f|
  f.write(JSON.pretty_generate(json_output))
end

puts "Output written to: #{output_path}"
puts "Format: [{\"message_id\": \"...\", \"email_message\": \"...\"}, ...]"
puts "Ready for: ruby splitter.rb #{output_path} -o split/"