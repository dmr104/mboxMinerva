#!/usr/bin/env python3
# Usage: `python3 scripts/eval_before_after.py --base path/to/base.ckpt --ft path/tp/ft.ckpt --test-data path/to/test.jsonl`
#
# Explanation: Using LoRA/qLora the adapter deltas as applied on top of the base.
# base.ckpt is the original model.  Training makes a small adaptor (ft.ckpt) with just the 
# right weight tweaks, and for eval/inference you load the base + adaptor together.  If you later want the 
# latest model run merge_lora.rb to baske the adaptor into a standalone fine-tuned checkpoint; though it is 
# wise to keep base + adaptor separately for reproducibility and future retuning. 




"""
Evaluate model quality before and after fine-tuning.
Computes perplexity on held-out test set for base model vs fine-tuned checkpoint.
"""
import json
import argparse
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from torch.utils.data import DataLoader
from tqdm import tqdm
import numpy as np

def load_test_data(path):
    """Load JSONL test set."""
    with open(path) as f:
        return [json.loads(line) for line in f]

def compute_perplexity(model, tokenizer, data, batch_size=8, max_length=512):
    """Compute perplexity over dataset."""
    model.eval()
    device = next(model.parameters()).device
    
    total_loss = 0
    total_tokens = 0
    
    with torch.no_grad():
        for i in tqdm(range(0, len(data), batch_size), desc="Evaluating"):
            batch = data[i:i+batch_size]
            
            # Concatenate subject + body
            texts = [f"Subject: {d.get('subject', '')}\n\n{d.get('body', '')}" for d in batch]
            
            encodings = tokenizer(
                texts,
                return_tensors='pt',
                padding=True,
                truncation=True,
                max_length=max_length
            ).to(device)
            
            outputs = model(**encodings, labels=encodings['input_ids'])
            
            # Sum loss weighted by number of tokens
            loss = outputs.loss.item()
            num_tokens = encodings['attention_mask'].sum().item()
            
            total_loss += loss * num_tokens
            total_tokens += num_tokens
    
    avg_loss = total_loss / total_tokens
    perplexity = np.exp(avg_loss)
    
    return perplexity

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base-model', required=True, help='Base model path')
    parser.add_argument('--finetuned-model', required=True, help='Fine-tuned checkpoint path')
    parser.add_argument('--test-data', required=True, help='Test JSONL file')
    parser.add_argument('--batch-size', type=int, default=8)
    parser.add_argument('--max-length', type=int, default=512)
    args = parser.parse_args()
    
    print("Loading test data...")
    test_data = load_test_data(args.test_data)
    print(f"Loaded {len(test_data)} test examples")
    
    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    print(f"Using device: {device}")
    
    # Evaluate base model
    print("\n=== Evaluating BASE model ===")
    tokenizer = AutoTokenizer.from_pretrained(args.base_model)
    base_model = AutoModelForCausalLM.from_pretrained(args.base_model).to(device)
    base_ppl = compute_perplexity(base_model, tokenizer, test_data, args.batch_size, args.max_length)
    print(f"Base model perplexity: {base_ppl:.2f}")
    
    del base_model
    torch.cuda.empty_cache()
    
    # Evaluate fine-tuned model
    print("\n=== Evaluating FINE-TUNED model ===")
    finetuned_model = AutoModelForCausalLM.from_pretrained(args.finetuned_model).to(device)
    finetuned_ppl = compute_perplexity(finetuned_model, tokenizer, test_data, args.batch_size, args.max_length)
    print(f"Fine-tuned model perplexity: {finetuned_ppl:.2f}")
    
    # Summary
    improvement = ((base_ppl - finetuned_ppl) / base_ppl) * 100
    print("\n" + "="*50)
    print("SUMMARY")
    print("="*50)
    print(f"Base perplexity:       {base_ppl:.2f}")
    print(f"Fine-tuned perplexity: {finetuned_ppl:.2f}")
    print(f"Improvement:           {improvement:+.1f}%")
    print("="*50)
    
    if finetuned_ppl < base_ppl:
        print("✅ Fine-tuning IMPROVED model quality")
    else:
        print("⚠️  Fine-tuning did NOT improve (possible overfitting)")

if __name__ == '__main__':
    main()