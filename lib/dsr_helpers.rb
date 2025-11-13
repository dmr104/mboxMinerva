# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require_relative 'pii_scrubber'
require_relative 'vault_guard'

##
# DSRHelpers: GDPR/CCPA Data Subject Request utilities.
#
# Enforces git-crypt vault encryption before any pseudonym lookups.
module DSRHelpers
  ##
  # Reverse-lookup pseudonyms for a given email (export use case).
  # Returns array of thread_ids containing the email.
  def self.locate_email(email, manifest_path:, vault_dir: 'vault/', seed: 42)
    VaultGuard.ensure_unlocked!(vault_dir: vault_dir)
    scrubber = PIIScrubber.new(vault_dir: vault_dir, seed: seed)
    pseudo = scrubber.instance_variable_get(:@email_map)[email]
    return [] unless pseudo

    manifest = JSON.parse(File.read(manifest_path))
    threads = []
    manifest['threads'].each do |thread|
      threads << thread['thread_id'] if thread['content'].include?(pseudo)
    end
    threads
  end

  ##
  # Write tombstone for a thread_id (deletion use case).
  # Tombstones are plain JSON (no PII), safe to commit unencrypted.
  def self.tombstone_thread(thread_id, manifest_path:, reason: 'DSR deletion')
    tombstone_dir = File.join(File.dirname(manifest_path), 'tombstones')
    FileUtils.mkdir_p(tombstone_dir)

    tombstone = {
      thread_id: thread_id,
      deleted_at: Time.now.utc.iso8601,
      reason: reason
    }

    tombstone_file = File.join(tombstone_dir, "#{thread_id}.json")
    File.write(tombstone_file, JSON.pretty_generate(tombstone))
    tombstone_file
  end

  ##
  # Export thread content with pseudonyms reversed (if vault permits).
  # Returns hash: { thread_id:, content:, reversed: bool }
  def self.export_thread(thread_id, manifest_path:, vault_dir: 'vault/', seed: 42, reverse: true)
    VaultGuard.ensure_unlocked!(vault_dir: vault_dir) if reverse

    manifest = JSON.parse(File.read(manifest_path))
    thread = manifest['threads'].find { |t| t['thread_id'] == thread_id }
    return nil unless thread

    content = thread['content']
    reversed_content = content

    if reverse
      scrubber = PIIScrubber.new(vault_dir: vault_dir, seed: seed)
      email_map = scrubber.instance_variable_get(:@email_map)
      ip_map = scrubber.instance_variable_get(:@ip_map)

      # Reverse substitution: REDACTED_xyz → original
      email_map.each { |orig, pseudo| reversed_content.gsub!(pseudo, orig) }
      ip_map.each { |orig, pseudo| reversed_content.gsub!(pseudo, orig) }
    end

    {
      thread_id: thread_id,
      content: reversed_content,
      reversed: reverse
    }
  end
end
