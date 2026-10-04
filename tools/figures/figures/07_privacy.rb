# frozen_string_literal: true

module Figures
  NEVER = ["Anything said before sign-in", "The extracurricular folder", "Chats outside the course folder", "The student ID typed at sign-in", "Prompts the gate blocks"].freeze
  STAYS = ["The interview profile", "Private memory of how the student works", "The extracurricular folder", "The install's private key", "Unsealed course materials", "ZIP copies and signed receipts"].freeze
  LEAVES = [
    ["Assignment conversations", "signed in, on an assignment: all of it"],
    ["Enrollment details", "and a scrambled computer fingerprint"],
    ["Submitted files", "only after the student says yes"],
    ["Own-part answers", "the questions only the student can answer"],
    ["Help requests", "a summary the student agrees to send"],
    ["\"Anything new?\" checks", "no files, no conversation text"],
    ["Fault reports", "where it failed, never what was typed"]
  ].freeze

  def self.privacy_columns(f)
    f.card(116, 318, 330, 520, tone: :stop, icon: :eye_off, title: "Never recorded")
    f.bullets(140, 410, NEVER, tone: :stop, gap: 42, size: 17, fill: :ink)
    f.para(140, 640, "Not written to disk. Not sent anywhere by rEach. Recording runs only for signed-in assignment work.", 30, size: 15, fill: :soft, lh: 22)
    f.card(468, 318, 360, 520, tone: :student, icon: :lock, title: "Stays on this computer")
    f.bullets(492, 410, STAYS, tone: :student, gap: 42, size: 16, fill: :ink)
    f.para(492, 690, "The student can see it, export it and erase it. The profile is shared only inside a help request the student agrees to.", 34, size: 15, fill: :soft, lh: 22)
    f.card(850, 318, 380, 520, tone: :reach, icon: :doc, title: "Leaves, to the course server")
    LEAVES.each_with_index do |(head, sub), i|
      y = 398 + i * 61
      f.icon(:check, 884, y + 2, 18, :reach, sw: 2.2)
      f.text(904, y + 7, head, size: 17, weight: 650)
      f.text(904, y + 29, sub, size: 14, fill: :soft)
    end
  end

  figure("07-privacy-map",
         title: "rEach and Teach: the privacy map",
         desc: "Three columns on the student's computer: what is never recorded, what stays on the computer and what leaves for the course server. Teach receives only the third column, which includes the conversation of signed-in assignment work.") do |f|
    f.header("07", "The privacy map", "What is never recorded, what never leaves and the list of what the course server receives.")

    f.boundary(80, 268, 1186, 610, "The student's computer", tone: :student)
    privacy_columns(f)

    f.frost(1340, 268, 500, 610, zone_h: 82, top: 108, gap: 14, zones: [
              ["Submitted work", "what the student said yes to", :doc],
              ["Enrollment record", "a roster match, a fingerprint", :person],
              ["Help requests", "a summary and recent changes", :hand],
              ["Assignment conversations", "signed-in assignment work only", :doc],
              ["Run by the instructors", "they control what it keeps", :board]
            ])
    f.arrow([[1230, 578], [1340, 578]], tone: :reach, sw: 4)
    f.pill(1285, 536, "sealed", tone: :reach, size: 13, anchor: "middle")

    [
      [:soft, :cloud, "The AI provider", "What the student types goes to the AI provider they chose, as any chat does, under that provider's policy."],
      [:student, :brain, "Memory is the student's", "Ask rEach what it remembers, or run reach memory list. reach memory forget erases it."],
      [:instructor, :board, "The grade of record", "Nothing rEach saves changes a grade. The grade of record is kept by the school."]
    ].each_with_index do |(tone, ico, head, body), i|
      x = 80 + i * 596
      f.card(x, 922, 568, 138, tone: tone, icon: ico, title: head, accent: false)
      f.para(x + 22, 1000, body, 66, size: 14, fill: :soft, lh: 20)
    end

    f.footer(LEGEND)
  end
end
