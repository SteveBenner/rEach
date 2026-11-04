# frozen_string_literal: true

module Figures
  CHANNELS = [
    [:out, :student, :hand, "Raise a hand", "reach hand raise",
     "The student asks, and rEach raises one by itself at the third failed try. Every hand has a type: a grade question, a technical issue, an extension request and more.",
     "a hand", ["Answers hands", "the instructors see its type and reply", :hand]],
    [:out, :reach, :bug, "Fault reports", "reach issues",
     "A fault that stops enrollment, sign-in, sync, qualify or submit is reported the first time, any other the third time in a day; never a prompt or code.",
     "a fault report", ["Tracks each fault", "and says when the fix reaches the student", :bug]],
    [:out, :student, :chat, "Feedback notes", "reach feedback send",
     "Anything that can wait: an idea, a question, a problem, how the pace feels. Shown word for word, sent on a yes, named or anonymous.",
     "a note, on a yes", ["Delivers notes", "an anonymous one is stored without a name", :chat]],
    [:out, :instructor, :live, "Live sessions", "reach_live",
     "On the student's typed yes the instructors' assistant works with rEach. Each action it asks for, and each message sent, needs another yes.",
     "a session, on a yes", ["Carries live sessions", "between rEach and the instructors' assistant", :live]],
    [:in, :teach, :receipt, "Replies and workarounds", "reach sync",
     "Replies to hands and named notes arrive with the next sync. A problem the course server is already fixing carries a workaround until the fix arrives.",
     "a reply", ["Sends replies", "picked up on the next sync", :receipt]],
    [:in, :instructor, :bell, "Announcements and due times", "reach announcements",
     "Shown once, word for word, and kept in a list by date. A moved due time is shown once, with the earlier and the new time.",
     "an announcement", ["Sends announcements", "to the course, a group or one student", :bell]],
    [:in, :instructor, :sliders, "Course controls", "reach status",
     "A pause stops course work, a hold stops submitting, a test locks all but the test. rEach enforces each in code, and reach support keeps working.",
     "a control", ["Sets pauses, holds and tests", "chosen by the instructors", :sliders]]
  ].freeze

  figure("11-reaching-the-instructors", height: 1360,
                                        title: "rEach and Teach: reaching the instructors",
                                        desc: "Seven channels between the student's computer and the instructors. Hands, fault reports, feedback notes and live sessions go out to Teach; replies, announcements and course controls come back. Notes, live sessions and the student's own help requests wait for the student's yes.") do |f|
    f.header("11", "Reaching the instructors", "Four ways out to the instructors and three ways back. Notes and live sessions go only on the student's yes.")

    f.boundary(80, 268, 848, 944, "The student's computer", tone: :student)
    f.frost(1290, 268, 550, 944, zones: [], seed: 17, sub: "course server · read and answered by the instructors")

    f.section(116, 334, "From the student", tone: :student, width: 776)
    CHANNELS.each_with_index do |(dir, tone, ico, title, tag, body, label, zone), i|
      y = 370 + i * 112 + (dir == :in ? 44 : 0)
      f.row(116, y, 776, 98, tone: tone, icon: ico, title: title, body: body, tag: tag, chars: 84)
      f.zone(1312, y, 506, 98, zone[0], zone[1], zone[2])
      mid = y + 49
      if dir == :out
        f.arrow([[892, mid], [1312, mid]], tone: tone == :instructor ? :instructor : :reach, sw: 2.6, label: label, at: [1102, mid - 12])
      else
        f.arrow([[1312, mid], [892, mid]], tone: tone == :instructor ? :instructor : :teach, sw: 2.6, label: label, at: [1102, mid - 12])
      end
    end
    f.section(116, 840, "To the student", tone: :teach, width: 776)

    f.footer(LEGEND)
  end
end
