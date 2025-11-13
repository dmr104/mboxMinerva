#!/usr/bin/env ruby
# mbox_pre-parser.rb - Convert mbox to JSON format compatible with refactored_splitter.rb
# Usage: ruby mbox_pre-parser.rb input.mbox -o output.json [--cohort YYYY-MM]
# Output: `[{"message_id": "...", "thread_id": "...", "cohort_id": "...", "email_message": "raw RFC 822..."}]`

require 'json'
require 'digest/sha256'
require 'mail'
require 'optparse'
require 'date'

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

def normalize_subject(subject)
  # Strip Re:, Fwd:, Fw:, etc. and whitespace for subject-based threading
  return "" if subject.nil? || subject.empty?
  subject.gsub(/^(re|fwd?|aw):\s*/i, '').strip.downcase
end

def derive_thread_id(mail, message_id)
  # Threading strategy:
  # 1. Use first References header ID (root of thread)
  # 2. Else use In-Reply-To
  # 3. Else use normalized Subject hash
  # 4. Else use message_id itself (new thread)
  
  begin
    # Try References header (oldest ancestor)
    if mail.references && !mail.references.empty?
      return mail.references.first.to_s.strip
    end
    
    # Try In-Reply-To header
    if mail.in_reply_to && !mail.in_reply_to.empty?
      in_reply = mail.in_reply_to.is_a?(Array) ? mail.in_reply_to.first : mail.in_reply_to
      return in_reply.to_s.strip
    end
    
    # Fallback to normalized subject hash
    subject = mail.subject
    if subject && !subject.empty?
      normalized = normalize_subject(subject)
      if !normalized.empty?
        return "subject-#{Digest::SHA256.hexdigest(normalized)[0..15]}"
      end
    end
    
    # Final fallback: this message starts a new thread
    return message_id
  rescue => e
    # On any parse error, treat as new thread
    return message_id
  end
end

def stamp_cohort_id(mail, mbox_path, override_cohort)
  # Cohort stamping strategy:
  # 1. Use --cohort override if provided
  # 2. Else parse Date: header from email
  # 3. Else use mbox file mtime as fallback
  
  return override_cohort if override_cohort
  
  begin
    # Try Date: header
    if mail.date
      return mail.date.strftime('%Y-%m')
    end
  rescue => e
    # Parse error, fall through to mtime
  end
  
  # Fallback to file modification time
  File.mtime(mbox_path).strftime('%Y-%m')
end

# Parse command-line arguments
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ruby mbox_pre-parser.rb input.mbox -o output.json [--cohort YYYY-MM]"
  
  opts.on("-o", "--output FILE", "Output JSON file") do |o|
    options[:output] = o
  end
  
  opts.on("--cohort COHORT", "Override cohort_id (YYYY-MM format)") do |c|
    options[:cohort] = c
  end
  
  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end.parse!

if ARGV.empty?
  puts "Error: No input mbox file specified"
  puts "Usage: ruby mbox_pre-parser.rb input.mbox -o output.json [--cohort YYYY-MM]"
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

# Convert to required JSON format with threading and cohort
json_output = raw_messages.map do |raw_email|
  mail = Mail.new(raw_email)
  message_id = extract_message_id(raw_email)
  thread_id = derive_thread_id(mail, message_id)
  cohort_id = stamp_cohort_id(mail, mbox_path, options[:cohort])
  
  {
    "message_id" => message_id,
    "thread_id" => thread_id,
    "cohort_id" => cohort_id,
    "email_message" => raw_email.strip
  }
end

# Write JSON output
File.open(output_path, 'w') do |f|
  f.write(JSON.pretty_generate(json_output))
end

puts "Output written to: #{output_path}"
puts "Messages: #{json_output.size}"

# Thread statistics
thread_counts = json_output.group_by { |m| m["thread_id"] }.transform_values(&:size)
puts "Unique threads: #{thread_counts.size}"
puts "Largest thread: #{thread_counts.values.max} messages"

# Cohort statistics
cohort_counts = json_output.group_by { |m| m["cohort_id"] }.transform_values(&:size)
puts "Cohorts: #{cohort_counts.keys.sort.join(', ')}"

puts "Ready for: ruby splitter.rb -i #{output_path} -o splits/ --pin YYYY-MM"