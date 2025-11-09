# lib/pii_scrubber.rb
# frozen_string_literal: true

require 'digest'
require 'json'

class PIIScrubber
  # Known PII patterns
  EMAIL_REGEX = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/
  PHONE_REGEX = /\b(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b/
  SSN_REGEX = /\b\d{3}-\d{2}-\d{4}\b/
  CREDIT_CARD_REGEX = /\b(?:\d{4}[\s-]?){3}\d{4}\b/
  IP_ADDRESS_REGEX = /\b(?:\d{1,3}\.){3}\d{1,3}\b/
  
  # Map to store pseudonym mappings for reversibility (optional)
  attr_reader :pseudonym_map
  
  def initialize(seed: 42, deterministic: true)
    @seed = seed
    @deterministic = deterministic
    @pseudonym_map = {}
  end
  
  # Main scrubbing method
  def scrub(text)
    return text if text.nil? || text.empty?
    
    scrubbed = text.dup
    
    # Scrub emails
    scrubbed.gsub!(EMAIL_REGEX) { |match| pseudonymize_email(match) }
    
    # Scrub phone numbers
    scrubbed.gsub!(PHONE_REGEX) { |_| '<PHONE>' }
    
    # Scrub SSNs
    scrubbed.gsub!(SSN_REGEX) { |_| '<SSN>' }
    
    # Scrub credit cards
    scrubbed.gsub!(CREDIT_CARD_REGEX) { |_| '<CREDIT_CARD>' }
    
    # Scrub IP addresses (optional - may have false positives)
    scrubbed.gsub!(IP_ADDRESS_REGEX) { |match| pseudonymize_ip(match) }
    
    scrubbed
  end
  
  # Process an entire message hash
  def scrub_message(message)
    scrubbed = message.dup
    
    # Scrub text fields
    %w[subject body].each do |field|
      scrubbed[field] = scrub(scrubbed[field]) if scrubbed[field]
    end
    
    # Optionally scrub sender/recipient (or just hash them)
    if scrubbed['from']
      scrubbed['from'] = pseudonymize_email(scrubbed['from'])
    end
    
    if scrubbed['to']
      scrubbed['to'] = scrubbed['to'].is_a?(Array) ? 
        scrubbed['to'].map { |addr| pseudonymize_email(addr) } :
        pseudonymize_email(scrubbed['to'])
    end
    
    scrubbed
  end
  
  private
  
  def pseudonymize_email(email)
    return email if @pseudonym_map.key?(email)
    
    if @deterministic
      # Deterministic hash-based pseudonym
      hash = Digest::SHA256.hexdigest("#{email}-#{@seed}")[0..7]
      @pseudonym_map[email] = "user_#{hash}@example.com"
    else
      # Random pseudonym
      @pseudonym_map[email] = "user_#{SecureRandom.hex(4)}@example.com"
    end
    
    @pseudonym_map[email]
  end
  
  def pseudonymize_ip(ip)
    return ip if @pseudonym_map.key?(ip)
    
    if @deterministic
      hash = Digest::SHA256.hexdigest("#{ip}-#{@seed}")[0..7]
      @pseudonym_map[ip] = "10.0.#{hash[0..1].to_i(16) % 256}.#{hash[2..3].to_i(16) % 256}"
    else
      @pseudonym_map[ip] = "10.0.#{rand(256)}.#{rand(256)}"
    end
    
    @pseudonym_map[ip]
  end
end

# CLI usage
if __FILE__ == $PROGRAM_NAME
  require 'optparse'
  
  options = { seed: 42, deterministic: true }
  
  OptionParser.new do |opts|
    opts.banner = "Usage: pii_scrubber.rb [options] INPUT_JSON OUTPUT_JSON"
    
    opts.on("-s", "--seed SEED", Integer, "Seed for deterministic pseudonymization (default: 42)") do |s|
      options[:seed] = s
    end
    
    opts.on("-r", "--[no-]deterministic", "Use deterministic pseudonymization (default: true)") do |d|
      options[:deterministic] = d
    end
    
    opts.on("--save-map FILE", "Save pseudonym map to FILE (JSON)") do |f|
      options[:map_file] = f
    end
  end.parse!
  
  if ARGV.size < 2
    puts "Error: INPUT_JSON and OUTPUT_JSON required"
    exit 1
  end
  
  input_file, output_file = ARGV
  
  scrubber = PIIScrubber.new(seed: options[:seed], deterministic: options[:deterministic])
  
  # Process input
  data = JSON.parse(File.read(input_file))
  
  scrubbed_data = if data.is_a?(Array)
    data.map { |msg| scrubber.scrub_message(msg) }
  else
    scrubber.scrub_message(data)
  end
  
  # Write output
  File.write(output_file, JSON.pretty_generate(scrubbed_data))
  
  # Optionally save map
  if options[:map_file]
    File.write(options[:map_file], JSON.pretty_generate(scrubber.pseudonym_map))
  end
  
  puts "Scrubbed #{data.is_a?(Array) ? data.size : 1} messages -> #{output_file}"
  puts "Pseudonym map saved to #{options[:map_file]}" if options[:map_file]
end