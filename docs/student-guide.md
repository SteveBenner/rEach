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
   the chat and rEach asks you, one at a time, for the course passkey your
   instructor shared in class (it looks like `BUS101-K7QX-94TD`; dashes,
   spaces and capitals don't matter), your school username (your university
   email, like `jsmi123@school.example`) and your student ID, and last to choose
   a password (at least 8 characters, typed twice; write it down, you will
   type it every time you sign in). Your AI
   partner never sees what you type here. You can also run
   `reach enroll --course-passkey PASSKEY --username USER --student-id ID` in a
   terminal; in Antigravity your AI partner walks you through that terminal
   step, because rEach cannot ask in its chat. Type `start over` at any point
   to begin again.
3. rEach introduces itself and asks a few questions. Answer as many or as few
   as you like; you can always finish later.

## Every day

- Each time you start, rEach asks for your student ID and then "Am I speaking with <your name>?". Type yes, then type your rEach password, and you're signed in. Your AI partner never sees the password. Nobody can look it up for you, not even your instructor: if you forget it, type `forgot password`, ask your instructor to allow a password reset, then type `forgot password` again and choose a new one. If you're not the student this computer is enrolled for, rEach won't do course work.
- `reach next` tells you your next step. Your AI partner uses it too when you're not sure where to start.
- Each assignment has a few questions only you can answer, about your business and your decisions. Your AI partner asks them one at a time; answer in your own words. rEach sends your answers with your work, and won't submit until they're all answered (`reach part` shows which).
- rEach only works inside your course folders. To share a file for the course, drag it into the chat or paste its text; rEach copies it into the folder's `materials/`. Share only what the course needs.
- If your course lets you choose your modules, `reach modules` shows the options. Once you say yes to the lock-in question, your choice is fixed for the course; only your instructor can change it. If your instructor moved you to other modules, tell rEach: it asks whether to notify the professor, who confirms the move.
- If you're having a hard time, run `reach support`, or just say so. If it's an emergency, call 911.
- rEach checks your course server for news (grades, replies, new materials) every few minutes while you work and about every 15 minutes in the background, and tells you what it found; `reach subscribe uninstall` turns the background check off.
- `reach status` shows your enrollment, your slices, whether each one has passed its checks, and any receipts.
- Your AI partner writes and checks all the code. Before anything is submitted it proves the work against checks of its own and the instructors' checks on the course server; you only talk about what the business needs.
- When a part passes its checks, your AI partner will tell you that you can ask it to submit. rEach asks you first and sends your work in only when you say yes. Right after, it saves a copy of all your work for the assignment in your Downloads folder as a ZIP named with the course, the assignment and the date and time. Upload that ZIP to Blackboard too: that is what earns credit. You can submit again as many times as you like until the due time; the last one you send counts. After the due time, a part that is already submitted can't be submitted again.
- `reach submit` sends your work in. You will see the receipt number as soon as it arrives. rEach keeps every receipt on your computer, confirms each one back to the course server with a signed receipt of its own, and `reach sync` fetches any receipt your computer is missing, so you and your instructors hold matching copies.
- If your AI partner needs a second try, it tells you. After three tries it asks your instructors for help on its own, tells you, and keeps trying only if you say yes. After ten tries it stops until your instructors reply.

## Your course folders

Everything lives in `~/reach-work`:

- `deliverables/<course>/<assignment>/<cutout>-<slice>/` holds each slice you are assigned. Code for an assignment goes only in your slice's own files here. `reach work` opens a slice.
- `extracurricular/` is your own code folder, for anything you want to build that is not an assignment. It is never graded or submitted. `reach work --extracurricular` opens it.

Your AI partner puts code in files in one of these folders, not in the chat. While you are signed in and working on an assignment, what you and your AI partner say is recorded for your instructors, without your name on it (see Privacy below); nothing said in `extracurricular/` is recorded, and its files stay on your computer (see Privacy below).

## Choosing a model in Hermes

If you use Hermes, the model behind it decides whether your AI partner keeps the course rules. Claude Sonnet or Opus, and OpenAI GPT-5.x, through Hermes' own providers, are the models known to fit the course. Local open-weight models are not recommended until your instructor has checked one. Qwen3-Coder-30B was tried and did not keep the course rules: it talked code with the student and called failing work ready.

## If something looks wrong

Run `reach doctor`. It checks your Ruby, your course rules, your keys and your connection, and tells you the one command that fixes whatever it finds.

If rEach itself breaks, it tells your instructors on its own. You'll see one short note saying it reported a technical problem. You don't need to do anything or ask for help about it, and you can keep working. The report says where rEach failed and what version you have. It never includes what you typed or your code.

## A live session with your instructor

When something in rEach does not work and a normal request for help is not enough, you can ask for a live session. Tell your AI partner "ask my instructor for a live session". rEach asks you first, and the session opens only when you type yes and an instructor accepts. An instructor can also offer you one. rEach then asks you, and you can say no.

While a session is open, your instructors can see what rEach itself records on your computer: what rEach did and when. They do not see what you type, your AI partner's replies, your code or your files. Two things always need your yes. rEach asks you before it runs any check your instructor requests, and it shows you every message your AI partner wants to send them, word for word, before it goes out. You can end the session at any time by saying so. It also ends by itself after an hour unless your instructor extends it.

If rEach is not letting your messages through at all, you can still get a live session. Type a message with the words "live session" in it. rEach asks you its question right under its notice, and you answer yes or no. What your instructor writes and each check they ask for show up the same way. To stop, type "end live session".

When your instructor writes while you are waiting, rEach shows a small notification on your screen. On a recent Claude Code your AI partner also picks it up by itself. If nothing new shows in the chat, type anything.

## What rEach remembers about you

The answers you give rEach in its interview are saved in a profile, on your
computer only. Ask rEach "what do you know about me?" anytime to see or
change it, or say "forget my profile" to delete it. It is never sent to the
course server, unless you say yes when rEach asks the instructors for help.

## Privacy

rEach sends your submitted slice files, your enrollment details, your own-part answers and, when your AI partner asks for help, a short summary with your recent changes to the course server. While you are signed in and working on an assignment, rEach also records the conversation (what you type, and your AI partner's replies, reasoning, actions, the output of its tools and commands, and assignment code) and sends it to the course server in the background while you work, about every ten minutes, where your instructors can read it. It is sent under a random label, with your name, email, student ID and computer details replaced by placeholders; your instructors can reveal whose conversation it is, and each reveal is logged. Nothing is recorded before you sign in, in your extracurricular folder or outside your course folder. Ask rEach to export your conversations to save your own copy as a ZIP in Downloads. To keep your enrollment yours, rEach also sends a scrambled fingerprint of this computer and computer account (never your files or passwords), which your course server checks; if your rEach is copied to another computer or account, it locks until you enroll there. rEach does not send other files on your computer, or anything else outside your course folders. What rEach learns about you, in its interview and from what you type, is saved on this computer only; the interview profile is shared with your instructors only if you agree to add it when asking for help, and `reach profile forget` deletes it. When rEach hits an error it sends your course server a short report of where it happened. The report holds no files, typed text or replies. Like any chat, what you type to rEach goes to the AI provider you use.

The same thing as a picture: [the privacy map](architecture.md#7-the-privacy-map), one of ten figures in [`architecture.md`](architecture.md) that show how rEach and your course server fit together.
