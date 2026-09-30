# rEach: the student guide

rEach is your academic assistant. It introduces itself, gets to know you a
little, then connects your AI agent (Claude Code, Claude Cowork, Codex,
Antigravity or Hermes) to your instructors' course server, keeps your agent inside the
part of the assignment that is yours to write, checks your work as you go,
and sends it in when you are ready.

## Getting started

1. Paste this repository's link into your AI app and ask it to install rEach.
   Cowork users: add it under Customize › Plugins › Add › Add marketplace
   instead. Hermes users: rEach sets up its own Hermes profile, so always
   open your course with `~/.reach/bin/reach work --harness hermes`
   (setup shows the exact command for your computer).
2. rEach introduces itself and asks a few questions. Answer as many or as few
   as you like; you can always finish later.
3. Then enroll with your code: give rEach the enrollment code your instructor
   gave you in class, and it takes care of the rest.

## Every day

- `reach status` shows your enrollment, your slices, whether each one has passed its checks, and any receipts.
- Your AI partner writes and checks all the code. Before anything is submitted it proves the work against checks of its own and the instructors' checks on the course server; you only talk about what the business needs.
- `reach submit` sends your work in. You will see the receipt number as soon as it arrives. rEach keeps every receipt on your computer, confirms each one back to the course server with a signed receipt of its own, and `reach sync` fetches any receipt your computer is missing, so you and your instructors hold matching copies.
- If your AI partner needs a second try, it tells you. After three tries it asks your instructors for help on its own, tells you, and keeps trying only if you say yes. After ten tries it stops until your instructors reply.

## Your course folders

Everything lives in `~/reach-work`:

- `deliverables/<course>/<assignment>/<cutout>-<slice>/` holds each slice you are assigned. Code for an assignment goes only in your slice's own files here. `reach work` opens a slice.
- `extracurricular/` is your own code folder, for anything you want to build that is not an assignment. It is never graded or submitted. `reach work --extracurricular` opens it.

Your AI partner puts code in files in one of these folders, not in the chat. Everything written in both folders is part of your course record (see Privacy below).

## If something looks wrong

Run `reach doctor`. It checks your Ruby, your course rules, your keys and your connection, and tells you the one command that fixes whatever it finds.

## What rEach remembers about you

The answers you give rEach in its interview are saved in a profile, on your
computer only. Ask rEach "what do you know about me?" anytime to see or
change it, or say "forget my profile" to delete it. It is never sent to the
course server, unless you say yes when rEach asks the instructors for help.

## Privacy

Reach sends your submitted slice files, your enrollment details, your course record and, when your AI partner asks for help, a short summary with your recent changes to the course server. Your course record is everything you and your AI partner write in your course folders (your deliverables and your extracurricular folder): what you type, your AI partner's replies, its reasoning where your AI tool shows it, the actions it takes, and every version of the code written there. Your instructors can read it. Reach does not send what you type outside your course folders, other files on your computer, or anything else outside your course folders. What rEach learns about you in its interview is saved on this computer only; it is shared with your instructors only if you agree to add it when asking for help, and reach profile forget deletes it, but answers you type in a course folder are in your course record like everything else you type there. Like any chat, what you type to rEach goes to the AI provider you use.
