require "json"
require "openssl"
require "open3"

module SecurityAuditScan
  EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904".freeze

  SECRET_PATTERNS = [
    ["private key block", /-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----/, 0],
    ["AWS access key", /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/, 0],
    ["GitHub token", /\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{22,})/, 0],
    ["Anthropic key", /\bsk-ant-[A-Za-z0-9_\-]{20,}/, 0],
    ["OpenAI key", /\bsk-(?:proj-)?[A-Za-z0-9_\-]{32,}/, 0],
    ["Slack token", /\bxox[abprs]-[A-Za-z0-9\-]{10,}/, 0],
    ["Google API key", /\bAIza[0-9A-Za-z_\-]{35}/, 0],
    ["bearer token", /\bBearer\s+([A-Za-z0-9_\-\.=]{20,})/i, 1],
    ["URL with embedded credentials", %r{\b[a-z][a-z0-9+.\-]*://[^/\s:@"']+:([^/\s@"']+)@[^\s"']+}i, 1],
    ["password literal", /\b(?:password|passwd|pwd)\b["']?\s*[:=]\s*["']([^"'\s]{4,})["']/i, 1]
  ].freeze

  SECRET_FILES = [
    /(?:\A|\/)\.env(?:\.[^\/]*)?\z/,
    /\.pem\z/,
    /\.key\z/,
    /(?:\A|\/)id_rsa[^\/]*\z/,
    /\.p12\z/,
    /(?:\A|\/)credentials[^\/]*\.json\z/,
    /(?:\A|\/)TOKENS\.jsonl\z/,
    /\.(?:sqlite3?|db)\z/,
    /(?:\A|\/)teach\.env\z/
  ].freeze

  LOCK_FILE = /(?:\.lock|-lock\.json|\.lockb)\z/
  EMAIL = /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/
  DIGITS = /(?<!\d)\d{6,9}(?!\d)/
  WORD = /[A-Za-z][A-Za-z'\-]*/
  LOCAL_PATH = %r{(?:/home/[A-Za-z0-9._\-]+/|/Users/[A-Za-z0-9._\-]+/|[A-Za-z]:\\Users\\[A-Za-z0-9._\-]+\\)}
  QUOTED = /["']([^"'\s]{32,})["']/
  STUDENT_ID = /student[\s_\-]*id\D{0,24}(?<!\d)(\d{6,9})(?!\d)/i
  INSTITUTION_EMAIL = /[A-Za-z0-9._%+\-]+@(?:[A-Za-z0-9\-]+\.)+edu\b/i

  module_function

  def mask(value)
    text = value.to_s
    return "*" * text.length if text.length <= 4

    stars = [text.length - 4, 16].min
    text[0, 2] + ("*" * stars) + text[-2, 2]
  end

  def mask_text(text)
    out = text.to_s.dup
    SECRET_PATTERNS.each do |_, pattern, group|
      out = out.gsub(pattern) do
        match = Regexp.last_match
        whole = match[0]
        if group.zero?
          mask(whole)
        else
          whole.sub(match[group], mask(match[group]))
        end
      end
    end
    out.gsub(INSTITUTION_EMAIL) { |value| mask(value) }
  end

  def entropy(text)
    counts = Hash.new(0)
    text.each_char { |char| counts[char] += 1 }
    size = text.length.to_f
    counts.values.inject(0.0) { |sum, count| p = count / size; sum - p * Math.log2(p) }
  end

  def git(root, *args)
    out, status = Open3.capture2("git", "-C", root, "-c", "core.quotepath=false", *args, err: File::NULL)
    status.success? ? out : nil
  end

  def diff(root, base, sha)
    raw = git(root, "diff", "--unified=0", "--no-color", "--no-ext-diff", "--no-renames", "--diff-filter=AMR", base, sha) || ""
    added = []
    file = nil
    line = 0
    raw.each_line do |row|
      row = row.chomp
      if row.start_with?("+++ ")
        name = row[4..-1].to_s.sub(/\t.*\z/, "")
        file = name == "/dev/null" ? nil : name.sub(%r{\Ab/}, "")
      elsif row.start_with?("@@")
        line = row[/\+(\d+)/, 1].to_i
      elsif row.start_with?("+") && file
        added << [file, line, row[1..-1].to_s]
        line += 1
      end
    end
    paths = (git(root, "diff", "--name-only", "--no-renames", "--diff-filter=AMR", base, sha) || "").split("\n")
    { raw: raw, added: added, paths: paths }
  end

  def candidates(text)
    found = []
    text.scan(EMAIL) { |m| found << [:email, m.downcase] }
    text.scan(DIGITS) { |m| found << [:digits, m] }
    tokens = text.scan(WORD).map(&:downcase)
    tokens.each { |t| found << [:word, t] if t.length >= 4 }
    tokens.each_cons(2) do |a, b|
      pair = "#{a} #{b}"
      found << [:words, pair] if pair.length >= 4
    end
    found
  end

  def roster_index(roster)
    return nil unless roster.is_a?(Hash) && roster["salt"] && roster["digests"].is_a?(Array)

    { salt: roster["salt"].to_s, set: roster["digests"].each_with_object({}) { |d, h| h[d.to_s] = true }, memo: {} }
  end

  def digest(index, value)
    index[:memo][value] ||= OpenSSL::HMAC.hexdigest("SHA256", index[:salt], value)
  end

  def run(root, base, diff, roster, roster_check)
    findings = []
    seen = {}
    index = roster_check ? roster_index(roster) : nil
    add = lambda do |severity, category, file, line, title, detail, key|
      id = [file, line, category, key]
      next if seen[id]

      seen[id] = true
      findings << { "severity" => severity, "category" => category, "file" => file, "line" => line, "title" => title, "detail" => detail }
    end

    diff[:paths].each do |path|
      next unless SECRET_FILES.any? { |rule| path =~ rule }

      add.call("critical", "secret-file", path, nil, "Secret-bearing file in release", "#{path} matches a file name that normally holds credentials or private data", path)
    end

    diff[:added].each do |file, line, text|
      next if text.length > 4000 && file =~ /\.(?:min\.js|svg|json|map)\z/

      SECRET_PATTERNS.each do |name, pattern, group|
        text.scan(pattern) do
          match = Regexp.last_match
          value = group.zero? ? match[0] : match[group]
          add.call("critical", "secret", file, line, "Possible #{name}", "#{name} found, value #{mask(value)}", value)
        end
      end

      roster_hit = false
      if index
        candidates(text).each do |kind, value|
          next unless index[:set][digest(index, value)]

          roster_hit = true
          add.call("critical", "student-data", file, line, "Student identifier in release", "A #{kind} value #{mask(value)} matches the student roster", value)
        end
      end

      unless roster_hit
        text.scan(INSTITUTION_EMAIL) do
          value = Regexp.last_match[0]
          add.call("high", "student-data-shape", file, line, "Student-style email address", "Address #{mask(value)} has the shape of a student address", value)
        end
        text.scan(STUDENT_ID) do
          value = Regexp.last_match[1]
          add.call("high", "student-data-shape", file, line, "Student ID near a number", "A student ID label is followed by #{mask(value)}", value)
        end
      end

      unless file =~ LOCK_FILE
        text.scan(QUOTED) do
          value = Regexp.last_match[1]
          next unless entropy(value) > 4.5

          add.call("high", "entropy", file, line, "High-entropy quoted string", "A #{value.length}-character string #{mask(value)} looks like a generated secret", value)
        end
      end

      text.scan(LOCAL_PATH) do
        value = Regexp.last_match[0]
        next if carried?(root, base, file, value)

        add.call("medium", "local-path", file, line, "Absolute home path", "Path #{value} exposes a local account name", value)
      end
    end

    findings
  end

  def carried?(root, base, file, value)
    return false unless file =~ /\.md\z/ || file.start_with?("docs/")
    return false if base == EMPTY_TREE

    old = git(root, "show", "#{base}:#{file}")
    !old.nil? && old.include?(value)
  end
end
