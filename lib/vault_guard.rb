# frozen_string_literal: true

require 'fileutils'
require 'open3'

##
# VaultGuard: Enforces git-crypt encryption for vault/ before any I/O.
#
# Usage:
#   VaultGuard.ensure_unlocked!(vault_dir: 'vault/')
#
# Raises RuntimeError if:
#   - git-crypt is not installed
#   - vault/ is locked (encrypted on disk)
#   - .git-crypt/ keyring is missing (repo not initialized)
#
# Security rationale:
#   Fail-fast prevents accidental writes to locked vault (would corrupt
#   encrypted files) or reads of uninitialized vault (leaks plaintext).
module VaultGuard
  DEFAULT_VAULT_DIR = 'vault'

  class << self
    ##
    # Ensures vault is unlocked and git-crypt is operational.
    # Raises RuntimeError with actionable message if checks fail.
    def ensure_unlocked!(vault_dir: DEFAULT_VAULT_DIR)
      check_git_crypt_installed!
      check_repo_initialized!
      check_vault_unlocked!(vault_dir)
    end

    private

    def check_git_crypt_installed!
      stdout, status = Open3.capture2('git-crypt', '--version')
      return if status.success?

      raise <<~ERROR
        git-crypt not found. Install via:
          Debian/Ubuntu: sudo apt-get install git-crypt
          macOS:         brew install git-crypt
          RHEL/CentOS:   sudo yum install git-crypt
      ERROR
    rescue Errno::ENOENT
      raise 'git-crypt not found in PATH. Install git-crypt first.'
    end

    def check_repo_initialized!
      return if File.directory?('.git-crypt')

      raise <<~ERROR
        git-crypt not initialized. Run:
          git-crypt init
          git-crypt export-key .git-crypt-key
        Store .git-crypt-key securely (e.g., password manager, CI secret).
        Collaborators unlock via: git-crypt unlock .git-crypt-key
      ERROR
    end

    def check_vault_unlocked!(vault_dir)
      # Create vault/ if missing (first run)
      FileUtils.mkdir_p(vault_dir) unless Dir.exist?(vault_dir)

      # Write sentinel file and check if it's encrypted
      sentinel = File.join(vault_dir, '.unlock_check')
      File.write(sentinel, 'unlocked')
      content = File.binread(sentinel)

      # If git-crypt is locked, file will contain binary garbage (NUL bytes)
      if content.include?("\x00") || content != 'unlocked'
        raise <<~ERROR
          vault/ is LOCKED (encrypted on disk). Unlock via:
            git-crypt unlock .git-crypt-key
          Then retry. Never commit while locked (corrupts encrypted files).
        ERROR
      end
    ensure
      File.delete(sentinel) if sentinel && File.exist?(sentinel)
    end
  end
end