# frozen_string_literal: true

module Figures
  STAGES = [
    ["Sync", :box, :teach, ["Sealed rules and the", "slice arrive. No", "rules, no work."], "reach sync", "provisioned"],
    ["Plan", :doc, :reach, ["The agent plans the", "slice; a second pass", "audits the plan."], "reach plan", "provisioned"],
    ["Build", :agent, :reach, ["The agent codes in", "the slice. Every", "write is saved."], "reach gate", "in_progress"],
    ["Check", :shield, :reach, ["Each change against", "the course shape", "and the rules."], "reach check", "in_progress"],
    ["Qualify", :loop, :reach, ["Its own scenarios run", "here, then on Teach", "with hidden checks."], "reach qualify", "checked"],
    ["Consent", :person, :student, ["rEach asks. Only a", "yes for exactly", "these files counts."], "yes, within 30 min", "checked"],
    ["Submit", :doc, :reach, ["Sealed and sent.", "Late work is taken", "and marked late."], "reach submit", "submitted"],
    ["Receipt", :receipt, :teach, ["Signed proof arrives.", "A ZIP copy lands in", "Downloads."], "reach grade", "received, graded"]
  ].freeze

  def self.stage_x(i)
    80 + i * 222
  end

  def self.stage_cx(i)
    stage_x(i) + 102
  end

  figure("04-work-lifecycle",
         title: "rEach and Teach: the work lifecycle",
         desc: "Eight stages from sync to receipt: sync, plan, build, check, qualify, consent, submit and receipt. Four of them exchange sealed or signed material with Teach, and failed qualifications climb an attempt ladder that ends with the instructors.") do |f|
    f.header("04", "The work lifecycle", "One slice of one assignment, from the first sealed package to the signed receipt.")

    f.line(stage_cx(0), 262, stage_cx(7), 262, stroke: :line, sw: 3)
    STAGES.each_with_index do |(name, ico, tone, body, tag, state), i|
      x = stage_x(i)
      f.num(stage_cx(i), 262, i + 1, tone, r: 18)
      f.card(x, 300, 204, 200, tone: tone, icon: ico, title: name, body: body, tag: tag, body_size: 14, pad: 18, title_size: 20)
      f.text(stage_cx(i), 530, state, size: 13, fill: :faint, mono: true, anchor: "middle")
    end

    f.frost(80, 676, 1760, 216, zone_h: 78, top: 108, cols: 4, zones: [
              ["Builds and seals", "one package per student", :box],
              ["Runs the hidden checks", "ungraded, same checks as grading", :eye_off],
              ["Takes the work in", "timestamps it, marks late work", :doc],
              ["Receipts, grades, replies", "signed, then shown by rEach", :receipt]
            ])

    f.arrow([[stage_cx(0), 676], [stage_cx(0), 554]], tone: :teach, sw: 3, label: ["sealed", "packages"], at: [stage_cx(0) + 16, 606], anchor: "start")
    f.arrow([[stage_cx(4), 554], [stage_cx(4), 676]], tone: :reach, sw: 3, both: true, label: ["ungraded run", "on the server"], at: [stage_cx(4) + 16, 606], anchor: "start")
    f.arrow([[stage_cx(6), 554], [stage_cx(6), 676]], tone: :reach, sw: 3, label: ["sealed", "submission"], at: [stage_cx(6) + 16, 606], anchor: "start")
    f.arrow([[stage_cx(7), 676], [stage_cx(7), 554]], tone: :teach, sw: 3, label: ["signed", "receipts"], at: [stage_cx(7) - 16, 606], anchor: "end")

    f.arrow([[stage_cx(4), 243], [stage_cx(4), 226], [stage_cx(2), 226], [stage_cx(2), 241]], tone: :stop, sw: 2, dashed: true)
    f.text((stage_cx(2) + stage_cx(4)) / 2, 219, "fails? fix and try again", size: 14, weight: 600, fill: :stop, anchor: "middle", halo: true)

    f.card(80, 924, 868, 120, tone: :stop, icon: :hand, title: "The attempt ladder",
           body: ["2nd failed try: a notice. 3rd: a hand goes up, and the student's yes is needed to go on.", "10th: everything stops until an instructor replies. A pass resets it."])
    f.card(972, 924, 868, 120, tone: :soft, icon: :cloud, title: "Offline, partial and written work", accent: false,
           body: ["Offline the gate passes for 24 hours and submissions wait. Unfinished work can go in", "as a partial; a document assignment skips plan, check and qualify."])

    f.footer(LEGEND)
  end
end
