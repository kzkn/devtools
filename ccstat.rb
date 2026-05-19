#!/usr/bin/env ruby
# frozen_string_literal: true

# ccstat - 稼働中の Claude Code セッションを一覧表示

require "json"
require "time"

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

def user_prompt_text(rec)
  msg = rec["message"] || {}
  content = msg["content"]
  case content
  when String
    content.strip
  when Array
    return "" if content.any? { |c| c.is_a?(Hash) && c["type"] == "tool_result" }
    content
      .select { |c| c.is_a?(Hash) && c["type"] == "text" }
      .map { |c| c["text"].to_s }
      .join(" ")
      .strip
  else
    ""
  end
end

def parse_session(jsonl_path)
  lines = File.readlines(jsonl_path, encoding: "utf-8:utf-8", invalid: :replace)
rescue
  return nil
else
  last_ts          = nil
  total_input      = 0
  total_output     = 0
  latest_prompt    = nil
  last_meaningful  = nil

  lines.each do |raw|
    raw = raw.strip
    next if raw.empty?

    begin
      rec = JSON.parse(raw)
    rescue JSON::ParserError
      next
    end

    if (ts_str = rec["timestamp"])
      begin
        last_ts = Time.parse(ts_str).utc
      rescue ArgumentError
        # ignore
      end
    end

    case rec["type"]
    when "user"
      text = user_prompt_text(rec)
      if text.empty?
        last_meaningful = :user_tool_result
      else
        latest_prompt = text
        last_meaningful = :user_prompt
      end
    when "assistant"
      msg = rec["message"] || {}
      usage = msg["usage"] || {}
      total_input  += (usage["input_tokens"]  || 0).to_i
      total_output += (usage["output_tokens"] || 0).to_i

      stop = msg["stop_reason"]
      last_meaningful =
        case stop
        when "end_turn", "stop_sequence" then :assistant_done
        when "tool_use"                   then :assistant_tool_use
        else                                    :assistant_other
        end
    end
  end

  return nil if last_ts.nil?

  {
    last_ts:         last_ts,
    input_tokens:    total_input,
    output_tokens:   total_output,
    latest_prompt:   latest_prompt || "",
    last_meaningful: last_meaningful,
  }
end

def running_claude_processes
  out = `ps -eo pid,comm,args 2>/dev/null`
  out.lines.filter_map do |line|
    parts = line.strip.split(/\s+/, 3)
    next unless parts.size == 3
    pid, comm, args = parts
    next unless comm == "claude"
    cwd = begin
      File.readlink("/proc/#{pid}/cwd")
    rescue
      nil
    end
    next unless cwd
    session_id = args[/-r\s+(\S+)/, 1]
    { pid: pid.to_i, cwd: cwd, session_id: session_id }
  end
rescue
  []
end

def find_session_jsonl(claude_dir, cwd, session_id)
  project_dir = File.join(claude_dir, cwd.gsub(%r{[/._]}, "-"))
  return nil unless Dir.exist?(project_dir)

  if session_id
    path = File.join(project_dir, "#{session_id}.jsonl")
    return File.exist?(path) ? path : nil
  end

  Dir.glob("#{project_dir}/*.jsonl").max_by { |f| File.mtime(f) }
end

def session_status(session, jsonl_path)
  # ファイルが直近で更新されていれば running と判定
  return "running" if Time.now - File.mtime(jsonl_path) < 3

  case session[:last_meaningful]
  when :assistant_done then "waiting"
  else                      "running"
  end
end

claude_dir = File.join(Dir.home, ".claude", "projects")
unless Dir.exist?(claude_dir)
  puts "~/.claude/projects が見つかりません。"
  exit 1
end

procs = running_claude_processes
if procs.empty?
  puts "稼働中の Claude Code セッションはありません。"
  exit 0
end

rows = procs.filter_map do |p|
  jsonl = find_session_jsonl(claude_dir, p[:cwd], p[:session_id])
  next nil unless jsonl
  s = parse_session(jsonl)
  next nil unless s

  {
    pid:           p[:pid],
    cwd:           p[:cwd],
    status:        session_status(s, jsonl),
    last_ts:       s[:last_ts],
    tokens:        s[:input_tokens] + s[:output_tokens],
    latest_prompt: s[:latest_prompt],
  }
end

if rows.empty?
  puts "稼働中のプロセスは見つかりましたが、対応するセッションを特定できませんでした。"
  exit 0
end

rows.sort_by! { |r| -r[:last_ts].to_i }

puts format("%-7s %-35s %-8s %-12s %9s  %s",
            "PID", "CWD", "STATUS", "LAST ACTIVE", "TOKENS", "LATEST PROMPT")
puts "─" * 110

rows.each do |r|
  cwd_short = r[:cwd].sub(Dir.home, "~")
  cwd_short = "…" + cwd_short[-32..] if cwd_short.length > 33
  prompt = (r[:latest_prompt].empty? ? "(no prompt yet)" : r[:latest_prompt]).gsub("\n", " ")[0, 55]
  puts format("%-7d %-35s %-8s %-12s %9s  %s",
              r[:pid], cwd_short, r[:status], relative_time(r[:last_ts]),
              fmt_tokens(r[:tokens]), prompt)
end
