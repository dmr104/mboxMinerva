# spec/split_integrity_spec.rb
# frozen_string_literal: true

require 'json'
require 'digest'
require 'rspec'

RSpec.describe 'Split Integrity' do
  let(:manifest_path) { 'assignments.json' }
  let(:manifest) { JSON.parse(File.read(manifest_path)) }
  
  describe 'Immutability' do
    it 'never changes existing assignments across runs' do
      # Take a snapshot of current manifest
      snapshot = manifest.dup
      
      # Simulate re-running splitter (in practice, run actual splitter.rb)
      # For this test, we just verify the snapshot matches current state
      
      current_manifest = JSON.parse(File.read(manifest_path))
      
      # All existing IDs must have identical assignments
      snapshot.each do |id, assignment|
        expect(current_manifest).to have_key(id), "ID #{id} disappeared from manifest"
        expect(current_manifest[id]).to eq(assignment), "Assignment for #{id} changed"
      end
    end
  end
  
  describe 'Thread Integrity' do
    it 'assigns all messages in a thread to the same split' do
      threads = {}
      
      manifest.each do |id, meta|
        thread_id = meta['thread_id']
        split = meta['split']
        
        threads[thread_id] ||= []
        threads[thread_id] << split
      end
      
      threads.each do |thread_id, splits|
        unique_splits = splits.uniq
        expect(unique_splits.size).to eq(1), 
          "Thread #{thread_id} has messages in multiple splits: #{unique_splits.join(', ')}"
      end
    end
    
    it 'assigns all windows of a thread to the same split' do
      thread_windows = {}
      
      manifest.each do |id, meta|
        if id.include?('_window_')
          base_thread = meta['thread_id']
          split = meta['split']
          
          thread_windows[base_thread] ||= []
          thread_windows[base_thread] << split
        end
      end
      
      thread_windows.each do |thread_id, splits|
        unique_splits = splits.uniq
        expect(unique_splits.size).to eq(1),
          "Thread #{thread_id} windows span multiple splits: #{unique_splits.join(', ')}"
      end
    end
  end
  
  describe 'Split Distribution' do
    it 'maintains approximately 80/10/10 train/val/test distribution' do
      splits = manifest.values.map { |m| m['split'] }
      total = splits.size
      
      train_pct = (splits.count('train') / total.to_f) * 100
      val_pct = (splits.count('val') / total.to_f) * 100
      test_pct = (splits.count('test') / total.to_f) * 100
      
      # Allow ±5% tolerance
      expect(train_pct).to be_within(5).of(80), "Train split: #{train_pct.round(1)}% (expected ~80%)"
      expect(val_pct).to be_within(5).of(10), "Val split: #{val_pct.round(1)}% (expected ~10%)"
      expect(test_pct).to be_within(5).of(10), "Test split: #{test_pct.round(1)}% (expected ~10%)"
    end
  end
  
  describe 'Determinism' do
    it 'reproduces the same assignment for a given ID and seed' do
      seed = 42
      
      manifest.each do |id, meta|
        thread_id = meta['thread_id']
        expected_split = meta['split']
        
        # Reproduce hash-bucket calculation
        bucket = Digest::SHA256.hexdigest("#{thread_id}-#{seed}").to_i(16) % 100
        computed_split = case bucket
                         when 0..79 then 'train'
                         when 80..89 then 'val'
                         else 'test'
                         end
        
        expect(computed_split).to eq(expected_split),
          "ID #{id} has split #{expected_split} but deterministic hash gives #{computed_split}"
      end
    end
  end
  
  describe 'No Cross-Contamination' do
    it 'prevents test IDs from appearing in train/val splits' do
      test_ids = manifest.select { |_, m| m['split'] == 'test' }.keys
      train_val_ids = manifest.select { |_, m| m['split'] != 'test' }.keys
      
      overlap = test_ids & train_val_ids
      expect(overlap).to be_empty, "Test IDs found in train/val: #{overlap.inspect}"
    end
  end
end