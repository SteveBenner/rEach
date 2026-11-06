# frozen_string_literal: true

module Figures
  INSTALL_PATHS = [
    ["One install command", "INSTALL.md; this copy updates itself"],
    ["Claude Code", "the command"],
    ["Claude app", "Code tab: the command"],
    ["Codex", "the command, then trust the hooks"],
    ["Antigravity", "the command; it runs no hooks"],
    ["Hermes", "the command; its own reach profile"],
    ["rplugin", "optional SDK path"]
  ].freeze

  figure("08-deployment-topology", height: 1260,
                                   title: "rEach and Teach: deployment topology",
                                   desc: "rEach installs from a public GitHub repository into five AI apps on Linux, macOS or Windows and updates itself from the stable branch. It keeps its home, its pinned runtime and SDK kits and the course folder under reach-work on the student's computer and reaches Teach over HTTPS. A local fixture server stands in for Teach during development.") do |f|
    f.header("08", "Deployment topology", "Where every piece runs: a public repository, the student's computer and one private address.")

    f.card(80, 268, 330, 250, tone: :soft, icon: :box, title: "GitHub, public", accent: false,
           body: ["The rEach repository", "stable: the Latest release,", "after the platform smoke", "Runtime kit, SDK kit"], tag: "SteveBenner/rEach")
    f.card(80, 548, 330, 600, tone: :soft, title: "Seven ways in", accent: false)
    INSTALL_PATHS.each_with_index do |(name, how), i|
      y = 632 + i * 72
      f.circle(110, y - 6, 4, fill: :reach)
      f.text(126, y, name, size: 17, weight: 650)
      f.text(126, y + 22, how, size: 14, fill: :soft)
    end

    f.boundary(470, 268, 800, 880, "The student's computer", tone: :student)
    f.card(506, 316, 728, 176, tone: :reach, icon: :shield, title: "The rEach plugin, inside the AI app",
           body: ["Hooks on session start, prompts, writes and commands; an MCP bridge", "for its tools; skills for the course flows. In ~/reach-work/.reach-home/plugin."])
    x = 528
    HARNESSES.each { |h| x += f.pill(x, 446, h, tone: :reach, size: 13, weight: 500) + 8 }
    f.card(506, 516, 354, 200, tone: :reach, icon: :key, title: "rEach home", tag: ".reach-home",
           body: ["Keys, vault, state,", "receipts and checkpoints.", "Closed to the agent."])
    f.card(880, 516, 354, 200, tone: :reach, icon: :box, title: "Pinned kits", tag: "pinned manifests",
           body: ["Ruby 4.0.7 and Chrome for", "Testing 154, what Teach", "grades with; rplugin, rBrain."])
    f.card(506, 740, 354, 186, tone: :student, icon: :folder, title: "Course folder", tag: "~/reach-work",
           body: ["deliverables/ per slice,", "extracurricular/, and", ".reach-brain/ for memory."])
    f.card(880, 740, 354, 186, tone: :reach, icon: :loop, title: "In the background",
           body: ["Anything new? Every few minutes", "in a session, ~10 min otherwise.", "Updates hourly, applied at the", "next session start."], body_size: 14)
    f.card(506, 950, 728, 106, tone: :student, icon: :folder, title: "Outside reach-work", accent: false,
           body: ["Application data: a second copy of every checkpoint. Downloads: ZIPs and receipts."], body_size: 14)
    x = 506
    ["Linux", "macOS", "Windows"].each { |p| x += f.pill(x, 1082, p, tone: :student, size: 14) + 10 }
    f.text(x + 8, 1102, "Ruby 2.6.10 to 4.0.x, standard library only. No Ruby? The kit brings one.", size: 14, fill: :soft)

    f.frost(1330, 268, 510, 396, zone_h: 78, top: 106, zones: [
              ["One HTTPS address", "carried by rEach, never asked of the student", :cloud],
              ["Signs everything it sends", "packages and receipts", :seal],
              ["Sets the minimum version", "an old rEach is told to update", :shield]
            ])
    f.rect(1330, 700, 510, 190, rx: 18, fill: :panel, stroke: :soft, sw: 1.5, so: 0.7, dash: "8 7")
    f.badge(1369, 737, 22, :server, :soft)
    f.text(1398, 744, "Fixture server, for development", size: 19, weight: 650)
    f.para(1352, 782, "A local stand-in for the wire: enrollment, packages, submissions, hands and grades. It is not Teach and carries none of it.", 64, size: 14, fill: :soft, lh: 20)
    f.pill(1352, 846, "tools/fake_teach", tone: :soft, mono: true, size: 13, weight: 500)
    f.card(1330, 918, 510, 230, tone: :ok, icon: :check, title: "Proved before release",
           body: ["Platform smoke on Linux, macOS and Windows on", "every push to main, and daily on the Latest tag", "before stable moves. Sandboxed agent sessions", "before a release a student sees."], body_size: 14)

    f.arrow([[410, 388], [470, 388]], tone: :soft, sw: 2.6, label: "install", at: [440, 370])
    f.arrow([[410, 440], [470, 440]], tone: :soft, sw: 2.6, dashed: true, label: "updates", at: [440, 466])
    f.arrow([[1270, 430], [1330, 430]], tone: :reach, sw: 3, both: true)
    f.text(1300, 410, "signed", size: 13, weight: 600, fill: :reach, anchor: "middle", halo: true)
    f.arrow([[1270, 795], [1330, 795]], tone: :soft, sw: 2.4, dashed: true, both: true)
    f.text(1300, 777, "dev only", size: 12, weight: 600, fill: :soft, anchor: "middle", halo: true)

    f.footer(LEGEND)
  end
end
