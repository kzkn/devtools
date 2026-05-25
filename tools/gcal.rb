#!/usr/bin/env ruby
# frozen_string_literal: true

# gcal - 指定された日付の Google カレンダー予定を JSON で出力
#
# 認証情報: ~/.config/gcal/credentials.json に OAuth クライアント JSON
# (Google Cloud Console のデスクトップアプリ) を置く
# 使い方:
#   gcal.rb auth          # 初回認証
#   gcal.rb               # 今日
#   gcal.rb 2026-05-23    # 指定日

require "date"
require "fileutils"
require "json"
require "net/http"
require "socket"
require "time"
require "uri"

CONFIG_DIR = File.join(Dir.home, ".config", "gcal")
CRED_PATH = File.join(CONFIG_DIR, "credentials.json")
TOKEN_PATH = File.join(CONFIG_DIR, "token.json")
REDIRECT_URI = "http://127.0.0.1:9876"
SCOPE = "https://www.googleapis.com/auth/calendar.readonly"

def client_config
  unless File.exist?(CRED_PATH)
    warn <<~MSG
           OAuth クライアント JSON が見つかりません: #{CRED_PATH}

           セットアップ手順:
             1. Google Cloud Console (https://console.cloud.google.com/) でプロジェクトを作成
             2. 「APIとサービス」→「ライブラリ」で Google Calendar API を有効化
             3. 「APIとサービス」→「認証情報」→「認証情報を作成」→「OAuth クライアント ID」
             4. アプリケーションの種類: 「デスクトップアプリ」を選択
             5. 作成後ダウンロードした JSON を次に保存: #{CRED_PATH}
             6. mkdir -p #{CONFIG_DIR} && mv ~/Downloads/client_secret_*.json #{CRED_PATH}
         MSG
    exit 1
  end
  JSON.parse(File.read(CRED_PATH)).values.first
end

def post_form(url, params)
  res = Net::HTTP.post_form(URI(url), params)
  JSON.parse(res.body)
end

def authenticate!
  cfg = client_config
  auth_url = URI(cfg["auth_uri"])
  auth_url.query = URI.encode_www_form(
    client_id: cfg["client_id"],
    redirect_uri: REDIRECT_URI,
    response_type: "code",
    scope: SCOPE,
    access_type: "offline",
    prompt: "consent",
  )
  warn "ブラウザで開いて認証してください: #{auth_url}"
  system("xdg-open", auth_url.to_s, out: File::NULL, err: File::NULL)

  uri = URI(REDIRECT_URI)
  server = TCPServer.new(uri.host, uri.port)
  session = server.accept
  path = session.gets.split(" ")[1]
  code = URI.decode_www_form(URI(path).query).to_h.fetch("code")
  session.write "HTTP/1.1 200 OK\r\n\r\n認証完了\n"
  session.close
  server.close

  tok = post_form(cfg["token_uri"],
                  code: code,
                  client_id: cfg["client_id"],
                  client_secret: cfg["client_secret"],
                  redirect_uri: REDIRECT_URI,
                  grant_type: "authorization_code")
  tok["expires_at"] = Time.now.to_i + tok["expires_in"].to_i
  FileUtils.mkdir_p(CONFIG_DIR)
  File.write(TOKEN_PATH, JSON.pretty_generate(tok))
  warn "保存: #{TOKEN_PATH}"
end

def access_token
  tok = JSON.parse(File.read(TOKEN_PATH))
  if Time.now.to_i >= tok["expires_at"].to_i - 60
    cfg = client_config
    refreshed = post_form(cfg["token_uri"],
                          client_id: cfg["client_id"],
                          client_secret: cfg["client_secret"],
                          refresh_token: tok["refresh_token"],
                          grant_type: "refresh_token")
    tok.merge!(refreshed)
    tok["expires_at"] = Time.now.to_i + refreshed["expires_in"].to_i
    File.write(TOKEN_PATH, JSON.pretty_generate(tok))
  end
  tok["access_token"]
end

def parse_date(arg)
  case arg
  when nil, "today" then Date.today
  when "tomorrow" then Date.today + 1
  when "yesterday" then Date.today - 1
  else Date.parse(arg)
  end
end

def fetch_events(date)
  day_start = Time.new(date.year, date.month, date.day)
  day_end = day_start + 24 * 60 * 60
  uri = URI("https://www.googleapis.com/calendar/v3/calendars/primary/events")
  uri.query = URI.encode_www_form(
    singleEvents: true,
    orderBy: "startTime",
    timeMin: day_start.iso8601,
    timeMax: day_end.iso8601,
    maxResults: 250,
  )
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{access_token}"
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  JSON.parse(res.body).fetch("items", []).map do |e|
    start_h = e["start"] || {}
    end_h = e["end"] || {}
    {
      id: e["id"],
      summary: e["summary"],
      start: start_h["dateTime"] || start_h["date"],
      end: end_h["dateTime"] || end_h["date"],
      all_day: !start_h["date"].nil?,
      location: e["location"],
      attendees: (e["attendees"] || []).map { |a| { email: a["email"], response: a["responseStatus"] } },
      html_link: e["htmlLink"],
    }
  end
end

if ARGV[0] == "auth"
  authenticate!
else
  puts JSON.pretty_generate(events: fetch_events(parse_date(ARGV[0])))
end
