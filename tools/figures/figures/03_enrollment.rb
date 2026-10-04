# frozen_string_literal: true

module Figures
  figure("03-enrollment-handshake",
         title: "rEach and Teach: the enrollment handshake",
         desc: "A sequence across four lanes: student, AI agent, rEach and Teach. rEach blocks every prompt, asks the student for their details without the agent seeing them, makes a key pair and a fingerprint, and receives a signed enrollment stamp from Teach.") do |f|
    f.header("03", "The enrollment handshake", "Until a student enrolls, nothing works. The agent never sees a single detail the student gives.")

    lanes = { student: 240, agent: 640, reach: 1040, teach: 1590 }
    f.frost(1350, 240, 490, 846, zones: [], seed: 11)
    [
      [:student, :person, "Student", :student],
      [:agent, :agent, "AI agent", :soft],
      [:reach, :shield, "rEach", :reach]
    ].each do |key, ico, label, tone|
      x = lanes[key]
      f.line(x, 330, x, 1070, stroke: tone, sw: 1.5, so: 0.45, dash: "4 8")
      f.rect(x - 120, 250, 240, 68, rx: 16, fill: :panel, stroke: tone, sw: 1.5, so: 0.7)
      f.badge(x - 82, 284, 22, ico, tone)
      f.text(x - 50, 292, label, size: 22, weight: 650)
    end
    f.line(lanes[:teach], 350, lanes[:teach], 1070, stroke: :teach, sw: 1.5, so: 0.5, dash: "4 8")

    step = lambda do |n, y, from, to, tone, label, tag = nil|
      x1 = lanes[from]
      x2 = lanes[to]
      f.arrow([[x1, y], [x2, y]], tone: tone, sw: 2.6)
      f.num([x1, x2].min + 30, y, n, tone, r: 15)
      f.text([x1, x2].min + 58, y - 14, label, size: 16, weight: 600, fill: :ink, halo: true)
      f.pill([x1, x2].max - 24, y + 12, tag, tone: tone, mono: true, size: 12, weight: 500, anchor: "end") if tag
    end

    f.rect(520, 352, 640, 54, rx: 14, fill: :panel)
    f.rect(520, 352, 640, 54, rx: 14, fill: :stop, fo: f.theme[:tint], stroke: :stop, sw: 1.4, so: 0.7)
    f.icon(:lock, 550, 379, 22, :stop)
    f.text(574, 385, "Locked: rEach blocks every prompt until the student enrolls", size: 16, weight: 600)

    step.call(1, 462, :reach, :student, :reach, "asks, one at a time: course passkey, username, student ID, a password twice")
    step.call(2, 548, :student, :reach, :student, "answers are captured by rEach's prompt hook")
    f.pill(lanes[:agent], 566, "the agent never sees them", tone: :stop, size: 13, anchor: "middle")

    f.rect(880, 610, 400, 92, rx: 14, fill: :panel)
    f.rect(880, 610, 400, 92, rx: 14, fill: :reach, fo: f.theme[:tint], stroke: :reach, sw: 1.4, so: 0.7)
    f.num(880, 656, 3, :reach, r: 15)
    f.text(908, 642, "makes an install key pair, here", size: 16, weight: 600)
    f.text(908, 665, "and a scrambled fingerprint of this", size: 15, fill: :soft)
    f.text(908, 686, "computer and account", size: 15, fill: :soft)
    f.pill(1268, 620, "RSA-4096", tone: :reach, mono: true, size: 12, weight: 500, anchor: "end")

    step.call(4, 760, :reach, :teach, :reach, "public key, details, fingerprint", "POST /api/v1/enroll")
    f.zone(1400, 800, 390, 66, "Checks the roster", "is this student in this course?", :person)
    f.zone(1400, 950, 390, 66, "Signs the stamp", "tied to this computer's fingerprint", :seal)
    step.call(5, 916, :teach, :reach, :teach, "signed enrollment stamp", "W-ENR-5")
    step.call(6, 996, :reach, :student, :reach, "unlocked: rEach introduces itself and runs a short interview, kept on this computer")

    f.rect(1080, 1030, 250, 50, rx: 12, fill: :panel)
    f.rect(1080, 1030, 250, 50, rx: 12, fill: :stop, fo: f.theme[:tint], stroke: :stop, sw: 1.2, so: 0.6)
    f.text(1205, 1052, "A copied install fails the", size: 13, weight: 600, anchor: "middle")
    f.text(1205, 1069, "fingerprint check and locks again", size: 13, weight: 600, anchor: "middle")

    f.footer(LEGEND)
  end
end
