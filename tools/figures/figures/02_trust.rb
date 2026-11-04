# frozen_string_literal: true

module Figures
  figure("02-trust-boundaries", height: 1290,
                                title: "rEach and Teach: trust boundaries",
                                desc: "The student's computer, the private course server, the AI provider and GitHub are separate zones. Seven numbered crossings show what moves between them and how each is protected.") do |f|
    f.header("02", "Trust boundaries", "Four zones, seven crossings. Everything between the computer and the course server is signed, sealed or both.")

    f.boundary(80, 268, 900, 640, "The student's computer", tone: :student)
    f.card(116, 318, 404, 150, tone: :soft, icon: :agent, title: "AI app and agent",
           body: ["The assistant the student already uses.", "rEach's hooks sit on every prompt,", "write and command."], accent: false)
    f.card(116, 494, 404, 378, tone: :reach, icon: :key, title: "rEach home", tag: "~/reach-work/.reach-home")
    f.bullets(140, 584, ["Install key: made here, never leaves", "Vault: unsealed course materials", "State, receipts and checkpoints", "Sign-in check value, never the password", "The plugin and its pinned kits"], tone: :reach, gap: 40)
    f.card(550, 318, 394, 250, tone: :student, icon: :folder, title: "Course folder", tag: "~/reach-work")
    f.bullets(574, 406, ["Owned files: the agent may write", "Everything else: read-only", "Extracurricular: free, never sent"], tone: :student, gap: 36)
    f.card(550, 594, 394, 278, tone: :stop, icon: :lock, title: "Closed to the agent")
    f.bullets(574, 682, ["rEach's home: keys, vault, state", "rEach's own hook settings", "Other slices and course files", "Git, inside course folders", "Folders outside the course spaces"], tone: :stop, gap: 34)

    f.frost(1290, 268, 550, 444, zone_h: 70, top: 104, gap: 12, zones: [
              ["Verifies every request", "signature and computer fingerprint", :shield],
              ["Seals every package", "readable by one install only", :box],
              ["Signs every receipt", "checkable later, even offline", :receipt],
              ["Holds conversations de-identified", "each reveal of a name is logged", :chat]
            ])
    f.card(1290, 736, 550, 80, tone: :soft, icon: :cloud, title: "AI provider", accent: false)
    f.text(1530, 784, "sees the chat, as with any assistant", size: 15, fill: :soft)
    f.card(1290, 830, 550, 80, tone: :soft, icon: :box, title: "GitHub, public", accent: false)
    f.text(1530, 878, "releases, updates, runtime and SDK kits", size: 15, fill: :soft)

    [
      [330, :reach, false, "signed requests"],
      [404, :teach, true, "sealed, signed packages"],
      [478, :reach, false, "sealed submissions"],
      [552, :teach, true, "signed receipts"],
      [626, :reach, false, "de-identified conversations"]
    ].each_with_index do |(y, tone, back, label), i|
      pts = back ? [[1290, y], [980, y]] : [[980, y], [1290, y]]
      f.arrow(pts, tone: tone, sw: 3, label: label, at: [1150, y - 14])
      f.num(1020, y, i + 1, tone, r: 15)
    end
    f.arrow([[980, 776], [1290, 776]], tone: :soft, sw: 2.4, dashed: true, both: true, label: "the conversation", at: [1150, 762])
    f.num(1020, 776, 6, :soft, r: 15)
    f.arrow([[1290, 870], [980, 870]], tone: :soft, sw: 2.4, dashed: true, label: "updates", at: [1150, 856])
    f.num(1020, 870, 7, :soft, r: 15)

    notes = [
      [:reach, "Signed requests", "Each request carries a signature from the install's own RSA-4096 key and a digest of the computer's fingerprint."],
      [:teach, "Sealed, signed packages", "AES-256-GCM, with the key wrapped for this one install. Verified before a single byte is unpacked."],
      [:reach, "Sealed submissions", "Owned files and a manifest, sealed to the course server's key, and only after the student says yes."],
      [:teach, "Signed receipts", "Proof of what arrived and when. rEach verifies each receipt before it tells the student anything."],
      [:reach, "De-identified conversations", "Signed-in assignment work only, about every ten minutes, under a pseudonym with the names rEach knows replaced."],
      [:soft, "The conversation", "Goes to the student's AI provider, as any chat does, under that provider's own policy."],
      [:soft, "Updates", "rEach follows the stable branch. The runtime and SDK kits are verified against manifests pinned in rEach."]
    ]
    notes.each_with_index do |(tone, head, body), i|
      x = 80 + (i % 4) * 446
      y = 966 + (i / 4) * 104
      f.num(x + 16, y + 10, i + 1, tone, r: 15)
      f.text(x + 44, y + 16, head, size: 17, weight: 650)
      f.para(x + 44, y + 40, body, 52, size: 14, fill: :soft, lh: 19)
    end

    f.footer(LEGEND)
  end
end
