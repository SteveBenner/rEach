# frozen_string_literal: true

module Figures
  figure("02-trust-boundaries",
         title: "rEach and Teach: trust boundaries",
         desc: "The student's computer, the private course server, the AI provider and GitHub are separate zones. Six numbered crossings show what moves between them and how each is protected.") do |f|
    f.header("02", "Trust boundaries", "Four zones, six crossings. Everything between the computer and the course server is signed, sealed or both.")

    f.boundary(80, 268, 900, 610, "The student's computer", tone: :student)
    f.card(116, 318, 404, 160, tone: :soft, icon: :agent, title: "AI app and agent",
           body: ["The assistant the student already uses.", "rEach's hooks sit on every prompt,", "write and command."], accent: false)
    f.card(116, 508, 404, 330, tone: :reach, icon: :key, title: "rEach home", tag: "~/.reach")
    f.bullets(140, 598, ["Install key: made here, never leaves", "Vault: unsealed course materials", "State and signed receipts", "Private memory of the student"], tone: :reach, gap: 40)
    f.card(550, 318, 394, 250, tone: :student, icon: :folder, title: "Course folder", tag: "~/reach-work")
    f.bullets(574, 406, ["Owned files: the agent may write", "Everything else: read-only", "Extracurricular: free, never sent"], tone: :student, gap: 36)
    f.card(550, 598, 394, 240, tone: :stop, icon: :lock, title: "Closed to the agent")
    f.bullets(574, 686, ["Keys and the vault", "rEach's own hook settings", "Other slices and course files", "Git, inside course folders"], tone: :stop, gap: 34)

    f.frost(1290, 268, 550, 392, zone_h: 76, top: 106, zones: [
              ["Verifies every request", "signature and computer fingerprint", :shield],
              ["Seals every package", "readable by one install only", :box],
              ["Signs every receipt", "checkable later, even offline", :receipt]
            ])
    f.card(1290, 690, 550, 86, tone: :soft, icon: :cloud, title: "AI provider", accent: false)
    f.text(1530, 742, "sees the chat, as with any assistant", size: 15, fill: :soft)
    f.card(1290, 792, 550, 86, tone: :soft, icon: :box, title: "GitHub, public", accent: false)
    f.text(1530, 844, "releases, updates, runtime kit", size: 15, fill: :soft)

    [
      [330, :reach, false, "signed requests"],
      [410, :teach, true, "sealed, signed packages"],
      [490, :reach, false, "sealed submissions"],
      [570, :teach, true, "signed receipts"]
    ].each_with_index do |(y, tone, back, label), i|
      pts = back ? [[1290, y], [980, y]] : [[980, y], [1290, y]]
      f.arrow(pts, tone: tone, sw: 3, label: label, at: [1150, y - 14])
      f.num(1020, y, i + 1, tone, r: 15)
    end
    f.arrow([[980, 733], [1290, 733]], tone: :soft, sw: 2.4, dashed: true, both: true, label: "the conversation", at: [1150, 719])
    f.num(1020, 733, 5, :soft, r: 15)
    f.arrow([[1290, 835], [980, 835]], tone: :soft, sw: 2.4, dashed: true, label: "updates", at: [1150, 821])
    f.num(1020, 835, 6, :soft, r: 15)

    notes = [
      [:reach, "Signed requests", "Each request carries a signature from the install's own RSA-4096 key and a digest of the computer's fingerprint."],
      [:teach, "Sealed, signed packages", "AES-256-GCM, with the key wrapped for this one install. Verified before a single byte is unpacked."],
      [:reach, "Sealed submissions", "Owned files and a manifest, sealed to the course server's key, and only after the student says yes."],
      [:teach, "Signed receipts", "Proof of what arrived and when. rEach verifies each receipt before it tells the student anything."],
      [:soft, "The conversation", "Goes to the student's AI provider, as any chat does. rEach records none of it and sends none of it."],
      [:soft, "Updates", "rEach comes from public GitHub releases. The runtime kit is verified against a manifest pinned in rEach."]
    ]
    notes.each_with_index do |(tone, head, body), i|
      x = 80 + (i % 3) * 596
      y = 922 + (i / 3) * 90
      f.num(x + 16, y + 10, i + 1, tone, r: 15)
      f.text(x + 44, y + 16, head, size: 17, weight: 650)
      f.para(x + 44, y + 39, body, 68, size: 14, fill: :soft, lh: 19)
    end

    f.footer(LEGEND)
  end
end
