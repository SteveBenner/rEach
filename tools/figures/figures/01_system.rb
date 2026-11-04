# frozen_string_literal: true

module Figures
  LEGEND = [
    [:student, "Student"],
    [:reach, "rEach, on the student's computer"],
    [:teach, "Teach, the private course server"],
    [:instructor, "Instructors"]
  ].freeze

  TEACH_ZONES = [
    ["Roster and enrollment", "who is in the course, on which computer", :person],
    ["Signed course packages", "rules, slices and reference material", :box],
    ["Hidden checks", "run on the server, never shipped", :eye_off],
    ["Receipts and grades", "signed proof of what arrived", :receipt],
    ["Assignment conversations", "kept under a pseudonym", :chat],
    ["Help desk", "hands, notes, live sessions, replies", :hand]
  ].freeze

  HARNESSES = ["Claude Code", "Cowork", "Codex", "Antigravity", "Hermes"].freeze

  REACH_TILES = [
    ["Sign-in", "ID, a yes and the password"],
    ["Gate", "keeps writes inside the slice"],
    ["Plan and check", "the plan, the shape, the rules"],
    ["Qualify", "scenarios here, then on Teach"],
    ["Submit", "only after the student's yes"],
    ["Help", "hands, feedback, live sessions"],
    ["Record", "assignment work, de-identified"],
    ["Memory", "private, on this computer only"]
  ].freeze

  def self.system_body(f)
    f.boundary(80, 268, 1010, 632, "On the student's computer", tone: :student)
    f.card(116, 318, 262, 236, tone: :student, icon: :person, title: "Student",
           body: ["Owns the business", "behavior. Decides what", "to build and when to", "submit. Writes no code."])
    f.card(116, 604, 262, 250, tone: :student, icon: :folder, title: "Course folder",
           body: ["deliverables/: one", "folder per slice, the", "only graded work.", "extracurricular/: their", "own, never sent."], tag: "~/reach-work")

    f.rect(440, 300, 614, 566, rx: 26, fill: :panel)
    f.rect(440, 300, 614, 566, rx: 26, fill: :reach, fo: f.theme[:tint] * 0.7, stroke: :reach, sw: 2, so: 0.8)
    f.badge(486, 348, 26, :shield, :reach)
    f.text(522, 348, "rEach", size: 30, weight: 650)
    f.text(522, 374, "the bounded course partner, inside the student's AI app", size: 15, fill: :soft)
    f.card(476, 400, 542, 150, tone: :soft, icon: :agent, title: "The student's own AI agent",
           body: ["Does all the coding, in files, inside the student's slice."], accent: false)
    x = 498
    HARNESSES.each { |h| x += f.pill(x, 502, h, tone: :soft, size: 13, weight: 500) + 8 }
    REACH_TILES.each_with_index do |(name, sub), i|
      cx = 476 + (i % 2) * 276
      cy = 570 + (i / 2) * 72
      f.rect(cx, cy, 266, 62, rx: 13, fill: :reach, fo: f.theme[:tint], stroke: :reach, sw: 1.1, so: 0.45)
      f.text(cx + 18, cy + 26, name, size: 17, weight: 650, fill: :reach)
      f.text(cx + 18, cy + 47, sub, size: 14, fill: :soft)
    end

    f.arrow([[378, 410], [440, 410]], tone: :student)
    f.arrow([[440, 470], [378, 470]], tone: :reach)
    f.text(409, 392, "asks", size: 13, weight: 600, fill: :student, anchor: "middle", halo: true)
    f.text(409, 496, "answers", size: 13, weight: 600, fill: :reach, anchor: "middle", halo: true)
    f.arrow([[440, 730], [378, 730]], tone: :reach, both: true)
    f.text(409, 712, "fenced", size: 13, weight: 600, fill: :reach, anchor: "middle", halo: true)

    f.frost(1290, 268, 550, 632, zones: TEACH_ZONES, zone_h: 70, top: 104, gap: 12)

    f.arrow([[1290, 450], [1054, 450]], tone: :teach, sw: 3, label: "sealed course packages", at: [1172, 432])
    f.arrow([[1054, 550], [1290, 550]], tone: :reach, sw: 3, label: "signed requests", at: [1172, 532])
    f.arrow([[1054, 640], [1290, 640]], tone: :reach, sw: 3, label: "sealed submissions", at: [1172, 622])
    f.arrow([[1054, 730], [1290, 730]], tone: :reach, sw: 3, label: "de-identified transcripts", at: [1172, 712])
    f.arrow([[1290, 820], [1054, 820]], tone: :teach, sw: 3, label: "signed receipts", at: [1172, 802])
    f.pill(1172, 340, "wire protocol 1 · HTTPS", tone: :soft, mono: true, size: 13, weight: 500, anchor: "middle")
    f.line(1172, 366, 1172, 414, stroke: :faint, sw: 1.2, dash: "3 5")

    f.card(1290, 944, 550, 110, tone: :instructor, icon: :board, title: "Instructors",
           body: ["Set the rules, read the work, answer hands, grade."])
    f.arrow([[1565, 944], [1565, 904]], tone: :instructor)

    [
      [:student, "The student steers", "Plain words about the business; no code, no git."],
      [:reach, "The agent builds, fenced in", "Every write, command and change is checked."],
      [:teach, "The server decides", "Rules, hidden checks, receipts and grades."]
    ].each_with_index do |(tone, head, sub), i|
      cx = 80 + i * 343
      f.rect(cx, 944, 324, 110, rx: 16, fill: :panel, stroke: tone, sw: 1.3, so: 0.45)
      f.circle(cx + 26, 976, 6, fill: tone)
      f.text(cx + 44, 983, head, size: 18, weight: 650)
      f.para(cx + 22, 1014, sub, 38, size: 14, fill: :soft)
    end
  end

  figure("01-system-at-a-glance",
         title: "rEach and Teach: the system at a glance",
         desc: "A student steers their own AI agent. rEach wraps the agent on the student's computer, signs the student in, fences the work into the student's slice and talks over a signed wire to Teach, the private course server the instructors run.") do |f|
    f.header("01", "The system at a glance", "A student, their own AI agent, a bounded partner on their computer and a private course server that decides what counts.")
    system_body(f)
    f.footer(LEGEND)
  end
end
