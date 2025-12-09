source 'https://rubygems.org'

# Ruby 3.4.7 (Oct 2025) Compatibility Set
# ---------------------------------------

# Core Email Parsing (Pinned for Thread safety)
gem 'mail', '~> 2.8'

# Database for RAG/Context (Requires libpq-dev in Dockerfile)
gem 'pg', '~> 1.5'

# Contamination Guard (SimHash/Jaccard)
gem 'simhash', '~> 0.1'

# Unbundled Gems (MANDATORY for Ruby 3.1+)
gem 'net-smtp', require: false
gem 'net-imap', require: false
gem 'net-pop', require: false
gem 'psych', '~> 5.1'

# Unbundled Gems (MANDATORY for Ruby 3.4+)
# Base64 and CSV are effectively "bundled" but best declared explicitly for Bundler
gem 'base64'
gem 'csv'
gem 'logger'
gem 'open3'