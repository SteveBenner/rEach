module Reach
  module Attempts
    THRESHOLD = 3

    module_function

    def record(finding_id:, slice:, resolved:)
      corpus.attempt(finding_id: finding_id, slice: slice, resolved: resolved)
      count = unresolved_streak(finding_id: finding_id, slice: slice)
      { count: count, escalate: !resolved && count >= THRESHOLD }
    end

    def settle(slice:)
      workspace = workspace_for_slice(slice)
      return [] unless workspace

      current_findings = Reach::Check.run(workspace, format: :agent, stamp: true)
      current_ids = current_findings.map { |finding| finding[:finding_id] }.compact

      escalated = []

      open_finding_ids(slice).each do |finding_id|
        resolved = !current_ids.include?(finding_id)
        result = record(finding_id: finding_id, slice: slice, resolved: resolved)
        escalated << finding_id if result[:escalate]
      end

      already_open = open_finding_ids(slice)
      current_findings.each do |finding|
        finding_id = finding[:finding_id]
        next if finding_id.nil?
        next if already_open.include?(finding_id)

        result = record(finding_id: finding_id, slice: slice, resolved: false)
        escalated << finding_id if result[:escalate]
      end

      escalated.uniq
    end

    def corpus
      @corpus ||= Reach::Corpus.new(nil)
    end

    def unresolved_streak(finding_id:, slice:)
      records = corpus.recent("attempt", limit: 1000)
      matching = records.select { |record| record["finding_id"] == finding_id && record["slice"] == slice }
      streak_from(matching)
    end

    def streak_from(records)
      count = 0
      records.reverse_each do |record|
        break if record["resolved"]

        count += 1
      end
      count
    end

    def open_finding_ids(slice)
      records = corpus.recent("attempt", limit: 1000)
      grouped = {}
      records.each do |record|
        next unless record["slice"] == slice

        (grouped[record["finding_id"]] ||= []) << record
      end
      grouped.select { |_finding_id, entries| streak_from(entries).positive? }.keys
    end

    def workspace_for_slice(slice)
      Reach::Workspace.current_slices.find { |path| File.basename(path) == slice.to_s }
    rescue StandardError
      nil
    end
  end
end
