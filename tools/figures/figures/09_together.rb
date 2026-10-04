# frozen_string_literal: true

module Figures
  TOGETHER = [
    ["Identity", "Anyone can install it. Nobody knows who is doing the work.",
     "The roster confirms the student, and the enrollment is tied to their computer."],
    ["Rules", "Rules are local files that the machine's owner can edit.",
     "Rules arrive signed by the instructors. Unsigned or stale rules stop the work."],
    ["Checks", "An agent can only pass the checks it can see, and can tune to them.",
     "Hidden checks run on the server, where the agent can neither read nor tune to them."],
    ["Evidence", "Seals and ledgers are written, and nobody ever reads them.",
     "The server reads the seal and the witness ledger when it weighs where work came from."],
    ["Proof", "\"Submitted\" is only a claim on the student's own computer.",
     "A signed receipt proves what arrived and when. The due time is enforced on the server."],
    ["Help", "A stuck student stays stuck, and no one finds out.",
     "After three failed tries a hand goes up to the instructors, who can answer."]
  ].freeze

  figure("09-why-together",
         title: "rEach alone and rEach with Teach",
         desc: "A side-by-side comparison across six capabilities: identity, rules, checks, evidence, proof and help. Alone, rEach is a careful assistant with nobody to answer to. With Teach, each capability closes into a loop the agent cannot grade itself in.") do |f|
    f.header("09", "Why the two belong together", "rEach alone is a careful assistant with nobody to answer to. Teach is what makes its promises checkable.")

    lx = 300
    lw = 720
    rx = 1060
    rw = 780
    f.rect(lx, 244, lw, 818, rx: 24, fill: :panel, fo: 0.6, stroke: :faint, sw: 1.5, so: 0.6, dash: "8 7")
    f.badge(lx + 44, 290, 24, :shield, :faint)
    f.text(lx + 78, 290, "rEach alone", size: 26, weight: 650, fill: :soft)
    f.text(lx + 78, 314, "every promise rests on the student's own computer", size: 15, fill: :faint)

    f.frost(rx, 244, rw, 818, title: "rEach with Teach", sub: "every promise has someone on the other side to check it", zones: [], seed: 21, title_size: 26)

    TOGETHER.each_with_index do |(name, alone, both), i|
      y = 350 + i * 116
      f.text(80, y + 42, name, size: 24, weight: 650)
      f.line(80, y + 60, 250, y + 60, stroke: :line, sw: 1.5)
      f.rect(lx + 22, y, lw - 44, 96, rx: 14, fill: :panel, stroke: :line, sw: 1.2)
      f.level(lx + 56, y + 48, :deny, r: 13)
      f.para(lx + 88, y + 42, alone, 72, size: 16, fill: :soft, lh: 23)
      f.rect(rx + 22, y, rw - 44, 96, rx: 14, fill: :zone, fo: f.theme[:zone_op], stroke: :teach, sw: 1.2, so: 0.45)
      f.level(rx + 56, y + 48, :full, r: 13)
      f.para(rx + 88, y + 42, both, 84, size: 16, fill: :ink, lh: 23)
      f.arrow([[lx + lw - 16, y + 48], [rx + 16, y + 48]], tone: :teach, sw: 2.2)
    end

    f.footer(LEGEND, note: "The mechanisms behind the glass are private. The guarantees are public.")
  end
end
