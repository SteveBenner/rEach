# frozen_string_literal: true

module Figures
  INSTALL_PATHS = [
    ["Claude Code", "plugin marketplace"],
    ["Claude app, Cowork", "add marketplace by link"],
    ["Codex", "plugin marketplace, trust hooks"],
    ["Antigravity", "one install command"],
    ["Hermes", "installer, its own profile"],
    ["rplugin", "optional SDK path"]
  ].freeze

  figure("08-deployment-topology",
         title: "rEach and Teach: deployment topology",
         desc: "rEach installs from a public GitHub repository into five AI apps on Linux, macOS or Windows. It keeps a home folder, a runtime kit and a course folder on the student's computer and reaches Teach over HTTPS. A local fixture server stands in for Teach during development.") do |f|
    f.header("08", "Deployment topology", "Where every piece runs: a public repository, the student's computer and one private address.")

    f.card(80, 268, 330, 240, tone: :soft, icon: :box, title: "GitHub, public", accent: false,
           body: ["The rEach repository", "Releases and tags", "The runtime kit"], tag: "SteveBenner/rEach")
    f.card(80, 538, 330, 520, tone: :soft, title: "Six ways in", accent: false)
    INSTALL_PATHS.each_with_index do |(name, how), i|
      y = 608 + i * 72
      f.circle(110, y - 6, 4, fill: :reach)
      f.text(126, y, name, size: 17, weight: 650)
      f.text(126, y + 22, how, size: 14, fill: :soft)
    end

    f.boundary(470, 268, 800, 790, "The student's computer", tone: :student)
    f.card(506, 316, 728, 176, tone: :reach, icon: :shield, title: "The rEach plugin, inside the AI app",
           body: ["Hooks on session start, prompts, writes and commands. An MCP bridge", "for tools the app runs outside its sandbox. Skills for the course flows."])
    x = 528
    HARNESSES.each { |h| x += f.pill(x, 446, h, tone: :reach, size: 13, weight: 500) + 8 }
    f.card(506, 516, 354, 216, tone: :reach, icon: :key, title: "rEach home", tag: "~/.reach",
           body: ["Keys, vault, state,", "receipts and the", "student's private memory."])
    f.card(880, 516, 354, 216, tone: :reach, icon: :box, title: "Runtime kit", tag: "pinned manifest",
           body: ["Ruby 4.0.7 with its gems and", "Chrome for Testing: the same", "versions the server grades with."])
    f.card(506, 756, 354, 170, tone: :student, icon: :folder, title: "Course folder", tag: "~/reach-work",
           body: ["Deliverables per slice,", "plus extracurricular."])
    f.card(880, 756, 354, 170, tone: :reach, icon: :loop, title: "Background checks",
           body: ["Anything new? About every", "minute in a session, every 15", "minutes otherwise. Updates hourly."], body_size: 15)
    x = 506
    ["Linux", "macOS", "Windows"].each { |p| x += f.pill(x, 962, p, tone: :student, size: 14) + 10 }
    f.text(x + 8, 982, "Ruby 2.6.10 to 4.0.x, standard library only. No Ruby? The kit brings one.", size: 14, fill: :soft)

    f.frost(1330, 268, 510, 396, zone_h: 78, top: 106, zones: [
              ["One HTTPS address", "carried by rEach, never asked of the student", :cloud],
              ["Signs everything it sends", "packages and receipts", :seal],
              ["Sets the minimum version", "an old rEach is told to update", :shield]
            ])
    f.rect(1330, 700, 510, 190, rx: 18, fill: :panel, stroke: :soft, sw: 1.5, so: 0.7, dash: "8 7")
    f.badge(1369, 737, 22, :server, :soft)
    f.text(1398, 744, "Fixture server, for development", size: 19, weight: 650)
    f.para(1352, 782, "A local stand-in: enrollment, packages, submissions, hands and grades. It is not Teach and carries none of it.", 64, size: 14, fill: :soft, lh: 20)
    f.pill(1352, 846, "tools/fake_teach", tone: :soft, mono: true, size: 13, weight: 500)
    f.pill(1508, 846, "127.0.0.1:9480", tone: :soft, mono: true, size: 13, weight: 500)
    f.card(1330, 918, 510, 140, tone: :ok, icon: :check, title: "Proved before release",
           body: ["Platform smoke on Linux, macOS and Windows, every", "push. Sandboxed agent sessions before each release."], body_size: 14)

    f.arrow([[410, 388], [470, 388]], tone: :soft, sw: 2.6, label: "install", at: [440, 370])
    f.arrow([[410, 440], [470, 440]], tone: :soft, sw: 2.6, dashed: true, label: "updates", at: [440, 466])
    f.arrow([[1270, 430], [1330, 430]], tone: :reach, sw: 3, both: true)
    f.text(1300, 410, "signed", size: 13, weight: 600, fill: :reach, anchor: "middle", halo: true)
    f.arrow([[1270, 795], [1330, 795]], tone: :soft, sw: 2.4, dashed: true, both: true)
    f.text(1300, 777, "dev only", size: 12, weight: 600, fill: :soft, anchor: "middle", halo: true)

    f.footer(LEGEND)
  end
end
