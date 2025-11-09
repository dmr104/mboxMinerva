# lib/dsr_helpers.rb
# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'pii_scrubber'

module DSRHelpers
  # Load pseudonym vault from disk
  def self.load_vault(vault_path = 'vault/pseudonym_map.json')
    return {} unless File.exist?(vault_path)
    JSON.parse(File.read(vault_path))
  end

  # Reverse lookup: given a real email/identifier, find pseudonym
  def self.find_pseudonym(real_identifier, vault)
    vault.each do |pseudo, real|
      return pseudo if real == real_identifier
    end
    nil
  end

  # Match a record by subject (real email or pseudonym)
  def self.record_matches?(record, subject, vault)
    # Check direct pseudonym match
    return true if record['from']&.include?(subject)
    return true if record['to']&.any? { |addr| addr.include?(subject) }
    return true if record['cc']&.any? { |addr| addr.include?(subject) }

    # Check reverse vault lookup (if subject is a real identifier)
    pseudo = find_pseudonym(subject, vault)
    return false unless pseudo

    record['from']&.include?(pseudo) ||
      record['to']&.any? { |addr| addr.include?(pseudo) } ||
      record['cc']&.any? { |addr| addr.include?(pseudo) }
  end

  # Collect all thread members from a manifest
  def self.collect_thread_members(manifest_path, thread_id)
    members = []
    File.foreach(manifest_path) do |line|
      record = JSON.parse(line.strip)
      members << record if record['thread_id'] == thread_id
    end
    members
  end

  # Load existing tombstones
  def self.load_tombstones(tombstone_path = 'vault/dsr_tombstones.jsonl')
    return Set.new unless File.exist?(tombstone_path)
    File.readlines(tombstone_path).map { |l| JSON.parse(l.strip)['message_id'] }.to_set
  end

  # Append tombstones
  def self.append_tombstones(tombstones, tombstone_path = 'vault/dsr_tombstones.jsonl')
    FileUtils.mkdir_p('vault')
    File.open(tombstone_path, 'a') do |f|
      tombstones.each { |ts| f.puts(ts.to_json) }
    end
  end
end
