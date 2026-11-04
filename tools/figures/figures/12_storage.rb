# frozen_string_literal: true

module Figures
  WORK_TREE = [
    [0, :student, "deliverables/", "assignment work, one folder per slice", "sent on a yes"],
    [0, :student, "extracurricular/", "the student's own code", "never sent"],
    [0, :student, ".reach-brain/", "the memory's files, marked with the student's ID", "kept on uninstall"],
    [0, :reach, ".reach-home/", "rEach's own files", "closed to the agent"],
    [1, :reach, "plugin/", "rEach itself, replaced by each update", nil],
    [1, :reach, "keys/", "the install's private key", "never leaves"],
    [1, :reach, "vault/", "unsealed course materials", nil],
    [1, :reach, "state/", "sign-in, sync and update progress, and more", nil],
    [1, :reach, "checkpoints/", "a save of the slice on every write", nil],
    [1, :reach, "runtime/", "the runtime kit: Ruby and Chrome for Testing", nil],
    [1, :reach, "corpora/", "the organized memory", nil]
  ].freeze

  ERASE = ["reach memory list · forget", "reach transcripts export · forget", "reach checkpoint forget", "reach profile forget", "reach uninstall"].freeze

  figure("12-what-stays-on-the-computer", height: 1400,
                                          title: "rEach and Teach: what rEach keeps on the computer",
                                          desc: "The folders rEach keeps on the student's computer: the reach-work folder with the student's work, rEach's own closed home and the memory, a second copy of checkpoints in the account's application data, the memory library's shared state, the Downloads folder, the background jobs and the commands that show and erase each copy.") do |f|
    f.header("12", "What rEach keeps on the computer", "Every folder rEach writes, who it belongs to and how to erase it. Uninstalling never touches the work.")

    f.boundary(80, 268, 1760, 846, "The student's computer", tone: :student)

    f.card(116, 318, 860, 762, tone: :student, icon: :folder, title: "~/reach-work", accent: false)
    WORK_TREE.each_with_index do |(depth, tone, path, sub, tag), i|
      y = 410 + i * 60
      x = 146 + depth * 44
      f.line(x - 14, y - 26, x - 14, y + 18, stroke: :line, sw: 1.2) if depth == 1
      f.icon(:folder, x + 10, y - 6, 20, tone, sw: 1.6)
      f.text(x + 32, y, path, size: 17, weight: 600, fill: tone, mono: true)
      f.text(x + 32, y + 22, sub, size: 14, fill: :soft)
      f.pill(946, y - 20, tag, tone: tone, size: 12, anchor: "end") if tag
    end

    f.card(1010, 318, 794, 176, tone: :student, icon: :folder, title: "The account's application data",
           body: ["A second copy of every checkpoint, filed under a code, and seal.json: the", "fingerprint's secret and this computer's enrollments. Both stay when", "reach-work is deleted."], body_size: 15)
    f.card(1010, 518, 794, 150, tone: :student, icon: :brain, title: "rplugin state, shared by the account",
           body: ["What rEach learned and its copy of what was typed, not split by student:", "a shared computer should give each student their own account."], body_size: 15)
    f.card(1010, 692, 794, 150, tone: :student, icon: :download, title: "Downloads",
           body: ["A ZIP of each submitted assignment with its receipts, a conversation ZIP", "when the student asks, and a setup report after three failed setups."], body_size: 15)
    f.card(1010, 866, 794, 214, tone: :reach, icon: :loop, title: "Running in the background")
    f.bullets(1036, 952, ["\"Anything new?\": every few minutes in a session, about every 10 minutes otherwise", "Assignment conversations: sent about every ten minutes", "Updates: checked hourly, installed at the next session start", "Runtime kit: installed in the background when missing"], tone: :reach, size: 15, gap: 31)

    f.section(80, 1166, "See it and erase it")
    x = 80
    ERASE.each { |c| x += f.pill(x, 1184, c, tone: :reach, mono: true, size: 14, weight: 500) + 12 }
    f.text(80, 1252, "Conversations are deleted 180 days after the course ends, unsent ones after 30. Uninstall keeps the student's work and memory unless asked.", size: 15, fill: :soft)

    f.footer(LEGEND)
  end
end
