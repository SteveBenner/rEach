# frozen_string_literal: true

module Figures
  TOGETHER = [
    ["Identity", "Anyone can install it. Nobody knows who is doing the work.",
     "The roster confirms the student, the enrollment is tied to their computer and a password signs them in."],
    ["Rules", "Rules are local files that the machine's owner can edit.",
     "Rules arrive signed by the instructors. Unsigned or stale rules stop the work."],
    ["Checks", "An agent can only pass the checks it can see, and can tune to them.",
     "Hidden checks run on the server, where the agent can neither read nor tune to them."],
    ["Evidence", "Seals and ledgers are written, and nobody ever reads them.",
     "The server reads the seal and the witness ledger when it weighs where work came from."],
    ["Record", "Nobody sees how the work was actually done.",
     "De-identified assignment conversations reach the instructors, who can read how the work was made."],
    ["Proof", "\"Submitted\" is only a claim on the student's own computer.",
     "A signed receipt proves what arrived and when. The due time is kept on the server."],
    ["Help", "A stuck student stays stuck, and no one finds out.",
     "Hands, fault reports and notes reach the instructors, who answer, live if needed."]
  ].freeze

  figure("09-why-together",
         title: "rEach alone and rEach with Teach",
         desc: "A side-by-side comparison across seven capabilities: identity, rules, checks, evidence, record, proof and help. Alone, rEach is a careful assistant with nobody to answer to. With Teach, each capability closes into a loop the agent cannot grade itself in.") do |f|
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
      y = 346 + i * 100
      f.text(80, y + 40, name, size: 22, weight: 650)
      f.line(80, y + 56, 250, y + 56, stroke: :line, sw: 1.5)
      f.rect(lx + 22, y, lw - 44, 86, rx: 14, fill: :panel, stroke: :line, sw: 1.2)
      f.level(lx + 56, y + 43, :deny, r: 13)
      la = f.wrap(alone, 72)
      f.lines(lx + 88, y + 49 - (la.length - 1) * 11, la, size: 16, fill: :soft, lh: 22)
      f.rect(rx + 22, y, rw - 44, 86, rx: 14, fill: :zone, fo: f.theme[:zone_op], stroke: :teach, sw: 1.2, so: 0.45)
      f.level(rx + 56, y + 43, :full, r: 13)
      lb = f.wrap(both, 78)
      f.lines(rx + 88, y + 49 - (lb.length - 1) * 11, lb, size: 16, fill: :ink, lh: 22)
      f.arrow([[lx + lw - 16, y + 43], [rx + 16, y + 43]], tone: :teach, sw: 2.2)
    end

    f.footer(LEGEND, note: "The mechanisms behind the glass are private. The guarantees are public.")
  end
end
