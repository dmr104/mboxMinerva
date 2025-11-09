#!/usr/bin/env ruby
# RAG_evaluator.rb - Distant-supervision RAG evaluation via thread-graph gold sets
# builds thread graphs, extracts gold sets (ancestors+siblings), constructs queries 
# (subject + first N non-quoted lines), runs BM25 retrieval, 
# excludes self/future-dated docs, optionally uses 
# thread/References heuristics, reports Hit@k and Recall@k with 95% confidence interval

# Usage: ruby RAG_evaluator.rb input.json --k 5 --sample-size 1000 --query-lines 3

require 'json'
require 'set'
require 'optparse'
require 'digest'

# Simple BM25 implementation
class BM25
  def initialize(docs, k1: 1.5, b: 0.75)
    @k1, @b = k1, b
    @docs = docs
    @doc_freqs = Hash.new(0)
    @doc_lengths = {}
    @inverted_index = Hash.new { |h, k| h[k] = [] }
    
    # Build index
    @docs.each_with_index do |doc, idx|
      tokens = tokenize(doc[:text])
      @doc_lengths[idx] = tokens.size
      token_freqs = Hash.new(0)
      tokens.each { |t| token_freqs[t] += 1 }
      token_freqs.each do |term, freq|
        @doc_freqs[term] += 1
        @inverted_index[term] << [idx, freq]
      end
    end
    
    @avg_doc_length = @doc_lengths.values.sum.to_f / @doc_lengths.size
    @num_docs = @docs.size
  end
  
  def tokenize(text)
    text.downcase.scan(/\b[a-z0-9]+\b/)
  end
  
  def search(query_text, k)
    query_tokens = tokenize(query_text)
    scores = Hash.new(0.0)
    
    query_tokens.each do |term|
      next unless @inverted_index.key?(term)
      idf = Math.log((@num_docs - @doc_freqs[term] + 0.5) / (@doc_freqs[term] + 0.5) + 1.0)
      @inverted_index[term].each do |doc_idx, term_freq|
        doc_len = @doc_lengths[doc_idx]
        norm = @k1 * ((1 - @b) + @b * (doc_len / @avg_doc_length))
        scores[doc_idx] += idf * (term_freq * (@k1 + 1.0)) / (term_freq + norm)
      end
    end
    
    scores.sort_by { |_, score| -score }.take(k).map(&:first)
  end
end

# Thread graph builder using References/In-Reply-To
class ThreadGraph
  def initialize(emails)
    @emails = emails
    @id_to_email = {}
    @threads = Hash.new { |h, k| h[k] = Set.new }
    
    emails.each do |email|
      @id_to_email[email[:message_id]] = email
    end
    
    # Build ancestor/sibling relationships
    emails.each do |email|
      msg_id = email[:message_id]
      refs = parse_references(email[:references]) + parse_references(email[:in_reply_to])
      
      # Add all referenced messages as ancestors
      refs.each do |ref_id|
        @threads[msg_id] << ref_id if @id_to_email[ref_id]
      end
      
      # Find siblings: emails that share any ancestor
      emails.each do |other|
        next if other[:message_id] == msg_id
        other_refs = parse_references(other[:references]) + parse_references(other[:in_reply_to])
        if (refs & other_refs).any? || refs.include?(other[:message_id]) || other_refs.include?(msg_id)
          @threads[msg_id] << other[:message_id]
        end
      end
    end
  end
  
  def gold_set(message_id)
    @threads[message_id].to_a
  end
  
  private
  
  def parse_references(ref_str)
    return [] if ref_str.nil? || ref_str.empty?
    ref_str.scan(/<([^>]+)>/).flatten
  end
end

# Query constructor: subject + first N non-quoted lines
def construct_query(email, num_lines: 3)
  subject = email[:subject] || ""
  body = email[:text] || ""
  
  # Strip quoted lines (starting with >, |, or "On ... wrote:")
  clean_lines = body.lines.reject { |line| line =~ /^\s*[>|]/ || line =~ /^On .* wrote:/ }
  first_lines = clean_lines.take(num_lines).join(" ")
  
  "#{subject} #{first_lines}".strip
end

# Main evaluation
def evaluate_rag(emails, k: 5, sample_size: 1000, query_lines: 3, heuristics: true)
  puts "Building thread graph..."
  graph = ThreadGraph.new(emails)
  
  puts "Indexing #{emails.size} documents for BM25..."
  bm25 = BM25.new(emails)
  
  # Sample queries
  puts "Sampling #{sample_size} queries..."
  sampled = emails.sample([sample_size, emails.size].min)
  
  hit_scores = []
  recall_scores = []
  
  sampled.each_with_index do |query_email, idx|
    gold = graph.gold_set(query_email[:message_id])
    next if gold.empty?  # Skip emails with no gold set
    
    query_text = construct_query(query_email, num_lines: query_lines)
    retrieved_indices = bm25.search(query_text, k)
    retrieved_ids = retrieved_indices.map { |i| emails[i][:message_id] }
    
    # Exclude self and future-dated docs
    query_date = query_email[:date]
    filtered_ids = retrieved_ids.reject do |rid|
      rid == query_email[:message_id] ||
      (query_date && emails.find { |e| e[:message_id] == rid }&.dig(:date).to_s > query_date.to_s)
    end
    
    # Optional heuristic: grant correctness if retrieved shares thread_id or References
    if heuristics
      query_refs = Set.new([query_email[:references], query_email[:in_reply_to]].compact.flat_map { |r| r.scan(/<([^>]+)>/).flatten })
      filtered_ids = filtered_ids.select do |rid|
        gold.include?(rid) ||
        query_refs.include?(rid) ||
        emails.find { |e| e[:message_id] == rid }&.dig(:thread_id) == query_email[:thread_id]
      end
    end
    
    intersection = (Set.new(filtered_ids) & Set.new(gold)).size
    hit_scores << (intersection > 0 ? 1 : 0)
    recall_scores << (intersection.to_f / gold.size)
    
    if (idx + 1) % 100 == 0
      puts "  Processed #{idx + 1}/#{sampled.size} queries..."
    end
  end
  
  # Compute metrics
  hit_at_k = hit_scores.sum.to_f / hit_scores.size
  recall_at_k_macro = recall_scores.sum / recall_scores.size
  recall_at_k_micro = recall_scores.sum / recall_scores.size  # Same for single-query granularity
  
  # Confidence intervals (95%, assuming normal approximation)
  hit_std = Math.sqrt(hit_at_k * (1 - hit_at_k) / hit_scores.size)
  recall_std = Math.sqrt(recall_scores.map { |r| (r - recall_at_k_macro) ** 2 }.sum / recall_scores.size)
  
  puts "\n=== RAG Evaluation Results (k=#{k}, sample=#{hit_scores.size}) ==="
  puts "Hit@#{k}:         #{(hit_at_k * 100).round(2)}% ± #{(1.96 * hit_std * 100).round(2)}%"
  puts "Recall@#{k} (macro): #{(recall_at_k_macro * 100).round(2)}% ± #{(1.96 * recall_std * 100).round(2)}%"
  puts "Recall@#{k} (micro): #{(recall_at_k_micro * 100).round(2)}%"
  
  {
    hit_at_k: hit_at_k,
    recall_at_k_macro: recall_at_k_macro,
    recall_at_k_micro: recall_at_k_micro,
    sample_size: hit_scores.size
  }
end

# CLI
options = { k: 5, sample_size: 1000, query_lines: 3, heuristics: true }
OptionParser.new do |opts|
  opts.banner = "Usage: ruby RAG_evaluator.rb input.json [options]"
  opts.on("-k", "--k K", Integer, "Top-k for retrieval (default: 5)") { |v| options[:k] = v }
  opts.on("-s", "--sample-size SIZE", Integer, "Number of queries to sample (default: 1000)") { |v| options[:sample_size] = v }
  opts.on("-l", "--query-lines LINES", Integer, "Number of body lines for query (default: 3)") { |v| options[:query_lines] = v }
  opts.on("--[no-]heuristics", "Use thread/References heuristics (default: true)") { |v| options[:heuristics] = v }
end.parse!

if ARGV.empty?
  puts "Error: Please provide input JSON file"
  exit 1
end

input_file = ARGV[0]
puts "Loading emails from #{input_file}..."
emails = JSON.parse(File.read(input_file), symbolize_names: true)

evaluate_rag(emails, **options)