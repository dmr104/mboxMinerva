#!/usr/bin/env ruby
# merge_lora.rb - Merge LoRA adapter into base model using Python transformers+PEFT
# Usage: ruby merge_lora.rb --base meta-llama/Llama-3.2-1B --adapter ./checkpoint-1000 --out ./merged_model
require 'optparse'
require 'fileutils'
require 'json'
require 'tempfile'

options = {
  base: nil,
  adapter: nil,
  out: nil,
  dtype: 'float16',      # float16, bfloat16, float32
  device: 'auto',        # auto, cuda, cpu
  install_deps: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: merge_lora.rb --base MODEL --adapter CHECKPOINT --out OUTPUT_DIR [options]"
  
  opts.on("--base MODEL", "Base model name or path (e.g. meta-llama/Llama-3.2-1B)") { |v| options[:base] = v }
  opts.on("--adapter PATH", "Path to LoRA adapter checkpoint") { |v| options[:adapter] = v }
  opts.on("--out DIR", "Output directory for merged model") { |v| options[:out] = v }
  opts.on("--dtype DTYPE", "Data type: float16, bfloat16, float32 (default: float16)") { |v| options[:dtype] = v }
  opts.on("--device DEVICE", "Device: auto, cuda, cpu (default: auto)") { |v| options[:device] = v }
  opts.on("--install-deps", "Install Python dependencies if missing") { options[:install_deps] = true }
  opts.on("-h", "--help", "Show this help") { puts opts; exit }
end.parse!

unless options[:base] && options[:adapter] && options[:out]
  STDERR.puts "Error: --base, --adapter, and --out are required"
  STDERR.puts "Run with --help for usage"
  exit 1
end

# Check Python dependencies
def check_python_deps
  result = `python3 -c "import transformers, peft; print('OK')" 2>&1`
  $?.success? && result.strip == 'OK'
end

# Install Python dependencies
def install_python_deps
  puts "Installing Python dependencies (transformers, peft, accelerate)..."
  system("pip3 install --upgrade transformers peft accelerate torch") or raise "Failed to install dependencies"
end

# Check and optionally install dependencies
unless check_python_deps
  if options[:install_deps]
    install_python_deps
    unless check_python_deps
      STDERR.puts "Error: Failed to install Python dependencies"
      exit 1
    end
  else
    STDERR.puts "Error: Python transformers/peft not found. Install with:"
    STDERR.puts "  pip3 install transformers peft accelerate torch"
    STDERR.puts "Or run with --install-deps flag"
    exit 1
  end
end

# Create output directory
FileUtils.mkdir_p(options[:out])

# Python merge script
python_script = <<~PYTHON
import sys
import json
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import PeftModel
import torch

config = json.loads(sys.argv[1])

print(f"Loading base model: {config['base']}")
dtype_map = {
    'float16': torch.float16,
    'bfloat16': torch.bfloat16,
    'float32': torch.float32
}
dtype = dtype_map.get(config['dtype'], torch.float16)

model = AutoModelForCausalLM.from_pretrained(
    config['base'],
    torch_dtype=dtype,
    device_map=config['device'],
    trust_remote_code=True
)

print(f"Loading LoRA adapter: {config['adapter']}")
model = PeftModel.from_pretrained(model, config['adapter'])

print("Merging adapter into base model...")
model = model.merge_and_unload()

print(f"Saving merged model to: {config['out']}")
model.save_pretrained(config['out'], safe_serialization=True)

print(f"Saving tokenizer to: {config['out']}")
tokenizer = AutoTokenizer.from_pretrained(config['base'], trust_remote_code=True)
tokenizer.save_pretrained(config['out'])

print("Merge complete!")
print(f"\\nMerged model saved to: {config['out']}")
print("Load with: AutoModelForCausalLM.from_pretrained('#{config['out']}')")
PYTHON

# Prepare config for Python script
config_json = JSON.generate({
  base: options[:base],
  adapter: File.expand_path(options[:adapter]),
  out: File.expand_path(options[:out]),
  dtype: options[:dtype],
  device: options[:device]
})

# Write Python script to temp file
Tempfile.create(['merge_lora', '.py']) do |f|
  f.write(python_script)
  f.flush
  
  puts "=" * 60
  puts "Merging LoRA adapter into base model"
  puts "=" * 60
  puts "Base model:  #{options[:base]}"
  puts "Adapter:     #{options[:adapter]}"
  puts "Output:      #{options[:out]}"
  puts "Data type:   #{options[:dtype]}"
  puts "Device:      #{options[:device]}"
  puts "=" * 60
  puts
  
  # Run Python merge script
  success = system("python3", f.path, config_json)
  
  unless success
    STDERR.puts "\nError: Merge failed"
    exit 1
  end
end

puts
puts "=" * 60
puts "✓ Merge completed successfully"
puts "=" * 60
puts "Merged model location: #{File.expand_path(options[:out])}"
puts
puts "To use the merged model:"
puts "  from transformers import AutoModelForCausalLM, AutoTokenizer"
puts "  model = AutoModelForCausalLM.from_pretrained('#{File.expand_path(options[:out])}')"
puts "  tokenizer = AutoTokenizer.from_pretrained('#{File.expand_path(options[:out])}')"