# lib/pii_scrubber.rb
require 'json'
require 'digest'
require 'fileutils'
require 'open3'

class PiiScrubber
  attr_reader :vault, :vault_dir, :salt

  # algorithm: "symmetric" (AES) or "asymmetric" (Pubkey)
  # key_material: Passphrase (for symmetric) or Recipient Email (for asymmetric)
  def initialize(vault_dir:, salt_seed:, algorithm: :symmetric, key_material: nil)
    @vault_dir = vault_dir
    @salt = Digest::SHA256.hexdigest(salt_seed)
    @vault = {}
    @algorithm = algorithm
    @key_material = key_material # Passphrase or Recipient
    
    # Ensure vault dir exists
    FileUtils.mkdir_p(@vault_dir)

    # Load existing vaults
    load_vaults
  end

  def scrub_email(email)
    return nil if email.nil? || email.empty?
    scrub(email, 'email')
  end

  def save!
    save_vaults
  end

  private

  def scrub(original, type)
    # 1. Deterministic Hash (HMAC-like)
    hash = Digest::SHA256.hexdigest("#{@salt}:#{type}:#{original}")
    
    # 2. Check Vault
    if @vault[hash]
      return @vault[hash]
    end

    # 3. Generate Pseudonym if new
    # Taking first 12 chars of hash as ID
    pseudo = "user_#{hash[0..11]}"
    @vault[hash] = pseudo
    
    # We store the reverse mapping too if needed, but here we just need consistency.
    # To support DSR (reverse lookup), we'd store { pseudo => original } in a separate locked file.
    # For now, we just memoize in memory.
    
    pseudo
  end

  # --- GPG Storage Logic ---

  def vault_file
    File.join(@vault_dir, "pii_vault.json.gpg")
  end

  def load_vaults
    return unless File.exist?(vault_file)

    puts "[PiiScrubber] Loading encrypted vault: #{vault_file}"
    
    decrypted_json = gpg_decrypt(vault_file)
    @vault = JSON.parse(decrypted_json)
  rescue JSON::ParserError
    raise "Vault corruption: Decrypted data is not valid JSON."
  end

  def save_vaults
    puts "[PiiScrubber] Saving encrypted vault..."
    json_data = JSON.dump(@vault)
    gpg_encrypt(json_data, vault_file)
  end

  # Robust GPG Wrapper using FD 3 for Passphrase to avoid 'ps' leakage
  def gpg_decrypt(file_path)
    # CMD: gpg --decrypt --batch --yes --pinentry-mode loopback --passphrase-fd 3 <file>
    cmd = %w[gpg --decrypt --batch --yes --pinentry-mode loopback --passphrase-fd 3]
    cmd << file_path

    out, status = Open3.capture2(*cmd, 3 => @key_material) # Pass passphrase on FD 3

    unless status.success?
      raise "GPG Decryption Failed! Check your passphrase/key. (Exit: #{status.exitstatus})"
    end
    out
  end

  def gpg_encrypt(plain_text, output_path)
    if @algorithm == :asymmetric
      # Public Key Mode: No passphrase needed to ENCRYPT, just Recipient
      # CMD: gpg --encrypt --recipient <email> --batch --yes --output <file>
      cmd = %W[gpg --encrypt --recipient #{@key_material} --batch --yes --output #{output_path}]
      
      # We pipe the JSON data into stdin
      out, status = Open3.capture2(*cmd, stdin_data: plain_text)
    else
      # Symmetric Mode: Needs Passphrase
      # CMD: gpg --symmetric --batch --yes --pinentry-mode loopback --passphrase-fd 3 --output <file>
      cmd = %W[gpg --symmetric --batch --yes --pinentry-mode loopback --passphrase-fd 3 --output #{output_path}]
      
      # We pipe JSON to stdin (content) AND Passphrase to FD 3 (auth) simultaneously
      out, status = Open3.capture2(*cmd, stdin_data: plain_text, 3 => @key_material)
    end

    unless status.success?
      raise "GPG Encryption Failed! (Exit: #{status.exitstatus})"
    end
  end
end