#!/usr/bin/env ruby
# frozen_string_literal: true

# bin/metrics_watcher.rb
# KPI = key performance indicator
# Computes KPIs (exclusion backlog, contamination drift, split distribution)
# and fires email/Slack/webhook alerts when thresholds are breached.
#
# Usage:
#   bin/metrics_watcher.rb --config config/alerts.yml --manifest data/manifest.jsonl
#
# Schedule via cron or GitLab CI (daily or weekly):
#   0 9 * * 1 cd /app && bin/metrics_watcher.rb --config config/alerts.yml

require 'json'
require 'yaml'
require 'digest'
require 'net/http'
require 'net/smtp'
require 'uri'
require 'optparse'
require 'time'

class MetricsWatcher
  def initialize(config_path:, manifest_path:, splits_dir: 'data/splits', pin: nil)
    @config = YAML.load_file(config_path)
    @manifest_path = manifest_path
    @splits_dir = splits_dir
    @pin = pin || @config.dig('defaults', 'pin')
    @stats = {}
  end

  def run
    puts "[#{Time.now.iso8601}] Starting metrics watch..."
    
    # Compute all KPIs
    compute_exclusion_backlog
    compute_split_distribution
    compute_contamination_drift
    compute_tombstone_count
    
    # Check thresholds and fire alerts
    check_alerts
    
    puts "[#{Time.now.iso8601}] Metrics watch complete."
    puts JSON.pretty_generate(@stats)
  end

  private

  def compute_exclusion_backlog
    manifest = load_manifest(@manifest_path)
    total_rows = manifest.size
    
    # Count rows excluded by pin filter
    excluded_by_pin = manifest.count { |row| row['cohort_id'] && row['cohort_id'] > @pin }
    
    # Count quarantined rows (if exclusion_ids.txt exists)
    quarantined = 0
    exclusion_file = File.join(@splits_dir, 'exclusion_ids.txt')
    if File.exist?(exclusion_file)
      quarantined = File.readlines(exclusion_file).map(&:strip).size
    end
    
    total_excluded = excluded_by_pin + quarantined
    exclusion_pct = total_rows > 0 ? (total_excluded.to_f / total_rows * 100).round(2) : 0.0
    
    @stats[:exclusion_backlog] = {
      total_rows: total_rows,
      excluded_by_pin: excluded_by_pin,
      quarantined: quarantined,
      total_excluded: total_excluded,
      exclusion_pct: exclusion_pct
    }
  end

  def compute_split_distribution
    manifest = load_manifest(@manifest_path)
    
    # Filter by pin
    in_scope = manifest.select { |row| !row['cohort_id'] || row['cohort_id'] <= @pin }
    
    train_count = in_scope.count { |r| r['split'] == 'train' }
    val_count = in_scope.count { |r| r['split'] == 'val' }
    test_count = in_scope.count { |r| r['split'] == 'test' }
    total = in_scope.size
    
    train_pct = total > 0 ? (train_count.to_f / total * 100).round(2) : 0.0
    val_pct = total > 0 ? (val_count.to_f / total * 100).round(2) : 0.0
    test_pct = total > 0 ? (test_count.to_f / total * 100).round(2) : 0.0
    
    @stats[:split_distribution] = {
      train: train_count,
      val: val_count,
      test: test_count,
      total: total,
      train_pct: train_pct,
      val_pct: val_pct,
      test_pct: test_pct
    }
  end

  def compute_contamination_drift
    report_file = File.join(@splits_dir, 'contamination_report.json')
    
    if File.exist?(report_file)
      report = JSON.parse(File.read(report_file))
      @stats[:contamination] = {
        contamination_pct: report['contamination_pct'] || 0.0,
        flagged_pairs: report['contamination_pairs'] || 0,
        status: report['status'] || 'UNKNOWN'
      }
    else
      @stats[:contamination] = {
        contamination_pct: 0.0,
        flagged_pairs: 0,
        status: 'NO_REPORT'
      }
    end
  end

  def compute_tombstone_count
    tombstone_file = 'vault/dsr_tombstones.jsonl'
    
    if File.exist?(tombstone_file)
      count = File.readlines(tombstone_file).size
      @stats[:tombstones] = { count: count }
    else
      @stats[:tombstones] = { count: 0 }
    end
  end

  def check_alerts
    @config['kpis'].each do |kpi_name, kpi_def|
      value = fetch_metric_value(kpi_def['metric_path'])
      threshold = kpi_def['threshold']
      comparison = kpi_def['comparison'] || 'gt' # gt (greater than) or lt (less than)
      
      breached = case comparison
                 when 'gt' then value > threshold
                 when 'lt' then value < threshold
                 when 'gte' then value >= threshold
                 when 'lte' then value <= threshold
                 else false
                 end
      
      next unless breached
      
      # Threshold breached, fire alert
      fire_alert(
        kpi_name: kpi_name,
        kpa: kpi_def['kpa'],
        value: value,
        threshold: threshold,
        recommended_action: kpi_def['recommended_action'],
        severity: kpi_def['severity'] || 'warning'
      )
    end
  end

  def fetch_metric_value(path)
    parts = path.split('.')
    parts.reduce(@stats) { |obj, key| obj[key.to_sym] || obj[key] }
  rescue
    0.0
  end

  def fire_alert(kpi_name:, kpa:, value:, threshold:, recommended_action:, severity:)
    message = build_alert_message(
      kpi_name: kpi_name,
      kpa: kpa,
      value: value,
      threshold: threshold,
      recommended_action: recommended_action,
      severity: severity
    )
    
    puts "[ALERT] #{severity.upcase}: #{kpi_name} = #{value} (threshold: #{threshold})"
    puts "  KPA: #{kpa}"
    puts "  Action: #{recommended_action}"
    
    # Fire to all configured channels
    send_email(message) if @config.dig('notifications', 'email', 'enabled')
    send_slack(message) if @config.dig('notifications', 'slack', 'enabled')
    send_webhook(message) if @config.dig('notifications', 'webhook', 'enabled')
  end

  def build_alert_message(kpi_name:, kpa:, value:, threshold:, recommended_action:, severity:)
    {
      timestamp: Time.now.iso8601,
      severity: severity,
      kpi: kpi_name,
      kpa: kpa,
      current_value: value,
      threshold: threshold,
      recommended_action: recommended_action,
      stats_snapshot: @stats
    }
  end

  def send_email(message)
    email_config = @config.dig('notifications', 'email')
    return unless email_config

    smtp_server = email_config['smtp_server']
    smtp_port = email_config['smtp_port'] || 587
    from = email_config['from']
    to = email_config['to']
    subject = "[mboxMinerva Alert] #{message[:severity].upcase}: #{message[:kpi]}"
    
    body = <<~EMAIL
      KPI Alert: #{message[:kpi]}
      KPA (Business Area): #{message[:kpa]}
      
      Current Value: #{message[:current_value]}
      Threshold: #{message[:threshold]}
      Severity: #{message[:severity]}
      
      Recommended Action:
      #{message[:recommended_action]}
      
      Full Stats:
      #{JSON.pretty_generate(message[:stats_snapshot])}
      
      Timestamp: #{message[:timestamp]}
    EMAIL

    msg = <<~MSG
      From: #{from}
      To: #{to}
      Subject: #{subject}
      
      #{body}
    MSG

    begin
      Net::SMTP.start(smtp_server, smtp_port) do |smtp|
        smtp.send_message(msg, from, to)
      end
      puts "  → Email sent to #{to}"
    rescue => e
      puts "  ✗ Email failed: #{e.message}"
    end
  end

  def send_slack(message)
    slack_config = @config.dig('notifications', 'slack')
    return unless slack_config

    webhook_url = slack_config['webhook_url']
    
    payload = {
      text: "[mboxMinerva Alert] #{message[:severity].upcase}: #{message[:kpi]}",
      attachments: [
        {
          color: message[:severity] == 'critical' ? 'danger' : 'warning',
          fields: [
            { title: 'KPI', value: message[:kpi], short: true },
            { title: 'KPA', value: message[:kpa], short: true },
            { title: 'Current Value', value: message[:current_value].to_s, short: true },
            { title: 'Threshold', value: message[:threshold].to_s, short: true },
            { title: 'Recommended Action', value: message[:recommended_action], short: false }
          ],
          footer: 'mboxMinerva Metrics Watcher',
          ts: Time.now.to_i
        }
      ]
    }

    begin
      uri = URI(webhook_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
      request.body = payload.to_json
      response = http.request(request)
      
      if response.code.to_i == 200
        puts "  → Slack alert sent"
      else
        puts "  ✗ Slack failed: #{response.code} #{response.body}"
      end
    rescue => e
      puts "  ✗ Slack failed: #{e.message}"
    end
  end

  def send_webhook(message)
    webhook_config = @config.dig('notifications', 'webhook')
    return unless webhook_config

    webhook_url = webhook_config['url']
    
    begin
      uri = URI(webhook_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
      request.body = message.to_json
      response = http.request(request)
      
      if response.code.to_i >= 200 && response.code.to_i < 300
        puts "  → Webhook posted to #{webhook_url}"
      else
        puts "  ✗ Webhook failed: #{response.code} #{response.body}"
      end
    rescue => e
      puts "  ✗ Webhook failed: #{e.message}"
    end
  end

  def load_manifest(path)
    File.readlines(path).map { |line| JSON.parse(line.strip) }
  rescue => e
    puts "ERROR loading manifest: #{e.message}"
    []
  end
end

# CLI entry point
if __FILE__ == $PROGRAM_NAME
  options = { config: 'config/alerts.yml', manifest: 'data/manifest.jsonl', pin: nil }
  
  OptionParser.new do |opts|
    opts.banner = "Usage: metrics_watcher.rb [options]"
    opts.on('-c', '--config PATH', 'Path to alerts.yml config') { |v| options[:config] = v }
    opts.on('-m', '--manifest PATH', 'Path to manifest.jsonl') { |v| options[:manifest] = v }
    opts.on('-p', '--pin COHORT_ID', 'Cohort pin cutoff') { |v| options[:pin] = v }
    opts.on('-s', '--splits-dir DIR', 'Splits directory') { |v| options[:splits_dir] = v }
  end.parse!
  
  watcher = MetricsWatcher.new(
    config_path: options[:config],
    manifest_path: options[:manifest],
    pin: options[:pin],
    splits_dir: options[:splits_dir] || 'data/splits'
  )
  
  watcher.run
end