require "digest"
require "json"
require "net/http"
require "open3"
require "time"
require "uri"
require "rubygems"

module ReleaseGate
  class Context
    TIMEOUT_S = 10

    attr_reader :repo

    def initialize(repo)
      @repo = repo
      @raw = {}
    end

    def git(*args)
      out, status = Open3.capture2("git", "-C", repo.root, "-c", "core.quotepath=false", *args, err: File::NULL)
      status.success? ? out : nil
    rescue StandardError
      nil
    end

    def git_lines(*args)
      (git(*args) || "").split("\n").map(&:strip).reject(&:empty?)
    end

    def show(sha, path)
      git("show", "#{sha}:#{path}")
    end

    def gh(*args)
      binary = ENV["RELEASE_GATE_GH"].to_s.empty? ? "gh" : ENV["RELEASE_GATE_GH"]
      out, err, status = Open3.capture3(binary, *args, chdir: repo.root)
      status.success? ? [out.strip, nil] : [nil, err.lines.first.to_s.strip[0, 160]]
    rescue Errno::ENOENT
      [nil, "#{binary} not found"]
    rescue StandardError => e
      [nil, e.class.name]
    end

    def raw(path)
      return @raw[path] if @raw.key?(path)

      uri = URI.parse("#{repo.raw_base}/#{path}")
      net = Net::HTTP.new(uri.host, uri.port)
      net.use_ssl = uri.scheme == "https"
      net.open_timeout = TIMEOUT_S
      net.read_timeout = TIMEOUT_S
      response = net.request(Net::HTTP::Get.new(uri.request_uri))
      @raw[path] = response.code.to_i == 200 ? [response.body.to_s, nil] : [nil, "HTTP #{response.code}"]
    rescue StandardError => e
      @raw[path] = [nil, e.class.name]
    end

    def owner_heads
      out, status = Open3.capture2("git", "ls-remote", "--heads", repo.owner_git, err: File::NULL)
      return nil unless status.success?

      out.split("\n").map { |line| line.split(/\s+/).first }.compact
    rescue StandardError
      nil
    end
  end

  module Checks
    ACCEPTS_FLOOR = Gem::Version.new("0.40.0")
    TABLE = {
      "GATE-SPEC" => { repos: %w[reach teach], class: "critical_class" },
      "GATE-FACTS" => { repos: %w[reach teach], class: "critical_class" },
      "SEC-SCAN" => { repos: %w[reach teach], class: "critical_class" },
      "SEC-AUDIT" => { repos: %w[reach teach], class: "warn_class" },
      "CMP-WIRE-LIVE" => { repos: %w[reach], class: "critical_class" },
      "CMP-WIRE-MAIN" => { repos: %w[reach], class: "warn_class" },
      "CMP-PIN" => { repos: %w[reach teach], class: "critical_class" },
      "CMP-INSTALLS" => { repos: %w[teach], class: "critical_class" },
      "VER-COLLISION" => { repos: %w[reach teach], class: "critical_class" },
      "VER-HOMES" => { repos: %w[reach teach], class: "critical_class" },
      "VER-TAG-RELEASE" => { repos: %w[reach], class: "warn_class" },
      "VER-DEMOTE" => { repos: %w[reach], class: "critical_class" },
      "VER-STABLE" => { repos: %w[reach], class: "warn_class" },
      "KNOWN-ALARM" => { repos: %w[reach teach], class: "critical_class" },
      "KNOWN-ISSUE" => { repos: %w[reach teach], class: "critical_class" },
      "KNOWN-DOCTOR" => { repos: %w[reach teach], class: "critical_class" },
      "KNOWN-BACKUP" => { repos: %w[reach teach], class: "critical_class" },
      "INST-FLAP" => { repos: %w[reach teach], class: "critical_class" },
      "INST-STALE" => { repos: %w[reach teach], class: "critical_class" }
    }.freeze
    ORDER = %w[CMP-WIRE-LIVE CMP-WIRE-MAIN CMP-PIN CMP-INSTALLS VER-COLLISION VER-HOMES VER-TAG-RELEASE VER-DEMOTE VER-STABLE
               KNOWN-ALARM KNOWN-ISSUE KNOWN-DOCTOR KNOWN-BACKUP INST-FLAP INST-STALE].freeze
    FACTS_CHECKS = %w[CMP-WIRE-LIVE CMP-WIRE-MAIN CMP-PIN CMP-INSTALLS KNOWN-ALARM KNOWN-ISSUE KNOWN-DOCTOR KNOWN-BACKUP INST-FLAP INST-STALE].freeze
    DESK_STALE_S = 3 * 3600
    SELF_ALARMS = /\Arelease_gate(?:_override)?:/.freeze

    module_function

    def finding(id, severity, title, detail, clear = nil)
      { "id" => id, "severity" => severity, "class" => TABLE.fetch(id)[:class], "title" => title, "detail" => detail.to_s[0, 2000], "clear" => clear }
    end

    def error(id, detail)
      finding(id, "error", "#{id} could not run", detail)
    end

    def digest(text)
      Digest::SHA256.hexdigest(text.to_s.gsub("\r\n", "\n"))
    end

    def short(sha)
      sha.to_s[0, 12]
    end

    def version(text)
      Gem::Version.new(text.to_s.strip.sub(/\A[vV]/, "").sub(/\+.*\z/, ""))
    rescue ArgumentError
      nil
    end

    def spec_mismatch(repo)
      spec = repo.spec
      return error("GATE-SPEC", "#{repo.spec_path} is missing or not valid YAML") unless spec.is_a?(Hash) && spec["checks"].is_a?(Array)

      listed = {}
      spec["checks"].each { |row| listed[row["id"].to_s] = { repos: Array(row["repos"]).map(&:to_s).sort, class: row["class"].to_s } if row.is_a?(Hash) }
      compiled = TABLE.each_with_object({}) { |(id, row), out| out[id] = { repos: row[:repos].sort, class: row[:class] } }
      return nil if listed == compiled

      missing = compiled.keys - listed.keys
      extra = listed.keys - compiled.keys
      differ = (compiled.keys & listed.keys).reject { |id| compiled[id] == listed[id] }
      parts = []
      parts << "the code runs #{missing.join(', ')} which the spec does not name" unless missing.empty?
      parts << "the spec names #{extra.join(', ')} which the code lacks" unless extra.empty?
      parts << "#{differ.join(', ')} differ in repos or class" unless differ.empty?
      error("GATE-SPEC", parts.join("; "))
    end

    def run(repo, release, facts, ctx, overrides: [])
      findings = []
      ORDER.each do |id|
        next unless TABLE[id][:repos].include?(repo.name)
        next if FACTS_CHECKS.include?(id) && facts.nil?

        begin
          result = send(id.downcase.tr("-", "_"), repo, release, facts, ctx, overrides)
          findings.concat((result.is_a?(Array) ? result : [result]).compact)
        rescue StandardError => e
          findings << error(id, "#{e.class.name}: #{e.message.to_s[0, 200]}")
        end
      end
      findings
    end

    def release_wire_digest(ctx, sha)
      text = ctx.show(sha, "specs/wire.yml")
      text && digest(text)
    end

    def cmp_wire_live(_repo, release, facts, ctx, _overrides)
      mine = release_wire_digest(ctx, release[:sha])
      return error("CMP-WIRE-LIVE", "specs/wire.yml is not in the pushed tree") unless mine

      live = facts.dig("teach", "wire_sha256").to_s
      return error("CMP-WIRE-LIVE", "Teach reported no wire digest") if live.empty?
      return nil if mine == live

      finding("CMP-WIRE-LIVE", "high", "Wire contract differs from the live Teach",
              "this release's specs/wire.yml is #{short(mine)}, the live Teach #{facts.dig('teach', 'version_tree')} serves #{short(live)}; every install that updates would run a contract Teach does not match",
              "deploy the Teach that carries this contract first, or override with the deploy order as the reason")
    end

    def cmp_wire_main(_repo, release, facts, ctx, _overrides)
      mine = release_wire_digest(ctx, release[:sha])
      live = facts.dig("teach", "wire_sha256").to_s
      main = facts.dig("teach", "main", "wire_sha256")
      return nil unless mine && mine == live
      return error("CMP-WIRE-MAIN", "Teach reported no main digest (no origin/main in its checkout)") if main.to_s.empty?
      return nil if main == mine

      finding("CMP-WIRE-MAIN", "medium", "Teach main carries an unshipped wire change",
              "Teach origin/main (#{short(facts.dig('teach', 'main', 'sha'))}, fetched #{facts.dig('teach', 'main', 'fetched_at')}) has wire #{short(main)}; this release and the live Teach have #{short(mine)}",
              "ship Teach main or revert its contract change")
    end

    def cmp_pin(repo, release, facts, ctx, _overrides)
      return cmp_pin_reach(release, facts, ctx) if repo.name == "reach"

      drifted = []
      on_branch = []
      errors = []
      heads = nil
      repo.pins.each do |pin|
        mine = ctx.show(release[:sha], pin["path"])
        if mine.nil?
          drifted << "#{pin['path']} missing from the pushed tree"
          next
        end
        owner, err = ctx.raw("main/#{pin['owner_path']}")
        if owner.nil?
          errors << "#{pin['owner_path']} on the owner's main: #{err}"
          next
        end
        next if digest(mine) == digest(owner)

        heads = ctx.owner_heads if heads.nil?
        published = Array(heads).any? do |sha|
          body, = ctx.raw("#{sha}/#{pin['owner_path']}")
          body && digest(body) == digest(mine)
        end
        (published ? on_branch : drifted) << "#{pin['path']} (#{short(digest(mine))} here, #{short(digest(owner))} on the owner's main)"
      end
      out = []
      out << error("CMP-PIN", "could not read the owner's copy: #{errors.join('; ')}") unless errors.empty?
      out << finding("CMP-PIN", "high", "Pinned copies drifted from their owner", drifted.join("; "), "re-pin from rEach main, or land the owner's change on its main") unless drifted.empty?
      out << finding("CMP-PIN", "medium", "Pinned copies match a published rEach branch, not main", on_branch.join("; "), "land the owner's change on its main") unless on_branch.empty?
      out
    end

    def cmp_pin_reach(release, facts, ctx)
      out = []
      teach_main = facts.dig("teach", "main", "wire_sha256").to_s
      if teach_main.empty?
        out << error("CMP-PIN", "Teach reported no main wire digest (no origin/main in its checkout)")
      else
        mine = release_wire_digest(ctx, release[:sha])
        origin_main = ctx.git("rev-parse", "--verify", "--quiet", "refs/remotes/origin/main")
        current = origin_main && release_wire_digest(ctx, origin_main.strip)
        unless [mine, current].compact.include?(teach_main)
          out << finding("CMP-PIN", "high", "Teach's pinned wire contract matches neither rEach main nor this release",
                         "Teach main pins #{short(teach_main)}; rEach origin/main has #{short(current)} and this release #{short(mine)}",
                         "re-pin Teach from rEach main")
        end
      end
      control = facts.dig("teach", "main", "agent_control_sha256").to_s
      bundled = ctx.show(release[:sha], "agent-control/agent-control.yml")
      if control.empty?
        out << error("CMP-PIN", "Teach reported no agent-control digest for its main")
      elsif bundled.nil?
        out << finding("CMP-PIN", "high", "the bundled agent-control.yml is missing from the pushed tree",
                       "agent-control/agent-control.yml is absent at #{short(release[:sha])}", "restore the bundled copy from Teach main")
      elsif digest(bundled) != control
        out << finding("CMP-PIN", "medium", "the bundled agent-control.yml differs from Teach main",
                       "bundled #{short(digest(bundled))}, Teach main #{short(control)}; rEach loads the course copy from Teach at run time, so the bundled copy is only the fallback",
                       "re-pin agent-control/agent-control.yml from Teach main")
      end
      out
    end

    def cmp_installs(_repo, release, facts, ctx, _overrides)
      mine = release_wire_digest(ctx, release[:sha])
      minimum = version(facts.dig("teach", "minimum_reach_version"))
      rows = Array(facts.dig("installs", "by_version")).select { |row| row.is_a?(Hash) && row["count"].to_i.positive? }
      below = []
      silenced = []
      degraded = []
      unknown = []
      rows.each do |row|
        ver = version(row["reach_version"])
        label = "#{row['count']} on #{row['reach_version']}"
        if ver.nil?
          unknown << label
          next
        end
        below << label if minimum && ver < minimum
        theirs = row["wire_sha256"].to_s
        if theirs.empty?
          unknown << "#{label} (digest #{row['digest_state'] || 'unknown'})"
        elsif mine && theirs != mine
          (ver < ACCEPTS_FLOOR ? silenced : degraded) << "#{label} (#{short(theirs)})"
        end
      end
      out = []
      out << finding("CMP-INSTALLS", "high", "Active installs below minimum_reach_version", "#{below.join('; ')} would be refused (minimum #{minimum})", "installs update, or the minimum is lowered") unless below.empty?
      out << finding("CMP-INSTALLS", "high", "Active installs whose fault reporting this release would silence", "#{silenced.join('; ')} run a contract other than #{short(mine)} on a rEach older than #{ACCEPTS_FLOOR}", "installs update to rEach #{ACCEPTS_FLOOR} or newer") unless silenced.empty?
      out << finding("CMP-INSTALLS", "medium", "Active installs this release degrades", "#{degraded.join('; ')} run a contract other than #{short(mine)}; typed reporting degrades through accepts", "installs update") unless degraded.empty?
      out << finding("CMP-INSTALLS", "info", "Active installs with an unknown wire digest", unknown.join("; "), "the desk fills digests from the tag list") unless unknown.empty?
      out
    end

    def ver_collision(_repo, release, _facts, ctx, _overrides)
      sha = release[:sha]
      mine = ctx.show(sha, "VERSION").to_s.strip
      return error("VER-COLLISION", "VERSION is not in the pushed tree") if mine.empty?

      heads = ctx.git_lines("for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/remotes").map { |line| line.split(" ", 2) }
      porcelain = (ctx.git("worktree", "list", "--porcelain") || "").split("\n\n")
      porcelain.each do |block|
        head = block[/^HEAD (\h+)/, 1]
        branch = block[/^branch (\S+)/, 1]
        heads << ["worktree #{branch || 'detached'}", head] if head
      end
      same = []
      heads.each do |name, other|
        next if other.nil? || other == sha || name.end_with?("/HEAD")
        next if ctx.git("merge-base", "--is-ancestor", other, sha)
        next if ctx.git("merge-base", "--is-ancestor", sha, other)

        theirs = ctx.show(other, "VERSION").to_s.strip
        same << "#{name.sub('refs/', '')} (#{short(other)})" if theirs == mine
      end
      out = []
      out << finding("VER-COLLISION", "high", "Another line claims version #{mine}", same.uniq.join(", "), "re-version one line, or merge it") unless same.empty?
      remote = ctx.git_lines("ls-remote", "--tags", "origin", "refs/tags/v#{mine}", "refs/tags/v#{mine}^{}")
      peeled = remote.find { |line| line.end_with?("^{}") } || remote.first
      if peeled
        tag_sha = peeled.split(/\s+/).first
        out << finding("VER-COLLISION", "critical", "The remote already holds tag v#{mine} on another commit", "origin v#{mine} is #{short(tag_sha)}, this push is #{short(sha)}", "re-version") if tag_sha && tag_sha != sha
      end
      out
    end

    def home_version(path, text)
      return text.to_s.strip if path == "VERSION"

      if path.end_with?(".json")
        data = JSON.parse(text)
        return data["version"].to_s if data.is_a?(Hash) && data["version"]
        return Array(data["plugins"]).first.to_h["version"].to_s if data.is_a?(Hash) && data["plugins"]

        return nil
      end
      text.to_s[/^version:\s*['"]?([0-9][0-9A-Za-z.+\-]*)/, 1]
    rescue JSON::ParserError
      nil
    end

    def ver_homes(repo, release, _facts, ctx, _overrides)
      sha = release[:sha]
      mine = ctx.show(sha, "VERSION").to_s.strip
      return error("VER-HOMES", "VERSION is not in the pushed tree") if mine.empty?

      wrong = []
      repo.version_homes.each do |path|
        next if path == "VERSION"

        text = ctx.show(sha, path)
        if text.nil?
          wrong << "#{path} missing"
          next
        end
        found = home_version(path, text)
        wrong << "#{path} says #{found.inspect}" unless found == mine
      end
      wrong << "tag #{release[:tag]} is not v#{mine}" if release[:trigger] == "tag" && release[:tag] && release[:tag] != "v#{mine}"
      return nil if wrong.empty?

      finding("VER-HOMES", "high", "Version homes disagree with VERSION #{mine}", wrong.join("; "), "make every home agree")
    end

    def remote_tags(ctx)
      ctx.git_lines("ls-remote", "--tags", "origin", "refs/tags/v*").map { |line| line.split(/\s+/)[1].to_s.sub("refs/tags/", "").sub("^{}", "") }.uniq
    end

    def ver_tag_release(repo, release, _facts, ctx, _overrides)
      released, err = ctx.gh("api", "repos/#{repo.slug}/releases", "--paginate", "--jq", ".[].tag_name")
      return error("VER-TAG-RELEASE", "gh: #{err}") if released.nil?

      missing = remote_tags(ctx) - released.split("\n").map(&:strip) - [release[:tag]].compact
      return nil if missing.empty?

      finding("VER-TAG-RELEASE", "medium", "Tags without a GitHub release", missing.sort.first(10).join(", "), "create the release or delete the tag")
    end

    def latest_release(repo, ctx)
      ctx.gh("api", "repos/#{repo.slug}/releases/latest", "--jq", ".tag_name")
    end

    def ver_demote(repo, release, _facts, ctx, _overrides)
      return nil unless release[:trigger] == "tag" && release[:tag]

      latest, err = latest_release(repo, ctx)
      return error("VER-DEMOTE", "gh: #{err}") if latest.nil?

      pushed = version(release[:tag])
      newest = version(latest)
      return nil if pushed.nil? || newest.nil? || pushed >= newest

      finding("VER-DEMOTE", "high", "Tag #{release[:tag]} is older than Latest #{latest}", "a release made from it would demote Latest", "do not release an older tag, or override with the reason")
    end

    def ver_stable(repo, _release, _facts, ctx, overrides)
      return nil if overrides.any? { |record| Array(record["checks"]).include?("VER-STABLE") || Array(record["checks"]).include?("*") }

      latest, err = latest_release(repo, ctx)
      return error("VER-STABLE", "gh: #{err}") if latest.nil?

      stable = ctx.git_lines("ls-remote", "origin", "refs/heads/stable").first.to_s.split(/\s+/).first
      target_lines = ctx.git_lines("ls-remote", "origin", "refs/tags/#{latest}", "refs/tags/#{latest}^{}")
      target = (target_lines.find { |line| line.end_with?("^{}") } || target_lines.first).to_s.split(/\s+/).first
      return error("VER-STABLE", "origin has no tag #{latest}") if target.to_s.empty?
      return nil if stable == target

      finding("VER-STABLE", "medium", "stable is not at Latest #{latest}", "origin stable is #{stable.to_s.empty? ? 'absent' : short(stable)}, Latest is #{short(target)}, and no hold names why",
              "move stable with tools/release_stable.rb or record a hold")
    end

    def claims(release, ctx)
      base = release[:base]
      text = base ? ctx.git("log", "--format=%B", "#{base}..#{release[:sha]}").to_s : ""
      "#{text}\n#{release[:branch]}"
    end

    def known_alarm(_repo, release, facts, ctx, _overrides)
      claimed = claims(release, ctx)
      open = Array(facts["alarms"]).select { |row| row.is_a?(Hash) && row["severity"] == "blocker" && !(row["check_name"].to_s =~ SELF_ALARMS) }
      unclaimed = open.reject { |row| claimed.include?(row["check_name"].to_s) }
      return nil if unclaimed.empty?

      finding("KNOWN-ALARM", "high", "Open blocker alarms this release does not claim",
              unclaimed.first(10).map { |row| "#{row['check_name']} since #{row['first_at']} (#{row['count']}x): #{row['detail'].to_s[0, 120]}" }.join("; "),
              "the alarm clears, or a commit message names the check")
    end

    def known_issue(repo, release, facts, ctx, _overrides)
      claimed = claims(release, ctx)
      rows = Array(facts["issues"]).select { |row| row.is_a?(Hash) && row["severity"] == "blocker" }
      unclaimed = rows.reject { |row| claimed.include?(row["id"].to_s) }
      mine, theirs = unclaimed.partition { |row| row["repo"].to_s == repo.name }
      out = []
      out << finding("KNOWN-ISSUE", "high", "Open blocker issues of #{repo.name} this release does not claim", mine.first(10).map { |row| "#{row['id']} #{row['state']}: #{row['title'].to_s[0, 100]}" }.join("; "), "ship or close the issue, or name it in a commit message") unless mine.empty?
      out << finding("KNOWN-ISSUE", "medium", "Open blocker issues of the other repository", theirs.first(10).map { |row| "#{row['id']} (#{row['repo']}) #{row['state']}: #{row['title'].to_s[0, 100]}" }.join("; "), "ship or close the issue") unless theirs.empty?
      out
    end

    def known_doctor(_repo, _release, facts, _ctx, _overrides)
      desk = Array(facts["units"]).find { |row| row.is_a?(Hash) && row["unit"] == "service-desk" }
      ran = desk && desk["ran_at"] && (Time.parse(desk["ran_at"].to_s) rescue nil)
      return error("KNOWN-DOCTOR", "the service desk has never recorded a health run, so no doctor verdict exists") if ran.nil?
      return error("KNOWN-DOCTOR", "the service desk last ran at #{desk['ran_at']}, over #{DESK_STALE_S / 3600} hours ago, so the doctor verdict is stale") if Time.now.utc - ran > DESK_STALE_S

      alarm = Array(facts["alarms"]).find { |row| row.is_a?(Hash) && row["check_name"] == "doctor" }
      return nil if alarm.nil?

      finding("KNOWN-DOCTOR", "high", "the course server's doctor fails", "#{alarm['detail']} (since #{alarm['first_at']}, #{alarm['count']}x)", "doctor passes")
    end

    def known_backup(_repo, _release, facts, _ctx, _overrides)
      line = facts["backup_line"]
      return error("KNOWN-BACKUP", "Teach reported no backup line") unless line.is_a?(Hash)
      return nil if line["state"] == "green"

      finding("KNOWN-BACKUP", "high", "The backup line is #{line['state']}", Array(line["reasons"]).join("; "), "a fresh restore-tested backup is in every configured place")
    end

    def inst_flap(_repo, _release, facts, _ctx, _overrides)
      rows = Array(facts["flapping"]).select { |row| row.is_a?(Hash) }
      return nil if rows.empty?

      finding("INST-FLAP", "high", "Flapping alarms (3 or more openings in 24 h)",
              rows.first(10).map { |row| "#{row['check_name']} opened #{row['opens']}x in #{row['window_h']} h (#{row['severity']})" }.join("; "),
              "24 hours pass without a new opening of that alarm")
    end

    def inst_stale(_repo, _release, facts, _ctx, _overrides)
      out = []
      Array(facts["units"]).each do |row|
        next unless row.is_a?(Hash)

        loaded = row["version_loaded"].to_s
        tree = row["version_tree"].to_s
        if loaded.empty?
          out << finding("INST-STALE", "info", "#{row['unit']} reports no loaded version", "its staleness cannot be judged from facts", nil)
        elsif !tree.empty? && loaded != tree
          out << finding("INST-STALE", "high", "#{row['unit']} runs #{loaded} while the tree is #{tree}", "started #{row['started_at']}; its verdicts come from older code", "restart the unit")
        end
      end
      out
    end
  end
end
