# frozen_string_literal: true

module Figures
  POSTER_WHY = [
    ["Identity", "The roster confirms who is working, on which computer."],
    ["Rules", "Signed by the instructors; unsigned rules stop the work."],
    ["Checks", "Hidden checks run where the agent cannot read them."],
    ["Evidence", "Seals and ledgers are read by the server."],
    ["Record", "De-identified assignment conversations reach the instructors."],
    ["Proof", "A signed receipt says what arrived, and when."],
    ["Help", "Hands and notes reach instructors who answer, live if needed."]
  ].freeze

  figure("10-system-poster", width: 2880, height: 1920,
                             title: "rEach and Teach: the whole system on one sheet",
                             desc: "A poster combining the system at a glance, the nine guardrail layers, the eight-stage work lifecycle, seven reasons the two halves belong together and the privacy split between what is recorded only on assignments, what stays and what leaves.") do |f|
    f.text(80, 104, "SYSTEM POSTER", size: 18, weight: 700, fill: :reach, mono: true, spacing: 4)
    f.text(80, 190, "One course, two halves, one closed loop", size: 76, weight: 650)
    f.text(80, 244, "The student steers. Their own AI agent builds, fenced in by rEach. Teach, the private course server, decides what counts.", size: 27, fill: :soft)
    f.mark(2800, 116, size: 38)

    f.group(0, 60) { system_body(f) }

    f.rect(1900, 328, 900, 786, rx: 26, fill: :panel, stroke: :reach, sw: 1.6, so: 0.55)
    f.badge(1946, 376, 26, :shield, :reach)
    f.text(1982, 386, "Nine guardrail layers", size: 30, weight: 650)
    LAYERS.each_with_index do |(name, tone, _body, tag, short), i|
      y = 422 + i * 76
      f.line(1930, y, 2770, y, stroke: :line, sw: 1)
      f.num(1954, y + 38, i + 1, tone, r: 16)
      f.text(1988, y + 32, name, size: 20, weight: 650)
      f.text(1988, y + 58, short, size: 16, fill: :soft)
      f.pill(2770, y + 12, tag, tone: tone, mono: true, size: 12, weight: 500, anchor: "end")
    end

    f.text(80, 1222, "THE WORK LIFECYCLE", size: 16, weight: 700, fill: :faint, spacing: 2.4)
    STAGES.each_with_index do |(name, ico, tone, _body, tag, _state), i|
      x = stage_x(i)
      f.rect(x, 1250, 204, 132, rx: 16, fill: :panel)
      f.rect(x, 1250, 204, 132, rx: 16, fill: tone, fo: f.theme[:tint] * 0.6, stroke: tone, sw: 1.4, so: 0.55)
      f.num(x + 32, 1290, i + 1, tone, r: 16)
      f.icon(ico, x + 174, 1290, 24, tone)
      f.text(x + 58, 1298, name, size: 22, weight: 650)
      f.text(x + 18, 1354, tag, size: 15, fill: tone, mono: true)
      f.arrow([[x + 206, 1316], [x + 220, 1316]], tone: :faint, sw: 2) if i < STAGES.length - 1
    end
    f.frost(80, 1412, 1760, 196, zone_h: 62, top: 112, cols: 4, zones: [
              ["Builds and seals", nil, :box], ["Runs the hidden checks", nil, :eye_off],
              ["Takes the work in", nil, :doc], ["Receipts, grades, replies", nil, :receipt]
            ])
    f.arrow([[stage_cx(0), 1412], [stage_cx(0), 1386]], tone: :teach, sw: 3)
    f.arrow([[stage_cx(4), 1386], [stage_cx(4), 1412]], tone: :reach, sw: 3, both: true)
    f.arrow([[stage_cx(6), 1386], [stage_cx(6), 1412]], tone: :reach, sw: 3)
    f.arrow([[stage_cx(7), 1412], [stage_cx(7), 1386]], tone: :teach, sw: 3)

    f.frost(1900, 1170, 900, 438, title: "Why the two belong together", sub: "what the course server makes checkable", zones: [], seed: 31, title_size: 28)
    POSTER_WHY.each_with_index do |(name, line), i|
      y = 1280 + i * 46
      f.level(1946, y, :full, r: 12)
      f.text(1976, y + 7, name, size: 20, weight: 650)
      f.text(2096, y + 6, line, size: 18, fill: :soft)
    end

    [
      [:stop, :eye_off, "Recorded only on assignments", "Nothing said before sign-in, in the extracurricular folder or outside the course folder, and never the password."],
      [:student, :lock, "Stays on the computer", "The profile, private memory, checkpoints, the setup log and the install's private key."],
      [:reach, :doc, "Leaves, to the course server only", "De-identified assignment conversations, work submitted after a yes, own-part answers, agreed help requests."]
    ].each_with_index do |(tone, ico, head, body), i|
      x = 80 + i * 916
      f.card(x, 1648, 888, 132, tone: tone, icon: ico, title: head)
      f.para(x + 22, 1728, body, 96, size: 18, fill: :soft, lh: 24)
    end

    f.footer(LEGEND, note: "The mechanisms behind the glass are private. The guarantees are public.  github.com/SteveBenner/rEach")
  end
end
