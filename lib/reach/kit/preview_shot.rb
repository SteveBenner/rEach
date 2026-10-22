# frozen_string_literal: true

require "json"
require "ferrum"

url, out_png, module_id = ARGV
unless url && out_png && module_id
  warn "reach-preview: usage: preview_shot.rb URL OUT_PNG MODULE_ID"
  exit 1
end

def clip(text)
  text.to_s.gsub(/\s+/, " ").strip[0, 300]
end

console_errors = []
options = { headless: true, window_size: [1280, 800], process_timeout: 20, timeout: 15, js_errors: false }
options[:browser_path] = ENV["REACH_CHROME"] if ENV["REACH_CHROME"] && !ENV["REACH_CHROME"].empty?
options[:browser_options] = { "no-sandbox" => nil } if ENV["CUPRITE_NO_SANDBOX"] == "1"

browser = nil
result = nil
begin
  browser = Ferrum::Browser.new(**options)
  page = browser.page

  page.on("Runtime.consoleAPICalled") do |params|
    next unless params["type"] == "error"

    text = Array(params["args"]).map { |arg| arg["value"] || arg["description"] }.compact.join(" ")
    console_errors << clip(text)
  end
  page.on("Runtime.exceptionThrown") do |params|
    details = params["exceptionDetails"] || {}
    text = details.dig("exception", "description") || details["text"]
    console_errors << clip(text)
  end
  page.on("Log.entryAdded") do |params|
    entry = params["entry"] || {}
    console_errors << clip("#{entry['text']} #{entry['url']}") if entry["level"] == "error"
  end
  page.command("Log.enable")

  begin
    browser.goto(url)
  rescue Ferrum::StatusError
    nil
  end
  selector = "[data-dovetail-panel='#{module_id}']"
  found = false
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    found = !browser.at_css(selector).nil?
    break if found

    sleep 0.25
  end
  begin
    page.network.wait_for_idle(timeout: 3)
  rescue Ferrum::TimeoutError
    nil
  end

  browser.screenshot(path: out_png, full: true)

  failed = []
  page.network.traffic.each do |exchange|
    status = exchange.response&.status
    if exchange.error
      failed << { "url" => exchange.url.to_s[0, 300], "status" => status || exchange.error.error_text.to_s }
    elsif status && status >= 400
      failed << { "url" => exchange.url.to_s[0, 300], "status" => status }
    end
  end

  result = {
    "png" => out_png,
    "panel_found" => found,
    "console_errors" => console_errors.uniq.first(20),
    "failed_requests" => failed.first(20)
  }
rescue StandardError => e
  warn "reach-preview: #{clip(e.message)}"
  exit 1
ensure
  begin
    browser&.quit
  rescue StandardError
    nil
  end
end

puts JSON.generate(result)
exit 0
