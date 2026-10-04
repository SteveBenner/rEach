# frozen_string_literal: true

module Figures
  LAYERS = [
    ["Enrollment lock", :teach, "Every prompt is refused until the student enrolls on this computer. A copied install locks again.", "reach gate enroll"],
    ["Signed rules", :teach, "No work until the instructors' rules are installed and their signature verifies. Offline grace: 24 hours.", "reach gate session"],
    ["Student consent", :student, "Nothing is submitted without the student's yes, given within 30 minutes for exactly these files.", "reach submit"],
    ["Qualification", :reach, "The agent must prove the slice first. Three failed tries raise a hand; the hard stop ends writes.", "reach qualify"],
    ["Seal and witness ledger", :reach, "Each owned file carries an invisible seal and each session leaves a ledger. The server reads both.", "seal · ledger"],
    ["Shape check", :reach, "Every change is checked against the course's Dovetail shape and the directive table.", "reach check"],
    ["Slice fence", :reach, "Writes and commands land only inside the student's owned files. Keys, vault and git are off limits.", "reach gate write · shell"]
  ].freeze

  figure("05-guardrail-layers",
         title: "rEach and Teach: guardrail layers",
         desc: "Seven nested layers surround the AI agent: enrollment lock, signed rules, student consent, qualification, seal and witness ledger, shape check and slice fence. Beyond them, Teach runs hidden checks and grading on the server.") do |f|
    f.header("05", "Guardrail layers", "Seven nested layers around the agent. The last word is not on the student's computer at all.")

    cx = 510
    cy = 668
    LAYERS.each_with_index do |(name, tone, _body, _tag), i|
      hw = 430 - i * 50
      hh = 404 - i * 48
      f.rect(cx - hw, cy - hh, hw * 2, hh * 2, rx: 30 - i * 2, fill: :panel, fo: 0.55)
      f.rect(cx - hw, cy - hh, hw * 2, hh * 2, rx: 30 - i * 2, fill: tone, fo: f.theme[:tint] * 0.55, stroke: tone, sw: 1.7, so: 0.75)
      f.num(cx - hw + 32, cy - hh + 25, i + 1, tone, r: 13)
      f.text(cx - hw + 54, cy - hh + 31, name, size: 15, weight: 650, fill: tone)
    end
    f.badge(cx, cy + 8, 40, :agent, :ink)
    f.text(cx, cy + 68, "AI agent", size: 17, weight: 650, anchor: "middle")

    LAYERS.each_with_index do |(name, tone, body, tag), i|
      y = 250 + i * 96
      f.rect(1000, y, 840, 84, rx: 16, fill: :panel, stroke: tone, sw: 1.2, so: 0.45)
      f.num(1036, y + 42, i + 1, tone, r: 16)
      f.text(1068, y + 32, name, size: 19, weight: 650)
      f.pill(1822, y + 10, tag, tone: tone, mono: true, size: 12, weight: 500, anchor: "end")
      f.para(1068, y + 54, body, 116, size: 14, fill: :soft, lh: 19)
    end

    f.frost(1000, 930, 840, 152, title: "Beyond the last layer: Teach", sub: "hidden checks and grading run on the server, out of the agent's reach", zones: [], seed: 5, title_size: 24)
    f.text(1024, 1040, "rEach stops accidents and casual tampering. It does not claim to stop a determined", size: 14, fill: :soft, italic: true)
    f.text(1024, 1060, "machine owner, which is exactly why the grading happens on Teach.", size: 14, fill: :soft, italic: true)
    f.arrow([[940, 1006], [1000, 1006]], tone: :teach, sw: 2.6)

    f.footer(LEGEND)
  end
end
