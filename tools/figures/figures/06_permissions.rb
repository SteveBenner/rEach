# frozen_string_literal: true

module Figures
  ROLES = [
    ["Student", :person, :student],
    ["AI agent", :agent, :soft],
    ["rEach", :shield, :reach],
    ["Teach", :lock, :teach],
    ["Instructors", :board, :instructor]
  ].freeze

  PERMISSIONS = [
    ["Enrollment secrets", "passkey, student ID, password",
     [[:full, "types them, once"], [:deny, "never sees them"], [:part, "captures them at the prompt"], [:part, "checks them, keeps a hash"], [:full, "issue the passkey"]]],
    ["Owned slice files", "the student's assignment code",
     [[:full, "directs the work"], [:part, "writes, inside the fence"], [:part, "gates, checks, seals"], [:part, "receives on submit"], [:full, "review and grade"]]],
    ["Other course files", "read-only material, other slices",
     [[:part, "may read"], [:part, "may read, never write"], [:full, "enforces read-only"], [:full, "delivers them sealed"], [:full, "author them"]]],
    ["Keys and vault", "install key, unsealed materials",
     [[:none, "no need to touch"], [:deny, "refused"], [:full, "the only user"], [:none, "never gets the key"], [:none, "no access"]]],
    ["Course rules", "guardrails and directives",
     [[:part, "can read them"], [:part, "must follow them"], [:part, "verifies, enforces"], [:full, "signs and delivers"], [:full, "author them"]]],
    ["Hidden checks", "what grading looks for",
     [[:none, "sees results only"], [:deny, "never sees them"], [:none, "sees results only"], [:full, "holds and runs them"], [:full, "author them"]]],
    ["The conversation", "prompts, replies, reasoning",
     [[:full, "theirs"], [:full, "takes part"], [:none, "records nothing"], [:none, "receives nothing"], [:none, "see nothing"]]],
    ["Decision to submit", "what goes in, and when",
     [[:full, "says yes or no"], [:part, "relays the question"], [:part, "asks, enforces the yes"], [:part, "issues the receipt"], [:part, "set the due time"]]],
    ["Private memory", "what rEach learns of the student",
     [[:full, "sees, exports, erases"], [:part, "records findings"], [:full, "keeps it on the computer"], [:none, "never receives it"], [:none, "never receive it"]]],
    ["The grade", "points on record",
     [[:part, "reads it"], [:none, "no part in it"], [:part, "shows it"], [:full, "holds the points"], [:full, "record it"]]]
  ].freeze

  figure("06-permissions",
         title: "rEach and Teach: who may do what",
         desc: "A matrix of ten assets against five parties: student, AI agent, rEach, Teach and instructors. Each cell says whether that party owns or decides, has a limited role, has no access or is refused.") do |f|
    f.header("06", "Who may do what", "Ten things worth protecting, five parties, and one answer in every cell.")

    left = 80
    label_w = 400
    col_w = 272
    top = 246
    row_h = 74
    table_h = 76 + PERMISSIONS.length * row_h

    tx = left + label_w + 3 * col_w
    f.rect(tx, top, col_w, table_h, rx: 18, fill: :frost, fo: f.theme[:frost_op] * 1.3)
    f.rect(tx, top, col_w, table_h, rx: 18, fill: "url(#hatch)", stroke: :teach, sw: 1.4, so: 0.6)

    ROLES.each_with_index do |(name, ico, tone), i|
      x = left + label_w + i * col_w
      f.badge(x + 40, top + 38, 22, ico, tone)
      f.text(x + 70, top + 46, name, size: 21, weight: 650)
    end
    f.text(left, top + 46, "What is protected", size: 15, weight: 700, fill: :faint, spacing: 1.2)

    PERMISSIONS.each_with_index do |(name, sub, cells), r|
      y = top + 76 + r * row_h
      f.line(left, y, left + label_w + 5 * col_w, y, stroke: :line, sw: 1)
      f.text(left, y + 32, name, size: 19, weight: 650)
      f.text(left, y + 54, sub, size: 14, fill: :soft)
      cells.each_with_index do |(kind, word), i|
        x = left + label_w + i * col_w
        f.level(x + 34, y + 37, kind)
        f.text(x + 56, y + 42, word, size: 15, fill: kind == :none ? :faint : :ink)
      end
    end

    ky = top + table_h + 34
    [[:full, "owns or decides"], [:part, "a limited role"], [:none, "no access, by design"], [:deny, "refused if it tries"]].each_with_index do |(kind, word), i|
      f.level(left + 12 + i * 250, ky, kind)
      f.text(left + 34 + i * 250, ky + 5, word, size: 15, fill: :soft)
    end
    f.text(1840, ky + 5, "The Teach column states outcomes only. How the server does it stays private.", size: 14, fill: :faint, anchor: "end", italic: true)

    f.footer(LEGEND)
  end
end
