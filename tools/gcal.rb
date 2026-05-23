#!/usr/bin/env ruby
# frozen_string_literal: true

# gcal - 指定された日付の Google カレンダー予定を JSON で出力
#
# 必要な gem: google-apis-calendar_v3, googleauth
# 認証情報: ~/.config/gcal/credentials.json に OAuth クライアント JSON を置く
# 使い方:
#   gcal.rb auth          # 初回認証
#   gcal.rb               # 今日
#   gcal.rb 2026-05-23    # 指定日

require "date"
require "fileutils"
require "json"
require "socket"
require "time"
require "uri"

require "google/apis/calendar_v3"
require "googleauth"
require "googleauth/stores/file_token_store"

CONFIG_DIR    = File.join(Dir.home, ".config", "gcal")
CRED_PATH     = File.join(CONFIG_DIR, "credentials.json")
TOKEN_PATH    = File.join(CONFIG_DIR, "token.yaml")
SCOPE         = Google::Apis::CalendarV3::AUTH_CALENDAR_READONLY
CALLBACK_URI  = "http://127.0.0.1:9876"
USER_ID       = "default"

def authorizer
  FileUtils.mkdir_p(CONFIG_DIR)
  client_id   = Google::Auth::ClientId.from_file(CRED_PATH)
  token_store = Google::Auth::Stores::FileTokenStore.new(file: TOKEN_PATH)
  Google::Auth::UserAuthorizer.new(client_id, SCOPE, token_store, CALLBACK_URI)
end

def authenticate!
  auth = authorizer
  url  = auth.get_authorization_url
  warn "ブラウザで開いて認証してください: #{url}"
  system("xdg-open", url, out: File::NULL, err: File::NULL)

  uri     = URI(CALLBACK_URI)
  server  = TCPServer.new(uri.host, uri.port)
  session = server.accept
  path    = session.gets.split(" ")[1]
  code    = URI.decode_www_form(URI(path).query).to_h.fetch("code")
  session.write "HTTP/1.1 200 OK\r\n\r\n認証完了\n"
  session.close
  server.close

  auth.get_and_store_credentials_from_code(user_id: USER_ID, code: code)
  warn "保存: #{TOKEN_PATH}"
end

def parse_date(arg)
  case arg
  when nil, "today" then Date.today
  when "tomorrow"   then Date.today + 1
  when "yesterday"  then Date.today - 1
  else                   Date.parse(arg)
  end
end

def fetch_events(date)
  service = Google::Apis::CalendarV3::CalendarService.new
  service.authorization = authorizer.get_credentials(USER_ID)

  day_start = Time.new(date.year, date.month, date.day)
  day_end   = day_start + 24 * 60 * 60

  result = service.list_events(
    "primary",
    single_events: true,
    order_by:      "startTime",
    time_min:      day_start.iso8601,
    time_max:      day_end.iso8601,
    max_results:   250,
  )

  result.items.map do |e|
    {
      id:        e.id,
      summary:   e.summary,
      start:     e.start.date_time&.iso8601 || e.start.date,
      end:       e.end.date_time&.iso8601   || e.end.date,
      all_day:   !e.start.date.nil?,
      location:  e.location,
      attendees: (e.attendees || []).map { |a| { email: a.email, response: a.response_status } },
      html_link: e.html_link,
    }
  end
end

if ARGV[0] == "auth"
  authenticate!
else
  puts JSON.pretty_generate(events: fetch_events(parse_date(ARGV[0])))
end
