# frozen_string_literal: true

module Figures
  NEVER = ["Anything said before sign-in", "The extracurricular folder", "Chats outside the course folder", "Sign-in and enrollment steps", "The password, at any step", "Passwords and keys: [redacted]"].freeze
  STAYS = ["The interview profile", "Private memory and its corpus", "A copy of each conversation", "Two copies of every checkpoint", "The setup log, never sent", "The install's private key", "Unsealed course materials", "ZIPs and signed receipts", "The password's check value"].freeze
  LEAVES = [
    ["Assignment conversations", "de-identified, about every ten minutes"],
    ["Enrollment details", "a fingerprint; the password, hashed there"],
    ["Submitted files", "only after the student says yes"],
    ["Own-part answers", "the questions only the student can answer"],
    ["Help requests and notes", "only the text the student agreed to"],
    ["Qualify failure records", "where it failed, no files or chat text"],
    ["Faults and setup problems", "where it failed, never what was typed"],
    ["Progress and app details", "steps, times, app, OS and Ruby"],
    ["\"Anything new?\" checks", "no files, no conversation text"]
  ].freeze

  figure("07-privacy-map", height: 1260,
                           title: "rEach and Teach: the privacy map",
                           desc: "Three columns on the student's computer: what is never in a recording, what stays on the computer and what leaves for the course server. Teach receives only the third column, which includes signed-in assignment conversations under a pseudonym.") do |f|
    f.header("07", "The privacy map", "What is never recorded, what never leaves and the list of what the course server receives.")

    f.boundary(80, 268, 1186, 700, "The student's computer", tone: :student)

    f.card(116, 318, 330, 620, tone: :stop, icon: :eye_off, title: "Never in a recording")
    f.bullets(140, 410, NEVER, tone: :stop, gap: 42, size: 16, fill: :ink)
    f.para(140, 690, "Recording runs only for signed-in assignment work in a course folder. The password is never written to disk or shown to the agent.", 32, size: 15, fill: :soft, lh: 22)

    f.card(468, 318, 360, 620, tone: :student, icon: :lock, title: "Stays on this computer")
    f.bullets(492, 408, STAYS, tone: :student, gap: 40, size: 16, fill: :ink)
    f.para(492, 802, "The student can see, export and erase it. The profile leaves only in a help request they agree to.", 34, size: 15, fill: :soft, lh: 22)

    f.card(850, 318, 380, 620, tone: :reach, icon: :doc, title: "Leaves, to the course server")
    LEAVES.each_with_index do |(head, sub), i|
      y = 400 + i * 58
      f.icon(:check, 884, y + 2, 18, :reach, sw: 2.2)
      f.text(904, y + 7, head, size: 17, weight: 650)
      f.text(904, y + 28, sub, size: 14, fill: :soft)
    end

    f.frost(1340, 268, 500, 700, zone_h: 82, top: 108, gap: 14, zones: [
              ["Submitted work", "what the student said yes to", :doc],
              ["Enrollment record", "a roster match, a fingerprint", :person],
              ["Conversations", "under a pseudonym; reveals logged", :chat],
              ["Help and feedback", "hands, notes and replies", :hand],
              ["Run by the instructors", "conversations deleted 365 days after the course", :board]
            ])
    f.arrow([[1230, 618], [1340, 618]], tone: :reach, sw: 4)
    f.pill(1285, 576, "sealed", tone: :reach, size: 13, anchor: "middle")

    [
      [:soft, :cloud, "The AI provider", "What the student types goes to the AI provider they chose, as any chat does, under that provider's policy."],
      [:student, :brain, "Memory is the student's", "Ask rEach what it remembers, or run reach memory list. reach memory forget and reach transcripts forget erase."],
      [:instructor, :board, "The grade of record", "Nothing rEach saves changes a grade. The grade of record is kept by the school."]
    ].each_with_index do |(tone, ico, head, body), i|
      x = 80 + i * 596
      f.card(x, 1010, 568, 138, tone: tone, icon: ico, title: head, accent: false)
      f.para(x + 22, 1088, body, 66, size: 14, fill: :soft, lh: 20)
    end

    f.footer(LEGEND)
  end
end
