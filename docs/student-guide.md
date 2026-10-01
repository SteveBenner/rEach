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
2. Enroll right away: rEach does nothing else until you do. Type anything in
   the chat and rEach asks you, one at a time, for the enrollment code your
   instructor shared in class (it looks like `BUS101-K7QX-94TD`; dashes,
   spaces and capitals don't matter), your school username (your university
   email, like `jsmi123@school.example`) and your seven-digit student ID. Your AI
   partner never sees what you type here. You can also run
   `reach enroll --course-code CODE --username USER --student-id ID` in a
   terminal. Type `start over` at any point to begin again.
3. rEach introduces itself and asks a few questions. Answer as many or as few
   as you like; you can always finish later.

## Every day

- Each time you start, rEach asks for your student ID and then "Am I speaking with <your name>?". Type yes and you're signed in. If you're not the student this computer is enrolled for, rEach won't do course work.
- `reach next` tells you your next step. Your AI partner uses it too when you're not sure where to start.
- Each assignment has a few questions only you can answer, about your business and your decisions. Your AI partner asks them one at a time; answer in your own words. rEach sends your answers with your work, and won't submit until they're all answered (`reach part` shows which).
- rEach only works inside your course folders. To share a file for the course, drag it into the chat or paste its text; rEach copies it into the folder's `materials/`. Share only what the course needs.
- If your course lets you choose your modules, `reach modules` shows the options. Once you say yes to the lock-in question, your choice is fixed for the course; only your instructor can change it. If your instructor moved you to other modules, tell rEach: it asks whether to notify the professor, who confirms the move.
- If you're having a hard time, run `reach support`, or just say so. If it's an emergency, call 911.
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

Reach sends your submitted slice files, your enrollment details, your course record and, when your AI partner asks for help, a short summary with your recent changes to the course server. Your course record is everything you and your AI partner write in your course folders (your deliverables and your extracurricular folder): what you type, your AI partner's replies, its reasoning where your AI tool shows it, the actions it takes, and every version of the code written there. Your instructors can read it. To keep your enrollment yours, Reach also sends a scrambled fingerprint of this computer and computer account (never your files or passwords), which your course server checks; if your rEach is copied to another computer or account, it locks until you enroll there. Reach does not send what you type outside your course folders, other files on your computer, or anything else outside your course folders. What rEach learns about you in its interview is saved on this computer only; it is shared with your instructors only if you agree to add it when asking for help, and reach profile forget deletes it, but answers you type in a course folder are in your course record like everything else you type there. Like any chat, what you type to rEach goes to the AI provider you use.
