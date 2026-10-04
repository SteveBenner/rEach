# frozen_string_literal: true

module Figures
  STAGES = [
    ["Sync", :box, :teach, ["Sealed rules and the", "student's slice arrive.", "No rules, no work."], "reach sync", "provisioned"],
    ["Build", :agent, :reach, ["The agent codes inside", "the slice. Every write", "passes the gate."], "reach gate", "in_progress"],
    ["Check", :shield, :reach, ["Each change is tested", "against the course", "shape and the rules."], "reach check", "in_progress"],
    ["Qualify", :loop, :reach, ["The agent proves the", "slice with scenarios", "of its own."], "reach qualify", "checked"],
    ["Consent", :person, :student, ["rEach asks the student.", "Only a yes, for exactly", "these files, counts."], "yes, within 30 min", "checked"],
    ["Submit", :doc, :reach, ["The work is sealed", "and sent. rEach waits", "for the receipt."], "reach submit", "submitted"],
    ["Receipt", :receipt, :teach, ["Signed proof arrives.", "A ZIP copy lands in", "Downloads."], "reach grade", "received, graded"]
  ].freeze

  def self.stage_x(i)
    80 + i * 254
  end

  figure("04-work-lifecycle",
         title: "rEach and Teach: the work lifecycle",
         desc: "Seven stages from sync to receipt: sync, build, check, qualify, consent, submit and receipt. Four of them exchange sealed or signed material with Teach.") do |f|
    f.header("04", "The work lifecycle", "One slice of one assignment, from the first sealed package to the signed receipt.")

    f.line(196, 262, 1720, 262, stroke: :line, sw: 3)
    STAGES.each_with_index do |(name, ico, tone, body, tag, state), i|
      x = stage_x(i)
      f.num(x + 116, 262, i + 1, tone, r: 18)
      f.card(x, 300, 232, 236, tone: tone, icon: ico, title: name, body: body, tag: tag, body_size: 15, pad: 20)
      f.text(x + 116, 566, state, size: 13, fill: :faint, mono: true, anchor: "middle")
    end

    f.frost(80, 724, 1760, 216, zone_h: 78, top: 108, cols: 4, sub: "course server · private to the instructors", zones: [
              ["Builds and seals", "one package per student", :box],
              ["Runs the hidden checks", "ungraded, same checks as grading", :eye_off],
              ["Takes the work in", "timestamps it, enforces the due time", :doc],
              ["Receipts, grades, replies", "signed, then shown by rEach", :receipt]
            ])

    f.arrow([[196, 724], [196, 590]], tone: :teach, sw: 3, label: ["sealed", "packages"], at: [212, 648], anchor: "start")
    f.arrow([[958, 590], [958, 724]], tone: :reach, sw: 3, both: true, label: ["ungraded run", "on the server"], at: [974, 648], anchor: "start")
    f.arrow([[1466, 590], [1466, 724]], tone: :reach, sw: 3, label: ["sealed", "submission"], at: [1482, 648], anchor: "start")
    f.arrow([[1720, 724], [1720, 590]], tone: :teach, sw: 3, label: ["signed", "receipts"], at: [1704, 648], anchor: "end")

    f.arrow([[958, 242], [958, 216], [450, 216], [450, 240]], tone: :stop, sw: 2, dashed: true)
    f.text(704, 206, "fails? fix and try again", size: 14, weight: 600, fill: :stop, anchor: "middle", halo: true)

    f.card(80, 968, 868, 104, tone: :stop, icon: :hand, title: "Three failed tries raise a hand",
           body: ["rEach tells the instructors on its own, and at the hard stop the agent may write no more."])
    f.card(972, 968, 868, 104, tone: :soft, icon: :cloud, title: "Offline is not a dead end", accent: false,
           body: ["The gate passes for up to 24 hours on verified rules, and submissions wait in a queue."])

    f.footer(LEGEND)
  end
end
