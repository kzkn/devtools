#!/usr/bin/env ruby
# frozen_string_literal: true

# ccstat - Claude Code セッション状態をCLI一発で確認するツール
#
# 使い方:
#   ccstat              # 全プロジェクトの最新セッション一覧
#   ccstat -n 20        # 表示件数を指定
#   ccstat -p myproject # プロジェクト名でフィルタ
#   ccstat -v           # 詳細表示（トークン数、最初のプロンプトなど）
#   ccstat --today      # 今日のセッションのみ
#   ccstat --running    # 実行中のclaudeプロセスも表示

require "json"
require "optparse"
require "time"

# ── ユーティリティ ────────────────────────────────────────
def decode_project_path(encoded)
  encoded.gsub("-", "/").sub(%r{\A/+}, "")
end

def relative_time(t)
  diff = Time.now.utc - t.utc
  case diff
  when 0...60        then "#{diff.to_i}s ago"
  when 60...3_600    then "#{(diff / 60).to_i}m ago"
  when 3_600...86_400 then "#{(diff / 3_600).to_i}h ago"
  else                    "#{(diff / 86_400).to_i}d ago"
  end
end

def fmt_tokens(n)
  if n >= 1_000_000
    format("%.1fM", n / 1_000_000.0)
  elsif n >= 1_000
    format("%.1fk", n / 1_000.0)
  else
    n.to_s
  end
end

# ── JSONL パース ──────────────────────────────────────────
def parse_session(jsonl_path)
  lines = File.readlines(jsonl_path, encoding: "utf-8:utf-8", invalid: :replace)
rescue
  return nil
else
  session_id   = File.basename(jsonl_path, ".jsonl")
  cwd          = nil
  summary      = nil
  first_prompt = nil
  first_ts     = nil
  last_ts      = nil
  total_input  = 0
  total_output = 0
  user_turns   = 0
  tool_calls   = 0
  model        = nil

  lines.each do |raw|
    raw = raw.strip
    next if raw.empty?

    begin
      rec = JSON.parse(raw)
    rescue JSON::ParserError
      next
    end

    # タイムスタンプ
    if (ts_str = rec["timestamp"])
      begin
        ts = Time.parse(ts_str).utc
        first_ts ||= ts
        last_ts = ts
      rescue ArgumentError
        # ignore
      end
    end

    # 作業ディレクトリ
    cwd ||= rec["cwd"] if rec["cwd"] && !rec["cwd"].empty?

    rtype = rec["type"] || ""

    # ユーザーメッセージ
    if rtype == "user"
      msg     = rec["message"] || {}
      content = msg["content"] || ""
      if content.is_a?(Array)
        content = content
          .select { |c| c.is_a?(Hash) && c["type"] == "text" }
          .map { |c| c["text"].to_s }
          .join(" ")
      end
      content = content.strip
      first_prompt ||= content[0, 120] unless content.empty?
      user_turns += 1
    end

    # アシスタントメッセージ
    if rtype == "assistant"
      msg   = rec["message"] || {}
      usage = msg["usage"] || {}
      total_input  += (usage["input_tokens"]  || 0).to_i
      total_output += (usage["output_tokens"] || 0).to_i
      model ||= msg["model"]

      (msg["content"] || []).each do |blk|
        tool_calls += 1 if blk.is_a?(Hash) && blk["type"] == "tool_use"
      end
    end

    # サマリ
    summary = rec["summary"] if rtype == "summary"
  end

  return nil if first_ts.nil?

  {
    session_id:    session_id,
    cwd:           cwd || "",
    summary:       summary,
    first_prompt:  first_prompt || "",
    first_ts:      first_ts,
    last_ts:       last_ts || first_ts,
    input_tokens:  total_input,
    output_tokens: total_output,
    user_turns:    user_turns,
    tool_calls:    tool_calls,
    model:         model || "",
  }
end

# ── プロセス確認 ──────────────────────────────────────────
def running_processes
  out = `ps aux 2>/dev/null`
  out.lines.filter_map do |line|
    next unless line.downcase.include?("claude")
    next if line.include?("ccstat") || line.include?("grep")
    parts = line.split(nil, 11)
    next unless parts.size >= 11
    { pid: parts[1], cpu: parts[2], mem: parts[3], command: parts[10].strip[0, 80] }
  end
rescue
  []
end

# ── メイン出力 ────────────────────────────────────────────
def print_sessions(sessions, verbose:)
  if verbose
    puts format("%-35s %-12s %7s %7s %5s %5s  %s",
                "PROJECT/CWD", "LAST ACTIVE", "IN", "OUT", "TURNS", "TOOLS", "SUMMARY")
    puts "─" * 110
  else
    puts format("%-35s %-12s %9s  %s", "PROJECT/CWD", "LAST ACTIVE", "TOKENS", "SUMMARY/PROMPT")
    puts "─" * 95
  end

  sessions.each do |s|
    cwd_short = s[:cwd].empty? ? "(unknown)" : s[:cwd].sub(Dir.home, "~")
    cwd_short = "…" + cwd_short[-32..] if cwd_short.length > 33

    rel   = relative_time(s[:last_ts])
    label = (s[:summary] || s[:first_prompt] || "(no content)").gsub("\n", " ")[0, 55]

    if verbose
      puts format("%-35s %-12s %7s %7s %5d %5d  %s",
                  cwd_short, rel,
                  fmt_tokens(s[:input_tokens]), fmt_tokens(s[:output_tokens]),
                  s[:user_turns], s[:tool_calls], label)
      puts "  └ session: #{s[:session_id]}"
    else
      tok = fmt_tokens(s[:input_tokens] + s[:output_tokens])
      puts format("%-35s %-12s %9s  %s", cwd_short, rel, tok, label)
    end
  end
end

def print_processes(procs)
  puts
  puts "▶ Running claude processes"
  puts "─" * 70
  if procs.empty?
    puts "  (none)"
  else
    procs.each do |p|
      puts "  PID #{p[:pid]}  CPU #{p[:cpu]}%  MEM #{p[:mem]}%  #{p[:command]}"
    end
  end
end

# ── エントリポイント ──────────────────────────────────────
options = { num: 15, project: nil, verbose: false, today: false, running: false }

OptionParser.new do |o|
  o.banner = "使い方: ccstat [options]"
  o.on("-n", "--num N",        Integer, "表示件数 (default: 15)")  { |v| options[:num]     = v }
  o.on("-p", "--project NAME", String,  "プロジェクト名フィルタ")   { |v| options[:project] = v }
  o.on("-v", "--verbose",               "詳細表示")                { options[:verbose] = true }
  o.on("--today",                       "今日のセッションのみ")     { options[:today]   = true }
  o.on("--running",                     "実行中プロセスも表示")     { options[:running] = true }
  o.on("-h", "--help")                                             { puts o; exit }
end.parse!

claude_dir = File.join(Dir.home, ".claude", "projects")
unless Dir.exist?(claude_dir)
  puts "~/.claude/projects が見つかりません。Claude Code を一度起動してください。"
  exit 1
end

# 全セッション収集
sessions = []
Dir.glob("#{claude_dir}/*/").each do |project_dir|
  dir_name = File.basename(project_dir)
  next if options[:project] && !dir_name.downcase.include?(options[:project].downcase)

  Dir.glob("#{project_dir}*.jsonl").each do |jsonl|
    s = parse_session(jsonl)
    next unless s
    s[:cwd] = "/" + decode_project_path(dir_name) if s[:cwd].empty?
    sessions << s
  end
end

if sessions.empty?
  puts "セッションが見つかりませんでした。"
  exit 0
end

# 今日フィルタ
if options[:today]
  today_start = Time.now.utc.then { |t| Time.utc(t.year, t.month, t.day) }
  sessions.select! { |s| s[:last_ts] >= today_start }
end

# ソート・件数制限
sessions.sort_by! { |s| -s[:last_ts].to_i }
sessions = sessions.first(options[:num])

# ヘッダ表示
puts
filter_note = options[:project] ? ", filter: #{options[:project]}" : ""
puts "  Claude Code Sessions  (#{sessions.size} sessions shown#{filter_note})"
puts

print_sessions(sessions, verbose: options[:verbose])

total_tok = sessions.sum { |s| s[:input_tokens] + s[:output_tokens] }
puts
puts "  Total tokens: #{fmt_tokens(total_tok)}"

if options[:running]
  procs = running_processes
  print_processes(procs)
end

puts
