#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: utf-8
#
# Generates results/report.md from results/results.json + results/meta.json
#

require 'json'

BASE_DIR    = File.expand_path(__dir__)
RESULTS_DIR = File.join(BASE_DIR, 'results')

results = JSON.parse(File.read(File.join(RESULTS_DIR, 'results.json')))
meta    = JSON.parse(File.read(File.join(RESULTS_DIR, 'meta.json')))

languages = results.map { |r| r['language'] }.uniq
versions  = meta['versions'] || {}

LANGUAGE_LABELS = {
  'c/zigcc' => 'C (zig cc)',
  'cpp' => 'C++',
  'csharp' => 'C#',
  'php' => 'PHP',
  'ocaml' => 'OCaml',
  'typescript' => 'TypeScript',
  'javascript' => 'JavaScript',
  'python/mypy' => 'Python/mypy',
  'ruby/steep' => 'Ruby/steep',
}.freeze

def fmt(n)
  n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
end

def stddev(values)
  return 0.0 if values.size <= 1
  mean = values.sum / values.size.to_f
  Math.sqrt(values.sum { |v| (v - mean)**2 } / (values.size - 1).to_f)
end

def agent_data(record, phase)
  record["#{phase}_agent"] || record["#{phase}_codex"] || record["#{phase}_claude"]
end

def agent_field(record, phase, field)
  data = agent_data(record, phase)
  data ? (data[field] || 0) : 0
end

def total_tokens(cd)
  return 0 unless cd
  (cd['input_tokens'] || 0) + (cd['output_tokens'] || 0) +
    (cd['cache_creation_tokens'] || 0) + (cd['cache_read_tokens'] || 0)
end

def language_label(lang)
  LANGUAGE_LABELS[lang] || lang.capitalize
end

# ---------------------------------------------------------------------------
report = []

agent_name = meta['agent_name'] || 'Claude Code'
agent_version = meta['agent_version'] || meta['codex_version'] || meta['claude_version'] || 'unknown'

report << "# #{agent_name} Language Benchmark Report"
report << ''
report << '## Environment'
report << "- Date: #{meta['date']}"
report << "- #{agent_name} Version: #{agent_version}"
report << "- Trials per language: #{meta['trials']}"
report << ''

report << '## Language Versions'
report << '| Language | Version |'
report << '|----------|---------|'
languages.each { |l| report << "| #{language_label(l)} | #{versions[l] || 'unknown'} |" }
report << ''

# ---------------------------------------------------------------------------
# Results Summary (per-language averages)
# ---------------------------------------------------------------------------
report << '## Results Summary'
report << '| Language | v1 Time | v1 Turns | v1 LOC | v1 Tests | v2 Time | v2 Turns | v2 LOC | v2 Tests | Total Time | Avg Cost |'
report << '|----------|---------|----------|--------|----------|---------|----------|--------|----------|------------|----------|'

languages.each do |lang|
  lr = results.select { |r| r['language'] == lang }
  n  = lr.size.to_f
  next if n.zero?

  # v1 time
  v1_times = lr.map { |r| r['v1_time'] || 0 }
  v1_avg = (v1_times.sum / n).round(1)
  v1_sd  = stddev(v1_times).round(1)

  # v2 time
  v2_times = lr.map { |r| r['v2_time'] || 0 }
  v2_avg = (v2_times.sum / n).round(1)
  v2_sd  = stddev(v2_times).round(1)

  # total time
  total_times = lr.map { |r| (r['v1_time'] || 0) + (r['v2_time'] || 0) }
  total_avg = (total_times.sum / n).round(1)
  total_sd  = stddev(total_times).round(1)

  # turns
  v1_turns = (lr.sum { |r| agent_field(r, 'v1', 'num_turns') } / n).round(1)
  v2_turns = (lr.sum { |r| agent_field(r, 'v2', 'num_turns') } / n).round(1)

  # LOC
  v1_loc = (lr.sum { |r| r['v1_loc'] } / n).round(0)
  v2_loc = (lr.sum { |r| r['v2_loc'] } / n).round(0)

  # test results
  v1_pass = lr.count { |r| r['v1_pass'] }
  v2_pass = lr.count { |r| r['v2_pass'] }
  v1_tests = "#{v1_pass}/#{lr.size}"
  v2_tests = "#{v2_pass}/#{lr.size}"

  # cost
  total_cost = lr.sum do |r|
    %w[v1 v2].sum { |ph| agent_field(r, ph, 'cost_usd') }
  end
  avg_cost = total_cost / n

  report << "| #{language_label(lang)} " \
            "| #{v1_avg}s\u00B1#{v1_sd}s " \
            "| #{v1_turns} " \
            "| #{v1_loc} " \
            "| #{v1_tests} " \
            "| #{v2_avg}s\u00B1#{v2_sd}s " \
            "| #{v2_turns} " \
            "| #{v2_loc} " \
            "| #{v2_tests} " \
            "| #{total_avg}s\u00B1#{total_sd}s " \
            "| $#{'%.2f' % avg_cost} |"
end
report << ''

# ---------------------------------------------------------------------------
# Token Summary (per-language averages)
# ---------------------------------------------------------------------------
report << '## Token Summary'
report << '| Language | Avg Input | Avg Output | Avg Cache Create | Avg Cache Read | Avg Total | Avg Cost |'
report << '|----------|-----------|------------|------------------|----------------|-----------|----------|'

languages.each do |lang|
  lr = results.select { |r| r['language'] == lang }
  n  = lr.size.to_f
  next if n.zero?

  sum_input = sum_output = sum_cache_create = sum_cache_read = 0
  sum_cost = 0.0

  lr.each do |r|
    %w[v1 v2].each do |ph|
      sum_input        += agent_field(r, ph, 'input_tokens')
      sum_output       += agent_field(r, ph, 'output_tokens')
      sum_cache_create += agent_field(r, ph, 'cache_creation_tokens')
      sum_cache_read   += agent_field(r, ph, 'cache_read_tokens')
      sum_cost         += agent_field(r, ph, 'cost_usd')
    end
  end

  avg_total = ((sum_input + sum_output + sum_cache_create + sum_cache_read) / n).round(0)

  report << "| #{language_label(lang)} " \
            "| #{fmt((sum_input / n).round(0))} " \
            "| #{fmt((sum_output / n).round(0))} " \
            "| #{fmt((sum_cache_create / n).round(0))} " \
            "| #{fmt((sum_cache_read / n).round(0))} " \
            "| #{fmt(avg_total)} " \
            "| $#{'%.4f' % (sum_cost / n)} |"
end
report << ''

# ---------------------------------------------------------------------------
# Full Results (all trials)
# ---------------------------------------------------------------------------
report << '## Full Results'
report << '| Language | Trial | v1 Time | v1 Turns | v1 LOC | v1 Tests | v2 Time | v2 Turns | v2 LOC | v2 Tests | Total Time | Cost |'
report << '|----------|-------|---------|----------|--------|----------|---------|----------|--------|----------|------------|------|'

results.each do |r|
  v1t = r['v1_pass'] ? 'PASS' : 'FAIL'
  v2t = r['v2_pass'] ? 'PASS' : 'FAIL'
  v1_tests = "#{r['v1_passed_count']}/#{r['v1_total_count']} #{v1t}"
  v2_tests = "#{r['v2_passed_count']}/#{r['v2_total_count']} #{v2t}"

  v1_turns = agent_field(r, 'v1', 'num_turns')
  v2_turns = agent_field(r, 'v2', 'num_turns')

  total_time = ((r['v1_time'] || 0) + (r['v2_time'] || 0)).round(1)
  cost = %w[v1 v2].sum { |ph| agent_field(r, ph, 'cost_usd') }

  report << "| #{language_label(r['language'])} | #{r['trial']} " \
            "| #{r['v1_time']}s | #{v1_turns} | #{r['v1_loc']} | #{v1_tests} " \
            "| #{r['v2_time']}s | #{v2_turns} | #{r['v2_loc']} | #{v2_tests} " \
            "| #{total_time}s | $#{'%.2f' % cost} |"
end
report << ''

# ---------------------------------------------------------------------------
# Full Tokens (all trials)
# ---------------------------------------------------------------------------
report << '## Full Tokens'
report << '| Language | Trial | Phase | Input | Output | Cache Create | Cache Read | Total | Cost USD |'
report << '|----------|-------|-------|-------|--------|--------------|------------|-------|----------|'

results.each do |r|
  %w[v1 v2].each do |phase|
    data = agent_data(r, phase)
    if data
      tot = total_tokens(data)
      report << "| #{language_label(r['language'])} | #{r['trial']} | #{phase} " \
                "| #{fmt(data['input_tokens'] || 0)} | #{fmt(data['output_tokens'] || 0)} " \
                "| #{fmt(data['cache_creation_tokens'] || 0)} | #{fmt(data['cache_read_tokens'] || 0)} " \
                "| #{fmt(tot)} | $#{'%.4f' % (data['cost_usd'] || 0)} |"
    else
      report << "| #{language_label(r['language'])} | #{r['trial']} | #{phase} | - | - | - | - | - | - |"
    end
  end
end
report << ''

# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------

report_path = File.join(RESULTS_DIR, 'report.md')
File.write(report_path, report.join("\n") + "\n")
puts "Report written to: #{report_path}"
puts
puts report.join("\n")
