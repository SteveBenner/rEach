# frozen_string_literal: true

module Figures
  LAYERS = [
    ["Enrollment lock", :teach, "Every prompt is refused until a security validation pass succeeds and the student enrolls on this computer. A copied install locks again.", "reach validate · enroll",
     "No work before validation and enrollment."],
    ["Sign-in", :student, "The student ID, a yes and the password open the gates, for 12 hours in any app on this computer. Wrong tries lock the sign-in out.", "reach login",
     "ID, a yes and the password open the gates."],
    ["Signed rules and course controls", :teach, "No work until the instructors' signed rules verify; offline they hold for 24 hours. Their pauses, holds and tests are enforced in code.", "reach gate session",
     "Signed rules first; pauses, holds and tests in code."],
    ["Student consent", :student, "Nothing is submitted without the student's yes, within 30 minutes, for exactly these files. A live-session action needs a typed yes too.", "reach submit",
     "Nothing is submitted without the student's yes."],
    ["Qualification", :reach, "A plan audit, scored passes and the agent's own scenarios, here and on Teach. The third failed try raises a hand; the tenth stops.", "reach qualify",
     "The agent proves the slice here and on Teach."],
    ["Seal and witness ledger", :reach, "Each owned file carries an invisible seal and each session leaves a signed ledger. The server reads both.", "seal · ledger",
     "Invisible seals and a signed ledger the server reads."],
    ["Shape and directive check", :reach, "Every change is checked against the course's Dovetail shape and the directive table.", "reach check",
     "Every change against the shape and the directives."],
    ["Reply policy", :reach, "Replies keep code and terminal tasks out of the chat and use everyday words: checked on screen in Claude Code, corrected after a reply in Claude Code and Codex, guidance elsewhere.", "guided-learner",
     "Replies keep code out of the chat, in everyday words."],
    ["Slice fence", :reach, "Writes and commands land only inside the student's owned files. rEach's home, other slices and git are off limits.", "reach gate write · shell",
     "Writes and commands only inside the owned files."]
  ].freeze

  figure("05-guardrail-layers", height: 1350,
                                title: "rEach and Teach: guardrail layers",
                                desc: "Nine nested layers surround the AI agent: enrollment lock, sign-in, signed rules and course controls, student consent, qualification, seal and witness ledger, shape and directive check, reply policy and slice fence. Beyond them, Teach runs hidden checks and grading on the server.") do |f|
    f.header("05", "Guardrail layers", "Nine nested layers around the agent. The last word is not on the student's computer at all.")

    cx = 510
    cy = 660
    LAYERS.each_with_index do |(name, tone, _body, _tag, _short), i|
      hw = 430 - i * 44
      hh = 410 - i * 42
      f.rect(cx - hw, cy - hh, hw * 2, hh * 2, rx: 30 - i * 2, fill: :panel, fo: 0.55)
      f.rect(cx - hw, cy - hh, hw * 2, hh * 2, rx: 30 - i * 2, fill: tone, fo: f.theme[:tint] * 0.5, stroke: tone, sw: 1.6, so: 0.7)
      f.num(cx - hw + 30, cy - hh + 22, i + 1, tone, r: 12)
      f.text(cx - hw + 50, cy - hh + 28, name, size: 14, weight: 650, fill: tone)
    end
    f.badge(cx, cy + 12, 32, :agent, :ink)
    f.text(cx, cy + 58, "AI agent", size: 16, weight: 650, anchor: "middle")

    LAYERS.each_with_index do |(name, tone, body, tag, _short), i|
      y = 250 + i * 90
      f.rect(1000, y, 840, 80, rx: 16, fill: :panel, stroke: tone, sw: 1.2, so: 0.4)
      f.num(1036, y + 40, i + 1, tone, r: 16)
      f.text(1068, y + 30, name, size: 19, weight: 650)
      f.pill(1822, y + 10, tag, tone: tone, mono: true, size: 12, weight: 500, anchor: "end")
      f.para(1068, y + 52, body, 100, size: 14, fill: :soft, lh: 19)
    end

    f.frost(1000, 1082, 840, 152, title: "Beyond the last layer: Teach", sub: "hidden checks and grading run on the server, out of the agent's reach", zones: [], seed: 5, title_size: 24)
    f.text(1024, 1192, "rEach stops accidents and casual tampering. It does not claim to stop a determined", size: 14, fill: :soft, italic: true)
    f.text(1024, 1212, "machine owner, which is exactly why the grading happens on Teach.", size: 14, fill: :soft, italic: true)
    f.arrow([[940, 1030], [968, 1030], [968, 1158], [1000, 1158]], tone: :teach, sw: 2.6, radius: 10)

    f.footer(LEGEND)
  end
end
