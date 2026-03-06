#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require 'open3'
require 'timeout'
require 'shellwords'

BASE_DIR = File.expand_path(__dir__)
WORK_DIR = File.join(BASE_DIR, 'generated')
RESULTS_DIR = File.join(BASE_DIR, 'results')
LOGS_DIR    = File.join(BASE_DIR, 'logs')

GO_DIR = File.join(Dir.home, '.local', 'go')
NPM_PREFIX = File.join(Dir.home, '.local', 'npm')

LANGUAGES = {
  'rust'        => { exts: %w[rs],     version_cmd: 'rustc --version' },
  'go'          => { exts: %w[go],     version_cmd: "#{GO_DIR}/bin/go version" },
  'c'           => { exts: %w[c h],    version_cmd: 'gcc --version | head -1' },
  'cpp'         => { exts: %w[cpp cc cxx h hpp hh hxx], version_cmd: 'g++ --version | head -1', prompt_name: 'C++' },
  'csharp'      => { exts: %w[cs],     version_cmd: 'dotnet --version || csc -version', prompt_name: 'C#' },
  'typescript'  => { exts: %w[ts],     version_cmd: "#{NPM_PREFIX}/bin/tsx --version" },
  'javascript'  => { exts: %w[js],     version_cmd: 'node --version' },
  'java'        => { exts: %w[java],   version_cmd: 'java --version 2>&1 | head -1' },
  'kotlin'      => { exts: %w[kt kts], version_cmd: 'kotlinc -version 2>&1 | head -1' },
  'swift'       => { exts: %w[swift],  version_cmd: 'swift --version | head -1' },
  'perl'        => { exts: %w[pl pm],  version_cmd: 'perl --version | head -2 | tail -1' },
  'python'      => { exts: %w[py],     version_cmd: 'python3 --version' },
  'python/mypy' => { exts: %w[py],     version_cmd: 'python3 --version && mypy --version',
                     extra_prompt: 'Write fully type-annotated Python code. All functions must have complete type hints. ' \
                                   'After passing the tests, also verify type correctness by running: mypy --strict *.py' },
  'ruby'        => { exts: %w[rb],     version_cmd: 'ruby --version' },
  'ruby/steep'  => { exts: %w[rb rbs], version_cmd: 'ruby --version && steep --version',
                     extra_prompt: 'Write Ruby code with RBS type signatures. Create .rbs files for all Ruby source files. ' \
                                   'After passing the tests, also verify type correctness by running: steep check' },
  'zig'         => { exts: %w[zig],    version_cmd: 'zig version', prompt_name: 'Zig' },
  'lua'         => { exts: %w[lua],    version_cmd: 'lua -v' },
  'elixir'      => { exts: %w[ex exs], version_cmd: 'elixir --version | head -1' },
  'julia'       => { exts: %w[jl],     version_cmd: 'julia --version', prompt_name: 'Julia' },
  'php'         => { exts: %w[php],    version_cmd: 'php --version | head -1', prompt_name: 'PHP' },
  'scheme'      => { exts: %w[scm],    version_cmd: 'guile --version | head -1' },
  'ocaml'       => { exts: %w[ml mli], version_cmd: 'ocaml --version' },
  'haskell'     => { exts: %w[hs],     version_cmd: 'ghc --version' },
}

TRIALS = 3

# ---------------------------------------------------------------------------
# CLI args
# ---------------------------------------------------------------------------

selected_languages = nil
selected_trials = TRIALS
selected_start = 1
dry_run = false

i = 0
while i < ARGV.length
  case ARGV[i]
  when '--lang', '-l'
    selected_languages = ARGV[i + 1].split(',').map(&:strip)
    i += 2
  when '--trials', '-t'
    selected_trials = ARGV[i + 1].to_i
    i += 2
  when '--start', '-s'
    selected_start = ARGV[i + 1].to_i
    i += 2
  when '--dry-run'
    dry_run = true
    i += 1
  else
    i += 1
  end
end

languages_to_run = selected_languages || LANGUAGES.keys

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def run_cmd(cmd, dir: nil, timeout: 600)
  opts = {}
  opts[:chdir] = dir if dir
  stdin_r, stdout_r, stderr_r, wait_thr = Open3.popen3(cmd, **opts)
  stdin_r.close
  stdout_r.set_encoding('UTF-8')
  stderr_r.set_encoding('UTF-8')
  stdout = stderr = ''
  begin
    Timeout.timeout(timeout) do
      stdout = stdout_r.read
      stderr = stderr_r.read
    end
  rescue Timeout::Error
    Process.kill('TERM', wait_thr.pid) rescue nil
    stdout = stdout_r.read rescue ''
    stderr = "Timeout after #{timeout}s"
  end
  stdout_r.close
  stderr_r.close
  status = wait_thr.value
  { stdout: stdout, stderr: stderr, exit_code: status.exitstatus, success: status.success? }
end

def extra_path
  "#{GO_DIR}/bin:#{NPM_PREFIX}/bin"
end


def get_version(lang)
  config = LANGUAGES[lang]
  cmd = "export PATH=#{extra_path}:$PATH && #{config[:version_cmd]}"
  result = run_cmd(cmd)
  if result[:success]
    (result[:stdout].strip.empty? ? result[:stderr].strip : result[:stdout].strip).lines.first&.strip || 'unknown'
  else
    'not installed'
  end
end

def prompt_language_name(lang)
  LANGUAGES[lang][:prompt_name] || lang.capitalize
end

def count_loc(dir, lang)
  config = LANGUAGES[lang]
  exts = config[:exts]
  files = exts.flat_map { |e| Dir.glob(File.join(dir, '**', "*.#{e}")) }
  files.reject! { |f| f.include?('/node_modules/') || f.include?('/target/') }

  # For scripting languages the executable `minigit` IS the source (no extension)
  minigit = File.join(dir, 'minigit')
  if File.exist?(minigit) && !files.include?(minigit)
    begin
      content = File.read(minigit, encoding: 'UTF-8')
      files << minigit if content.valid_encoding?
    rescue StandardError
      # skip binary files
    end
  end

  files.sum do |f|
    begin
      File.readlines(f).count { |l| !l.strip.empty? }
    rescue StandardError
      0
    end
  end
end

def parse_codex_output(raw_output)
  raw_output = raw_output.dup.force_encoding('UTF-8')
  events = raw_output.lines.filter_map do |line|
    stripped = line.strip
    next if stripped.empty?

    JSON.parse(stripped)
  end

  turn_events = events.select { |e| e.is_a?(Hash) && e['type'] == 'turn.completed' }
  return nil if turn_events.empty?

  {
    input_tokens: turn_events.sum { |e| e.dig('usage', 'input_tokens') || 0 },
    output_tokens: turn_events.sum { |e| e.dig('usage', 'output_tokens') || 0 },
    cache_creation_tokens: 0,
    cache_read_tokens: turn_events.sum { |e| e.dig('usage', 'cached_input_tokens') || 0 },
    cost_usd: 0.0,
    num_turns: turn_events.length,
    duration_ms: 0,
  }
rescue JSON::ParserError => e
  puts "  WARNING: Failed to parse Codex JSON output: #{e.message}"
  nil
end

def run_codex(prompt, dir:, log_path: nil)
  env_prefix = "export PATH=#{extra_path}:$PATH && "
  cmd = "#{env_prefix}codex exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox " \
        "-C #{Shellwords.escape(dir)} #{Shellwords.escape(prompt)}"

  puts "  Running Codex..."
  start_time = Time.now
  result = run_cmd(cmd, dir: dir, timeout: 1200)
  elapsed = Time.now - start_time

  if log_path
    FileUtils.mkdir_p(File.dirname(log_path))
    File.write(log_path, result[:stdout])
    puts "  Log saved to #{log_path}"
  end

  {
    stdout: result[:stdout],
    stderr: result[:stderr],
    success: result[:success],
    elapsed_seconds: elapsed.round(1),
    codex_data: parse_codex_output(result[:stdout]),
  }
end

def run_tests(test_script, dir:)
  cmd = "export PATH=#{extra_path}:$PATH && bash #{test_script}"
  result = run_cmd(cmd, dir: dir, timeout: 120)

  output = result[:stdout] + result[:stderr]
  passed = output[/PASSED:\s*(\d+)/, 1]&.to_i || 0
  failed = output[/FAILED:\s*(\d+)/, 1]&.to_i || 0

  {
    success: result[:success],
    passed: passed,
    failed: failed,
    total: passed + failed,
    output: output,
  }
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

puts '=' * 60
puts 'Codex Exec Language Benchmark'
puts '=' * 60
puts

codex_version_result = run_cmd('codex --version 2>/dev/null || echo unknown')
codex_version = codex_version_result[:stdout].strip

puts "Codex Version: #{codex_version}"
puts "Languages: #{languages_to_run.join(', ')}"
puts "Trials: #{selected_start}..#{selected_start + selected_trials - 1} (#{selected_trials} trials)"
puts "Dry run: #{dry_run}"
puts



# Language versions
puts '--- Language Versions ---'
versions = {}
languages_to_run.each do |lang|
  versions[lang] = get_version(lang)
  puts "  #{lang}: #{versions[lang]}"
end
puts

# Ensure directories exist
FileUtils.mkdir_p(WORK_DIR)
FileUtils.mkdir_p(RESULTS_DIR)

# Warmup: run a trivial prompt so Codex's process/cache is hot
unless dry_run
  puts '--- Warmup ---'
  warmup_dir = File.join(WORK_DIR, '.warmup')
  FileUtils.mkdir_p(warmup_dir)
  warmup_result = run_codex('Respond with just the word OK.', dir: warmup_dir)
  puts "  Warmup done in #{warmup_result[:elapsed_seconds]}s (success=#{warmup_result[:success]})"
  FileUtils.rm_rf(warmup_dir)
  puts
end

results = []

selected_trials.times do |trial_idx|
  trial = selected_start + trial_idx
  languages_to_run.each do |lang|
    puts '=' * 60
    puts "Trial #{trial} (#{trial_idx + 1}/#{selected_trials}) - #{lang}"
    puts '=' * 60

    dir_name = lang.tr('/', '-')
    v1_dir = File.join(WORK_DIR, "minigit-#{dir_name}-#{trial}-v1")
    v2_dir = File.join(WORK_DIR, "minigit-#{dir_name}-#{trial}-v2")
    FileUtils.rm_rf(v1_dir)
    FileUtils.rm_rf(v2_dir)
    FileUtils.mkdir_p(v1_dir)

    record = {
      language: lang, trial: trial, v1_dir: v1_dir, v2_dir: v2_dir,
      v1_time: nil, v1_pass: false, v1_passed_count: 0, v1_failed_count: 0, v1_total_count: 0, v1_loc: 0,
      v2_time: nil, v2_pass: false, v2_passed_count: 0, v2_failed_count: 0, v2_total_count: 0, v2_loc: 0,
      v1_agent: nil, v2_agent: nil,
    }

    # --- Phase 1: v1 ---
    puts "\n--- Phase 1: v1 ---"
    FileUtils.cp(File.join(BASE_DIR, 'SPEC-v1.txt'), v1_dir)
    FileUtils.cp(File.join(BASE_DIR, 'test-v1.sh'), v1_dir)

    v1_prompt = "Implement minigit as described in SPEC-v1.txt using #{prompt_language_name(lang)}. " \
                "The executable must be named 'minigit' and be runnable as ./minigit. " \
                "For compiled languages, include a Makefile or build script. " \
                "For interpreted languages, ensure the minigit file has a proper shebang line and is executable. " \
                "Verify your implementation passes all tests by running: bash test-v1.sh"
    v1_prompt += " #{LANGUAGES[lang][:extra_prompt]}" if LANGUAGES[lang][:extra_prompt]

    if dry_run
      puts "  [DRY RUN] Would run Codex with prompt for v1 #{lang}"
      record[:v1_time] = 0
    else
      v1_log = File.join(LOGS_DIR, "minigit-#{dir_name}-#{trial}-v1.json")
      v1_result = run_codex(v1_prompt, dir: v1_dir, log_path: v1_log)
      record[:v1_time] = v1_result[:elapsed_seconds]
      record[:v1_agent] = v1_result[:codex_data]
      puts "  Codex finished in #{v1_result[:elapsed_seconds]}s (success=#{v1_result[:success]})"

      puts '  Running v1 tests...'
      test_result = run_tests('test-v1.sh', dir: v1_dir)
      record[:v1_pass] = test_result[:success]
      record[:v1_passed_count] = test_result[:passed]
      record[:v1_failed_count] = test_result[:failed]
      record[:v1_total_count] = test_result[:total]
      puts "  Tests: #{test_result[:passed]}/#{test_result[:total]} passed (#{test_result[:success] ? 'PASS' : 'FAIL'})"

      record[:v1_loc] = count_loc(v1_dir, lang)
      puts "  LOC: #{record[:v1_loc]}"
    end

    # --- Phase 2: v2 (copy v1 then extend) ---
    puts "\n--- Phase 2: v2 ---"
    FileUtils.cp_r(v1_dir, v2_dir)
    FileUtils.cp(File.join(BASE_DIR, 'SPEC-v2.txt'), v2_dir)
    FileUtils.cp(File.join(BASE_DIR, 'test-v2.sh'), v2_dir)

    v2_prompt = "You are in a workspace copied from a passing v1 implementation. " \
                "Read SPEC-v2.txt and modify the existing minigit implementation in place to satisfy the full v2 spec " \
                "while preserving all v1 behavior. Do not start over unless it is strictly necessary. " \
                "Verify your implementation passes all tests by running: bash test-v2.sh"
    v2_prompt += " #{LANGUAGES[lang][:extra_prompt]}" if LANGUAGES[lang][:extra_prompt]

    if dry_run
      puts "  [DRY RUN] Would run Codex with prompt for v2 #{lang}"
      record[:v2_time] = 0
    else
      v2_log = File.join(LOGS_DIR, "minigit-#{dir_name}-#{trial}-v2.json")
      v2_result = run_codex(v2_prompt, dir: v2_dir, log_path: v2_log)
      record[:v2_time] = v2_result[:elapsed_seconds]
      record[:v2_agent] = v2_result[:codex_data]
      puts "  Codex finished in #{v2_result[:elapsed_seconds]}s (success=#{v2_result[:success]})"

      puts '  Running v2 tests...'
      test_result = run_tests('test-v2.sh', dir: v2_dir)
      record[:v2_pass] = test_result[:success]
      record[:v2_passed_count] = test_result[:passed]
      record[:v2_failed_count] = test_result[:failed]
      record[:v2_total_count] = test_result[:total]
      puts "  Tests: #{test_result[:passed]}/#{test_result[:total]} passed (#{test_result[:success] ? 'PASS' : 'FAIL'})"

      record[:v2_loc] = count_loc(v2_dir, lang)
      puts "  LOC: #{record[:v2_loc]}"
    end

    results << record
    puts
  end
end

# ---------------------------------------------------------------------------
# Save results JSON
# ---------------------------------------------------------------------------

puts '=' * 60
puts 'Saving results...'
puts '=' * 60

# Save metadata alongside results
meta = {
  date: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
  agent_name: 'Codex Exec',
  agent_version: codex_version,
  trials: selected_trials,
  versions: versions,
}

File.write(File.join(RESULTS_DIR, 'meta.json'), JSON.pretty_generate(meta))

# Load existing results and append new ones
results_path = File.join(RESULTS_DIR, 'results.json')
existing = if File.exist?(results_path)
             JSON.parse(File.read(results_path)) rescue []
           else
             []
           end
all_results = existing + results.map { |r| r.transform_keys(&:to_s) }
File.write(results_path, JSON.pretty_generate(all_results))

puts "Results saved to #{RESULTS_DIR}/"
puts 'Run `ruby report.rb` to generate the report.'
