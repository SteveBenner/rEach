# frozen_string_literal: true

module Figures
  figure("03-enrollment-handshake", height: 1480,
                                    title: "rEach and Teach: validation, enrollment and sign-in",
                                    desc: "A sequence across four lanes: student, AI agent, rEach and Teach. The agent runs a security validation pass with made-up answers, rEach asks the student for their enrollment details without the agent seeing them, makes a key pair and a fingerprint and receives a signed enrollment stamp, and every later sign-in asks for the student ID, a yes and the password.") do |f|
    f.header("03", "Validation, enrollment and sign-in", "Until a student enrolls, nothing works. The agent never sees a single detail the student gives.")

    lanes = { student: 240, agent: 640, reach: 1040, teach: 1590 }
    f.frost(1350, 240, 490, 1146, zones: [], seed: 11)
    [
      [:student, :person, "Student", :student],
      [:agent, :agent, "AI agent", :soft],
      [:reach, :shield, "rEach", :reach]
    ].each do |key, ico, label, tone|
      x = lanes[key]
      f.line(x, 330, x, 1384, stroke: tone, sw: 1.5, so: 0.45, dash: "4 8")
      f.rect(x - 120, 250, 240, 68, rx: 16, fill: :panel, stroke: tone, sw: 1.5, so: 0.7)
      f.badge(x - 82, 284, 22, ico, tone)
      f.text(x - 50, 292, label, size: 22, weight: 650)
    end
    f.line(lanes[:teach], 350, lanes[:teach], 1384, stroke: :teach, sw: 1.5, so: 0.5, dash: "4 8")

    step = lambda do |n, y, from, to, tone, label, tag = nil|
      x1 = lanes[from]
      x2 = lanes[to]
      f.arrow([[x1, y], [x2, y]], tone: tone, sw: 2.6)
      f.num([x1, x2].min + 30, y, n, tone, r: 15)
      f.text([x1, x2].min + 58, y - 14, label, size: 16, weight: 600, fill: :ink, halo: true)
      f.pill([x1, x2].max - 24, y + 12, tag, tone: tone, mono: true, size: 12, weight: 500, anchor: "end") if tag
    end
    phase = lambda do |y, label|
      f.text(100, y, label.upcase, size: 13, weight: 700, fill: :faint, spacing: 2.2, halo: true)
      f.line(100 + f.tw(label, 13, weight: 700) + label.length * 2.2 + 16, y - 5, 1330, y - 5, stroke: :line, sw: 1, dash: "2 6")
    end

    f.rect(520, 344, 640, 50, rx: 14, fill: :panel)
    f.rect(520, 344, 640, 50, rx: 14, fill: :stop, fo: f.theme[:tint], stroke: :stop, sw: 1.4, so: 0.7)
    f.icon(:lock, 550, 369, 22, :stop)
    f.text(574, 375, "Locked: rEach blocks every prompt until the student enrolls", size: 16, weight: 600)

    phase.call(438, "Security validation pass")
    step.call(1, 482, :agent, :reach, :soft, "reach validate, made-up answers")
    step.call(2, 552, :reach, :teach, :reach, "practice plan, check, qualify, submit", "POST /api/v1/validation")
    f.zone(1400, 604, 390, 60, "Checks and signs", "a receipt bound to this one run", :seal)
    step.call(3, 700, :teach, :reach, :teach, "signed practice receipt, verified here")
    f.pill(1010, 718, "cannot verify Teach? wait and ask the instructor", tone: :stop, size: 12, anchor: "end")

    phase.call(790, "Enrollment")
    step.call(4, 834, :reach, :student, :reach, "asks, one at a time: course passkey, school email, student ID, a password twice")
    step.call(5, 902, :student, :reach, :student, "answers are captured by rEach's prompt hook")
    f.pill(lanes[:agent], 920, "the agent never sees them", tone: :stop, size: 13, anchor: "middle")

    f.rect(880, 960, 400, 88, rx: 14, fill: :panel)
    f.rect(880, 960, 400, 88, rx: 14, fill: :reach, fo: f.theme[:tint], stroke: :reach, sw: 1.4, so: 0.7)
    f.num(880, 1004, 6, :reach, r: 15)
    f.text(908, 990, "makes an install key pair, here", size: 16, weight: 600)
    f.text(908, 1013, "and a scrambled fingerprint of this", size: 15, fill: :soft)
    f.text(908, 1034, "computer and account", size: 15, fill: :soft)
    f.pill(1268, 970, "RSA-4096", tone: :reach, mono: true, size: 12, weight: 500, anchor: "end")

    f.rect(100, 960, 460, 88, rx: 14, fill: :panel, stroke: :soft, sw: 1.2, so: 0.5, dash: "6 6")
    f.para(120, 988, "Antigravity runs no hooks, so its agent walks the student through reach enroll in a terminal. Hermes takes the password in a terminal.", 58, size: 14, fill: :soft, lh: 19)

    step.call(7, 1090, :reach, :teach, :reach, "public key, details, fingerprint", "POST /api/v1/enroll")
    f.zone(1400, 1140, 390, 58, "Checks the roster", "is this student in this course?", :person)
    step.call(8, 1232, :teach, :reach, :teach, "signed enrollment stamp, tied to the fingerprint", "W-ENR-5")
    f.pill(1010, 1250, "a copied install fails the fingerprint check and locks again", tone: :stop, size: 12, anchor: "end")
    f.pill(110, 1186, "then a short interview, kept on this computer", tone: :student, size: 12)

    phase.call(1306, "Every sign-in")
    step.call(9, 1346, :reach, :student, :reach, "student ID, a yes, then the password, checked on this computer")
    f.pill(1010, 1364, "one sign-in covers every app for 12 hours", tone: :reach, size: 12, anchor: "end")

    f.footer(LEGEND)
  end
end
