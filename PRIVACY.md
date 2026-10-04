# rEach Privacy Policy

rEach is the academic assistant for students in a course run on Teach. It is published by PatḗrasAI. This policy covers rEach and the "rEach" listing in the ChatGPT and Codex plugin directory, which only installs rEach.

## Who receives your information

rEach runs on your computer. It sends course information only to your course server: the Teach server your instructors run for your course. Your instructors control that server and what it keeps. PatḗrasAI runs no server that receives your course work or your conversations.

rEach downloads itself and its updates from its public GitHub repository, so GitHub sees those downloads like any other web request.

## What rEach sends to your course server

- Your enrollment details: the course passkey your instructor gave you, a security key rEach creates on your computer, and the rEach version, operating system and Ruby version.
- Your submitted assignment files, and only when you say yes to submitting.
- Your answers to the questions in each assignment that only you can answer.
- When your AI assistant asks your instructors for help: a short summary with your recent changes.
- A scrambled fingerprint of your computer and computer account, never your files or passwords, so your course server can tell that your enrollment is used on the computer it was made on.
- When rEach hits an error: a short report of where it happened, with no files, typed text or replies. While debug mode is on, these reports can include message text.

rEach also asks your course server whether anything changed (new course materials, grades, replies to your questions, receipts). It does this every few minutes while your AI assistant is open and about every 15 minutes in the background, even when no assistant is open. Each check sends only rEach's signed check from your computer: no files and nothing from your conversations. If the answer is that something changed, rEach then fetches it the same way `reach sync` does. To turn the background check off, set `subscribe.background` to `false` in rEach's `config.yml` or run `reach subscribe uninstall`. `REACH_SUBSCRIBE=0` turns off every check.

## What rEach does not send

- Your conversations. Nothing you type, and none of your AI assistant's replies, reasoning or actions, is recorded or sent, in any folder.
- Other files on your computer, or anything outside your course folders.
- The files in your extracurricular folder.

## What stays on your computer

- Your profile: the answers you give rEach in its short interview. It is shared with your instructors only if you say yes when rEach asks them for help. Say "forget my profile" to delete it.
- What rEach learns about how you like to work, from what you type. Ask rEach "what do you know about me?" to see it, or ask it to forget.
- A copy of each submission, saved in your Downloads folder, and your submission receipts.

## Codex's settings

If you use Codex, rEach asks before it changes Codex's own settings file on your computer (`config.toml` in Codex's folder), so Codex's commands can use the internet and save inside your reach-work folder. It changes only those settings, saves a copy of your old settings beside the file first, and never sends the file anywhere. If you say no, nothing changes. `reach codex off` stops rEach putting its settings back.

## Your AI provider

Like any chat, what you type to your AI assistant goes to the AI provider you use (for example OpenAI for Codex), under that provider's own privacy policy.

## Grades

Nothing rEach saves about you changes your grade. Your grade of record is kept by your school, not by rEach.

## Contact

For questions about this policy, open an issue at https://github.com/SteveBenner/rEach/issues. For questions about what your course server keeps, ask your instructors.
