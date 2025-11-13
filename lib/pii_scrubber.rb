# frozen_string_literal: true

require 'digest'
require 'json'
require 'fileutils'
require_relative 'vault_guard'

##
# PIIScrubber: Deterministic pseudonymization with encrypted vault storage.
#
# Usage:
#   scrubber = PIIScrubber.new(vault_dir: 'vault/', seed: 42)
#   scrubbed = scrubber.scrub_email(raw_email_text)
#   scrubber.save_vault  # Commit mappings to encrypted vault
#
# Enforces git-crypt encryption via VaultGuard before any vault I/O.
class PIIScrubber
  EMAIL_REGEX = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/
  IP_REGEX = /\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b/
  
  attr_reader :vault_dir, :seed

  def initialize(vault_dir: 'vault/', seed: 42)
    @vault_dir = vault_dir
    @seed = seed
    @email_map = {}
    @ip_map = {}
    @rng = Random.new(seed)

    # ENFORCE: git-crypt must be unlocked before loading/saving vault
    VaultGuard.ensure_unlocked!(vault_dir: vault_dir)

    load_vault
  end

  ##
  # Scrubs email addresses and IPs with deterministic pseudonyms.
  # Same input → same pseudonym (seeded hash).
  def scrub_email(text)
    text = text.dup
    text.gsub!(EMAIL_REGEX) { |email| pseudonymize_email(email) }
    text.gsub!(IP_REGEX) { |ip| pseudonymize_ip(ip) }
    text
  end

  ##
  # Reverse lookup: pseudonym → original (for DSR export).
  # Returns nil if pseudonym not found.
  def reverse_lookup_email(pseudo)
    @email_map.key(pseudo)
  end

  def reverse_lookup_ip(pseudo)
    @ip_map.key(pseudo)
  end

  ##
  # Saves mappings to encrypted vault (git-crypt enforced).
  # Call after scrubbing batch to persist new pseudonyms.
  def save_vault
    VaultGuard.ensure_unlocked!(vault_dir: vault_dir)
    FileUtils.mkdir_p(vault_dir)

    File.write(File.join(vault_dir, 'email_map.json'), JSON.pretty_generate(@email_map))
    File.write(File.join(vault_dir, 'ip_map.json'), JSON.pretty_generate(@ip_map))
    File.write(File.join(vault_dir, 'seed.txt'), @seed.to_s)
  end

  private

  def load_vault
    email_file = File.join(vault_dir, 'email_map.json')
    ip_file = File.join(vault_dir, 'ip_map.json')
    seed_file = File.join(vault_dir, 'seed.txt')

    @email_map = File.exist?(email_file) ? JSON.parse(File.read(email_file)) : {}
    @ip_map = File.exist?(ip_file) ? JSON.parse(File.read(ip_file)) : {}

    if File.exist?(seed_file)
      stored_seed = File.read(seed_file).to_i
      if stored_seed != @seed
        warn "[WARN] Vault seed mismatch: stored=#{stored_seed}, requested=#{@seed}. Using stored."
        @seed = stored_seed
        @rng = Random.new(@seed)
      end
    end
  end

  def pseudonymize_email(email)
    @email_map[email] ||= generate_pseudonym("email_#{email}")
  end

  def pseudonymize_ip(ip)
    @ip_map[ip] ||= generate_pseudonym("ip_#{ip}")
  end

  def generate_pseudonym(input)
    # Deterministic hash: seed + input → stable pseudonym
    hash = Digest::SHA256.hexdigest("#{@seed}:#{input}")[0..15]
    "REDACTED_#{hash}"
  end
end
